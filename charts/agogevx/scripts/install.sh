#!/usr/bin/env bash
#
# install.sh — menu-driven AGOGE VX Kubernetes installer (external Postgres).
#
# A pure-shell alternative to the `vxctl` binary for the Kubernetes production
# path, for machines where a compiled binary is blocked (locked-down / MDM
# macOS, hardened Linux). It reproduces what `vxctl init --external-db` +
# `vxctl deploy --external-db --fleet-tier <N>` do:
#
#   1. Gather your managed/external Postgres details + the server CA.
#   2. Mint this install's UNIQUE app-crypto secrets (openssl, in the exact
#      byte-formats the api expects — see go/cmd/vxctl/secrets.go).
#   3. Create the cluster Secrets the chart consumes:
#        agogevx-postgres  — your external DB role's password
#        agogevx-db-ca     — the CA that signs the external DB's TLS cert
#        agogevx-secrets   — the 6-key app-crypto set (generated)
#        ghcr-creds        — (optional) private-image pull secret
#   4. (Optional) run an in-cluster `select 1` pre-check against the DB.
#   5. Write a chmod-600 plaintext backup of the secrets next to you (KEEP IT).
#   6. Run `helm upgrade --install` with the fleet-size tier values file
#      (values-prod-<N>.yaml) + the external-DB --set flags.
#
# Every AGOGE VX Kubernetes install is PRODUCTION: it connects to a
# dedicated/managed external Postgres (the chart runs no in-cluster database at
# these tiers) and is sized to a fleet tier. Nothing this script generates is
# written to git or any values file — secrets live only in the cluster + your
# local 0600 backup.
#
# Requirements on this machine: bash, openssl, kubectl, helm 3.8+, a kubeconfig
# pointing at the cluster, and (for GCP / DigitalOcean / self-managed DBs) the
# server CA cert as a PEM file. `curl` is used to auto-fetch the AWS/Azure CA.
#
# Usage: ./install.sh          (interactive menu — asks you everything as it goes)

set -euo pipefail

