# Local GitOps platform

This repository contains a small Python HTTP application and a fully local
CI/GitOps pipeline: Gitea Actions tests and builds an image, Kargo promotes it
through dev and prod, Argo CD reconciles Git, and Argo Rollouts verifies a
canary before completing an update.

## Requirements

Docker with Compose, `k3d`, `kubectl`, Helm, the Kargo CLI, `openssl`, and `curl`.
On macOS, `brew install k3d kargo kubernetes-cli helm` installs the less common
tools. Allow several GB of memory and internet access for the initial image and
chart pulls.

Run:

```sh
bash scripts/up.sh
```

The script can be rerun. It creates a single-node k3d cluster (`k3d-full-auto`),
a Docker network, a persistent local Gitea server and OCI registry, a Gitea
Actions runner, cert-manager, Argo CD, Argo Rollouts, and Kargo. It also creates
the `demo/full-auto` Gitea repository and registers it with Argo CD. No GitHub
repository is needed at runtime. Kargo will use this same local Git server when
its Stages and Warehouse are defined with the application.

## URLs

| Service | URL from your Mac | Access |
| --- | --- | --- |
| Gitea | http://localhost:3000 | Available after `scripts/up.sh` |
| Demo repository and CI runs | http://localhost:3000/demo/full-auto and http://localhost:3000/demo/full-auto/actions | Available after the initial push |
| Image registry tags | http://localhost:5001/v2/demo-app/tags/list | Available after the first successful CI build |
| Argo CD | https://localhost:8081 | Port-forward required |
| Kargo | https://localhost:8082 | Port-forward required |
| Dev app | http://localhost:8083/api/double?value=21 | Port-forward required |
| Prod app | http://localhost:8084/api/double?value=21 | Port-forward required |

Run each port-forward you need in a separate terminal (they remain active
until stopped):

```sh
kubectl -n argocd port-forward svc/argocd-server 8081:443
kubectl -n kargo port-forward svc/kargo-api 8082:443
kubectl -n demo-dev port-forward svc/demo-app 8083:80
kubectl -n demo-prod port-forward svc/demo-app 8084:80
```

The app also serves `/livez`, `/readyz`, `/check`, and `/metrics` on either
app URL. Argo CD and Kargo use self-signed certificates; accept the local
browser warnings.

These addresses are for components running **inside** Docker or Kubernetes,
not for a browser on your Mac:

| Component | Internal address |
| --- | --- |
| Gitea Git repository | `https://gitea:3443/demo/full-auto.git` |
| Registry used for image pulls | `registry:5000` |
| Registry used by Kargo for image discovery | `registry:5443` |

Generated passwords and the runner token are kept in `.local/credentials.env`
(ignored by Git). The Gitea and Kargo administrator username is `demo` and
`admin`, respectively. Retrieve the Argo CD initial password with
`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
The other passwords are in `.local/credentials.env`; do not commit that file.

Once this repository has an initial commit, push it to the local Gitea remote.
The bootstrap does **not** silently commit or push your working tree:

```sh
git remote add local http://localhost:3000/demo/full-auto.git
set -a; . .local/credentials.env; set +a
GIT_ASKPASS="$PWD/scripts/git-askpass.sh" GIT_TERMINAL_PROMPT=0 \
  git -c credential.helper= -c credential.interactive=always push -u local HEAD:main
bash scripts/deploy-demo.sh
```

The workflow in `.gitea/workflows/build.yaml` runs containerized unit and HTTP
tests on each push to `main`. If they pass, it publishes an immutable
`build-<run number>-<commit>` tag to the local registry. Kargo's Warehouse
discovers that image; auto-promotion updates stage-specific Git branches,
syncs Argo CD, verifies dev, then promotes the *same* image to prod. Kargo
copies the Helm chart from `main`, updates `image.tag` in its values on
`stage/*`, and Argo CD renders that chart. It cannot retrigger the build on
`main`.

The app implements `/api/double?value=21`, `/livez`, `/readyz`, `/check`, and
`/metrics`. Kubernetes probes use the liveness and readiness endpoints. Argo
Rollouts calls `/check` through its canary-only Service using a web
`AnalysisTemplate`: a bad result aborts the rollout before it becomes stable.
Kargo waits for Argo CD health and independently checks `/api/double` before
making dev Freight eligible for prod. Requests are logged as JSON to stdout;
`/metrics` exposes simple Prometheus-format request counters, but no
Prometheus server is needed for the current web-based checks.

To inspect the deployment:

```sh
kubectl -n demo get warehouses,freight,stages,promotions
kubectl -n demo-dev get rollouts,analysisruns
kubectl -n demo-prod get rollouts,analysisruns
curl 'http://localhost:8083/api/double?value=21'
```

For a canary-abort demonstration, set `faultMode: true` in the chart's
`values.yaml`, commit, and push to local `main`. Tests still run, but `/check`
reports a failed check while `/readyz` remains healthy. Rollouts should abort dev and Kargo must not
promote that image to prod. Restore the setting in a subsequent commit to
resume with a new image. This is a deliberate demo fault, not a way to skip
tests.

The runner and its jobs have access to the host Docker socket and this setup
binds an unauthenticated HTTP registry to loopback. Kargo's internal HTTPS
Git and registry endpoints use generated self-signed certificates with
verification disabled in the local clients. Use this only on a trusted local
development machine. Running entirely without internet after setup also requires
mirroring or caching all controller, runner-job, and application images. The
workflow does not download any third-party Actions.

To pause the Docker services: `docker compose --env-file .local/credentials.env stop`.
To stop the cluster: `k3d cluster stop full-auto`. These commands preserve the
named volumes and Git data; `bash scripts/up.sh` starts them again.
