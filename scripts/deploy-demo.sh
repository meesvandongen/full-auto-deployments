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
      -c user.email='demo@localhost' commit -m "Seed $repo"
    git -C "$seed_dir" remote add origin "http://localhost:3000/demo/$repo.git"
  fi
  GIT_ASKPASS="$PWD/scripts/git-askpass.sh" GIT_TERMINAL_PROMPT=0 \
    git -C "$seed_dir" -c credential.helper= -c credential.interactive=always \
    push origin main
}

seed_repo demo-app-chart
seed_repo app-of-apps
kubectl apply -f seeds/app-of-apps/kargo/project.yaml
kubectl wait --for=create namespace/demo --timeout=120s
kubectl -n demo create secret generic gitops-repo \
  --from-literal=repoURL=https://gitea:3443/demo/demo-app-chart.git \
  --from-literal=username=demo \
  --from-literal=password="$GITEA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml |
  kubectl label --local -f - kargo.akuity.io/cred-type=git -o yaml |
  kubectl apply -f -
kubectl apply -f platform/root-application.yaml
kubectl -n argocd wait application/app-of-apps \
  --for=jsonpath='{.status.sync.status}'=Synced --timeout=120s
seed_repo demo-app-code
echo "Demo pipeline installed. Watch: kubectl -n demo get freight,promotions,stages -w"
