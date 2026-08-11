# AGOGE VX Helm chart

Deploys the AGOGE VX stack on Kubernetes using the **same nine GHCR images** the
Docker Compose path publishes (`ghcr.io/<org>/agogevx-*`). This is an **additive**
deployment method — the Compose path (`docker-compose.yml`, `customer_pack/docker/`) is
unchanged and remains fully supported.

> **Defaults are single-node** (Docker Desktop staging): `api`, `ingestion-worker`,
> and `frontend` are pinned to 1 replica and storage is `ReadWriteOnce`. Multi-node
> across a real cluster **is supported** (no `ReadWriteMany` storage required) — see
> **Scaling / multi-node** below before running this on a real cluster.

## What gets deployed

| Workload | Kind | Service | Replicas |
|---|---|---|---|
| db (Postgres) | StatefulSet | `db` (headless, 5432) | 1 |
| pgbouncer | Deployment | `pgbouncer` (6432) | 1 |
| api | Deployment | `api` (5000) | 1 |
| matcher-worker | Deployment | — | `matcher.replicas` |
| ingestion-worker | Deployment | — | 1 |
| report-worker | Deployment | — | `report.replicas` |
| bte-recompute-worker | Deployment | — | `bte.replicas` |
| audit-forward-worker | Deployment | — | `auditForward.replicas` |
| frontend (Caddy + SPA) | Deployment | `frontend` (ClusterIP 2019/80/443) + `frontend-lb` (LoadBalancer 80/443) | 1 |

Under the default (compose) mode five `ReadWriteOnce` PVCs hold state:
`postgres-data`, `bootstrap-config`, `tls-certs`, `user-uploads`,
`report-artifacts`. Under `ingress` (multi-node) mode only `postgres-data` is
provisioned — secrets move to the `agogevx-secrets` Secret, non-secret config to
Postgres `app_settings`, and blobs to S3 (see **Scaling / multi-node**). (The old
`uct-repo` volume was retired — the `ubuntu_uct` ingestion source clones into its
container temp dir, matching the docker-compose removal.)

