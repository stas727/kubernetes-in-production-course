#!/usr/bin/env bash
set -euo pipefail

CLUSTER_CONTEXT=k3d-kip
CLUSTER_NAME=k3d-kip
OUT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/kubeconfig"
TOKEN_DURATION=8760h

mkdir -p "$OUT_DIR"

ACTUAL_CLUSTER=$(kubectl config view --raw -o jsonpath="{.contexts[?(@.name==\"${CLUSTER_CONTEXT}\")].context.cluster}")
SERVER=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${ACTUAL_CLUSTER}\")].cluster.server}")
CA_DATA=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"${ACTUAL_CLUSTER}\")].cluster.certificate-authority-data}")

# namespace:serviceaccount pairs
PAIRS=(
  "mentor:mentor"
  "student01:student01"
  "student02:student02"
  "student03:student03"
)

for pair in "${PAIRS[@]}"; do
  NS="${pair%%:*}"
  SA="${pair##*:}"
  OUT_FILE="${OUT_DIR}/${SA}.kubeconfig"

  echo "Generating ${OUT_FILE} (namespace=${NS}, serviceaccount=${SA})"

  TOKEN=$(kubectl --context "$CLUSTER_CONTEXT" -n "$NS" create token "$SA" --duration="$TOKEN_DURATION")

  kubectl --kubeconfig="$OUT_FILE" config set-cluster "$CLUSTER_NAME" --server="$SERVER" >/dev/null
  kubectl --kubeconfig="$OUT_FILE" config set "clusters.${CLUSTER_NAME}.certificate-authority-data" "$CA_DATA" >/dev/null
  kubectl --kubeconfig="$OUT_FILE" config set-credentials "$SA" --token="$TOKEN" >/dev/null
  kubectl --kubeconfig="$OUT_FILE" config set-context "$SA" \
    --cluster="$CLUSTER_NAME" --user="$SA" --namespace="$NS" >/dev/null
  kubectl --kubeconfig="$OUT_FILE" config use-context "$SA" >/dev/null

  chmod 600 "$OUT_FILE"
done

echo ""
echo "Done. Generated files:"
ls -la "$OUT_DIR"
