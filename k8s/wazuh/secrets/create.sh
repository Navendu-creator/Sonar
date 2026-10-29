#!/usr/bin/env bash
# Generates the Wazuh certificates and credentials into k8s/wazuh/.secrets/
# (gitignored) and creates or updates the Kubernetes Secrets built from them:
#
#   indexer-certs, manager-certs, dashboard-certs  TLS between the components, and to agents
#   indexer-credentials, manager-credentials,
#   dashboard-credentials                          passwords each component starts with
#   wazuh-cluster-key                              shared key of the manager cluster (1516)
#   wazuh-authd-pass                               enrollment password of 4.x agents (1515)
#
# Usage:
#   KUBE_CONTEXT=dev-cluster-731372490312 \
#   AGENT_HOSTNAMES=<agents NLB DNS name> DASHBOARD_HOSTNAMES=<dashboard NLB DNS name> \
#     k8s/wazuh/secrets/create.sh [--generate-only]
#
# KUBE_CONTEXT is the kubeconfig context of the cluster Wazuh runs on. It is
# required, so the Secrets never land on whatever cluster happens to be current.
# AGENT_HOSTNAMES (comma-separated) lists every name agents dial. It goes into
# the agent listener certificate, and agents refuse any name it does not carry.
# DASHBOARD_HOSTNAMES (optional, comma-separated) lists the names the dashboard
# is opened with, so a browser that trusts root-ca.pem accepts its certificate.
# --generate-only writes .secrets/ without touching the cluster.
#
# Each value is generated once and reused on every run. The components keep the
# passwords they were first started with, and every certificate hangs off the
# CA in .secrets/certs/, so losing .secrets/ means losing both: back it up.
#
# The certificates mirror what wazuh-certs-tool.sh 5.0 issues (subjects,
# key usages, SANs); it is not used directly because its 5.0.0-rc1 build cannot
# yet issue the agent listener certificate the 5.0 manager needs.
set -euo pipefail

NS=wazuh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SECRETS="$DIR/.secrets"
CERTS="$SECRETS/certs"
PASSWORDS="$SECRETS/passwords"

# Must match the indexer StatefulSet's replicas: every node's name is in the
# indexer certificate, or the nodes refuse each other.
INDEXER_REPLICAS=3

APPLY=true
case "${1:-}" in
  "") ;;
  --generate-only) APPLY=false ;;
  *) echo "usage: KUBE_CONTEXT=<context> AGENT_HOSTNAMES=<name>[,<name>...] $0 [--generate-only]" >&2; exit 2 ;;
esac
if $APPLY; then
  : "${KUBE_CONTEXT:?set KUBE_CONTEXT to the kubeconfig context of the Wazuh cluster, e.g. dev-cluster-731372490312}"
fi

umask 077
mkdir -p "$CERTS" "$PASSWORDS"
chmod 700 "$SECRETS"

# ---------------------------------------------------------------- certificates

if [[ ! -s "$CERTS/root-ca.pem" ]]; then
  openssl req -x509 -new -nodes -newkey rsa:4096 -sha256 -days 3650 \
    -keyout "$CERTS/root-ca.key" -out "$CERTS/root-ca.pem" \
    -subj '/OU=Wazuh/O=Wazuh/L=California/' 2>/dev/null
fi