# ---------------------------------------------------------------------------
# Styling / small helpers
# ---------------------------------------------------------------------------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YEL=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GRN=""; YEL=""; CYN=""; RST=""
fi
say()  { printf '%s\n' "$*"; }
ok()   { printf '%s\xe2\x9c\x93%s %s\n' "$GRN" "$RST" "$*"; }
warn() { printf '%s!%s %s\n' "$YEL" "$RST" "$*"; }
info() { printf '%s\xe2\x86\x92%s %s\n' "$CYN" "$RST" "$*"; }
err()  { printf '%s\xe2\x9c\x97%s %s\n' "$RED" "$RST" "$*" >&2; }
die()  { err "$*"; exit 1; }
hr()   { printf '%s------------------------------------------------------------%s\n' "$DIM" "$RST"; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 not found on PATH — $2"; }

# ask VAR "Prompt" ["default"]   — reads a line, applies the default on empty input.
ask() {
  local __var="$1" __prompt="$2" __def="${3:-}" __in
  if [ -n "$__def" ]; then
    read -r -p "$(printf '%s%s%s [%s]: ' "$BOLD" "$__prompt" "$RST" "$__def")" __in || true
    __in="${__in:-$__def}"
  else
    read -r -p "$(printf '%s%s%s: ' "$BOLD" "$__prompt" "$RST")" __in || true
  fi
  printf -v "$__var" '%s' "$__in"
}

# ask_secret VAR "Prompt"        — reads without echo.
ask_secret() {
  local __var="$1" __prompt="$2" __in
  read -r -s -p "$(printf '%s%s%s: ' "$BOLD" "$__prompt" "$RST")" __in || true
  echo
  printf -v "$__var" '%s' "$__in"
}

# confirm "Question" ["Y"|"N" default]  — returns 0 for yes.
confirm() {
  local __q="$1" __def="${2:-N}" __in __hint
  if [ "$__def" = "Y" ]; then __hint="Y/n"; else __hint="y/N"; fi
  read -r -p "$(printf '%s%s%s [%s]: ' "$BOLD" "$__q" "$RST" "$__hint")" __in || true
  __in="${__in:-$__def}"
  case "$__in" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# ---------------------------------------------------------------------------
# Secret generation — formats verified against go/cmd/vxctl/secrets.go.
#   SECRET_KEY              base64url(32 bytes), NO padding  (RawURLEncoding)
#   API_KEY_PEPPER          base64 std(32 bytes), padded     (StdEncoding)
#   AGENT_TOKEN_PEPPER      base64 std(32 bytes), padded
#   MFA_ENCRYPTION_KEY      base64url(32 bytes), padded       (Fernet key)
#   BOOTSTRAP_KEY           base64url(32 bytes), padded       (Fernet key)
#   PGBOUNCER_AUTH_PASSWORD base64url(32 bytes), NO padding   (RawURLEncoding)
# (POSTGRES_PASSWORD is NOT generated here — it is your external DB's password.)
# ---------------------------------------------------------------------------
gen_b64_std()    { openssl rand -base64 "$1" | tr -d '\n'; }
gen_b64url_pad() { openssl rand -base64 "$1" | tr -d '\n' | tr '+/' '-_'; }
gen_b64url_raw() { openssl rand -base64 "$1" | tr -d '\n' | tr '+/' '-_' | tr -d '='; }

# ---------------------------------------------------------------------------
# kubectl / helm wrappers — CONTEXT is always resolved to a concrete value so we
# pass it explicitly (no ambiguity about which cluster we touch).
# ---------------------------------------------------------------------------
kc()    { kubectl --context "$CONTEXT" "$@"; }
helmc() { helm --kube-context "$CONTEXT" "$@"; }

secret_exists() { kc -n "$1" get secret "$2" >/dev/null 2>&1; }

# read_secret_key NS NAME KEY -> prints the DECODED value, or empty if absent.
read_secret_key() {
  local v
  v="$(kc -n "$1" get secret "$2" -o "jsonpath={.data.$3}" 2>/dev/null || true)"
  [ -n "$v" ] || return 0
  printf '%s' "$v" | openssl base64 -d 2>/dev/null || true
}

# upsert_generic NS NAME --from-...  — create-or-update an Opaque Secret.
upsert_generic() {
  local ns="$1" name="$2"; shift 2
  kc -n "$ns" create secret generic "$name" "$@" --dry-run=client -o yaml | kc -n "$ns" apply -f - >/dev/null
}

# is_ip HOST -> 0 if HOST looks like a bare IPv4/IPv6 literal (rejected: IP-SAN
# certs break sslmode=verify-full). Mirrors external_db.go isIPAddress.
is_ip() {
  case "$1" in *:*) return 0 ;; esac
  [[ "$1" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

# val_img KEY -> reads image.<KEY> (registry|org|version) from the chart values.
val_img() {
  awk -v k="$1" '
    /^[^[:space:]]/ { inb = ($0 ~ /^image:/) ? 1 : 0 }
    inb && $1 == k":" { v=$2; gsub(/["'\'']/,"",v); print v; exit }
  ' "$CHART/values.yaml"
}

# ---------------------------------------------------------------------------
# Chart auto-detection — the script lives in <chart>/scripts, so the chart is
# its parent. Fall back to the usual repo / bundle layouts, then ask.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
detect_chart() {
  local c
  for c in "$SCRIPT_DIR/.." \
           "./deploy/helm/agogevx" \
           "./kubernetes/helm_charts/agogevx" \
           "./helm_charts/agogevx"; do
    if [ -f "$c/Chart.yaml" ]; then (cd "$c" >/dev/null 2>&1 && pwd); return 0; fi
  done
  return 1
}

# ===========================================================================
# Flow
# ===========================================================================
clear 2>/dev/null || true
say "${BOLD}AGOGE VX — Kubernetes installer (external Postgres)${RST}"
say "${DIM}Secrets + Helm production install, the vxctl way, in pure shell.${RST}"
hr

# --- 0) Preflight -----------------------------------------------------------
need openssl "install it (ships with macOS/Linux; brew install openssl if missing)."
need kubectl "install it and point your kubeconfig at the target cluster."
need helm    "install Helm 3.8+ (brew install helm)."
ok "openssl, kubectl, helm found"

CHART="${CHART:-}"
if [ -z "$CHART" ]; then
  if CHART="$(detect_chart)"; then :; else
    warn "Could not auto-detect the Helm chart (looked for <chart>/Chart.yaml)."
    ask CHART "Path to the agogevx Helm chart directory"
  fi
fi
[ -f "$CHART/Chart.yaml" ] || die "no Chart.yaml under '$CHART' — set the CHART env var or answer the prompt."
ok "chart: $CHART"

# --- 1) Cluster context -----------------------------------------------------
hr
say "${BOLD}Choose the cluster (kube context)${RST}"
CURRENT="$(kubectl config current-context 2>/dev/null || true)"
CTXS=()
while IFS= read -r line; do [ -n "$line" ] && CTXS+=("$line"); done \
  < <(kubectl config get-contexts -o name 2>/dev/null || true)
[ "${#CTXS[@]}" -gt 0 ] || die "no kube contexts found — configure your kubeconfig first (kubectl config get-contexts)."

i=1
for c in "${CTXS[@]}"; do
  if [ "$c" = "$CURRENT" ]; then printf '  %s%2d)%s %s %s(current)%s\n' "$CYN" "$i" "$RST" "$c" "$DIM" "$RST"
  else printf '  %s%2d)%s %s\n' "$CYN" "$i" "$RST" "$c"; fi
  i=$((i + 1))
done
DEF_IDX=""
i=1; for c in "${CTXS[@]}"; do [ "$c" = "$CURRENT" ] && DEF_IDX="$i"; i=$((i + 1)); done
ask CTX_PICK "Context number" "${DEF_IDX:-1}"
case "$CTX_PICK" in ''|*[!0-9]*) die "not a number: $CTX_PICK" ;; esac
[ "$CTX_PICK" -ge 1 ] && [ "$CTX_PICK" -le "${#CTXS[@]}" ] || die "out of range: $CTX_PICK"
CONTEXT="${CTXS[$((CTX_PICK - 1))]}"
ok "context: $CONTEXT"

if kc cluster-info >/dev/null 2>&1; then
  ok "cluster reachable"
else
  warn "could not reach the cluster with this context (kubectl cluster-info failed)."
  confirm "Continue anyway?" "N" || die "aborted — fix your cluster access and re-run."
fi

# --- 2) Namespace / release -------------------------------------------------
hr
ask NAMESPACE "Namespace" "agogevx"
ask RELEASE   "Helm release name" "agogevx"

# --- 3) Fleet-size tier (selects values-prod-<tier>.yaml) -------------------
hr
say "${BOLD}Fleet size${RST}  ${DIM}(sizes the matcher/PgBouncer and the DB max_connections)${RST}"
say "  ${CYN}1)${RST} 25k    (\xe2\x89\xa4 25,000 agents  \xc2\xb7 matcher 3  \xc2\xb7 DB max_connections \xe2\x89\xa5 250)"
say "  ${CYN}2)${RST} 50k    (\xe2\x89\xa4 50,000 agents  \xc2\xb7 matcher 5  \xc2\xb7 DB max_connections \xe2\x89\xa5 300)"
say "  ${CYN}3)${RST} 100k   (\xe2\x89\xa4 100,000 agents \xc2\xb7 matcher 10 \xc2\xb7 DB max_connections \xe2\x89\xa5 350)"
say "  ${CYN}4)${RST} 150k   (\xe2\x89\xa4 150,000 agents \xc2\xb7 matcher 15 \xc2\xb7 DB max_connections \xe2\x89\xa5 400)"
say "  ${CYN}5)${RST} 200k   (\xe2\x89\xa4 200,000 agents \xc2\xb7 matcher 20 \xc2\xb7 DB max_connections \xe2\x89\xa5 500)"
say "  ${CYN}6)${RST} 250k   (\xe2\x89\xa4 250,000 agents \xc2\xb7 matcher 25 \xc2\xb7 DB max_connections \xe2\x89\xa5 600)"
ask TIER_PICK "Tier number" "3"
case "$TIER_PICK" in
  1) TIER="25k"  ;; 2) TIER="50k"  ;; 3) TIER="100k" ;;
  4) TIER="150k" ;; 5) TIER="200k" ;; 6) TIER="250k" ;;
  *) die "not a valid choice: $TIER_PICK" ;;