> Service names `db`, `pgbouncer`, `api`, and `frontend` are **fixed** — the
> images hardcode them (`DATABASE_URL` host, `http://frontend:2019` Caddy admin,
> Caddy's `api:5000` upstream). Do not rename them.

## Prerequisites

- Kubernetes (Docker Desktop's built-in cluster is the v1 target) + `kubectl`
- Helm 3.8+ (Helm 4 works too)
- A pull secret for the private GHCR images, and a Postgres password.

```sh
kubectl create namespace agogevx

kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=<github-user> \
  --docker-password=<PAT-with-read:packages> \
  -n agogevx
```

## Install

### Recommended: generate secrets with `vxctl` first

`vxctl` mints this install's unique secrets, writes an **encrypted backup
bundle** you keep, and creates the `agogevx-postgres` + `agogevx-secrets` (+ optional
`ghcr-creds`) Secrets in the cluster — nothing secret touches git or values.
Download the binary for your workstation from the
[GitHub releases page](https://github.com/agogeio/agogevx/releases) (built from
[go/cmd/vxctl](../../go/cmd/vxctl) via `vendor_tools/vxctl_build/vxctl-build.ps1`).
Then install with no password flags:

```sh
vxctl                 # interactive: pick cluster, enter GHCR token, set a backup passphrase
# then:
helm upgrade --install agogevx ./deploy/helm/agogevx \
  -f deploy/helm/agogevx/values-staging.yaml -n agogevx --create-namespace
```

The chart references `agogevx-postgres` (Postgres password) and `agogevx-secrets`
(`SECRET_KEY`/peppers/MFA key, injected into the api as optional env) by default,
so the secrets `vxctl` created are picked up automatically.

### Or supply the password inline (no installer)

```sh
helm upgrade --install agogevx ./deploy/helm/agogevx \
  -f deploy/helm/agogevx/values-staging.yaml \
  --set postgres.password="$(openssl rand -base64 32)" \
  -n agogevx --create-namespace
```

Then watch `kubectl -n agogevx get pods -w` and open `https://localhost/` for the
setup wizard (accept the self-signed cert). The wizard collects the domain,
public URLs, NVD/MSRC/Resend keys, admin account, and license — exactly as on
Compose. None of those belong in chart values.

### Running locally-built images (no GHCR pull)

Docker Desktop shares its image store with its Kubernetes node, so you can skip
the registry:

```sh
helm upgrade --install agogevx ./deploy/helm/agogevx -f deploy/helm/agogevx/values-staging.yaml \
  --set image.pullPolicy=Never --set imagePullSecrets=null \
  --set postgres.password="$(openssl rand -base64 32)" -n agogevx
```

(Tag your local builds `ghcr.io/<org>/agogevx-*:<version>` to match `image.*`.)

## Common operations

```sh
# Scale the matcher (primary throughput knob)
helm upgrade agogevx ./deploy/helm/agogevx -n agogevx --reuse-values --set matcher.replicas=4

# Route api/workers through PgBouncer (past ~10k agents)
helm upgrade agogevx ./deploy/helm/agogevx -n agogevx --reuse-values --set db.route=pgbouncer

# Bump the deployed image tag
helm upgrade agogevx ./deploy/helm/agogevx -n agogevx --reuse-values --set image.version=2.4

# Uninstall (PVCs are retained — delete them explicitly to wipe data)
helm uninstall agogevx -n agogevx
```

## Scaling / multi-node

The default values run single-node because every pod that shares a
`ReadWriteOnce` PVC lands on the same node. **Multi-node is supported with only
`ReadWriteOnce` block storage + S3 — no `ReadWriteMany` (NFS) class is required.**
Use `values-multinode.yaml` (see `plans/finished/deploy/k8s/2026-06-13-deploy-k8s-bootstrap_secret_migration.md`, the
authoritative design, plus `plans/finished/deploy/k8s/2026-06-13-deploy-k8s-multinode_loadbalancer_portable_storage.md`).

**Two multi-node profiles** (pick with `deployMode`; vxctl exposes them as a
choice):

- **`loadbalancer` (default, recommended):** a `Service type: LoadBalancer` is the
  external entry — the cloud provisions the load balancer on any provider — and the
  frontend **Caddy obtains its own Let's Encrypt cert (ACME)**. No nginx-ingress, no
  cert-manager, nothing to pre-install. `postgres-data` uses the cluster's default
  RWO StorageClass (`storageClass: ""`). After install, point your domain's DNS at
  the load balancer IP. The frontend runs at 1 replica (Caddy's local cert store);
  the api scales to N.
- **`ingress` (opt-in; regulated/shared clusters, e.g. IL5):** `deployMode=ingress`
  + `ingress.enabled=true` hand TLS to a **pre-installed** nginx-ingress +
  cert-manager (the controller's own LoadBalancer Service is the entry). Frontend
  scales to N. Requires those controllers + a ClusterIssuer to exist already.

The api/storage/blob points below apply to **both** profiles. The single-node
blockers are resolved like this:

1. **frontend → N replicas (ingress profile only):** `deployMode=ingress` +
   `ingress.enabled=true` hand TLS to nginx-ingress + cert-manager and gate off the
   api's Caddy admin push, so the frontend serves the SPA over HTTP at N replicas.
   (Under `loadbalancer` the frontend stays at 1 — Caddy keeps its cert locally; a
   future shared cert store on S3/Postgres would unpin it without nginx.)
2. **api → N replicas (B2, shipped):** in `ingress` mode every secret is sourced
   from the `agogevx-secrets` Secret (crypto secrets + the Fernet `BOOTSTRAP_KEY` +
   the pgbouncer password — injected as env / a mounted file) and every non-secret
   config field lives in Postgres `app_settings`, so the `bootstrap-config` volume
   is **dropped entirely** — it was the last RWX-needing volume. `vxctl` mints
   the full secret set at install, so the api runs at N replicas **from the very
   first boot** with no first-boot ordering or restart. (pgbouncer reads the
   password from the Secret; the api aligns the Postgres role to it.)
3. **Shared blobs (B3):** configure **object storage** on the admin Storage page
   (System → Storage → a private S3 bucket) and set
   `persistence.blobVolumeKind=emptyDir`. The api then carries no RWO blob PVC and
   scales across nodes. **Configure S3 before scaling api/report-worker past 1**, or
   blobs (avatars, rendered reports) land on per-pod disk and 404 cross-pod.
   *All-RWX fallback (no object store):* keep `blobVolumeKind=pvc` and set the
   `userUploads`/`reportArtifacts` accessMode to `ReadWriteMany` instead.

`pdb.enabled=true` + `topologySpread.enabled=true` add PodDisruptionBudgets (for
workloads >1 replica) and soft node spread. `postgres-data` is always
single-writer (RWO) and never needs RWX.

> **Multi-node scales the stateless tier (api / frontend / workers), not the
> database.** Postgres is a single-replica StatefulSet with no HA; losing its node
> is an outage until the pod reschedules and the RWO volume reattaches. Database HA
> (read replicas, external/managed Postgres, an operator) and 500k-host write
> scaling are a **separate performance plan** — point `db.route` / `DATABASE_URL` at
> an external managed Postgres via values when that lands.

## Production sizing tiers

Six **self-contained** production overlays size the stack for a given fleet. Each
is named for the agent count it targets and carries the full multi-node HA
settings (`deployMode: loadbalancer`, the 3-replica HA floor, external/dedicated
Postgres via PgBouncer, S3 blobs, PDBs, topology spread, NetworkPolicy) — apply
**one** as the only `-f` file; you do **not** also pass `values-multinode.yaml`.

| Overlay | Agents | K8s nodes (min) | Dedicated Postgres | matcher | pgbouncer `defaultPoolSize` | DB `max_connections` ≥ |
|---|---|---|---|---|---|---|
| `values-prod-25k.yaml`  | ≤ 25,000  | 3 × 4 vCPU / 8 GB   | 4 vCPU / 16 GB / NVMe  | 3  | 60  | 250 |
| `values-prod-50k.yaml`  | ≤ 50,000  | 3 × 4 vCPU / 16 GB  | 4 vCPU / 16 GB / NVMe  | 5  | 70  | 300 |
| `values-prod-100k.yaml` | ≤ 100,000 | 3 × 8 vCPU / 16 GB  | 8 vCPU / 32 GB / NVMe  | 10 | 80  | 350 |
| `values-prod-150k.yaml` | ≤ 150,000 | 3 × 8 vCPU / 32 GB  | 8 vCPU / 32 GB / NVMe  | 15 | 100 | 400 |
| `values-prod-200k.yaml` | ≤ 200,000 | 4 × 8 vCPU / 32 GB  | 16 vCPU / 64 GB / NVMe | 20 | 120 | 500 |
| `values-prod-250k.yaml` | ≤ 250,000 | 5 × 8 vCPU / 32 GB  | 16 vCPU / 64 GB / NVMe | 25 | 150 | 600 |

Every other component (`api`, `frontend`, `pgbouncer`, `ingestion`, `report`,
`maintenance`, `bte`, `auditForward`) stays at the **3-replica HA floor** across
all tiers — only the matcher (throughput) and PgBouncer pool (connection budget)
scale. Each file's header carries the per-tier connection-budget math; size the
dedicated Postgres `max_connections` to the value in the last column before
installing.

`vxctl` selects these automatically: on a **multi-node Kubernetes install**
(`--deploy-profile loadbalancer|ingress`, or the TUI/web multi-node profiles),
choosing a fleet size of `25k`…`250k` makes vxctl deploy with
`-f values-prod-<tier>.yaml` (and the sizing `--set`s are suppressed so the file
is authoritative). These tiers require a dedicated/managed Postgres — pass
`--external-db` (the wizard's external-DB step). To install by hand instead:

```sh
# Provision the dedicated Postgres + its Secrets first (see the file header), then:
helm upgrade --install agogevx ./agogevx \
  -f agogevx/values-prod-100k.yaml \
  --set domain=valex.example.com \
  --set postgres.external.host=pg.internal.example.com \
  -n agogevx --create-namespace
```

To run behind an existing nginx-ingress + cert-manager instead of the default
LoadBalancer profile, layer `values-ingress.yaml` **after** the tier file
(vxctl does this for you under the ingress profile).

## Values

See [values.yaml](values.yaml) for the full set with comments. It mirrors
`customer_pack/docker/.env.example`. Key knobs:

| Key | Default | Purpose |
|---|---|---|
| `image.org` / `image.version` | `agoge-io` / `2.7` | GHCR org + image tag |
| `postgres.password` / `postgres.existingSecret` | `""` | **required** at install |
| `domain` | `localhost` | public hostname (never an IP) |
| `db.route` | `direct` | `direct` or `pgbouncer` |
| `deployMode` | `compose` | `compose` (single-node, api-issued TLS) \| `loadbalancer` (multi-node, LoadBalancer Service + Caddy self-ACME) \| `ingress` (multi-node behind nginx-ingress + cert-manager) |
| `matcher.replicas` | `1` | matcher scale (1→20 across fleet sizes) |
| `api.replicas` | `1` | api scale — honoured under `ingress` AND `loadbalancer` (multi-node) |
| `frontend.serviceType` | `LoadBalancer` | external 80/443 entry (compose + loadbalancer modes) |
| `frontend.lbAnnotations` | `{}` | provider-specific annotations on the `frontend-lb` Service |
| `persistence.accessMode` / `.storageClass` | `ReadWriteOnce` / `""` | global default inherited per-volume |
| `persistence.volumes.<name>.accessMode` / `.storageClass` | `""` | per-volume override (e.g. `postgresData.storageClass`; RWX only for the all-RWX blob fallback — not needed otherwise) |
| `persistence.blobVolumeKind` | `pvc` | `pvc` (shared volume) or `emptyDir` (blobs in S3, multi-node) |
| `pdb.enabled` / `topologySpread.enabled` | `false` | PodDisruptionBudgets + soft node spread (multi-node) |
