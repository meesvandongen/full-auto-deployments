# Local GitOps platform

This is the infrastructure repository (published on GitHub). It holds
bootstrap scripts and one-time seeds in `seeds/`; **it is not pushed to local
Gitea**. The bootstrap creates three independent local Git repositories:

| Repository | Owner of desired state |
| --- | --- |
| `demo/demo-app-code` | Python application, Dockerfile, and Gitea Actions CI |
| `demo/demo-app-chart` | Helm chart; Kargo writes `stage/dev` and `stage/prod` branches |
| `demo/app-of-apps` | Argo CD child Applications and Kargo project/pipeline |

Gitea Actions tests code and publishes an image; Kargo promotes the image by
updating the chart repository; Argo CD reconciles the app-of-apps and chart
repositories; Argo Rollouts verifies a canary before completing an update.

## Requirements

Docker with Compose, `k3d`, `kubectl`, Helm, the Kargo CLI, `openssl`, and `curl`.
On macOS, `brew install k3d kargo kubernetes-cli helm` installs the less common
tools. Allow several GB of memory and internet access for the initial image and
chart pulls.

Run:

```sh
bash scripts/up.sh
bash scripts/deploy-demo.sh
```

The script can be rerun. It creates a single-node k3d cluster (`k3d-full-auto`),
a Docker network, a persistent local Gitea server and OCI registry, a Gitea
Actions runner, cert-manager, Argo CD, Argo Rollouts, Kargo, Headlamp, and a
small Prometheus server. The deploy
script seeds the three Gitea repositories from `seeds/` only if they have no
`main` branch, then bootstraps the root Argo CD Application and local Git
credentials. Subsequent runs leave the three Git histories alone. GitHub
hosts the infrastructure repository; no hosted Git service is needed during
the demo's deployment flow.

## URLs

| Service | URL from your Mac | Access |
| --- | --- | --- |
| Gitea | http://localhost:3000 | Available after `scripts/up.sh` |
| Code repository and CI runs | http://localhost:3000/demo/demo-app-code and http://localhost:3000/demo/demo-app-code/actions | Available after `scripts/deploy-demo.sh` |
| Helm chart repository | http://localhost:3000/demo/demo-app-chart | Available after `scripts/deploy-demo.sh` |
| App-of-apps repository | http://localhost:3000/demo/app-of-apps | Available after `scripts/deploy-demo.sh` |
| Image registry tags | http://localhost:5001/v2/demo-app-code/tags/list | Available after the first successful CI build |
| Argo CD | https://localhost:8081 | Port-forward required |
| Kargo | https://localhost:8082 | Port-forward required |
| Dev app | http://localhost:8083/api/double?value=21 | Port-forward required |
| Prod app | http://localhost:8084/api/double?value=21 | Port-forward required |
| Headlamp (cluster resources) | http://localhost:8085 | Port-forward and login token required |
| Prometheus (metrics/queries) | http://localhost:9090 | Port-forward required |

Run each port-forward you need in a separate terminal (they remain active
until stopped):

```sh
kubectl -n argocd port-forward svc/argocd-server 8081:443
kubectl -n kargo port-forward svc/kargo-api 8082:443
kubectl -n demo-dev port-forward svc/demo-app 8083:80
kubectl -n demo-prod port-forward svc/demo-app 8084:80
kubectl -n headlamp port-forward svc/headlamp 8085:80
kubectl -n monitoring port-forward svc/prometheus-server 9090:80
```

The app also serves `/livez`, `/readyz`, `/check`, and `/metrics` on either
app URL. Argo CD and Kargo use self-signed certificates; accept the local
browser warnings. Headlamp is a web app inside the cluster. Log in with a
short-lived, read-only service-account token generated locally:

```sh
kubectl -n headlamp create token headlamp --duration=8h
```

Paste the token into Headlamp's login screen. The chart's default cluster-admin
binding is overridden with Kubernetes' `view` role plus read-only access to
nodes, volumes, and Argo/Kargo resources. It cannot read Secrets or modify
workloads. Do not expose this service outside localhost.