esac
TIER_VALUES="$CHART/values-prod-$TIER.yaml"
[ -f "$TIER_VALUES" ] || die "tier values file not found: $TIER_VALUES"
ok "tier: $TIER  ($TIER_VALUES)"

# --- 4) Deploy profile + domain ---------------------------------------------
hr
say "${BOLD}Ingress path${RST}"
say "  ${CYN}1)${RST} loadbalancer  cloud LoadBalancer + Caddy self-ACME (recommended; baked into the tier file)."
say "  ${CYN}2)${RST} ingress       behind an EXISTING nginx-ingress + cert-manager."
ask PROFILE_PICK "Profile number" "1"
case "$PROFILE_PICK" in
  1) PROFILE="loadbalancer" ;;
  2) PROFILE="ingress" ;;
  *) die "not a valid choice: $PROFILE_PICK" ;;
esac
ok "profile: $PROFILE"

ask DOMAIN "Public hostname (DNS name that will resolve to this cluster, e.g. valex.example.com)"
[ -n "$DOMAIN" ] || die "a public hostname is required."
ISSUER=""
if [ "$PROFILE" = "ingress" ]; then
  ask ISSUER "cert-manager ClusterIssuer name (blank to leave the chart default)"
fi

# --- 5) External / managed Postgres -----------------------------------------
hr
say "${BOLD}External / managed Postgres${RST}"
ask DB_HOST "DB hostname (FQDN — never an IP; it must match the server's TLS SAN)"
[ -n "$DB_HOST" ] || die "the external DB hostname is required."
if is_ip "$DB_HOST"; then die "'$DB_HOST' is an IP — use a hostname (IP-SAN certs fail sslmode=verify-full)."; fi
ask        DB_PORT "DB port" "5432"
ask        DB_NAME "Database name" "vulndb"
ask        DB_USER "DB user" "vulndb"
ask_secret DB_PASS "DB password for user '$DB_USER' (input hidden)"
[ -n "$DB_PASS" ] || die "the external DB password is required."

