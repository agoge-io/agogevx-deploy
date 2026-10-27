# Install-secret helpers

The **supported** way to generate this install's secrets is the **`vx`**
binary (built from [go/cmd/vx](../../../../go/cmd/vx) by `vx installers`, and
shipped in the customer pack as `vx-<os>-<arch>[.exe]`).
It generates every secret uniquely, writes an **age-encrypted backup bundle** you
keep, optionally creates the GHCR pull secret, and creates the cluster Secrets the
chart consumes — interactively or as a single command. See the chart
[README](../README.md) → *Install* and the runbook
[kubernetes-deployment.md](../../../../docs/internal_documentation/kubernetes-deployment.md).

```sh
vx                    # interactive menu (secrets + deploy/teardown + compose)

# --- secrets ---
vx k8s secrets init --context <ctx> --namespace agogevx \
  --bundle ./agogevx-secrets.age --passphrase-env AGOGEVX_BUNDLE_PASS --non-interactive
# new cluster only, before deploy: it also writes the database password
vx k8s secrets restore --bundle ./agogevx-secrets.age --passphrase-env AGOGEVX_BUNDLE_PASS --non-interactive

# --- Kubernetes lifecycle (helm) ---
vx k8s deploy   --context <ctx> --namespace agogevx --non-interactive          # helm upgrade --install
vx k8s teardown --context <ctx> --namespace agogevx --non-interactive --yes     # helm uninstall (keeps data)
vx k8s teardown --context <ctx> --namespace agogevx --non-interactive --yes \
  --delete-namespace                                                            # also deletes the namespace + PVCs (DATA LOSS)
vx k8s db restore --archive <db_backup_*.tar.gz> --context <ctx> --namespace agogevx --yes   # offline restore of a full backup

# --- Docker Compose lifecycle (single host) ---
vx compose up   --domain localhost --non-interactive                         # docker compose up -d
vx compose down --non-interactive --yes                                      # docker compose down (keeps volumes)
vx compose down --non-interactive --yes --purge                              # also removes named volumes (DATA LOSS)
```

> Add `--dry-run` to `k8s deploy` / `k8s teardown` / `compose up` /
> `compose down` to preview without changing anything. The destructive verbs
> (`k8s teardown`, `compose down`) refuse to run non-interactively without
> `--yes`, and only destroy data when `--delete-namespace` / `--purge` is given.
> Secret generation applies to Kubernetes only — the compose stack
> auto-generates its own secrets via the setup wizard, so `vx compose up` just
> sets `DOMAIN`/URL and starts it.

## `install.sh` (full production install, for when the binary is blocked)

`install.sh` is a **menu-driven, pure-shell** stand-in for the Kubernetes path
of `vx`, for machines where a compiled binary won't run — locked-down /
MDM-managed **macOS**, hardened Linux. It drives the **external/managed-Postgres
production install** (every AGOGE VX Kubernetes deployment uses an external DB),
reproducing `vx k8s secrets init --external-db` + `vx k8s deploy --external-db
--fleet-tier <N>` in one interactive flow:

- prompts for your **external Postgres** (host, port, db, user, password, TLS
  mode, routing) and the **server CA** (auto-fetched for AWS/Azure; a PEM file
  for GCP / DigitalOcean / self-managed) — rejecting an IP host, as `verify-full`
  requires;
- mints this install's **app-crypto secrets** with `openssl`, in the exact
  byte-formats the api expects (verified against
  [secrets.go](../../../../go/internal/vxtool/deploy/secrets.go));
- creates the cluster Secrets the chart consumes — `agogevx-postgres` (your DB
  password), `agogevx-db-ca` (the CA), `agogevx-secrets` (the 6-key app-crypto
  set) — plus the optional `ghcr-creds` pull secret;
- optionally runs the same **in-cluster `select 1` pre-check** vx does
  (validates TLS + auth from *inside* the cluster, so a private-VPC DB your
  laptop can't reach is still checked);
- optionally runs a **one-time DB privilege bootstrap** (the managed DB must run
  PostgreSQL 17 or later; the migrations need 17): on a fresh managed DB the app
  user can't create its own tables until an admin grants it `CREATE` on the
  database + `public` schema (since PostgreSQL 15, `public` gives no user
  `CREATE` by default) and installs
  `pg_stat_statements` / `pg_trgm`. If you opt in, the script asks for your DB
  **admin** creds (e.g. `doadmin`), runs the grants through a one-off in-cluster
  Job, then deletes the Job **and** the transient admin Secret — the admin
  password is never persisted and the app user stays a plain, non-superuser
  role (it only gains `CREATE` on its own database);
- writes a **chmod-600 plaintext backup** of every secret to `./install_data/`
  (store it in your secret manager — it is not age-encrypted like the `vx`
  bundle);
- runs `helm upgrade --install` with the **fleet-size tier** file
  (`values-prod-<N>.yaml`) + the `postgres.external.*` / `db.route` `--set`
  flags, in either the loadbalancer or ingress profile.

```sh
chmod +x ./install.sh   # first time only
./install.sh            # asks: context, namespace, fleet tier, profile, domain, external DB + CA, GHCR
```

Requirements on your machine: `bash`, `openssl`, `kubectl`, `helm 3.8+`, a
kubeconfig already pointing at the cluster, and — for GCP / DigitalOcean /
self-managed DBs — the server CA as a PEM file (`curl` auto-fetches AWS/Azure).
It only talks to the cluster over your kubeconfig, so it runs fine from macOS.

> `install.sh` mints the **full** `agogevx-secrets` set, which multi-node
> (loadbalancer/ingress) deploys **require** — the api can't self-generate onto a
> shared volume when it scales across nodes. What it does **not** do that the
> `vx` binary does: write an **age-encrypted** backup bundle (it writes a
> chmod-600 plaintext file instead). Everything else on the production K8s path
> is covered. `install.sh` also has no full-backup restore: run
> `vx k8s db restore --archive` from a machine where `vx` runs.

> **If the binary is only quarantined** (Gatekeeper "unidentified developer"),
> you may be able to run `vx` directly with
> `xattr -d com.apple.quarantine ./vx-darwin-arm64 && chmod +x ./vx-darwin-arm64`.
> Use `install.sh` when a stricter policy blocks all non-allowlisted binaries.

## `init-secrets.ps1` (minimal fallback)

`init-secrets.ps1` is a tiny PowerShell fallback that only mints the **Postgres
password** Secret (`agogevx-postgres`) — useful if you can't run the binary. It does
**not** generate the app secrets or a backup bundle (the app self-generates its
crypto secrets on first boot when `agogevx-secrets` is absent). Prefer `vx`.

> **Idempotency / rotation:** both tools leave an existing secret untouched.
> Postgres applies `POSTGRES_PASSWORD` only on first data-volume init, so rotating
> it on a live database breaks auth — only `--rotate` against a fresh volume.
