#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
source .local/credentials.env
set +a
kubectl config use-context k3d-full-auto >/dev/null

seed_repo() {
  local repo="$1"
  local seed_dir=".local/seeds/$repo"
  if git ls-remote "http://localhost:3000/demo/$repo.git" refs/heads/main |
    grep -q 'refs/heads/main'; then
    return
  fi
  if [[ ! -d "$seed_dir/.git" ]]; then
    if [[ -e "$seed_dir" ]]; then
      echo "Cannot seed: $seed_dir exists without a Git repository." >&2
      exit 1
    fi
    mkdir -p "$seed_dir"
    cp -R "seeds/$repo/." "$seed_dir/"
    git -C "$seed_dir" init -b main
    git -C "$seed_dir" add -A
    git -C "$seed_dir" -c user.name='Demo Bootstrap' \
      -c user.email='demo@localhost' commit -m "Seed $repo" \
      -m 'Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>'
    git -C "$seed_dir" remote add origin "http://localhost:3000/demo/$repo.git"
  fi
  GIT_ASKPASS="$PWD/scripts/git-askpass.sh" GIT_TERMINAL_PROMPT=0 \
    git -C "$seed_dir" -c credential.helper= -c credential.interactive=always \
    push origin main
}

seed_repo demo-app-chart
seed_repo demo-echo-chart
seed_repo delivery-config
seed_repo app-of-apps
for project in demo echo; do
  kubectl apply -f "seeds/delivery-config/$project/project.yaml"
  kubectl wait --for=create "namespace/$project" --timeout=120s
done
for entry in demo:demo-app-chart echo:demo-echo-chart; do
  project="${entry%%:*}"
  chart_repo="${entry#*:}"
  kubectl -n "$project" create secret generic gitops-repo \
    --from-literal="repoURL=https://gitea:3443/demo/$chart_repo.git" \
    --from-literal=username=demo \
    --from-literal=password="$GITEA_ADMIN_PASSWORD" \
    --dry-run=client -o yaml |
    kubectl label --local -f - kargo.akuity.io/cred-type=git -o yaml |
    kubectl apply -f -
done
kubectl apply -f platform/root-application.yaml
kubectl -n argocd annotate application app-of-apps \
  argocd.argoproj.io/refresh=hard --overwrite
kubectl -n argocd wait application/app-of-apps \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=120s
for app in demo-delivery echo-delivery; do
  kubectl -n argocd wait --for=create "application/$app" --timeout=120s
  kubectl -n argocd wait "application/$app" \
    --for=jsonpath='{.status.sync.status}'=Synced --timeout=120s
done
seed_repo demo-app-code
if ! git ls-remote http://localhost:3000/demo/demo-echo-code.git refs/heads/main |
  grep -q 'refs/heads/main'; then
  kubectl -n demo wait stage/prod \
    --for=jsonpath='{.status.lastPromotion.status.phase}'=Succeeded --timeout=15m
fi
seed_repo demo-echo-code
echo "Demo pipelines installed. Watch: kubectl -n demo get freight,promotions,stages -w"