say ""
say "TLS mode:  ${CYN}1)${RST} verify-full ${DIM}(default; verifies hostname against the CA)${RST}   ${CYN}2)${RST} require ${DIM}(encrypt only)${RST}"
ask SSL_PICK "TLS mode number" "1"
case "$SSL_PICK" in 1) SSLMODE="verify-full" ;; 2) SSLMODE="require" ;; *) die "not a valid choice: $SSL_PICK" ;; esac

say ""
say "DB routing:  ${CYN}1)${RST} pgbouncer ${DIM}(pooled via in-cluster PgBouncer; recommended)${RST}   ${CYN}2)${RST} direct"
ask ROUTE_PICK "Routing number" "1"
case "$ROUTE_PICK" in 1) ROUTE="pgbouncer" ;; 2) ROUTE="direct" ;; *) die "not a valid choice: $ROUTE_PICK" ;; esac

# Admin creds for the one-time privilege bootstrap (the grant Job runs later, in
# section 12b). On a fresh managed DB the app user '$DB_USER' can't create its own
# tables until an admin GRANTs it CREATE + installs pg_stat_statements/pg_trgm.
# We collect the admin login HERE, right next to the app DB creds; the password is
# never persisted (transient Secret, deleted with the Job).
say ""
say "${BOLD}DB admin — for the one-time privilege bootstrap${RST}"
say "${DIM}'$DB_USER' needs CREATE granted by an admin on a fresh DB. Decline only if that's already done.${RST}"
DO_BOOTSTRAP="no"; ADMIN_USER=""; ADMIN_PW=""
if confirm "Grant '$DB_USER' its privileges during install (needs DB admin creds)?" "Y"; then
  ask        ADMIN_USER "DB admin user (can GRANT + CREATE EXTENSION, e.g. doadmin)" "doadmin"
  ask_secret ADMIN_PW   "Password for '$ADMIN_USER' (hidden; used once, never stored)"
  if [ -n "$ADMIN_PW" ]; then DO_BOOTSTRAP="yes"; else warn "no admin password entered — skipping bootstrap."; fi
fi

# --- 6) Server CA (mandatory — the chart always mounts agogevx-db-ca) -------
hr
say "${BOLD}Database server CA certificate${RST}"
say "  ${CYN}1)${RST} aws           AWS RDS / Aurora        ${DIM}(auto-fetch public bundle)${RST}"
say "  ${CYN}2)${RST} azure         Azure Database for PG   ${DIM}(auto-fetch public bundle)${RST}"
say "  ${CYN}3)${RST} gcp           GCP Cloud SQL           ${DIM}(supply the PEM file)${RST}"
say "  ${CYN}4)${RST} digitalocean  DO Managed Databases    ${DIM}(supply the PEM file)${RST}"
say "  ${CYN}5)${RST} self          Self-managed Postgres   ${DIM}(supply the PEM file)${RST}"
ask CA_PICK "Provider number" "1"
CA_TMP=""
CA_FILE=""
case "$CA_PICK" in
  1) CA_URL="https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem" ;;
  2) CA_URL="https://cacerts.digicert.com/DigiCertGlobalRootG2.crt.pem" ;;
  3|4|5) CA_URL="" ;;
  *) die "not a valid choice: $CA_PICK" ;;
