# Local GitOps platform

This is the infrastructure repository (published on GitHub). It holds
bootstrap scripts and one-time seeds in `seeds/`; **it is not pushed to local
Gitea**. The bootstrap creates six independent local Git repositories:

| Repository | Owner of desired state |
| --- | --- |
| `demo/demo-app-code` | Python application, unit/k6 tests, Dockerfile, and Gitea Actions CI |
| `demo/demo-app-chart` | Helm chart; Kargo writes `stage/dev` and `stage/prod` branches |
| `demo/demo-echo-code` | Independent greeting application, unit/k6 tests, Dockerfile, and CI |
| `demo/demo-echo-chart` | Independent Helm chart and stage branches |
| `demo/app-of-apps` | Only Argo CD child Application definitions |
| `demo/delivery-config` | Per-app Kargo pipelines and Testkube workflow runners |

Gitea Actions tests code and publishes an image; Kargo promotes the image by
updating the chart repository; Argo CD reconciles the app-of-apps and chart
repositories; Argo Rollouts verifies a canary before completing an update.
Echo also consumes Double's `/api/double` endpoint. Pact contracts protect
that dependency before a candidate image is released, independently of the
existing k6 checks of deployed services.

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
small Prometheus server, the standalone Testkube runner, and a self-hosted
Pact Broker with persistent PostgreSQL in the `pact` namespace. The deploy
script seeds the six Gitea repositories from `seeds/` only if they have no
`main` branch, then bootstraps the root Argo CD Application, Kargo Projects,
and local Git credentials. On the first run, it waits until Double has reached
prod before seeding Echo, so the first consumer deployment can pass the Pact
gate. Subsequent runs leave the Git histories alone. GitHub
hosts the infrastructure repository; no hosted Git service is needed during
the demo's deployment flow.

When using a second worktree with an **already initialized** local platform,
copy `.local/credentials.env` from the original checkout into this worktree's
`.local/` before running `scripts/up.sh`. The script adds a new Pact database
password if necessary; it refuses to generate new Gitea credentials against an
existing Gitea volume. Compose uses the same fixed project name from either
worktree. The seed files do not update Gitea repositories that already have a
`main` branch. For an existing demo, migrate the corresponding Gitea repositories
deliberately (suspend Echo auto-promotion while updating its chart and code,
and record the already deployed Double version), or bootstrap a fresh local
platform. Rerunning the seed script alone will not update existing Gitea
histories.

## Endpoints and credentials

`*.localhost` resolves to your computer's loopback address without a DNS
server. k3d exposes only `127.0.0.1:8443` to Traefik; include **both**
`https://` and `:8443` in browser URLs. Accept the local self-signed
certificate warning. Gitea and the registry use separate loopback ports.

### Browser interfaces

| Interface | URL | Login |
| --- | --- | --- |
| Gitea | http://localhost:3000 | Public repositories are readable anonymously; administration uses `demo` / `GITEA_ADMIN_PASSWORD` |
| Argo CD (sync, health, rollouts) | https://argocd.localhost:8443 | `admin` / initial admin password from the Kubernetes Secret below |
| Kargo (Freight, Stages, promotions) | https://kargo.localhost:8443 | `admin` / `KARGO_ADMIN_PASSWORD` |
| Headlamp (cluster resources) | https://headlamp.localhost:8443 | Short-lived read-only Kubernetes token below |
| Prometheus (queries and targets) | https://prometheus.localhost:8443 | No login; loopback-only ingress |
| Pact Broker (contracts and compatibility matrix) | http://localhost:9292 | No login; local demo only |

Headlamp can view nodes, volumes, and Argo/Kargo resources but cannot read
Secrets or modify workloads. Standalone Testkube has **no local web UI**;
use its CLI with the `k3d-full-auto` kubeconfig context to inspect executions.

### Application HTTP endpoints

| Application | Dev | Prod | Login |
| --- | --- | --- | --- |
| Double | https://dev.localhost:8443/api/double?value=21 | https://prod.localhost:8443/api/double?value=21 | None |
| Echo | https://echo-dev.localhost:8443/api/greet?name=World | https://echo-prod.localhost:8443/api/greet?name=World | None |

Add `&value=7` to an Echo greeting URL to ask the Double provider for the
calculated value: a compatible response includes `"doubled":14`. Without
`value`, Echo keeps its original standalone behavior.

Each app also exposes `/livez` (liveness), `/readyz` (readiness), `/check`
(behavioral verification), and `/metrics` (Prometheus text format) at the
corresponding hostname, for example
`https://dev.localhost:8443/metrics`. The canary-only Services are internal;
Rollouts and Testkube use them to inspect the new version before promotion.

### Local Git repositories and image registry

