# AGOGE VX Helm chart

Deploys the AGOGE VX stack on Kubernetes using the **same 11 GHCR images** the
Docker Compose path publishes (`ghcr.io/<org>/agogevx-*`). This is an **additive**
deployment method — the Compose path (`docker-compose.yml`, `customer_pack/docker/`) is
unchanged and remains fully supported.

> **Every service except the database runs 3 pods by default** (the HA floor), so
> one node failure cannot take any service fully offline. The default `deployMode`
> is `compose`: one node, for a trial with a plain `helm install` of `values.yaml`.
> In that mode the templates pin `api` and `frontend` to 1 pod, and storage is
> `ReadWriteOnce`. `vx` deploys only the multi-node modes (`loadbalancer`,
> `ingress`); for one machine, use the Docker Compose install. Multi-node needs no
> `ReadWriteMany` storage — see **Scaling / multi-node** below.

## What gets deployed

| Workload | Kind | Service | Replicas |
|---|---|---|---|
| db (Postgres) | StatefulSet | `db` (headless, 5432) | 1 (no database HA) |
| pgbouncer | Deployment | `pgbouncer` (6432) | `pgbouncer.replicas` (3) |
| api | Deployment | `api` (5000) | `api.replicas` (3); 1 in compose mode |
| matcher-worker | Deployment | — | `matcher.replicas` (3) |
| ingestion-worker | Deployment | — | `ingestion.replicas` (3) |
| report-worker | Deployment | — | `report.replicas` (3) |
| maintenance-worker | Deployment | — | `maintenance.replicas` (3) |
| bte-recompute-worker | Deployment | — | `bte.replicas` (3) |
| audit-forward-worker | Deployment | — | `auditForward.replicas` (3) |
| mcp-server | Deployment | `mcp-server` (5001) | `mcp.replicas` (3) |
| frontend (Caddy + SPA) | Deployment | `frontend` (ClusterIP 2019/80/443) + `frontend-lb` (LoadBalancer 80/443) | `frontend.replicas` (3); 1 in compose mode |

Under the default (compose) mode five `ReadWriteOnce` PVCs hold state:
`postgres-data`, `bootstrap-config`, `tls-certs`, `user-uploads`,
`report-artifacts`. Under `ingress` (multi-node) mode only `postgres-data` is
provisioned — secrets move to the `agogevx-secrets` Secret, non-secret config to
Postgres `app_settings`, and blobs to S3 (see **Scaling / multi-node**). (The old
`uct-repo` volume was retired — the `ubuntu_uct` ingestion source clones into its
container temp dir, matching the docker-compose removal.) Helm keeps every PVC
over `helm uninstall` and over a mode switch: see **Kept disks**.

