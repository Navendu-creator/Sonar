#!/usr/bin/env bash
# Generates PipeCD credentials into k8s/pipecd/.secrets/ (gitignored) and
# creates or updates the Kubernetes Secrets built from them:
#
#   pipecd-mysql      used by mysql/         (root and pipecd user passwords)
#   pipecd-filestore  used by filestore/     (S3 identity config)
#   pipecd-secrets    used by control-plane/ (encryption key, DB and S3 credentials)
#
# Each value is generated once and reused on every run. Losing .secrets/ means
# losing the database password and the encryption key, so back it up.
set -euo pipefail

NS=pipecd
SECRETS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.secrets"
mkdir -p "$SECRETS" && chmod 700 "$SECRETS"

# Writes a random value to $SECRETS/<name> unless it already exists.
# No trailing newline: PipeCD reads credential files verbatim.
gen() {
  local file="$SECRETS/$1"
  [[ -s "$file" ]] || { openssl rand -hex "${2:-24}" | tr -d '\n' > "$file"; chmod 600 "$file"; }
}

gen mysql-root-password
gen mysql-password
gen filestore-access-key 10
gen filestore-secret-key 20
gen state-key 32
# Encryption key exactly as the official docs generate it.
[[ -s "$SECRETS/encryption-key" ]] || { openssl rand 64 | base64 > "$SECRETS/encryption-key"; chmod 600 "$SECRETS/encryption-key"; }
printf '%s' pipecd > "$SECRETS/mysql-username"

cat > "$SECRETS/s3.json" <<EOF
{"identities":[{"name":"pipecd","credentials":[{"accessKey":"$(cat "$SECRETS/filestore-access-key")","secretKey":"$(cat "$SECRETS/filestore-secret-key")"}],"actions":["Admin","Read","List","Tagging","Write"]}]}
EOF
chmod 600 "$SECRETS/s3.json"

apply_secret() {
  kubectl -n "$NS" create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f -
}

apply_secret pipecd-mysql \
  --from-file=root-password="$SECRETS/mysql-root-password" \
  --from-file=username="$SECRETS/mysql-username" \
  --from-file=password="$SECRETS/mysql-password"
apply_secret pipecd-filestore --from-file=s3.json="$SECRETS/s3.json"
apply_secret pipecd-secrets \
  --from-file=encryption-key="$SECRETS/encryption-key" \
  --from-file=mysql-username="$SECRETS/mysql-username" \
  --from-file=mysql-password="$SECRETS/mysql-password" \
  --from-file=minio-access-key="$SECRETS/filestore-access-key" \
  --from-file=minio-secret-key="$SECRETS/filestore-secret-key"