# issue <name> <subject> <extendedKeyUsage> [<dns>...]
# Writes $CERTS/<name>.pem and <name>-key.pem, signed by the root CA, unless
# they already exist. -preserveDN keeps the subject in the order given: the
# indexer compares DNs as strings. notBefore is backdated one day so a peer
# whose clock lags still accepts a freshly issued certificate.
issue() {
  local name=$1 subject=$2 eku=$3
  shift 3
  [[ -s "$CERTS/$name.pem" ]] && return

  local tmp san=""
  tmp=$(mktemp -d)
  for dns in "$@"; do san+="${san:+,}DNS:$dns"; done

  cat > "$tmp/ca.cnf" <<EOF
[ ca ]
default_ca = issuer

[ issuer ]
database      = $tmp/index.txt
new_certs_dir = $tmp
certificate   = $CERTS/root-ca.pem
private_key   = $CERTS/root-ca.key
rand_serial   = yes
default_md    = sha256
policy        = policy
unique_subject = no

[ policy ]
countryName            = optional
localityName           = optional
organizationName       = optional
organizationalUnitName = optional
commonName             = supplied

[ leaf ]
basicConstraints       = critical, CA:FALSE
keyUsage               = critical, digitalSignature, keyEncipherment
extendedKeyUsage       = $eku
subjectKeyIdentifier   = hash
authorityKeyIdentifier = keyid, issuer
${san:+subjectAltName = $san}
EOF
  : > "$tmp/index.txt"

  openssl req -new -nodes -newkey rsa:2048 -subj "$subject" \
    -keyout "$CERTS/$name-key.pem" -out "$tmp/$name.csr" 2>/dev/null
  openssl ca -batch -notext -preserveDN -config "$tmp/ca.cnf" -extensions leaf \
    -startdate "$(date -u -d '-1 day' '+%Y%m%d%H%M%SZ')" \
    -enddate "$(date -u -d '+3650 days' '+%Y%m%d%H%M%SZ')" \
    -in "$tmp/$name.csr" -out "$CERTS/$name.pem" 2>/dev/null
  rm -rf "$tmp"
  openssl verify -CAfile "$CERTS/root-ca.pem" "$CERTS/$name.pem" >/dev/null
}

# Indexer: both ends of the transport layer, and the REST API. Its subject must
# match NODES_DN in ../indexer/statefulset.yaml.
indexer_dns=(wazuh-indexer wazuh-indexer.$NS.svc.cluster.local)
for ((i = 0; i < INDEXER_REPLICAS; i++)); do
  indexer_dns+=("wazuh-indexer-$i.wazuh-indexer" "wazuh-indexer-$i.wazuh-indexer.$NS.svc.cluster.local")
done
issue indexer '/CN=indexer/OU=Wazuh/O=Wazuh/L=California/C=US' 'serverAuth, clientAuth' "${indexer_dns[@]}"

# Admin: authenticates securityadmin.sh against the indexer security API.
issue admin '/CN=admin/OU=Wazuh/O=Wazuh/L=California/C=US' 'clientAuth'

# Manager: deployed as indexer-connector.pem, it only dials the indexer.
manager_dns=(wazuh-api wazuh-api.$NS.svc.cluster.local wazuh-agents wazuh-agents.$NS.svc.cluster.local)
issue manager '/C=US/L=California/O=Wazuh/OU=Wazuh/CN=manager' 'clientAuth' "${manager_dns[@]}"

# Agent listener (remoted, 1517): what agents verify, so it carries every name
# they dial. All manager nodes share it, since the NLB spreads agents over them.
# To add a name later, delete manager-remoted*.pem and run this script again.
if [[ ! -s "$CERTS/manager-remoted.pem" ]]; then
  : "${AGENT_HOSTNAMES:?set AGENT_HOSTNAMES to the DNS name(s) agents connect to, e.g. wazuh-agents.example.com}"
  IFS=, read -ra agent_dns <<< "$AGENT_HOSTNAMES"
  issue manager-remoted '/C=US/L=California/O=Wazuh/OU=Wazuh/CN=manager' 'serverAuth' \
    manager "${manager_dns[@]}" "${agent_dns[@]}"
  # remoted hands its peers the chain: the leaf, then the CA.
  cat "$CERTS/root-ca.pem" >> "$CERTS/manager-remoted.pem"
fi

# Dashboard: what browsers see through the pass-through NLB, so it carries the
# names they open. To add a name later, delete dashboard*.pem and run again.
IFS=, read -ra dashboard_dns <<< "${DASHBOARD_HOSTNAMES:-}"
issue dashboard '/C=US/L=California/O=Wazuh/OU=Wazuh/CN=dashboard' 'serverAuth' \
  dashboard dashboard.$NS.svc.cluster.local "${dashboard_dns[@]}"

# ----------------------------------------------------------------- credentials

