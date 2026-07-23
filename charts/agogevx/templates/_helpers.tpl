{{/*
Common labels applied to every object.
*/}}
{{- define "agogevx.commonLabels" -}}
app.kubernetes.io/name: agogevx
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Values.image.version | quote }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{/*
Build a full image reference for one of the published images.
Usage: {{ include "agogevx.image" (list . .Values.image.names.api) }}
*/}}
{{- define "agogevx.image" -}}
{{- $root := index . 0 -}}
{{- $name := index . 1 -}}
{{- printf "%s/%s/%s:%s" $root.Values.image.registry $root.Values.image.org $name $root.Values.image.version -}}
{{- end -}}

{{/*
External-database helpers (plans/finished/external-database-support.md).
*/}}
{{- define "agogevx.dbBackendKind" -}}
{{- if .Values.postgres.external.enabled -}}external{{- else -}}internal{{- end -}}
{{- end -}}

{{/* Effective DB user / database — the external block overrides the in-cluster
     defaults (a managed DB may use e.g. doadmin / defaultdb). */}}
{{- define "agogevx.dbUser" -}}
{{- if .Values.postgres.external.enabled -}}{{ .Values.postgres.external.user | default .Values.postgres.user }}{{- else -}}{{ .Values.postgres.user }}{{- end -}}
{{- end -}}
{{- define "agogevx.dbName" -}}
{{- if .Values.postgres.external.enabled -}}{{ .Values.postgres.external.database | default .Values.postgres.database }}{{- else -}}{{ .Values.postgres.database }}{{- end -}}
{{- end -}}

{{/*
DB host/port for the app pool.
  external + direct  -> the external host:port (app dials it; no pooler)
  pgbouncer (either) -> pgbouncer:6432 (pooled — our pgbouncer fronts db OR external)
  internal + direct  -> db:5432
*/}}
{{- define "agogevx.dbHost" -}}
{{- if and .Values.postgres.external.enabled (eq .Values.db.route "direct") -}}{{ .Values.postgres.external.host }}
{{- else if eq .Values.db.route "pgbouncer" -}}pgbouncer
{{- else -}}db
{{- end -}}
{{- end -}}
{{- define "agogevx.dbPort" -}}
{{- if and .Values.postgres.external.enabled (eq .Values.db.route "direct") -}}{{ .Values.postgres.external.port }}
{{- else if eq .Values.db.route "pgbouncer" -}}6432
{{- else -}}5432
{{- end -}}
{{- end -}}

{{/* CA volume + mount for the external-DB TLS leg. mountPath /etc/valex; the
     sslrootcert path is /etc/valex/db-ca.crt. The Secret must carry key ca.crt. */}}
{{- define "agogevx.dbCaVolume" -}}
- name: db-ca
  secret:
    secretName: {{ .Values.postgres.external.caCertSecret | quote }}
    items:
      - key: ca.crt
        path: db-ca.crt
{{- end -}}
{{- define "agogevx.dbCaVolumeMount" -}}
- name: db-ca
  mountPath: /etc/valex
  readOnly: true
{{- end -}}

{{/* "true" when this pod opens a DIRECT connection to the external DB and so
     needs the CA mounted. api, ingestion-worker, maintenance-worker, and
     report-worker always do (boot migrations / advisory locks / CONCURRENTLY
     matview refresh / the daily fleet-rollup scan all bypass pgbouncer); the
     other workers only do in direct sub-mode where there is no pgbouncer at all.
     Usage: pass (dict "root" . "direct" true) for
     api/ingestion/maintenance/report. */}}
{{- define "agogevx.dbCaNeeded" -}}
{{- $root := .root -}}
{{- if $root.Values.postgres.external.enabled -}}
{{- if .direct -}}true{{- else if eq $root.Values.db.route "direct" -}}true{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Name of the Secret holding POSTGRES_PASSWORD (existing or chart-created).
*/}}
{{- define "agogevx.postgresSecretName" -}}
{{- if .Values.postgres.existingSecret -}}{{ .Values.postgres.existingSecret }}{{- else -}}agogevx-postgres{{- end -}}
{{- end -}}

{{/*
Shared DB env block (POSTGRES_PASSWORD from Secret, DB_HOST/DB_PORT, DATABASE_URL).
DATABASE_URL uses Kubernetes $(VAR) expansion against the earlier vars so the
password stays only in the Secret. Emit under `env:` with `| nindent N`.
*/}}
{{- define "agogevx.dbEnv" -}}
- name: POSTGRES_PASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ include "agogevx.postgresSecretName" . }}
      key: POSTGRES_PASSWORD
- name: DB_HOST
  value: {{ include "agogevx.dbHost" . | quote }}
