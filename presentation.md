---
marp: true
theme: default
paginate: true
---

# From Argo CD only to automated delivery

Two independent apps, local Git and registry, no manual promotion.

---

# Today: Argo CD only

`Git desired state -> Argo CD -> Kubernetes`

- Argo CD reconciles manifests; it does not build application images.
- Image selection, environment promotion, and release verification need other components or manual steps.
- A successful sync does not prove a new version behaves correctly.

---

# The end-to-end loop

`Code push -> Gitea CI -> local registry -> Kargo Freight`

`-> dev -> verified -> prod`

- CI runs unit tests, k6, and Prometheus-format validation before publishing.
- Freight pins **image digest + code/test SHA + chart SHA**.
- Kargo writes stage Git branches from that Freight; Argo CD syncs each.

---

# Automated safety gates

- **Argo Rollouts:** canary update, abort on failed analysis.
- **Testkube + k6:** synthetic traffic even when user traffic is low.
- **Prometheus:** version-matched gauge; **HTTP:** functional check.
- **Kargo:** prod waits until dev Freight is verified.

A failed canary keeps the old ReplicaSet serving and blocks downstream promotion.

---

# Show it live

1. Push a code change to one Gitea app repo.
2. Follow CI, image publication, and Kargo Freight.
3. Watch dev canary, AnalysisRun, k6 execution, then prod promotion.
4. Confirm the other app remains independent.

- Kargo: https://kargo.localhost:8443
- Argo CD: https://argocd.localhost:8443
- Cluster status: https://headlamp.localhost:8443

---

# What remains

- This is a working **local demo**, not production hardening.
- Basic canary approximates traffic weight by pod count.
- A failed rollout protects live traffic, but does **not** automatically revert the stage's desired Git revision.

**Takeaway:** Argo CD still reconciles; CI, Kargo, Rollouts, and tests decide *what* advances and *when*.
