<#
.SYNOPSIS
  Create the per-install Kubernetes secrets AGOGE VX needs, with values UNIQUE to
  this install. Run ONCE before `helm install`. Nothing it generates is written
  to git or to any values file — the secret lives only in the cluster.

.DESCRIPTION
  AGOGE VX needs exactly one operator-supplied secret: the Postgres password. This
  script mints a strong random password for THIS install and stores it as the
  `agogevx-postgres` Secret. The chart references that name by default, so no
  `--set` is needed at install time.

  It can also create the (optional) private-image pull secret from YOUR GitHub
  token — that is your personal credential, not a shared one.

  It does NOT manage the app's own secrets (SECRET_KEY, the HMAC peppers, the MFA
  key, the pgbouncer password): the api generates those randomly on first boot
  and persists them to the bootstrap-config volume, so every install already gets
  its own.

  IDEMPOTENT: if the Postgres secret already exists it is left untouched. Postgres
  only applies POSTGRES_PASSWORD when it first initialises an empty data volume —
  rotating the secret on an existing database would desync it and break auth. Use
  -Rotate only against a fresh/empty postgres-data volume.

.EXAMPLE
  ./init-secrets.ps1
  ./init-secrets.ps1 -Namespace agogevx -GhcrUser myuser -GhcrToken ghp_xxx
#>
[CmdletBinding()]
param(
    [string]$Namespace      = "agogevx",
    [string]$SecretName     = "agogevx-postgres",
    [int]$PasswordLength     = 32,
    [switch]$Rotate,                         # DANGER: only on a fresh DB volume
    [string]$GhcrUser,                       # optional private-image pull cred
    [string]$GhcrToken,
    [string]$GhcrSecretName = "ghcr-creds"
)

$ErrorActionPreference = "Stop"

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw "kubectl not found on PATH. Install it and select your cluster context first."
}

function New-RandomAlphanumeric([int]$Length) {
    # URL-safe (A-Za-z0-9 only) so the password is safe inside DATABASE_URL.
    $alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $bytes = New-Object 'byte[]' $Length
        $rng.GetBytes($bytes)
        -join ($bytes | ForEach-Object { $alphabet[ $_ % $alphabet.Length ] })
    } finally { $rng.Dispose() }
}

# 1) Namespace -------------------------------------------------------------
kubectl get namespace $Namespace *> $null
if ($LASTEXITCODE -ne 0) {
    kubectl create namespace $Namespace | Out-Null
    Write-Host "Created namespace '$Namespace'."
}

# 2) Postgres password secret (idempotent) ---------------------------------
kubectl get secret $SecretName -n $Namespace *> $null
$exists = ($LASTEXITCODE -eq 0)

if ($exists -and -not $Rotate) {
    Write-Host "Secret '$SecretName' already exists in '$Namespace' — leaving it unchanged."
    Write-Host "  (Postgres sets its password only on first data-volume init; rotating now would"
    Write-Host "   break auth against an existing database. Use -Rotate only on a fresh volume.)"
}
else {
    if ($exists -and $Rotate) {
        Write-Warning "Rotating '$SecretName'. This is safe ONLY if postgres-data is fresh/empty; otherwise the running DB keeps its old password and auth breaks."
        kubectl delete secret $SecretName -n $Namespace | Out-Null
    }
    $pw = New-RandomAlphanumeric $PasswordLength
    kubectl create secret generic $SecretName -n $Namespace `
        --from-literal=POSTGRES_PASSWORD=$pw | Out-Null
    Write-Host "Created secret '$SecretName' in '$Namespace' with a unique random password ($PasswordLength chars)."
}

# 3) Optional private-image pull secret ------------------------------------
if ($GhcrUser -and $GhcrToken) {
    kubectl get secret $GhcrSecretName -n $Namespace *> $null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Pull secret '$GhcrSecretName' already exists — leaving it unchanged."
    } else {
        kubectl create secret docker-registry $GhcrSecretName -n $Namespace `
            --docker-server=ghcr.io --docker-username=$GhcrUser --docker-password=$GhcrToken | Out-Null
        Write-Host "Created image pull secret '$GhcrSecretName'."
    }
}
elseif ($GhcrUser -or $GhcrToken) {
    Write-Warning "Provide BOTH -GhcrUser and -GhcrToken to create the pull secret (skipping)."
}

# 4) Next step -------------------------------------------------------------
Write-Host ""
Write-Host "Secrets are in the cluster (never in git). Install without passing a password:"
Write-Host "  helm upgrade --install agogevx ./deploy/helm/agogevx ``"
Write-Host "    -f ./deploy/helm/agogevx/values-staging.yaml ``"
Write-Host "    -n $Namespace --create-namespace"
Write-Host ""
Write-Host "The chart references the '$SecretName' Secret by default — no --set postgres.password needed."
