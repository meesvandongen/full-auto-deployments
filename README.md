# Local GitOps platform

This is the infrastructure repository (published on GitHub). It holds
bootstrap scripts and one-time seeds in `seeds/`; **it is not pushed to local
Gitea**. The bootstrap creates six independent local Git repositories:

| Repository | Owner of desired state |
| --- | --- |
| `demo/demo-app-code` | Python application, Dockerfile, and Gitea Actions CI |
| `demo/demo-app-chart` | Helm chart; Kargo writes `stage/dev` and `stage/prod` branches |
| `demo/demo-echo-code` | Independent greeting application, Dockerfile, and CI |
| `demo/demo-echo-chart` | Independent Helm chart and stage branches |
| `demo/app-of-apps` | Only Argo CD child Application definitions |
| `demo/delivery-config` | Per-app Kargo pipelines and Testkube load workflows |

Gitea Actions tests code and publishes an image; Kargo promotes the image by
updating the chart repository; Argo CD reconciles the app-of-apps and chart
repositories; Argo Rollouts verifies a canary before completing an update.

## Requirements

Docker with Compose, `k3d`, `kubectl`, Helm, the Kargo CLI, `openssl`, and `curl`.
On macOS, `brew install k3d kargo kubernetes-cli helm` installs the less common
tools. `brew install testkube` is optional for manually running synthetic
tests. Allow several GB of memory and internet access for the initial image and
chart pulls.

Run:

```sh
bash scripts/up.sh
bash scripts/deploy-demo.sh
```

The script can be rerun. It creates a single-node k3d cluster (`k3d-full-auto`),
a Docker network, a persistent local Gitea server and OCI registry, a Gitea
Actions runner, cert-manager, Argo CD, Argo Rollouts, Kargo, Headlamp, a
small Prometheus server, and the standalone Testkube runner. The deploy
script seeds the six Gitea repositories from `seeds/` only if they have no
`main` branch, then bootstraps the root Argo CD Application, Kargo Projects,
and local Git credentials. Subsequent runs leave the Git histories alone. GitHub
hosts the infrastructure repository; no hosted Git service is needed during
the demo's deployment flow.

## URLs

| Service | URL from your Mac | Access |
| --- | --- | --- |
| Gitea | http://localhost:3000 | Available after `scripts/up.sh` |
| Double app code and CI | http://localhost:3000/demo/demo-app-code and http://localhost:3000/demo/demo-app-code/actions | Available after `scripts/deploy-demo.sh` |
| Double app Helm chart | http://localhost:3000/demo/demo-app-chart | Available after `scripts/deploy-demo.sh` |
| Echo app code and CI | http://localhost:3000/demo/demo-echo-code and http://localhost:3000/demo/demo-echo-code/actions | Available after `scripts/deploy-demo.sh` |
| Echo app Helm chart | http://localhost:3000/demo/demo-echo-chart | Available after `scripts/deploy-demo.sh` |
| App-of-apps repository | http://localhost:3000/demo/app-of-apps | Available after `scripts/deploy-demo.sh` |
| Delivery configuration repository | http://localhost:3000/demo/delivery-config | Available after `scripts/deploy-demo.sh` |
| Image registry tags | http://localhost:5001/v2/_catalog | Available after successful CI builds |
| Argo CD | https://argocd.localhost:8443 | In-cluster Traefik ingress |
| Kargo | https://kargo.localhost:8443 | In-cluster Traefik ingress |
| Double dev / prod | https://dev.localhost:8443/api/double?value=21 and https://prod.localhost:8443/api/double?value=21 | In-cluster Traefik ingress |
| Echo dev / prod | https://echo-dev.localhost:8443/api/greet?name=World and https://echo-prod.localhost:8443/api/greet?name=World | In-cluster Traefik ingress |
| Headlamp (cluster resources) | https://headlamp.localhost:8443 | Login token required |
| Prometheus (metrics/queries) | https://prometheus.localhost:8443 | In-cluster Traefik ingress |

`*.localhost` resolves to your computer's loopback address without a DNS
server. k3d maps only `127.0.0.1:8443` into Traefik, which routes by hostname;
include both `https://` and `:8443` in the browser. Traefik uses a local
self-signed certificate, so accept the browser warning. The app also serves
`/livez`, `/readyz`, `/check`, and `/metrics` on either app hostname.

