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

| Service | Address |
| --- | --- |
| Gitea | http://localhost:3000 |
| Local registry (from host) | `localhost:5001` |
| Local registry (from cluster) | `registry:5000` |
| Registry HTTPS endpoint (Kargo image discovery) | `registry:5443` |
| Git URL (from host) | `http://localhost:3000/demo/full-auto.git` |
| Git URL (from cluster) | `https://gitea:3443/demo/full-auto.git` |

Generated passwords and the runner token are kept in `.local/credentials.env`
(ignored by Git). The Gitea and Kargo administrator username is `demo` and
`admin`, respectively. To access the dashboards, use separate terminals:

```sh
kubectl -n argocd port-forward svc/argocd-server 8081:443
kubectl -n kargo port-forward svc/kargo-api 8082:443
```

Argo CD is at https://localhost:8081; Kargo is at https://localhost:8082.
Accept the local certificates. Retrieve the Argo CD initial password with
`kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d`.
The other passwords are in `.local/credentials.env`; do not commit that file.

Once this repository has an initial commit, push it to the local Gitea remote.
The bootstrap does **not** silently commit or push your working tree:

```sh
git remote add local http://localhost:3000/demo/full-auto.git
git push -u local HEAD:main
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
kubectl -n demo-dev port-forward svc/demo-app 8080:80
curl 'http://localhost:8080/api/double?value=21'
```

For a canary-abort demonstration, set `faultMode: true` in the chart's
`values.yaml` and make an application source change in the same commit, then
push to local `main`. Tests still run, but `/check` returns an error while
`/readyz` remains healthy. Rollouts should abort dev and Kargo must not
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
