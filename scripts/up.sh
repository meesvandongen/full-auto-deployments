#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for command in docker k3d kubectl helm kargo openssl curl python3; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done
docker info >/dev/null

umask 077
mkdir -p .local
if [[ ! -f .local/credentials.env ]]; then
  if docker volume inspect full-auto-deployments_gitea-data >/dev/null 2>&1; then
    echo "Existing demo found. Copy .local/credentials.env from its original checkout before starting this worktree." >&2
    exit 1
  fi
  {
    printf 'GITEA_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'GITEA_RUNNER_REGISTRATION_TOKEN=%s\n' "$(openssl rand -hex 24)"
    printf 'KARGO_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'KARGO_SIGNING_KEY=%s\n' "$(openssl rand -hex 32)"
    printf 'PACT_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)"
  } > .local/credentials.env
fi
if ! grep -q '^PACT_DB_PASSWORD=' .local/credentials.env; then
  printf 'PACT_DB_PASSWORD=%s\n' "$(openssl rand -hex 24)" >> .local/credentials.env
fi
set -a
source .local/credentials.env
set +a
if [[ ! -f .local/registry.crt || ! -f .local/registry.key ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -subj '/CN=registry' -addext 'subjectAltName=DNS:registry' \
    -keyout .local/registry.key -out .local/registry.crt >/dev/null 2>&1
fi
if [[ ! -f .local/gitea.crt || ! -f .local/gitea.key ]]; then
  openssl req -x509 -newkey rsa:2048 -nodes -days 365 \
    -subj '/CN=gitea' -addext 'subjectAltName=DNS:gitea' \
    -keyout .local/gitea.key -out .local/gitea.crt >/dev/null 2>&1
fi

compose() {
  docker compose --env-file .local/credentials.env "$@"
}

if ! docker network inspect full-auto >/dev/null 2>&1; then
  docker network create full-auto >/dev/null
fi
compose up -d gitea gitea-tls registry registry-tls

ready=false
for ((attempt = 0; attempt < 90; attempt++)); do
  if curl --silent --fail http://localhost:3000/api/healthz >/dev/null; then
    ready=true
    break
  fi
  sleep 2
done
if [[ "$ready" != true ]]; then
  echo "Gitea did not become ready; inspect 'docker compose logs gitea'." >&2
  exit 1
fi

status="$(curl --silent --output /dev/null --write-out '%{http_code}' http://localhost:3000/api/v1/users/demo)"
if [[ "$status" == 404 ]]; then
  compose exec -T -u git gitea gitea admin user create \
    --username demo --password "$GITEA_ADMIN_PASSWORD" \
    --email demo@localhost --admin --must-change-password=false
elif [[ "$status" != 200 ]]; then
  echo "Cannot check Gitea administrator (HTTP $status)." >&2
  exit 1
fi
curl --silent --fail --user "demo:$GITEA_ADMIN_PASSWORD" \
  http://localhost:3000/api/v1/user >/dev/null

for repo in demo-app-code demo-app-chart demo-echo-code demo-echo-chart app-of-apps delivery-config; do
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
    --user "demo:$GITEA_ADMIN_PASSWORD" "http://localhost:3000/api/v1/repos/demo/$repo")"
  if [[ "$status" == 404 ]]; then
    curl --silent --show-error --fail --user "demo:$GITEA_ADMIN_PASSWORD" \
      --header 'Content-Type: application/json' \
      --data "{\"name\":\"$repo\",\"default_branch\":\"main\"}" \
      http://localhost:3000/api/v1/user/repos >/dev/null
  elif [[ "$status" != 200 ]]; then
    echo "Cannot check the local $repo repository (HTTP $status)." >&2
    exit 1
  fi
done
compose up -d runner

if ! k3d cluster list --no-headers | awk '{print $1}' | grep -qx full-auto; then
  k3d cluster create full-auto --network full-auto --registry-config registries.yaml \
    --port '127.0.0.1:8443:443@loadbalancer'
else
  k3d cluster start full-auto
fi
ingress_port="$(docker port k3d-full-auto-serverlb 443/tcp 2>/dev/null || true)"
if [[ -z "$ingress_port" ]]; then
  k3d node edit k3d-full-auto-serverlb --port-add '127.0.0.1:8443:443'
elif [[ "$ingress_port" != '127.0.0.1:8443' ]]; then
  echo "Unexpected k3d ingress port mapping: $ingress_port" >&2
  exit 1
fi
kubectl config use-context k3d-full-auto >/dev/null

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo add jetstack https://charts.jetstack.io --force-update
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ --force-update
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
helm repo add kubeshop https://kubeshop.github.io/helm-charts --force-update
helm repo add pact-broker https://pact-foundation.github.io/pact-broker-chart/ --force-update
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --version v1.21.3 --namespace cert-manager --create-namespace \
  --set crds.enabled=true --wait --timeout 10m
helm upgrade --install argocd argo/argo-cd \
  --version 10.19.1 --namespace argocd --create-namespace \
  --wait --timeout 10m
helm upgrade --install argo-rollouts argo/argo-rollouts \
  --version 2.43.12 --namespace argo-rollouts --create-namespace \
  --wait --timeout 10m
helm upgrade --install headlamp headlamp/headlamp \
  --version 0.46.0 --namespace headlamp --create-namespace \
  --set serviceAccount.name=headlamp \
  --set clusterRoleBinding.clusterRoleName=view \
  --wait --timeout 10m
kubectl apply -f platform/headlamp-rbac.yaml
helm upgrade --install prometheus prometheus-community/prometheus \
  --version 30.0.1 --namespace monitoring --create-namespace \
  --values platform/prometheus-values.yaml --wait --timeout 10m
helm upgrade --install testkube kubeshop/testkube \
  --version 2.15.3 --namespace testkube --create-namespace \
  --set installCRDs=true \
  --set mongodb.enabled=false --set postgresql.enabled=true \
  --set testkube-api.mongodb.enabled=false --set testkube-api.postgresql.enabled=true \
  --set testkube-api.analyticsEnabled=false --wait --timeout 10m

kubectl create namespace pact --dry-run=client -o yaml | kubectl apply -f -
kubectl -n pact create secret generic pact-db \
  --from-literal=password="$PACT_DB_PASSWORD" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f platform/pact-postgres.yaml
kubectl -n pact rollout status statefulset/pact-postgres --timeout=5m
helm upgrade --install pact-broker pact-broker/pact-broker \
  --version 6.6.0 --namespace pact \
  --values platform/pact-broker-values.yaml --wait --timeout 10m
broker_port="$(docker port k3d-full-auto-serverlb 30929/tcp 2>/dev/null || true)"
if [[ -z "$broker_port" ]]; then
  k3d node edit k3d-full-auto-serverlb --port-add '127.0.0.1:9292:30929'
elif [[ "$broker_port" != '127.0.0.1:9292' ]]; then
  echo "Unexpected Pact Broker port mapping: $broker_port" >&2
  exit 1
fi
curl --fail --retry 20 --retry-delay 2 http://localhost:9292/ >/dev/null
for environment in dev prod; do
  if ! curl --fail --silent --show-error http://localhost:9292/environments |
    python3 -c 'import json,sys; names = {e["name"] for e in json.load(sys.stdin)["_embedded"]["environments"]}; sys.exit(sys.argv[1] not in names)' "$environment"; then
    flags=(--name "$environment" --display-name "$environment")
    if [[ "$environment" == prod ]]; then
      flags+=(--production)
    else
      flags+=(--no-production)
    fi
    docker run --rm --network full-auto \
      -e PACT_BROKER_BASE_URL=http://k3d-full-auto-server-0:30929 \
      pactfoundation/pact-cli@sha256:328565c63fcd516c91ab9a3787231424e55ba22c05b082ab648dd67d841b47d9 \
      pact-broker create-environment "${flags[@]}"
  fi
done

kubectl create namespace kargo --dry-run=client -o yaml | kubectl apply -f -
password_hash="$(printf '%s' "$KARGO_ADMIN_PASSWORD" | kargo hash-password --password-stdin)"
kubectl -n kargo create secret generic kargo-admin \
  --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="$password_hash" \
  --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="$KARGO_SIGNING_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version 1.12.7 --namespace kargo --set api.secret.name=kargo-admin \
  --wait --timeout 10m

for repo in demo-app-chart demo-echo-chart app-of-apps delivery-config; do
  kubectl -n argocd create secret generic "local-$repo" \
    --from-literal=type=git \
    --from-literal=url="https://gitea:3443/demo/$repo.git" \
    --from-literal=username=demo \
    --from-literal=password="$GITEA_ADMIN_PASSWORD" \
    --from-literal=insecure=true \
    --dry-run=client -o yaml |
    kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml |
    kubectl apply -f -
done

for namespace in demo-dev demo-prod echo-dev echo-prod; do
  kubectl create namespace "$namespace" --dry-run=client -o yaml | kubectl apply -f -
done
kubectl apply -f platform/ingress.yaml

echo "Infrastructure is ready. See README.md for access and the next steps."