Headlamp is a web app inside the cluster. Log in with a short-lived,
read-only service-account token generated locally:

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
| Double chart Git repository | `https://gitea:3443/demo/demo-app-chart.git` |
| Echo chart Git repository | `https://gitea:3443/demo/demo-echo-chart.git` |
| App-of-apps Git repository | `https://gitea:3443/demo/app-of-apps.git` |
| Delivery configuration Git repository | `https://gitea:3443/demo/delivery-config.git` |
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

The echo pipeline works the same way: clone `demo/demo-echo-code`, edit, commit,
and push its own `main` branch. Its image, Warehouse, stages, Helm chart,
verification, and CI runs are independent of the double app.

Push infrastructure changes to GitHub with `git push origin main` from this
directory; that does not trigger a demo deployment. Edit each Helm chart,
app-of-apps, or delivery configuration in its own Gitea clone if needed. Chart
`main` changes are copied to stage branches with the **next image promotion**;
app-of-apps and delivery-config `main` are auto-synced by Argo CD.
The app-of-apps root manages only child Applications. Auto-prune is enabled for
the root, delivery resources, and application workloads; child Application
finalizers ensure removals clean up their resources. Kargo Projects are
bootstrapped separately and deliberately excluded from auto-prune because
deleting a Project also deletes its namespace and promotion history.
The `seeds/` copies are templates for **initial bootstrap**, not working
clones or additional Git remotes for this checkout.

Each code repo's Gitea workflow runs containerized unit and HTTP tests on
pushes to `main`. If they pass, it publishes an immutable image tag to the
local registry. Each app's Kargo Warehouse discovers its image; auto-promotion
updates stage-specific Git branches,
syncs Argo CD, verifies dev, then promotes the *same* image to prod. Kargo
copies the Helm chart from `main`, updates `image.tag` in its values on
`stage/*`, and Argo CD renders that chart. It cannot retrigger the build on
`main`.

Both apps implement `/livez`, `/readyz`, `/check`, and `/metrics`; their business
endpoints are `/api/double?value=21` and `/api/greet?name=World`.
Kubernetes probes use the liveness and readiness endpoints. Argo Rollouts
calls `/check` through each canary-only Service, queries Prometheus for the
app's version-matched behavior gauge, and runs the Testkube
k6 workflow against that canary. A failing signal aborts the rollout; missing
gauge data cannot count as success.
Kargo waits for Argo CD health, checks the business endpoint, and reruns the k6
Test Workflow against the stable stage before making dev Freight eligible for
prod. The workflow sends about ten requests per second for twelve seconds and
fails on incorrect answers, HTTP errors above 1%, or
95th-percentile latency above one second. Testkube runs entirely inside the
cluster; its standalone mode has no local web dashboard. Requests are logged
as JSON to stdout; `/metrics` exposes Prometheus-format counters and the
behavior gauge. Prometheus scrapes both apps' dev and prod canary Services every
five seconds. The gauge is a synthetic functional check, not a production SLO:
evaluating real
error rates or latency would also require representative traffic, a time
window, and enough samples. CI unit/HTTP tests, Kubernetes readiness, Rollouts
analysis, and Kargo's k6 verification are distinct gates.

To run the same synthetic load test manually and inspect its results locally
without uploading logs to a hosted viewer:

```sh
testkube set context --kubeconfig --namespace testkube
testkube run testworkflow demo-app-load \
  --config target=http://demo-app.demo-dev.svc.cluster.local --watch
testkube run testworkflow echo-app-load \
  --config target=http://echo-app.echo-dev.svc.cluster.local --watch
```

To inspect the deployment:

```sh
kubectl -n demo get warehouses,freight,stages,promotions
kubectl -n echo get warehouses,freight,stages,promotions
kubectl -n demo-dev get rollouts,analysisruns
kubectl -n echo-dev get rollouts,analysisruns
curl -k 'https://dev.localhost:8443/api/double?value=21'
curl -k 'https://echo-dev.localhost:8443/api/greet?name=World'
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