# Writes a random password to $PASSWORDS/<name> unless it already exists:
# 32 characters, at least one lowercase, uppercase, digit and symbol, all from
# the set every Wazuh component accepts (A-Z a-z 0-9 . _ + : @ % ^ = ~ -).
gen_password() {
  local file="$PASSWORDS/$1" p
  [[ -s "$file" ]] && return
  while :; do
    p=$(head -c 1024 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9._+:@%^=~-')
    p=${p:0:32}
    [[ ${#p} -eq 32 && $p =~ [a-z] && $p =~ [A-Z] && $p =~ [0-9] && $p =~ [._+:@%^=~-] ]] && break
  done
  printf '%s' "$p" > "$file"
}

gen_password WAZUH_INDEXER_ADMIN_PASSWORD
gen_password WAZUH_INDEXER_KIBANASERVER_PASSWORD
gen_password WAZUH_INDEXER_MANAGER_PASSWORD
gen_password WAZUH_MANAGER_API_PASSWORD
gen_password WAZUH_MANAGER_WUI_PASSWORD

# The cluster key must be exactly 32 alphanumeric characters, or every manager
# refuses to start.
[[ -s "$PASSWORDS/cluster-key" ]] || openssl rand -hex 16 | tr -d '\n' > "$PASSWORDS/cluster-key"
[[ -s "$PASSWORDS/authd-pass" ]] || openssl rand -hex 24 | tr -d '\n' > "$PASSWORDS/authd-pass"

# env_file <component> <key>...: the KEY=value file each component reads.
env_file() {
  local file="$SECRETS/$1.env"
  shift
  : > "$file"
  for key in "$@"; do printf '%s=%s\n' "$key" "$(cat "$PASSWORDS/$key")" >> "$file"; done
}

env_file indexer WAZUH_INDEXER_ADMIN_PASSWORD WAZUH_INDEXER_KIBANASERVER_PASSWORD WAZUH_INDEXER_MANAGER_PASSWORD
env_file manager WAZUH_INDEXER_MANAGER_PASSWORD WAZUH_MANAGER_API_PASSWORD WAZUH_MANAGER_WUI_PASSWORD
env_file dashboard WAZUH_INDEXER_KIBANASERVER_PASSWORD WAZUH_MANAGER_WUI_PASSWORD

if ! $APPLY; then
  echo "Generated into $SECRETS (nothing applied to the cluster)."
  exit 0
fi

# -------------------------------------------------------------------- secrets

kubectl --context "$KUBE_CONTEXT" apply -f "$DIR/namespace.yaml"

apply_secret() {
  kubectl -n "$NS" create secret generic "$@" --dry-run=client -o yaml |
    kubectl --context "$KUBE_CONTEXT" apply -f -
}

apply_secret indexer-certs \
  --from-file="$CERTS/indexer.pem" --from-file="$CERTS/indexer-key.pem" \
  --from-file="$CERTS/admin.pem" --from-file="$CERTS/admin-key.pem" \
  --from-file="$CERTS/root-ca.pem"
apply_secret manager-certs \
  --from-file="$CERTS/manager.pem" --from-file="$CERTS/manager-key.pem" \
  --from-file="$CERTS/manager-remoted.pem" --from-file="$CERTS/manager-remoted-key.pem" \
  --from-file="$CERTS/root-ca.pem"
apply_secret dashboard-certs \
  --from-file="$CERTS/dashboard.pem" --from-file="$CERTS/dashboard-key.pem" \
  --from-file="$CERTS/root-ca.pem"

apply_secret indexer-credentials --from-file=wazuh-credentials="$SECRETS/indexer.env"
apply_secret manager-credentials --from-file=wazuh-credentials="$SECRETS/manager.env"
apply_secret dashboard-credentials --from-file=wazuh-credentials="$SECRETS/dashboard.env"

apply_secret wazuh-cluster-key --from-file=key="$PASSWORDS/cluster-key"
apply_secret wazuh-authd-pass --from-file=authd.pass="$PASSWORDS/authd-pass"

echo "Dashboard login is 'admin'; its password is in $PASSWORDS/WAZUH_INDEXER_ADMIN_PASSWORD"
