#!/usr/bin/env bash
# triage.sh - read-only triage for "no VulnerabilityReports found" on trivy-operator.
# Most common cause: VulnerabilityReports are namespaced, so `kubectl get
# vulnerabilityreports` against `default` (or without -A) finds nothing even
# when the operator is healthy. Rules that out first, then checks for real
# failures (scan jobs failing, operator errors, registry rate limits).
#
# Usage: ./triage.sh [namespace]   (namespace defaults to trivy-system)

set -uo pipefail   # no -e: keep going when one diagnostic step fails

NS="${1:-trivy-system}"

hdr() { printf '\n== %s ==\n' "$*"; }

hdr "1. VulnerabilityReports across all namespaces"
kubectl get vulnerabilityreports.aquasecurity.github.io -A 2>&1

hdr "2. Operator logs (errors / rate limits)"
kubectl logs -n "$NS" deploy/trivy-operator --tail=100 2>&1 | grep -iE "error|fail|limit|toomanyrequests" || echo "  no matching lines"

hdr "3. Scan jobs and pods in $NS"
kubectl get jobs,pods -n "$NS" 2>&1

hdr "4. Recent scan job logs"
kubectl logs -n "$NS" -l app.kubernetes.io/managed-by=trivy-operator --tail=50 2>&1

hdr "5. Operator config (scanner / target namespaces)"
kubectl get cm trivy-operator -n "$NS" -o yaml 2>&1 | grep -iE "scanner|namespace" || echo "  configmap not found or keys absent"