esac
if [ -n "${CA_URL:-}" ] && confirm "Auto-fetch the provider CA bundle now?" "Y"; then
  need curl "install curl, or choose to supply the CA PEM file instead."
  CA_TMP="$(mktemp 2>/dev/null || echo "${TMPDIR:-/tmp}/agogevx-db-ca.$$")"
  info "downloading $CA_URL"
  curl -fsSL "$CA_URL" -o "$CA_TMP" || die "CA download failed — supply the PEM file manually instead."
  CA_FILE="$CA_TMP"
else
  ask CA_FILE "Path to the server CA cert (PEM)"
fi
[ -n "$CA_FILE" ] && [ -f "$CA_FILE" ] || die "CA file not found: '$CA_FILE'"
grep -q "BEGIN CERTIFICATE" "$CA_FILE" || die "'$CA_FILE' has no PEM CERTIFICATE block — wrong file?"
ok "CA: $CA_FILE"

# --- 7) Optional GHCR image-pull secret ------------------------------------
hr
GHCR_USER=""; GHCR_TOKEN=""
if confirm "Create a GHCR image-pull secret (needed if the images are private)?" "Y"; then
  ask        GHCR_USER  "GitHub username (bot user from onboarding)"
  ask_secret GHCR_TOKEN "GitHub token (read:packages PAT — input hidden)"
  if [ -z "$GHCR_USER" ] || [ -z "$GHCR_TOKEN" ]; then
    warn "both a username and token are required — skipping the pull secret."
    GHCR_USER=""; GHCR_TOKEN=""
  fi
fi

# --- 8) Values file + --set flags (mirrors vxctl helmSets/helmArgs) ---------
VALUES_FILES=("$TIER_VALUES")
SETS=("domain=$DOMAIN"
      "postgres.external.enabled=true"
      "postgres.external.host=$DB_HOST"
      "postgres.external.port=$DB_PORT"
      "postgres.external.database=$DB_NAME"
      "postgres.external.user=$DB_USER"
      "postgres.external.sslMode=$SSLMODE"
      "postgres.external.caCertSecret=agogevx-db-ca"
      "db.route=$ROUTE")
if [ "$PROFILE" = "ingress" ]; then
  # Layer values-ingress.yaml AFTER the tier file (helm merges later -f over
  # earlier), then --set the ingress identity (wins over both).
  [ -f "$CHART/values-ingress.yaml" ] || die "values-ingress.yaml not found in $CHART"
  VALUES_FILES+=("$CHART/values-ingress.yaml")
  SETS+=("deployMode=ingress" "ingress.enabled=true" "ingress.host=$DOMAIN")
  [ -n "$ISSUER" ] && SETS+=("certManager.issuerRef.name=$ISSUER")
fi

HELM_ARGS=(upgrade --install "$RELEASE" "$CHART")
for f in "${VALUES_FILES[@]}"; do HELM_ARGS+=(-f "$f"); done
HELM_ARGS+=(-n "$NAMESPACE" --create-namespace)
for s in "${SETS[@]}"; do HELM_ARGS+=(--set "$s"); done

# --- 9) Summary + go/no-go --------------------------------------------------
hr
say "${BOLD}Review${RST}"
say "  context     : $CONTEXT"
say "  namespace   : $NAMESPACE"
say "  release     : $RELEASE"
say "  fleet tier  : $TIER"
say "  profile     : $PROFILE"
say "  domain      : $DOMAIN"
[ -n "$ISSUER" ] && say "  issuer      : $ISSUER"
say "  external DB : $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME  sslmode=$SSLMODE  route=$ROUTE"
say "  DB CA       : $CA_FILE"
say "  pull secret : $([ -n "$GHCR_USER" ] && echo "ghcr-creds (user $GHCR_USER)" || echo "none")"
say "  db bootstrap: $([ "$DO_BOOTSTRAP" = "yes" ] && echo "yes (grant as $ADMIN_USER, one-off)" || echo "no")"
say "  helm        : helm ${HELM_ARGS[*]}"
hr
confirm "Create the secrets and run this install now?" "N" || die "aborted — nothing changed."

