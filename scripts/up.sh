#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

for command in docker k3d kubectl helm kargo openssl curl; do
  if ! command -v "$command" >/dev/null 2>&1; then
    echo "Missing required command: $command" >&2
    exit 1
  fi
done
docker info >/dev/null

umask 077
mkdir -p .local
if [[ ! -f .local/credentials.env ]]; then
  {
    printf 'GITEA_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'GITEA_RUNNER_REGISTRATION_TOKEN=%s\n' "$(openssl rand -hex 24)"
    printf 'KARGO_ADMIN_PASSWORD=%s\n' "$(openssl rand -hex 24)"
    printf 'KARGO_SIGNING_KEY=%s\n' "$(openssl rand -hex 32)"
  } > .local/credentials.env
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

status="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  --user "demo:$GITEA_ADMIN_PASSWORD" http://localhost:3000/api/v1/repos/demo/full-auto)"
if [[ "$status" == 404 ]]; then
  curl --silent --show-error --fail --user "demo:$GITEA_ADMIN_PASSWORD" \
    --header 'Content-Type: application/json' \
    --data '{"name":"full-auto","default_branch":"main"}' \
    http://localhost:3000/api/v1/user/repos >/dev/null
elif [[ "$status" != 200 ]]; then
  echo "Cannot check the local Git repository (HTTP $status)." >&2
  exit 1
fi
compose up -d runner

if ! k3d cluster list --no-headers | awk '{print $1}' | grep -qx full-auto; then
  k3d cluster create full-auto --network full-auto --registry-config registries.yaml
else
  k3d cluster start full-auto
fi
kubectl config use-context k3d-full-auto >/dev/null

helm repo add argo https://argoproj.github.io/argo-helm --force-update
helm repo add jetstack https://charts.jetstack.io --force-update
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

kubectl create namespace kargo --dry-run=client -o yaml | kubectl apply -f -
password_hash="$(printf '%s' "$KARGO_ADMIN_PASSWORD" | kargo hash-password --password-stdin)"
kubectl -n kargo create secret generic kargo-admin \
  --from-literal=ADMIN_ACCOUNT_PASSWORD_HASH="$password_hash" \
  --from-literal=ADMIN_ACCOUNT_TOKEN_SIGNING_KEY="$KARGO_SIGNING_KEY" \
  --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install kargo oci://ghcr.io/akuity/kargo-charts/kargo \
  --version 1.12.7 --namespace kargo --set api.secret.name=kargo-admin \
  --wait --timeout 10m

kubectl -n argocd create secret generic local-gitea \
  --from-literal=type=git \
  --from-literal=url=https://gitea:3443/demo/full-auto.git \
  --from-literal=username=demo \
  --from-literal=password="$GITEA_ADMIN_PASSWORD" \
  --from-literal=insecure=true \
  --dry-run=client -o yaml |
  kubectl label --local -f - argocd.argoproj.io/secret-type=repository -o yaml |
  kubectl apply -f -

echo "Infrastructure is ready. See README.md for access and the next steps."
