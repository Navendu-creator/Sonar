#!/usr/bin/env bash
# Creates a PipeCD project through the ops service and prints its static admin
# login. The password is shown only once; it is also saved to
# ../.secrets/project-<id>.html.
#
#   ./create-project.sh production
set -euo pipefail

ID="${1:?usage: create-project.sh <project-id>}"
NS=pipecd
OUT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.secrets/project-$ID.html"

kubectl -n "$NS" port-forward svc/pipecd-ops 19082:9082 >/dev/null 2>&1 &
PF=$!
trap 'kill $PF 2>/dev/null' EXIT
for _ in $(seq 1 20); do curl -sf -o /dev/null http://127.0.0.1:19082/ && break; sleep 1; done

curl -sf -X POST --data-urlencode "ID=$ID" --data-urlencode "Description=Production" \
  http://127.0.0.1:19082/projects/add -o "$OUT"
chmod 600 "$OUT"

echo "Project \"$ID\" created. Static admin login:"
# The page is a table: each label cell is followed by its value cell.
sed -e 's/<[^>]*>/\n/g' "$OUT" | sed 's/^[[:space:]]*//; /^$/d' \
  | awk '/^Static Admin (Username|Password)$/ { label = $0; next } label { print "  " label ": " $0; label = "" }'