- name: DB_PORT
  value: {{ include "agogevx.dbPort" . | quote }}
- name: DB_BACKEND
  value: {{ include "agogevx.dbBackendKind" . | quote }}
{{- if and .Values.postgres.external.enabled (eq .Values.db.route "direct") }}
# External direct (sub-mode B): the app pool dials the external DB itself, so
# DATABASE_URL carries the TLS params. CA is mounted on every pod here.
- name: DATABASE_URL
  value: "postgresql://{{ include "agogevx.dbUser" . }}:$(POSTGRES_PASSWORD)@$(DB_HOST):$(DB_PORT)/{{ include "agogevx.dbName" . }}?sslmode={{ .Values.postgres.external.sslMode }}&sslrootcert=/etc/valex/db-ca.crt"
{{- else }}
# Internal, or external pooled (sub-mode A): the app pool talks to the in-cluster
# pgbouncer/db over the trusted cluster network, so sslmode=disable.
- name: DATABASE_URL
  value: "postgresql://{{ include "agogevx.dbUser" . }}:$(POSTGRES_PASSWORD)@$(DB_HOST):$(DB_PORT)/{{ include "agogevx.dbName" . }}?sslmode=disable"
{{- end }}
{{- if .Values.postgres.external.enabled }}
# Direct-to-external DSN over TLS — consumed by api + ingestion-worker (boot
# migrations, advisory locks, CONCURRENTLY matview refresh) via
# migrate.DirectPGDSN. Always points at the external host (NOT the pgbouncer
# hop), regardless of sub-mode. Harmless/unused on workers that never dial direct.
- name: DIRECT_DATABASE_URL
  value: "postgresql://{{ include "agogevx.dbUser" . }}:$(POSTGRES_PASSWORD)@{{ .Values.postgres.external.host }}:{{ .Values.postgres.external.port }}/{{ include "agogevx.dbName" . }}?sslmode={{ .Values.postgres.external.sslMode }}&sslrootcert=/etc/valex/db-ca.crt"
{{- end }}
{{- end -}}

{{/*
BOOTSTRAP_KEY env from the app-secrets Secret (the vxctl-minted Fernet key).
secretsvc reads this to decrypt the integration_secrets table, so every service
that touches those rows (api, report-worker, audit-forward-worker,
ingestion-worker) needs it when running without a bootstrap volume (ingress).
optional:true so a compose-mode K8s deploy (api writes bootstrap.key to the
shared volume; secretsvc falls back to the file) is unaffected by a missing key.
Emit under `env:` with `| nindent N`.
*/}}
{{- define "agogevx.bootstrapKeyEnv" -}}
{{- if .Values.api.appSecretsSecret }}
- name: BOOTSTRAP_KEY
  valueFrom:
    secretKeyRef:
      name: {{ .Values.api.appSecretsSecret | quote }}
      key: BOOTSTRAP_KEY
      optional: true
{{- end }}
{{- end -}}

{{/*
Normalized deployment mode: "compose" (default) | "ingress" | "loadbalancer".
  - compose      : single-node; the api issues TLS (lego) + pushes Caddy config;
                   secrets/config on RWO volumes. (topology=single)
  - ingress      : multi-node behind nginx-ingress + cert-manager; secrets from
                   the agogevx-secrets Secret; api scales.
  - loadbalancer : multi-node behind a Service type=LoadBalancer; the frontend
                   Caddy self-ACMEs; secrets from the agogevx-secrets Secret; api scales.
"compose" and "loadbalancer" both keep ingress.enabled=false (the Ingress objects
render only under ingress.enabled), so the boolean alone cannot tell them apart —
templates that differ between them MUST use these helpers.
*/}}
{{- define "agogevx.deployMode" -}}
{{- .Values.deployMode | default "compose" | lower -}}
{{- end -}}

{{/* "true" only in compose mode (api manages TLS; RWO bootstrap-config + tls-certs). */}}
{{- define "agogevx.isCompose" -}}
{{- if eq (include "agogevx.deployMode" .) "compose" -}}true{{- end -}}
{{- end -}}

{{/* "true" in loadbalancer mode (frontend Caddy self-ACME behind a LoadBalancer Service). */}}
{{- define "agogevx.isLoadBalancer" -}}
{{- if eq (include "agogevx.deployMode" .) "loadbalancer" -}}true{{- end -}}
{{- end -}}

{{/* "true" when secrets come from the agogevx-secrets Secret and the api scales to N
     (ingress OR loadbalancer — i.e. NOT compose). */}}
{{- define "agogevx.secretsFromEnv" -}}
{{- if ne (include "agogevx.deployMode" .) "compose" -}}true{{- end -}}
{{- end -}}