# --- 10) Namespace ----------------------------------------------------------
if kc get namespace "$NAMESPACE" >/dev/null 2>&1; then
  ok "namespace/$NAMESPACE exists"
else
  kc create namespace "$NAMESPACE" >/dev/null
  ok "namespace/$NAMESPACE created"
fi

# --- 11) DB-side Secrets (must match the external DB → always upserted) ------
# ghcr-creds first, so the optional pre-check can pull the postgres image.
if [ -n "$GHCR_USER" ] && [ -n "$GHCR_TOKEN" ]; then
  if secret_exists "$NAMESPACE" "ghcr-creds"; then
    warn "secret/ghcr-creds already exists — left unchanged"
  else
    kc -n "$NAMESPACE" create secret docker-registry ghcr-creds \
       --docker-server=ghcr.io --docker-username="$GHCR_USER" --docker-password="$GHCR_TOKEN" >/dev/null
    ok "secret/ghcr-creds created"
  fi
fi

upsert_generic "$NAMESPACE" agogevx-db-ca --from-file="ca.crt=$CA_FILE"
ok "secret/agogevx-db-ca applied (external DB CA)"

upsert_generic "$NAMESPACE" agogevx-postgres --from-literal="POSTGRES_PASSWORD=$DB_PASS"
ok "secret/agogevx-postgres applied (external DB password)"

# Clean up an auto-fetched CA temp file now that it is in the cluster.
[ -n "$CA_TMP" ] && rm -f "$CA_TMP" 2>/dev/null || true

# --- 12) Optional in-cluster DB pre-check (TLS + auth + select 1) -----------
precheck_db() {
  local reg org ver image job dsn
  reg="$(val_img registry)"; org="$(val_img org)"; ver="$(val_img version)"
  if [ -z "$reg" ] || [ -z "$org" ] || [ -z "$ver" ]; then
    warn "could not resolve the postgres image from values.yaml — skipping pre-check"; return 0
  fi
  image="$reg/$org/agogevx-postgres:$ver"
  job="agogevx-db-precheck-$(date -u +%Y%m%d%H%M%S)"
  dsn="postgresql://$DB_USER@$DB_HOST:$DB_PORT/$DB_NAME?sslmode=$SSLMODE&sslrootcert=/etc/agogevx/db-ca.crt"
  info "pre-check: $image runs 'select 1' from inside the cluster…"
  kc -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $NAMESPACE
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: ghcr-creds
      containers:
        - name: precheck
          image: $image
          command: ["sh","-c","psql \"$dsn\" -c 'select 1'"]
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: agogevx-postgres
                  key: POSTGRES_PASSWORD
          volumeMounts:
            - name: db-ca
              mountPath: /etc/agogevx
              readOnly: true
      volumes:
        - name: db-ca
          secret:
            secretName: agogevx-db-ca
            items:
              - key: ca.crt
                path: db-ca.crt
EOF
  if kc -n "$NAMESPACE" wait --for=condition=complete "job/$job" --timeout=90s >/dev/null 2>&1; then
    ok "external DB reachable (TLS + auth + select 1)"
    kc -n "$NAMESPACE" delete job "$job" >/dev/null 2>&1 || true
    return 0
  fi
  err "external DB pre-check did NOT succeed. Job logs:"
  kc -n "$NAMESPACE" logs "job/$job" 2>&1 | sed 's/^/    /' || true
  kc -n "$NAMESPACE" delete job "$job" >/dev/null 2>&1 || true
  return 1
}
hr
if confirm "Run an in-cluster DB pre-check before deploying (recommended)?" "Y"; then
  if ! precheck_db; then
    confirm "Pre-check failed — continue with the install anyway?" "N" || die "aborted after failed pre-check."
  fi
fi

