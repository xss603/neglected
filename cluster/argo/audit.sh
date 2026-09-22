#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./argocd-audit.sh <application>
#
# Requirements:
#   argocd, kubectl, jq
#
# Shows:
#   - Argo CD sync history
#   - Sync initiator where available
#   - Resources affected by each deployment
#
# NOTE:
# Kubernetes resources modified OUTSIDE Argo CD require Kubernetes
# audit logs to reliably identify the user/service account.

APP="${1:-}"

if [[ -z "$APP" ]]; then
  echo "Usage: $0 <argocd-application>"
  exit 1
fi

for cmd in argocd kubectl jq; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "ERROR: '$cmd' is required."
    exit 1
  }
done

printf "%-22s %-20s %-15s %-12s %-25s %-45s\n" \
  "TIME" "USER/INITIATOR" "REVISION" "STATUS" "RESOURCE" "MESSAGE"

printf '%*s\n' 145 '' | tr ' ' '-'

# Get Argo CD application data, including operation state/history.
APP_JSON="$(argocd app get "$APP" -o json)"

echo "$APP_JSON" | jq -r '
  .status.history[]? |
  [
    (.deployedAt // "unknown"),
    (.initiatedBy.username // .initiatedBy.automated // "unknown"),
    ((.revision // "unknown") | tostring),
    "SYNC",
    "-",
    ("Deployment ID: " + ((.id // "?") | tostring))
  ] | @tsv
' | while IFS=$'\t' read -r time user revision status resource message; do
  printf "%-22s %-20s %-15.15s %-12s %-25s %-45s\n" \
    "$time" "$user" "$revision" "$status" "$resource" "$message"
done


echo
echo "CURRENT / LAST OPERATION"
printf '%*s\n' 145 '' | tr ' ' '-'

echo "$APP_JSON" | jq -r '
  .status.operationState? as $op |
  if $op then
    ($op.operation.initiatedBy.username //
     (if $op.operation.initiatedBy.automated == true
      then "automated"
      else "unknown"
      end)) as $user |

    ($op.syncResult.resources // [])[] |

    [
      ($op.finishedAt // $op.startedAt // "unknown"),
      $user,
      ($op.syncResult.revision // "unknown"),
      (.status // "unknown"),
      (
        (.group // "") +
        (if (.group // "") != "" then "/" else "" end) +
        (.kind // "unknown") + "/" +
        (.namespace // "-") + "/" +
        (.name // "unknown")
      ),
      (.message // "-")
    ] | @tsv
  else
    empty
  end
' | while IFS=$'\t' read -r time user revision status resource message; do
  printf "%-22s %-20s %-15.15s %-12s %-25.25s %-45.45s\n" \
    "$time" "$user" "$revision" "$status" "$resource" "$message"
done