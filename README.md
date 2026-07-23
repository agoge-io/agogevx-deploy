# AGOGE VX — Kubernetes Helm Chart

The official Helm chart for deploying **AGOGE VX**, a vulnerability-intelligence
platform, on Kubernetes.

This repository contains **only the Helm chart**. The container images it
deploys are licensed and distributed privately on GitHub Container Registry
(GHCR); you pull them with a credential issued during onboarding. The chart
itself is Apache-2.0 (see [LICENSE](LICENSE)) so you can freely fork, template,
and adapt your own deployment overlays.

- **Docs:** https://vx.agoge.io/docs
- **Chart source:** [`charts/agogevx/`](charts/agogevx)

---

## What you need

| Requirement | Detail |
| --- | --- |
| Kubernetes cluster | 1.26+ (managed or self-hosted) |
| `helm` | 3.8+ (OCI support) |
| `kubectl` | configured for your cluster |
| GHCR pull credential | a GitHub username + a Personal Access Token with **`read:packages`**, issued at onboarding — needed because the **images are private** even though this chart is public |
| Postgres | for multi-node / production, an **external** (managed) Postgres; a single-node evaluation can use the in-chart Postgres |
| License key | issued at onboarding; pasted into the setup wizard on first browse |

`linux/amd64` images only.

---

## Install

### 1. Namespace + image-pull secret

The images are private, so every install needs a pull secret named `ghcr-creds`:

```sh
kubectl create namespace agogevx

kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io \
  --docker-username=<github-username> \
  --docker-password=<read:packages PAT> \
  -n agogevx
```

### 2. Application secrets

- **Single-node / evaluation:** skip this — the api self-generates its crypto
  secrets on first boot when the `agogevx-secrets` Secret is absent, and the
  in-chart Postgres generates its own password.
- **Multi-node / production:** the api cannot self-generate onto a shared volume
  when it scales across nodes, so create the full secret set first. The chart
  ships a pure-shell helper that does this without any extra binary:

  ```sh
  ./charts/agogevx/scripts/install.sh
  # prompts for your external Postgres + CA and mints agogevx-postgres,
  # agogevx-db-ca, and the agogevx-secrets app-crypto set, then runs helm.
  ```

  `charts/agogevx/scripts/init-secrets.ps1` is a minimal PowerShell fallback
  that mints only the Postgres password Secret.

### 3. Install the chart

**From the GHCR OCI registry (recommended — no login for the public chart):**

```sh
helm install agogevx oci://ghcr.io/agoge-io/charts/agogevx \
  --version <release-version> \
  -n agogevx \
  -f charts/agogevx/values-prod-50k.yaml       # pick your fleet-size profile
```

**From a local clone:**

```sh
git clone https://github.com/agoge-io/agogevx-deploy
helm install agogevx ./agogevx-deploy/charts/agogevx \
  -n agogevx \
  -f ./agogevx-deploy/charts/agogevx/values-prod-50k.yaml
```

Then open `https://<your-host>/` and complete the setup wizard (admin account,
security keys, license). Save the security keys before continuing — losing them
locks every user out of their MFA secrets and re-keys every agent.

---

## Fleet-size profiles

The matcher-worker replica count is the main scaling knob. Pick the profile that
matches your fleet; each sets replicas, DB pool sizes, and PgBouncer routing:

| Profile | Fleet |
| --- | --- |
| `values.yaml` (defaults) | ≤ 1,000 agents |
| `values-prod-25k.yaml` | ~25,000 |
| `values-prod-50k.yaml` | ~50,000 |
| `values-prod-100k.yaml` | ~100,000 |
| `values-prod-150k.yaml` | ~150,000 |
| `values-prod-200k.yaml` | ~200,000 |
| `values-prod-250k.yaml` | ~250,000 |
| `values-staging.yaml` | small staging cluster |
| `values-multinode.yaml` | multi-node baseline |
| `values-ingress.yaml` | ingress (vs LoadBalancer) profile |

Override individual values with `--set` as usual. Key values:

- `image.org` — the GHCR org your images live under (default `agoge-io`).
- `image.version` — the release tag to deploy (pinned per chart release).
- `imagePullSecrets` — defaults to `[{ name: ghcr-creds }]`; set to `[]` only when running locally-built images.

---

## Upgrade

```sh
helm upgrade agogevx oci://ghcr.io/agoge-io/charts/agogevx \
  --version <new-version> -n agogevx --reuse-values
```

Database migrations run automatically on the api's first boot on the new tag and
are **forward-only**. Take a Postgres backup before upgrading.

## Uninstall

```sh
helm uninstall agogevx -n agogevx        # keeps the PersistentVolumeClaims (data)
```

Deleting the namespace or the PVCs destroys the database. Back up first.

---

## Support

Include your license tier, the deployed `image.version`, and `kubectl -n agogevx
get pods` output when reporting an issue. The support contact is in your
onboarding email.
