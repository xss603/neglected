#!/usr/bin/env bash
#
# export-workloads-to-csv.sh - read-only inventory export. For every
# Deployment and StatefulSet in every namespace, writes one CSV row with:
#   namespace, kind, name, replicas, workload_labels, namespace_labels, nodes
#
# "nodes" is the de-duplicated, sorted list of nodes currently running at
# least one pod for that workload (semicolon-separated) - derived by
# matching each workload's spec.selector.matchLabels against live pod
# labels in the same namespace, not by trusting a cached/previous state.
# A workload with 0 Ready pods (scaled to 0, CrashLoopBackOff before
# scheduling, etc.) gets an empty nodes field - that's expected, not a bug.
#
# Usage: ./export-workloads-to-csv.sh [-o out.csv] [-n namespace] [--context ctx]
#   -o FILE       write CSV here instead of stdout
#   -n NAMESPACE  limit to one namespace (default: all namespaces)
#   --context CTX kubectl context to use
#
# Requires: kubectl, jq.
#
# Caveat: selector matching only evaluates spec.selector.matchLabels
# (plain equality). A workload using matchExpressions (In/NotIn/Exists)
# instead of/alongside matchLabels will under- or over-match pods for
# that field - matchExpressions-only selectors are rare for
# Deployments/StatefulSets but check output for such workloads by hand.

set -euo pipefail

OUT="" NS_FILTER="" CTX=""

usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while (($#)); do
  case $1 in
    -o) [[ $# -ge 2 ]] || { echo "error: -o needs a value" >&2; exit 1; }; OUT=$2; shift 2 ;;
    -n) [[ $# -ge 2 ]] || { echo "error: -n needs a value" >&2; exit 1; }; NS_FILTER=$2; shift 2 ;;
    --context) [[ $# -ge 2 ]] || { echo "error: --context needs a value" >&2; exit 1; }; CTX=$2; shift 2 ;;
    -h|--help) usage 0 ;;
    *) echo "error: unknown argument: $1" >&2; usage 1 ;;
  esac
done

command -v kubectl >/dev/null || { echo "error: kubectl not found in PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "error: jq not found in PATH" >&2; exit 1; }

k() { kubectl ${CTX:+--context "$CTX"} "$@"; }

NS_SCOPE=(-A)
[[ -z $NS_FILTER ]] || NS_SCOPE=(-n "$NS_FILTER")

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

k get deployments "${NS_SCOPE[@]}" -o json > "$TMPDIR/deploy.json"
k get statefulsets "${NS_SCOPE[@]}" -o json > "$TMPDIR/sts.json"
k get namespaces -o json > "$TMPDIR/ns.json"
k get pods "${NS_SCOPE[@]}" -o json > "$TMPDIR/pods.json"

JQ_FILTER='
def kv_join(labels):
  (labels // {}) | to_entries | map("\(.key)=\(.value)") | join(",");

def matches_selector(podlabels; sel):
  podlabels as $pl
  | (sel | to_entries) as $se
  | ($se | length == 0) or ($se | all(.key as $k | $pl[$k] == .value));

($ns[0].items | map({key: .metadata.name, value: (.metadata.labels // {})}) | from_entries) as $nslabels
| ($pods[0].items) as $allpods
| (($deploy[0].items + $sts[0].items)) as $workloads
| ["namespace","kind","name","replicas","workload_labels","namespace_labels","nodes"],
  ( $workloads[]
    | . as $w
    | ($w.spec.selector.matchLabels // {}) as $sel
    | ($w.metadata.namespace) as $wns
    | [ $allpods[]
        | select(.metadata.namespace == $wns)
        | select(matches_selector(.metadata.labels // {}; $sel))
        | .spec.nodeName // empty
      ] | unique | sort | join(";") as $nodes
    | [
        $wns,
        $w.kind,
        $w.metadata.name,
        ($w.spec.replicas // 0 | tostring),
        kv_join($w.metadata.labels),
        kv_join($nslabels[$wns]),
        $nodes
      ]
  )
  | @csv
'

# --slurpfile loads each file as a one-element array ($deploy[0] is the
# actual List object) - avoids round-tripping large JSON through argv.
jq -n -r \
  --slurpfile deploy "$TMPDIR/deploy.json" \
  --slurpfile sts "$TMPDIR/sts.json" \
  --slurpfile ns "$TMPDIR/ns.json" \
  --slurpfile pods "$TMPDIR/pods.json" \
  "$JQ_FILTER" \
  > "$TMPDIR/out.csv"

if [[ -n $OUT ]]; then
  mv "$TMPDIR/out.csv" "$OUT"
  echo "wrote $(($(wc -l < "$OUT") - 1)) workload rows to $OUT" >&2
else
  cat "$TMPDIR/out.csv"
fi
