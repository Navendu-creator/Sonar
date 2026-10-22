#!/usr/bin/env bash
# Installs or upgrades piped (Helm release "piped"). Register the piped in the
# UI first (Settings → Piped → + Add) to get its ID and key.
#
#   ./install.sh <project-id> <piped-id> <piped-key-file>
#
# Re-run with the same arguments after changing values.yaml, piped-config.yaml
# or PIPECD_VERSION in ../versions.env.
set -euo pipefail

PROJECT_ID="${1:?usage: install.sh <project-id> <piped-id> <piped-key-file>}"
PIPED_ID="${2:?missing piped-id}"
KEY_FILE="${3:?missing piped-key-file}"
NS=pipecd
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="$DIR/../.secrets"
source "$DIR/../versions.env"

mkdir -p "$SECRETS"
sed -e "s/__PROJECT_ID__/$PROJECT_ID/" -e "s/__PIPED_ID__/$PIPED_ID/" \
  "$DIR/piped-config.yaml" > "$SECRETS/piped-config.yaml"

helm upgrade --install piped oci://ghcr.io/pipe-cd/chart/piped \
  --version "$PIPECD_VERSION" --namespace "$NS" \
  --values "$DIR/values.yaml" \
  --set-file config.data="$SECRETS/piped-config.yaml" \
  --set-file secret.data.piped-key="$KEY_FILE"

kubectl -n "$NS" rollout status deploy/piped --timeout=5m