These addresses are for components running **inside** Docker or Kubernetes,
not for a browser on your Mac:

| Component | Internal address |
| --- | --- |
| Chart Git repository | `https://gitea:3443/demo/demo-app-chart.git` |
| App-of-apps Git repository | `https://gitea:3443/demo/app-of-apps.git` |
| Registry used for image pulls | `registry:5000` |
| Registry used by Kargo for image discovery | `registry:5443` |

Generated passwords and the runner token are kept in `.local/credentials.env`
(ignored by Git). The Gitea and Kargo administrator username is `demo` and
`admin`, respectively. Retrieve the Argo CD initial password with
`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
The other passwords are in `.local/credentials.env`; do not commit that file.

To check in an application change, clone the **code** repository once. Edit
and commit there; pushing `main` triggers the pipeline. From this infrastructure
directory:

```sh
git clone http://localhost:3000/demo/demo-app-code.git ../full-auto-demo-app-code
# Edit files in ../full-auto-demo-app-code, then commit there:
git -C ../full-auto-demo-app-code add -A
git -C ../full-auto-demo-app-code commit -m "Update demo app"
set -a; . .local/credentials.env; set +a
GIT_ASKPASS="$PWD/scripts/git-askpass.sh" GIT_TERMINAL_PROMPT=0 \
  git -C ../full-auto-demo-app-code -c credential.helper= \
  -c credential.interactive=always push origin main
```

Push infrastructure changes to GitHub with `git push origin main` from this
directory; that does not trigger a demo deployment. Edit the Helm chart or
app-of-apps configuration in their own Gitea clones if needed. Changes to the
chart's `main` branch are copied to stage branches with the **next image
promotion**, whereas changes to app-of-apps `main` are auto-synced by Argo CD.
The `seeds/` copies are templates for **initial bootstrap**, not working
clones or additional Git remotes for this checkout.

The workflow in `seeds/demo-app-code/.gitea/workflows/build.yaml` runs containerized unit and HTTP
tests on each push to `main`. If they pass, it publishes an immutable
`app-<run number>-<commit>` tag to the local registry. Kargo's Warehouse
discovers that image; auto-promotion updates stage-specific Git branches,
syncs Argo CD, verifies dev, then promotes the *same* image to prod. Kargo
copies the Helm chart from `main`, updates `image.tag` in its values on
`stage/*`, and Argo CD renders that chart. It cannot retrigger the build on
`main`.

The app implements `/api/double?value=21`, `/livez`, `/readyz`, `/check`, and
`/metrics`. Kubernetes probes use the liveness and readiness endpoints. Argo
Rollouts calls `/check` through its canary-only Service and queries Prometheus
for `demo_check_success` from the *new image version*: either failing signal
aborts the rollout. Missing gauge data also fails the analysis; it does not
count as success.
Kargo waits for Argo CD health and independently checks `/api/double` before
making dev Freight eligible for prod. Requests are logged as JSON to stdout;
`/metrics` exposes Prometheus-format request counters and the behavior gauge.
Prometheus scrapes the dev and prod canary Services every five seconds. The
gauge is a synthetic functional check, not a production SLO: evaluating real
error rates or latency would also require representative traffic, a time
window, and enough samples. CI unit/HTTP tests, Kubernetes readiness, Rollouts
analysis, and Kargo verification are distinct gates.

To inspect the deployment:

```sh
kubectl -n demo get warehouses,freight,stages,promotions
kubectl -n demo-dev get rollouts,analysisruns
kubectl -n demo-prod get rollouts,analysisruns
curl 'http://localhost:8083/api/double?value=21'
```

For a canary-abort demonstration, set `faultMode: true` in a clone of the
chart repository's `chart/values.yaml`, commit and push the chart `main`
branch, then push a code change to trigger a new image. Tests still run,
but `/check` reports a failed check while
`/readyz` remains healthy. Rollouts should abort dev and Kargo must not
promote that image to prod. Restore the chart setting and push another code
change to resume with a new image. This is a deliberate demo fault, not a way
to skip tests.

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
