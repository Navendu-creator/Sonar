#!/usr/bin/env bash
# Registers the EKS cluster "dev-cluster" (account 731372490312, us-east-1) with
# the Argo CD running on kind-sonar, the way `argocd cluster add` does, but
# without logging in to the Argo CD API:
#
#   1. adds a kubeconfig context for the cluster (dev-cluster-731372490312)
#   2. on EKS:  creates kube-system/argocd-manager and its token (argocd-manager.yaml)
#   3. on kind: creates the Argo CD cluster Secret "cluster-dev-cluster" with the
#               EKS endpoint, CA and that token
#
# Needs AWS credentials for account 731372490312 with access to the cluster.
# Re-running is safe; it refreshes the Secret with the current token.
set -euo pipefail

CLUSTER=dev-cluster
REGION=us-east-1
ACCOUNT=731372490312
# Aliased: the kubeconfig's existing "dev-cluster" contexts point at another account.
EKS_CONTEXT=$CLUSTER-$ACCOUNT
ARGOCD_CONTEXT=kind-sonar
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

current=$(aws sts get-caller-identity --query Account --output text)
if [[ $current != "$ACCOUNT" ]]; then
  echo "AWS credentials are for account $current, not $ACCOUNT" >&2
  exit 1
fi

read -r endpoint ca < <(aws eks describe-cluster --name "$CLUSTER" --region "$REGION" \
  --query 'cluster.[endpoint, certificateAuthority.data]' --output text)

aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --alias "$EKS_CONTEXT" >/dev/null
kubectl --context "$EKS_CONTEXT" apply -f "$DIR/argocd-manager.yaml"

# The token controller fills the Secret in a moment after it is created.
token=""
for _ in $(seq 30); do
  token=$(kubectl --context "$EKS_CONTEXT" -n kube-system get secret argocd-manager-token \
    -o jsonpath='{.data.token}' | base64 -d)
  [[ -n $token ]] && break
  sleep 2
done
[[ -n $token ]] || { echo "argocd-manager-token was never filled in" >&2; exit 1; }

# Argo CD finds clusters by this label; "name" is what Applications refer to
# in destination.name. The config goes through a file so the token never shows
# up in the process list.
kubectl --context "$ARGOCD_CONTEXT" -n argocd create secret generic "cluster-$CLUSTER" \
  --from-literal=name="$CLUSTER" \
  --from-literal=server="$endpoint" \
  --from-file=config=<(printf '{"bearerToken":"%s","tlsClientConfig":{"insecure":false,"caData":"%s"}}' "$token" "$ca") \
  --dry-run=client -o yaml |
  kubectl label --local -f - argocd.argoproj.io/secret-type=cluster -o yaml |
  kubectl --context "$ARGOCD_CONTEXT" apply -f -

echo "Registered $CLUSTER ($endpoint) with Argo CD on $ARGOCD_CONTEXT."