{{/*
imagePullSecrets block. Emit at pod-spec indent with `| nindent N`.
*/}}
{{- define "agogevx.imagePullSecrets" -}}
{{- with .Values.imagePullSecrets }}
imagePullSecrets:
{{- toYaml . | nindent 0 }}
{{- end -}}
{{- end -}}

{{/*
Pod-level securityContext for the non-root services (api, workers, pgbouncer).
The db pod and frontend pod set their own (see their templates).
*/}}
{{- define "agogevx.podSecurityContext" -}}
runAsUser: 100
runAsGroup: 101
fsGroup: 101
fsGroupChangePolicy: OnRootMismatch
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{/*
Container-level securityContext for the hardened Go services (api + the six
workers). Drops all capabilities — none of the Go binaries need any — and runs
with a read-only root filesystem. Every persistent write goes to a mounted
volume.

/tmp handling differs by service:
  - api, ingestion, report, maintenance DO write /tmp (TLS status files, the lego
    writability probe, the Ubuntu-UCT go-git clone, DB-backup temp archives,
    multipart upload spill) and mount a `tmp` emptyDir. /tmp is data-only —
    nothing in any image execs from it (lego runs from /usr/local/bin; UCT uses
    in-process go-git, no git binary/hooks) — so it stays writable but unused for
    execution. k8s emptyDir has no noexec option; the dropped caps +
    allowPrivilegeEscalation:false + runAsNonRoot are the compensating controls.
  - matcher, bte-recompute, audit-forward write only to Postgres (+ a socket),
    so they mount NO writable volume at all — a 100% read-only filesystem.

NOTE: pgbouncer and frontend(Caddy) do NOT use this helper — their entrypoints
write runtime config/socket/data dirs (/etc/pgbouncer, /data/caddy, …) that
would need their own scratch mounts before readOnlyRootFilesystem is safe;
that hardening is the tracked follow-up in .trivyignore.yaml (AVD-KSV-0014).
*/}}
{{- define "agogevx.containerSecurityContext" -}}
allowPrivilegeEscalation: false
runAsNonRoot: true
readOnlyRootFilesystem: true
capabilities:
  drop:
    - ALL
{{- end -}}

{{/*
Per-component resources, falling back to the global .Values.resources default.
A component value (e.g. .Values.matcher) may carry its own `resources:` block to
override the global default — this lets the memory-heavy matcher take a larger
limit (sized by vxctl from the node memory) without inflating every pod.
Usage: {{ include "agogevx.componentResources" (dict "root" . "component" .Values.matcher) | nindent 12 }}
*/}}
{{- define "agogevx.componentResources" -}}
{{- $comp := .component -}}
{{- if and $comp $comp.resources -}}
{{- toYaml $comp.resources -}}
{{- else -}}
{{- toYaml .root.Values.resources -}}
{{- end -}}
{{- end -}}

{{/*
Enterprise egress proxy (enclave) — plans/enterprise-egress-proxy-support.md.
*/}}

{{/* Fail render if egress is enabled outside ingress mode: compose/loadbalancer
     run the api's lego TLS path, whose pinned UDP:53 resolver a CONNECT proxy
     cannot carry (it would hang, not fail fast). Invoke once from a template that
     always renders (api-deployment.yaml). */}}
{{- define "agogevx.validateEgress" -}}
{{- if and .Values.egress.enabled (ne (include "agogevx.deployMode" .) "ingress") -}}
{{- fail "egress.enabled is only supported with deployMode: ingress" -}}
{{- end -}}
{{- end -}}

{{/* Effective NO_PROXY: the configured base plus the external DB host (Class 2 —
     database traffic must never be sent through the HTTP proxy). */}}
{{- define "agogevx.egressNoProxy" -}}
{{- $np := .Values.egress.noProxy -}}
{{- if .Values.postgres.external.enabled -}}{{- $np = printf "%s,%s" $np .Values.postgres.external.host -}}{{- end -}}
{{- $np -}}
{{- end -}}

{{/* Proxy env block for a Class-1 egress workload. Gate the include at the call
     site with `and .Values.egress.enabled .Values.egress.httpWorkloads.<name>`;
     emit under `env:` with `| nindent 12`. */}}
{{- define "agogevx.egressProxyEnv" -}}
- name: HTTP_PROXY
  value: {{ .Values.egress.proxyUrl | quote }}
- name: HTTPS_PROXY
  value: {{ .Values.egress.proxyUrl | quote }}
- name: NO_PROXY
  value: {{ include "agogevx.egressNoProxy" . | quote }}
{{- end -}}
