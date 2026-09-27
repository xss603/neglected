#!/usr/bin/env bash
# upgrade.sh - upgrade trivy-operator to fix "unrecognized scan job
# condition: SuccessCriteriaMet" (see README.md "Confirmed root cause").
#
# This MUTATES the live cluster via `helm upgrade`. trivy-operator has no
# ArgoCD Application in this repo (see CLAUDE.md - nothing else is applied
# by hand), so this is the one accepted manual path until it's brought under
# GitOps. Run it ON THE SERVER, over the existing SSH session - not from a
# workstation with a separate kubeconfig.
#
# Usage: ./upgrade.sh [target-version] [namespace]
#   target-version defaults to the latest chart version from the repo index.
#   namespace defaults to trivy-system.

set -euo pipefail

CHART_REPO_NAME="aqua"
CHART_REPO_URL="https://aquasecurity.github.io/helm-charts/"
CHART="aqua/trivy-operator"
RELEASE="trivy-operator"
NS="${2:-trivy-system}"
TARGET_VERSION="${1:-}"
VALUES_FILE="$(dirname "$0")/values-fix.yaml"

command -v helm >/dev/null || { echo "helm not found in PATH" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found in PATH" >&2; exit 1; }

echo "== Current release =="
helm status "$RELEASE" -n "$NS"
CURRENT_VERSION=$(helm list -n "$NS" -f "^${RELEASE}\$" -o json | jq -r '.[0].chart')
echo "Currently installed: $CURRENT_VERSION"

echo "== Refreshing chart repo =="
helm repo add "$CHART_REPO_NAME" "$CHART_REPO_URL" >/dev/null 2>&1 || true
helm repo update "$CHART_REPO_NAME"

if [[ -z "$TARGET_VERSION" ]]; then
  TARGET_VERSION=$(helm search repo "$CHART" -o json | jq -r '.[0].version')
fi
echo "Target chart version: $TARGET_VERSION"

echo "== Diffing values (informational only; requires helm-diff plugin) =="
helm diff upgrade "$RELEASE" "$CHART" -n "$NS" \
  --version "$TARGET_VERSION" \
  --reuse-values -f "$VALUES_FILE" 2>&1 || echo "  (helm-diff not installed - skipping preview)"

read -r -p "Proceed with helm upgrade to $TARGET_VERSION? [y/N] " CONFIRM
[[ "$CONFIRM" == "y" || "$CONFIRM" == "Y" ]] || { echo "Aborted."; exit 1; }

echo "== Upgrading =="
helm upgrade "$RELEASE" "$CHART" -n "$NS" \
  --version "$TARGET_VERSION" \
  --reuse-values -f "$VALUES_FILE" \
  --wait --timeout 5m

echo "== Post-upgrade verification =="
kubectl -n "$NS" rollout status deploy/trivy-operator --timeout=120s
echo "-- confirming the operator no longer logs the SuccessCriteriaMet error --"
sleep 15
if kubectl logs -n "$NS" deploy/trivy-operator --tail=200 2>&1 | grep -q "unrecognized scan job condition"; then
  echo "STILL PRESENT: chart $TARGET_VERSION did not fix this. Check release notes for the actual fix version."
  echo "Rollback: helm rollback $RELEASE -n $NS"
  exit 1
fi
echo "No 'unrecognized scan job condition' errors in the last 200 log lines."

echo "-- confirming reports are now being produced --"
kubectl get vulnerabilityreports.aquasecurity.github.io -A --no-headers | wc -l | xargs -I{} echo "VulnerabilityReport count: {}"

echo "Done. If reports are still at 0, wait a few minutes for scan Jobs to complete, then re-run ./triage.sh."
echo "Rollback if anything looks wrong: helm rollback $RELEASE -n $NS"
