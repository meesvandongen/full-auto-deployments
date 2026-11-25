#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
source .local/credentials.env
kubectl config use-context k3d-full-auto >/dev/null

if ! git ls-remote http://localhost:3000/demo/full-auto.git refs/heads/main |
  grep -q 'refs/heads/main'; then
  echo "Push an initial commit to the local Gitea main branch first." >&2
  exit 1
fi

kubectl apply -f platform/project.yaml
kubectl wait --for=create namespace/demo --timeout=120s
kubectl -n demo create secret generic gitops-repo \
  --from-literal=repoURL=http://gitea:3000/demo/full-auto.git \
  --from-literal=username=demo \
  --from-literal=password="$GITEA_ADMIN_PASSWORD" \
  --dry-run=client -o yaml |
  kubectl label --local -f - kargo.akuity.io/cred-type=git -o yaml |
  kubectl apply -f -
kubectl apply -f platform/applications.yaml
kubectl apply -f platform/pipeline.yaml
echo "Demo pipeline installed. Watch: kubectl -n demo get freight,promotions,stages -w"