All six repositories are available after `scripts/deploy-demo.sh`. Cloning
these public repositories requires no credentials; **pushing** requires
`demo` / `GITEA_ADMIN_PASSWORD` (the push example below uses the local
askpass script). The seed files in this infrastructure repo are not Git
remotes.

| Repository | Browser | Git clone URL from your Mac |
| --- | --- | --- |
| Double code and CI | http://localhost:3000/demo/demo-app-code/actions | `http://localhost:3000/demo/demo-app-code.git` |
| Double Helm chart | http://localhost:3000/demo/demo-app-chart | `http://localhost:3000/demo/demo-app-chart.git` |
| Echo code and CI | http://localhost:3000/demo/demo-echo-code/actions | `http://localhost:3000/demo/demo-echo-code.git` |
| Echo Helm chart | http://localhost:3000/demo/demo-echo-chart | `http://localhost:3000/demo/demo-echo-chart.git` |
| App-of-apps | http://localhost:3000/demo/app-of-apps | `http://localhost:3000/demo/app-of-apps.git` |
| Delivery configuration | http://localhost:3000/demo/delivery-config | `http://localhost:3000/demo/delivery-config.git` |

The local OCI registry needs **no authentication**: browse
http://localhost:5001/v2/_catalog and the tag lists at
http://localhost:5001/v2/demo-app-code/tags/list and
http://localhost:5001/v2/demo-echo-code/tags/list. CI pushes images through
`localhost:5001`; cluster nodes pull from `registry:5000`.

### Retrieve login credentials locally

From this repository root, after `scripts/up.sh`:

```sh
. .local/credentials.env
printf 'Gitea user: demo, password: %s\n' "$GITEA_ADMIN_PASSWORD"
printf 'Kargo user: admin, password: %s\n' "$KARGO_ADMIN_PASSWORD"
printf 'Argo CD user: admin, password: '
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n headlamp create token headlamp --duration=8h
```

Paste the last command's token into Headlamp. It expires after eight hours;
run the command again when needed. The Gitea Actions runner registration
token and Kargo signing key are generated in `.local/credentials.env` but
are **not user logins**. Argo CD and Kargo Git credentials are provisioned
automatically as Kubernetes Secrets. Do not commit `.local/credentials.env`
or paste any of its values into Git.

### Internal-only service addresses

These are reachable from containers or pods, **not** from your Mac's browser:

| Purpose | Internal endpoint | Credentials |
| --- | --- | --- |
| Gitea code clones in CI | `http://gitea:3000/demo/<code-repo>.git` | None for public read |
| Gitea charts, app-of-apps, delivery config for Argo CD/Kargo | `https://gitea:3443/demo/<repo>.git` | Auto-provisioned Gitea credentials; self-signed TLS |
| Image pulls | `registry:5000/<image>@sha256:<digest>` | None; HTTP registry mirror |
| Kargo image discovery | `https://registry:5443/<image>` | None; self-signed TLS |
| Argo CD API | `https://argocd-server.argocd.svc.cluster.local:443` | Argo CD authentication |
| Kargo API | `https://kargo-api.kargo.svc.cluster.local:443` | Kargo authentication |
| Prometheus API | `http://prometheus-server.monitoring.svc.cluster.local:80` | None; cluster-internal |
| Testkube standalone API | `http://testkube-api-server.testkube.svc.cluster.local:8088` | None; cluster-internal |
| Headlamp service | `http://headlamp.headlamp.svc.cluster.local:80` | Kubernetes token |
| Pact Broker in Kubernetes | `http://pact-broker.pact.svc.cluster.local` | None; CI uses `http://k3d-full-auto-server-0:30929` on the Docker network |

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
app-of-apps, or delivery configuration in its own Gitea clone if needed. A
chart `main` change creates Freight with the current image once CI has
published an image matching the latest code commit. It traverses the same
dev-to-prod gates as a code change.
App-of-apps and delivery-config `main` are auto-synced by Argo CD.
The app-of-apps root manages only child Applications. Auto-prune is enabled for
the root, delivery resources, and application workloads; child Application
finalizers ensure removals clean up their resources. Kargo Projects are
bootstrapped separately and deliberately excluded from auto-prune because
deleting a Project also deletes its namespace and promotion history.
The `seeds/` copies are templates for **initial bootstrap**, not working
clones or additional Git remotes for this checkout.