# --- 12b) One-time DB privilege bootstrap (admin creds, used once) ----------
# Runs the GRANTs + CREATE EXTENSION as the DB admin via a one-off Job, then
# deletes the Job AND the transient admin-password Secret. agogevx_app is NEVER
# given admin rights — the admin only grants it CREATE on its own DB/schema.
# The password rides in a short-lived Secret (env, not argv) and is removed here.
bootstrap_db() {
  local reg org ver image job sname dsn rc=0
  reg="$(val_img registry)"; org="$(val_img org)"; ver="$(val_img version)"
  if [ -z "$reg" ] || [ -z "$org" ] || [ -z "$ver" ]; then
    err "could not resolve the postgres image from values.yaml — cannot run the bootstrap Job"; return 1
  fi
  image="$reg/$org/agogevx-postgres:$ver"
  job="agogevx-db-bootstrap-$(date -u +%Y%m%d%H%M%S)"
  sname="agogevx-db-bootstrap-admin"
  dsn="postgresql://$ADMIN_USER@$DB_HOST:$DB_PORT/$DB_NAME?sslmode=$SSLMODE&sslrootcert=/etc/agogevx/db-ca.crt"

  # Transient admin-password Secret (deleted right after the Job).
  kc -n "$NAMESPACE" create secret generic "$sname" --from-literal="PGPASSWORD=$ADMIN_PW" --dry-run=client -o yaml | kc -n "$NAMESPACE" apply -f - >/dev/null

  info "bootstrap: granting $DB_USER rights on $DB_NAME as $ADMIN_USER (one-off Job)…"
  kc -n "$NAMESPACE" apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: $job
  namespace: $NAMESPACE
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 120
  template:
    spec:
      restartPolicy: Never
      imagePullSecrets:
        - name: ghcr-creds
      containers:
        - name: bootstrap
          image: $image
          command: ["psql"]
          args:
            - "$dsn"
            - "-v"
            - "ON_ERROR_STOP=1"
            - "-c"
            - "GRANT ALL ON DATABASE \"$DB_NAME\" TO \"$DB_USER\";"
            - "-c"
            - "GRANT ALL ON SCHEMA public TO \"$DB_USER\";"
            - "-c"
            - "CREATE EXTENSION IF NOT EXISTS pg_stat_statements;"
            - "-c"
            - "CREATE EXTENSION IF NOT EXISTS pg_trgm;"
          env:
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: $sname
                  key: PGPASSWORD
          volumeMounts:
            - name: db-ca
              mountPath: /etc/agogevx
              readOnly: true
      volumes:
        - name: db-ca
          secret:
            secretName: agogevx-db-ca
            items:
              - key: ca.crt
                path: db-ca.crt
EOF
  if kc -n "$NAMESPACE" wait --for=condition=complete "job/$job" --timeout=90s >/dev/null 2>&1; then
    ok "bootstrap complete — $DB_USER granted CREATE on $DB_NAME + public; pg_stat_statements/pg_trgm ensured"
  else
    err "bootstrap Job did NOT succeed. Job logs:"
    kc -n "$NAMESPACE" logs "job/$job" 2>&1 | sed 's/^/    /' || true
    rc=1
  fi
  # Always remove the Job and the transient admin-password Secret.
  kc -n "$NAMESPACE" delete job "$job" >/dev/null 2>&1 || true
  kc -n "$NAMESPACE" delete secret "$sname" >/dev/null 2>&1 || true
  return $rc
}
if [ "$DO_BOOTSTRAP" = "yes" ]; then
  if ! bootstrap_db; then
    confirm "Bootstrap failed — continue with the install anyway?" "N" || die "aborted after failed bootstrap."
  fi
fi
ADMIN_PW=""  # drop the admin password from the shell regardless

# --- 13) App-crypto Secret (generated; NOT clobbered if it already exists) --
SECRET_KEY=""; API_KEY_PEPPER=""; AGENT_TOKEN_PEPPER=""
MFA_ENCRYPTION_KEY=""; BOOTSTRAP_KEY=""; PGBOUNCER_AUTH_PASSWORD=""
if secret_exists "$NAMESPACE" "agogevx-secrets"; then
  warn "secret/agogevx-secrets already exists — left unchanged (rotating it would break MFA + stored integration creds)"
  SECRET_KEY="$(read_secret_key "$NAMESPACE" "agogevx-secrets" "SECRET_KEY")"
  API_KEY_PEPPER="$(read_secret_key "$NAMESPACE" "agogevx-secrets" "API_KEY_PEPPER")"
  AGENT_TOKEN_PEPPER="$(read_secret_key "$NAMESPACE" "agogevx-secrets" "AGENT_TOKEN_PEPPER")"
  MFA_ENCRYPTION_KEY="$(read_secret_key "$NAMESPACE" "agogevx-secrets" "MFA_ENCRYPTION_KEY")"
  BOOTSTRAP_KEY="$(read_secret_key "$NAMESPACE" "agogevx-secrets" "BOOTSTRAP_KEY")"
  PGBOUNCER_AUTH_PASSWORD="$(read_secret_key "$NAMESPACE" "agogevx-secrets" "PGBOUNCER_AUTH_PASSWORD")"