> Service names `db`, `pgbouncer`, `api`, and `frontend` are **fixed** — the
> images hardcode them (`DATABASE_URL` host, `http://frontend:2019` Caddy admin,
> Caddy's `api:5000` upstream). Do not rename them.

## Prerequisites

- Kubernetes + `kubectl`: a multi-node cluster (3 nodes or more) for a `vx`
  deploy; Docker Desktop's built-in cluster for the one-node trial
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

> **`vx` deploys Kubernetes on a multi-node cluster only:** the `loadbalancer` or
> `ingress` profile, or a production tier. It no longer deploys a single-node
> Kubernetes install. For one machine, use the Docker Compose install. A plain
> `helm install` of `values.yaml` still runs the chart's one-node compose mode
> (below), for a trial.

### Recommended: generate secrets and deploy with `vx`

`vx` mints this install's unique secrets, writes an **encrypted backup
bundle** you keep, and creates the `agogevx-postgres` + `agogevx-secrets` (+ optional
`ghcr-creds`) Secrets in the cluster — nothing secret touches git or values.
The binary for your workstation is in the customer pack
(`vx-<os>-<arch>[.exe]`, built from [go/cmd/vx](../../../go/cmd/vx) by
`vx installers`). Then deploy with no password flags:

```sh
vx                    # interactive: choose Kubernetes, pick cluster, enter GHCR token, set a backup passphrase
# then (multi-node, a cloud load balancer; or --deploy-profile ingress):
vx k8s deploy --deploy-profile loadbalancer --domain agogevx.example.com --namespace agogevx --non-interactive
```

The chart references `agogevx-postgres` (Postgres password) and `agogevx-secrets`
(`SECRET_KEY`/peppers/MFA key, injected into the api as optional env) by default,
so the secrets `vx` created are picked up automatically.

### Or install with helm (no installer)

Multi-node, with the password inline:

```sh
# A new password is for a first install only. A reinstall over kept PVCs gives the old one (Kept disks).
helm upgrade --install agogevx ./deploy/helm/agogevx \
  -f deploy/helm/agogevx/values-multinode.yaml \
  --set domain=agogevx.example.com \
  --set postgres.password="$(openssl rand -base64 32)" \
  -n agogevx --create-namespace
```

A one-node trial (Docker Desktop's built-in cluster): `values.yaml` alone runs the
compose mode. The api issues the TLS cert, the api and the frontend run 1 pod
each, and every other service except db runs 3. It reserves about 14.4 GiB of
memory, mostly 3 matchers × 3 GiB; add `--set matcher.replicas=1` on a small
machine.

```sh
# A new password is for a first install only. A reinstall over kept PVCs gives the old one (Kept disks).
helm upgrade --install agogevx ./deploy/helm/agogevx \
  --set postgres.password="$(openssl rand -base64 32)" \
  -n agogevx --create-namespace
```

Then watch `kubectl -n agogevx get pods -w` and open the domain (the one-node
trial: `https://localhost/`) for the setup wizard (accept the self-signed cert).
The wizard collects the domain, public URLs, NVD/MSRC/Resend keys, admin account,
and license — exactly as on Compose. None of those belong in chart values.

### Running locally-built images (no GHCR pull)

Docker Desktop shares its image store with its Kubernetes node, so you can skip
the registry:

```sh
# A new password is for a first install only. A reinstall over kept PVCs gives the old one (Kept disks).
helm upgrade --install agogevx ./deploy/helm/agogevx \
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

# Uninstall (keeps the PVCs and the chart's agogevx-postgres Secret — delete them by hand to wipe data)
helm uninstall agogevx -n agogevx
```

## Kept disks

Chart 0.8.1 and later put `helm.sh/resource-policy: keep` on every PVC, and on the
`agogevx-postgres` Secret that the chart makes from `postgres.password`. Helm then
never deletes them:

- `helm uninstall` keeps the PVCs, the files on them and the password Secret. Its
  output lists them as "kept due to the resource policy".
- A `helm upgrade` that stops rendering a PVC also keeps it: a switch of
  `deployMode` or of `persistence.blobVolumeKind`, or a switch to an external
  database. The kept PVC stays unused until a release renders it again.
- To delete the data, delete the PVCs by hand
  (`kubectl delete pvc -n <namespace> <name>`), or delete the namespace.

**A reinstall over kept PVCs.** Use the same release name: each kept object
carries `meta.helm.sh/release-name`, and Helm refuses to adopt it into a release of
another name. Keep the access mode and the storage class of each PVC, and its size
(a larger size works only when the storage class allows volume expansion): Helm
cannot change the spec of an existing PVC. Give the same `postgres.password` as
before, or `--set postgres.existingSecret=agogevx-postgres` to use the kept Secret.
A new password does not open the kept database. For an empty start instead,
delete the kept PVCs, or install in a new namespace.

**A switch back.** A switch from an external database back to the in-cluster
database, or from a multi-node mode back to `compose`, renders the kept PVCs again.
The release then gets the old data back: the old database with its old password,
and the old first-boot files. Delete the kept PVCs first for an empty start.

`vx k8s teardown` keeps the same disks. By default it deletes only the GHCR pull
Secret `ghcr-creds`, and keeps `agogevx-postgres` and `agogevx-secrets`, because
only those two open the kept database. `--keep-secrets` keeps `ghcr-creds` too, and
`--delete-namespace` deletes everything. Over a kept `postgres-data` PVC,
`vx k8s secrets init` and `vx k8s deploy` refuse to run without those two
Secrets, and init also refuses `--rotate`. Restore them with
`vx k8s secrets restore --bundle <file>`, or delete the PVC to start an empty
database.

## Upgrading to chart 0.8.1

Chart 0.8.1 adds the keep annotation of **Kept disks**. The upgrade restarts every
pod once, because the `helm.sh/chart` label of each pod template changes.

Helm decides the delete of an upgrade from the live PVC, and the delete of an
uninstall from the stored release. The live PVCs of a release that an older chart
made have no annotation, so an upgrade to 0.8.1 that also switches the mode still
deletes them. Before the first upgrade to 0.8.1, annotate the live PVCs of the
release:

```sh
kubectl annotate pvc -n <namespace> -l app.kubernetes.io/instance=<release> helm.sh/resource-policy=keep
```

That protects the PVCs in that same upgrade, also one that switches the mode. An
old multi-node release with blob PVCs on `ReadWriteOnce` disks cannot render 0.8.x
with unchanged values (point 2 below), so its first upgrade is such a switch. The
0.8.1 upgrade then stores the annotation in the release, so a later
`helm uninstall` keeps the PVCs too. The step changes nothing else and is safe to
run again. It does not protect a `helm uninstall` of the old release: an uninstall
reads the stored release, so upgrade to 0.8.1 before you uninstall.

## Upgrading to chart 0.8.0

Chart 0.8.0 runs 3 pods of every service except the database by default. Read these three points
before you upgrade a release that an older chart made. Across chart versions, use
`--reset-then-reuse-values` (as `vx k8s update` does), not `--reuse-values`: the old value tree
lacks the keys the new chart added.

1. **Memory.** The release takes the new defaults, so each service whose count it did not set runs
   3 pods. A one-node compose-mode release (a plain `helm install` of `values.yaml`) then asks for
   about 14.4 GiB of memory requests, up from about 6.1 GiB, and on a small machine some pods wait
   in Pending. A multi-node release with the in-cluster database at tier S asks for about 16.6 GiB.
   *Way out:* give the nodes more memory, or keep that release small:
   `helm upgrade agogevx <chart> -n agogevx --reset-then-reuse-values --set matcher.replicas=1`
   (each matcher pod reserves 3 GiB).
2. **Blobs on disks in a multi-node mode.** A release that runs `loadbalancer` or `ingress` with
   `persistence.blobVolumeKind: pvc` on `ReadWriteOnce` disks (for example one made with the old
   `values-ingress.yaml`) no longer renders: pods on different nodes cannot share those disks, and
   1 api pod and 1 report-worker pod already share report-artifacts. `vx k8s update` and
   `helm upgrade` stop with a message that names the fix, and nothing changes. *Way out:* set up S3
   (System → Storage), copy the files you keep from the disks (uploads, avatars and evidence;
   report files can be made again), then upgrade with `persistence.blobVolumeKind=emptyDir`. Run
   the `kubectl annotate` step of **Upgrading to chart 0.8.1** first: then the upgrade to 0.8.1
   keeps the old disks, unused, and you delete them when you no longer need them. A new install
   can use `ReadWriteMany` disks instead; an existing disk cannot change its access mode.
3. **`values-ingress.yaml` keeps blobs in S3 now** (`blobVolumeKind: emptyDir`). Its documented
   command, run over a release made with the old file, stops rendering the user-uploads and
   report-artifacts disks. A chart older than 0.8.1 then makes Helm delete them and the files on
   them; chart 0.8.1 keeps them when their live PVCs carry the keep annotation (the
   `kubectl annotate` step). Either way, S3 does not move files that are already on a disk.
   *Way out:* set up S3 and copy those files first, as in point 2.

A compose-mode release keeps working with `vx k8s update` and `vx k8s resize`. `vx k8s deploy`
refuses to switch it to a multi-node mode: the new mode does not use its one-node disks, and a
release that no upgrade to chart 0.8.1 has touched also loses them.

## Scaling / multi-node

The default `deployMode: compose` runs on one node because every pod that shares a
`ReadWriteOnce` PVC lands on the same node. **Multi-node is supported with only
`ReadWriteOnce` block storage + S3 — no `ReadWriteMany` (NFS) class is required.**
Use `values-multinode.yaml` (see `plans/finished/deploy/k8s/2026-06-13-deploy-k8s-bootstrap_secret_migration.md`, the
authoritative design, plus `plans/finished/deploy/k8s/2026-06-13-deploy-k8s-multinode_loadbalancer_portable_storage.md`).

**Two multi-node profiles** (pick with `deployMode`; vx exposes them as a
choice):

- **`loadbalancer` (default, recommended):** a `Service type: LoadBalancer` is the
  external entry — the cloud provisions the load balancer on any provider — and the
  stack **obtains its own Let's Encrypt cert (ACME)**. No nginx-ingress, no
  cert-manager, nothing to pre-install. `postgres-data` uses the cluster's default
  RWO StorageClass (`storageClass: ""`). After install, point your domain's DNS at
  the load balancer IP. The api and the frontend both scale to N (3 by default):
  the api obtains the Let's Encrypt cert and publishes it into the `frontend-tls`
  Secret, which every frontend pod mounts.
- **`ingress` (opt-in; regulated/shared clusters, e.g. IL5):** `deployMode=ingress`
  + `ingress.enabled=true` hand TLS to a **pre-installed** nginx-ingress +
  cert-manager (the controller's own LoadBalancer Service is the entry). Frontend
  scales to N. Requires those controllers + a ClusterIssuer to exist already.

The api/storage/blob points below apply to **both** profiles. The single-node
blockers are resolved like this:

1. **frontend → N replicas (both profiles):** `deployMode=ingress` +
   `ingress.enabled=true` hand TLS to nginx-ingress + cert-manager and gate off the
   api's Caddy admin push, so the frontend serves the SPA over HTTP at N replicas.
   Under `loadbalancer` every frontend pod serves the cert the api publishes into
   the `frontend-tls` Secret, so it scales to N too.
2. **api → N replicas (B2, shipped):** in `ingress` mode every secret is sourced
   from the `agogevx-secrets` Secret (crypto secrets + the Fernet `BOOTSTRAP_KEY` +
   the pgbouncer password — injected as env / a mounted file) and every non-secret
   config field lives in Postgres `app_settings`, so the `bootstrap-config` volume
   is **dropped entirely** — it was the last RWX-needing volume. `vx` mints
   the full secret set at install, so the api runs at N replicas **from the very
   first boot** with no first-boot ordering or restart. (pgbouncer reads the
   password from the Secret; the api aligns the Postgres role to it.)
3. **Shared blobs (B3):** configure **object storage** on the admin Storage page
   (System → Storage → a private S3 bucket) and set
   `persistence.blobVolumeKind=emptyDir`. The api then carries no RWO blob PVC and
   scales across nodes. The api and the report-worker run 3 pods by default, so
   **configure S3 on first boot**, or blobs (avatars, rendered reports) land on
   per-pod disk and 404 cross-pod. *All-RWX fallback (no object store):* keep
   `blobVolumeKind=pvc` and set the `userUploads`/`reportArtifacts` accessMode to
   `ReadWriteMany` instead. In a multi-node mode the render fails when two or more
   pods would share a `ReadWriteOnce` blob disk (every api pod mounts user-uploads;
   every api and report-worker pod mounts report-artifacts, so 1 of each already
   share it), and the message names both fixes.

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
| `values-prod-25k.yaml`  | ≤ 25,000  | 3 × 4 vCPU / 16 GB  | 4 vCPU / 16 GB / NVMe  | 3  | 60  | 250 |
| `values-prod-50k.yaml`  | ≤ 50,000  | 3 × 4 vCPU / 16 GB  | 4 vCPU / 16 GB / NVMe  | 5  | 70  | 300 |
| `values-prod-100k.yaml` | ≤ 100,000 | 3 × 8 vCPU / 16 GB  | 8 vCPU / 32 GB / NVMe  | 10 | 80  | 350 |
| `values-prod-150k.yaml` | ≤ 150,000 | 3 × 8 vCPU / 32 GB  | 8 vCPU / 32 GB / NVMe  | 15 | 100 | 400 |
| `values-prod-200k.yaml` | ≤ 200,000 | 4 × 8 vCPU / 32 GB  | 16 vCPU / 64 GB / NVMe | 20 | 120 | 500 |
| `values-prod-250k.yaml` | ≤ 250,000 | 5 × 8 vCPU / 32 GB  | 16 vCPU / 64 GB / NVMe | 25 | 150 | 600 |

Every other component (`api`, `frontend`, `pgbouncer`, `ingestion`, `report`,
`maintenance`, `bte`, `auditForward`, `mcp`) stays at the **3-replica HA floor**
across all tiers — only the matcher (throughput) and PgBouncer pool (connection
budget) scale. Each file's header carries the per-tier connection-budget math; size the
dedicated Postgres `max_connections` to the value in the last column before
installing.

`vx` selects these automatically: on a **multi-node Kubernetes install**
(`--deploy-profile loadbalancer|ingress`, or the TUI/web multi-node profiles),
choosing a fleet size of `25k`…`250k` makes vx deploy with
`-f values-prod-<tier>.yaml` (and the sizing `--set`s are suppressed so the file
is authoritative). These tiers require a dedicated/managed Postgres: pass
`--external-db` and its flags (the terminal UI takes the database only from those
flags), or tick **external / managed Postgres** in the web console. The S, M, L
and XL tiers use the in-cluster database instead. To install by hand instead:

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
(vx does this for you under the ingress profile).

## Values

See [values.yaml](values.yaml) for the full set with comments. It mirrors
`customer_pack/docker/.env.example`. Key knobs:

| Key | Default | Purpose |
|---|---|---|
| `image.org` / `image.version` | `agoge-io` / the release tag | GHCR org + image tag |
| `postgres.password` / `postgres.existingSecret` | `""` | **required** at install |
| `domain` | `localhost` | public hostname (never an IP) |
| `db.route` | `direct` | `direct` or `pgbouncer` |
| `deployMode` | `compose` | `compose` (one node, api-issued TLS; a plain `helm install` trial — `vx` does not deploy it) \| `loadbalancer` (multi-node, LoadBalancer Service; the api obtains the Let's Encrypt cert and every frontend pod serves it) \| `ingress` (multi-node behind nginx-ingress + cert-manager) |
| `matcher.replicas` | `3` | matcher scale (3 → 25 across fleet sizes) |
| `api.replicas` / `frontend.replicas` | `3` | honoured under `ingress` AND `loadbalancer` (multi-node); compose mode pins both to 1 |
| `<service>.replicas` (pgbouncer, ingestion, report, maintenance, bte, auditForward, mcp) | `3` | the HA floor; only `db` runs 1 |
| `ingestion.tmpSizeLimit` | `8Gi` | the ingestion-worker's `/tmp` (node disk): the OSV dumps (up to 4 GiB each, deleted after the read) and the Ubuntu and CISA git clones |
| `frontend.serviceType` | `LoadBalancer` | external 80/443 entry (compose + loadbalancer modes) |
| `frontend.lbAnnotations` | `{}` | provider-specific annotations on the `frontend-lb` Service |
| `persistence.accessMode` / `.storageClass` | `ReadWriteOnce` / `""` | global default inherited per-volume |
| `persistence.volumes.<name>.accessMode` / `.storageClass` | `""` | per-volume override (e.g. `postgresData.storageClass`; RWX only for the all-RWX blob fallback — not needed otherwise) |
| `persistence.blobVolumeKind` | `pvc` | `pvc` (shared volume) or `emptyDir` (blobs in S3, multi-node) |
| `pdb.enabled` / `topologySpread.enabled` | `false` | PodDisruptionBudgets + soft node spread (multi-node) |
