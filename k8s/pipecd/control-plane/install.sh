#!/usr/bin/env bash
# Installs or upgrades the PipeCD control plane (Helm release "pipecd").
# Re-run after changing values.yaml, control-plane-config.yaml or
# PIPECD_VERSION in ../versions.env.
#
# Needs: ../secrets/create.sh run first, and MySQL and the filestore running.
set -euo pipefail

NS=pipecd
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SECRETS="$DIR/../.secrets"
source "$DIR/../versions.env"

[[ -s "$SECRETS/state-key" ]] || { echo "Run ../secrets/create.sh first." >&2; exit 1; }

# Fill in the state key so the real value never lands in git.
sed "s/__STATE_KEY__/$(cat "$SECRETS/state-key")/" \
  "$DIR/control-plane-config.yaml" > "$SECRETS/control-plane-config.yaml"

helm upgrade --install pipecd oci://ghcr.io/pipe-cd/chart/pipecd \
  --version "$PIPECD_VERSION" --namespace "$NS" \
  --values "$DIR/values.yaml" \
  --set-file config.data="$SECRETS/control-plane-config.yaml"

kubectl apply -k "$DIR"

# The chart doesn't roll server/ops when the ConfigMap or Secret changes.
kubectl -n "$NS" rollout restart deploy/pipecd-server deploy/pipecd-ops
for d in cache gateway server ops; do
  kubectl -n "$NS" rollout status "deploy/pipecd-$d" --timeout=10m
done