else
  SECRET_KEY="$(gen_b64url_raw 32)"
  API_KEY_PEPPER="$(gen_b64_std 32)"
  AGENT_TOKEN_PEPPER="$(gen_b64_std 32)"
  MFA_ENCRYPTION_KEY="$(gen_b64url_pad 32)"
  BOOTSTRAP_KEY="$(gen_b64url_pad 32)"
  PGBOUNCER_AUTH_PASSWORD="$(gen_b64url_raw 32)"
  kc -n "$NAMESPACE" create secret generic agogevx-secrets \
     --from-literal="SECRET_KEY=$SECRET_KEY" \
     --from-literal="API_KEY_PEPPER=$API_KEY_PEPPER" \
     --from-literal="AGENT_TOKEN_PEPPER=$AGENT_TOKEN_PEPPER" \
     --from-literal="MFA_ENCRYPTION_KEY=$MFA_ENCRYPTION_KEY" \
     --from-literal="BOOTSTRAP_KEY=$BOOTSTRAP_KEY" \
     --from-literal="PGBOUNCER_AUTH_PASSWORD=$PGBOUNCER_AUTH_PASSWORD" >/dev/null
  ok "secret/agogevx-secrets created (6 keys)"
fi

# --- 14) 0600 plaintext backup of the effective secrets ---------------------
BACKUP_DIR="${PWD}/install_data"
mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR" 2>/dev/null || true
TS="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="$BACKUP_DIR/agogevx-secrets-${NAMESPACE}-${TS}.env"
umask 077
{
  echo "# AGOGE VX install secrets — namespace '$NAMESPACE', context '$CONTEXT', $TS"
  echo "# PLAINTEXT and chmod 600. Store this in your secret manager and delete the file."
  echo "# DB: $DB_USER@$DB_HOST:$DB_PORT/$DB_NAME  sslmode=$SSLMODE  route=$ROUTE"
  echo "# The server CA is in the agogevx-db-ca Secret (from $CA_FILE)."
  echo "POSTGRES_PASSWORD=$DB_PASS"
  echo "SECRET_KEY=$SECRET_KEY"
  echo "API_KEY_PEPPER=$API_KEY_PEPPER"
  echo "AGENT_TOKEN_PEPPER=$AGENT_TOKEN_PEPPER"
  echo "MFA_ENCRYPTION_KEY=$MFA_ENCRYPTION_KEY"
  echo "BOOTSTRAP_KEY=$BOOTSTRAP_KEY"
  echo "PGBOUNCER_AUTH_PASSWORD=$PGBOUNCER_AUTH_PASSWORD"
} > "$BACKUP"
chmod 600 "$BACKUP" 2>/dev/null || true
ok "secret backup (0600) -> $BACKUP"
warn "KEEP THIS FILE SAFE. BOOTSTRAP_KEY decrypts stored integration creds; MFA_ENCRYPTION_KEY decrypts enrolled MFA seeds."

# --- 15) Helm install -------------------------------------------------------
hr
info "helm ${HELM_ARGS[*]}"
if helmc "${HELM_ARGS[@]}"; then
  ok "deploy complete"
else
  die "helm failed — the Secrets are already in the cluster; fix the error and re-run helm (or this script)."
fi

# --- 16) Post-install -------------------------------------------------------
hr
case "$PROFILE" in
  ingress)
    ok "Reach AGOGE VX at:  https://$DOMAIN/  (point its DNS at your ingress controller)"
    ;;
  loadbalancer)
    ADDR="$(kc -n "$NAMESPACE" get svc frontend-lb -o 'jsonpath={.status.loadBalancer.ingress[0].ip}{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
    if [ -n "$ADDR" ]; then
      ok "Point $DOMAIN's DNS at the frontend LoadBalancer:  $ADDR"
    else
      warn "LoadBalancer address still pending — check: kubectl -n $NAMESPACE get svc frontend-lb, then point $DOMAIN at it"
    fi
    ;;
esac
warn "Before scaling traffic: configure object storage (System -> Storage -> a private S3 bucket)."
warn "The prod tiers set blobVolumeKind=emptyDir, so without S3, avatars/reports land on per-pod disk and 404 cross-pod."
say ""
ok "Done. First browse lands on the setup wizard."