Each code repo's Gitea workflow runs unit tests, validates the running app's
Prometheus exposition with `promtool`, and runs its colocated k6 script against
the candidate image. Echo additionally tests its real Double HTTP client
against a Pact mock and publishes a versioned consumer contract using its Git
SHA. Its CI then runs the Double provider verifier against the provider's
current `main` commit; Double CI also runs that verifier on every provider
change. The verifier fetches Echo's main and deployed contracts from the
Broker and publishes results under the provider Git SHA. A failing
verification of an established pact prevents an image from being published;
a new pending pact may publish a failed result without breaking the provider
build, but `can-i-deploy` still blocks the incompatible consumer. Only then
does CI publish an image tagged with the CI run
number and full code commit SHA. Kargo's Warehouse discovers a matching image
and code commit together with a chart Git commit, creating one immutable
Freight tuple. A pending or failed CI build cannot pair an old image with new
code. Each PromotionTask checks out the **chart commit from that Freight**
(not mutable `main`) and writes its image digest, tag, and code/test commit
into the stage branch. Dev and prod promote the same Freight; Argo CD renders
the chart and Rollouts pulls the image by digest. Promotions never push to
code `main`, so they cannot retrigger CI.

The Testkube workflow definition is generic delivery configuration. Its k6
script lives in the code repository and is fetched at the commit pinned in
Freight. Argo CD applies the chart's AnalysisTemplate in an earlier sync wave
than the Rollout, so a new AnalysisRun uses the corresponding template.

### Release identity

The automatically generated image tag (`app-<run>-<full-code-SHA>` or
`echo-<run>-<full-code-SHA>`) is useful for tracing CI. The **digest** is the
deployment identity; the code and chart commit SHAs pin the test and
configuration. Semantic versioning is optional for human-facing releases or
compatibility policies, not needed to make this GitOps promotion reproducible.

### Pact release gate

The open-source Broker tracks `dev` and `prod` as distinct environments.
Before either app's Kargo PromotionTask changes a chart branch, its HTTP step
queries the Broker's `/matrix` endpoint for `can-i-deploy` compatibility with
the versions currently recorded in that environment. A missing or failed
verification stops the promotion. After Argo CD reports the new Rollout
healthy and synced, the task records the actual deployed Git SHA via the
Broker's deployment API. The provider can be deployed first with no consumers;
Echo cannot be deployed until the provider is recorded and verification
passed. The Broker is local-only, unauthenticated, and not suitable as a
production installation without access control and TLS.

To inspect compatibility after bootstrap, substitute an actual code Git SHA:

```sh
docker run --rm --network full-auto \
  -e PACT_BROKER_BASE_URL=http://k3d-full-auto-server-0:30929 \
  pactfoundation/pact-cli@sha256:328565c63fcd516c91ab9a3787231424e55ba22c05b082ab648dd67d841b47d9 \
  pact-broker can-i-deploy \
  --pacticipant echo-app --version ECHO_CODE_SHA --to-environment dev
kubectl -n pact get pods
```

For a contract-specific failure demo, change Double's `double()` function in
the **Gitea code clone** so that it returns a wrong result only for `value=7`
and push that commit. The Double unit/k6 checks still exercise `value=21`,
but Pact's provider verification rejects the candidate against Echo's
published expectation of `14`. CI does not push an incompatible image; the
Broker matrix shows that the candidate SHA cannot be deployed. Restore
compatibility in a subsequent commit. This is consumer-driven verification
against a running candidate, not an OpenAPI-only comparison.

### Stage rollback gap

On a failed canary, Rollouts aborts the update and keeps serving the stable
ReplicaSet; Kargo blocks that Freight from moving downstream. Neither
automatically reverts the Stage's Git branch to the last good revision in this
open-source setup. Recover the Git desired state by promoting a known-good
Freight, reverting the chart branch, or publishing a fix.

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
demo_freight=$(kubectl -n demo get stage dev -o jsonpath='{.status.freightSummary}')
demo_sha=$(kubectl -n demo get freight "$demo_freight" \
  -o jsonpath='{.commits[?(@.repoURL=="https://gitea:3443/demo/demo-app-code.git")].id}')
testkube run testworkflow demo-app-load \
  --config target=http://demo-app.demo-dev.svc.cluster.local \
  --config "revision=$demo_sha" --watch
echo_freight=$(kubectl -n echo get stage dev -o jsonpath='{.status.freightSummary}')
echo_sha=$(kubectl -n echo get freight "$echo_freight" \
  -o jsonpath='{.commits[?(@.repoURL=="https://gitea:3443/demo/demo-echo-code.git")].id}')
testkube run testworkflow echo-app-load \
  --config target=http://echo-app.echo-dev.svc.cluster.local \
  --config "revision=$echo_sha" --watch
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
branch. This creates a new Freight using the existing image and a new chart
commit; no code change is needed. CI already tested that image, but
`/check` reports a failed check while
`/readyz` remains healthy. Rollouts should abort dev and Kargo must not
promote that Freight to prod. Restore the chart setting in a subsequent
chart commit to resume with the same tested image. This is a deliberate demo
fault, not a way to skip tests.

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
