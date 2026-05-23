#!/usr/bin/env bash
# calculate-node-current-usage.sh
# Counts current ACTUAL resource consumption (usage) of pods on a node,
# not requests/limits. Requires metrics-server.
# Usage: ./scripts/calculate-node-current-usage.sh <node-name> <namespace-to-exclude>

set -euo pipefail

NODE_NAME="${1:-}"
EXCLUDE_NS="${2:-}"
DEBUG="${DEBUG:-0}"

if [[ -z "$NODE_NAME" || -z "$EXCLUDE_NS" ]]; then
    echo "Usage: $0 <node-name> <namespace-to-exclude>"
    echo "Example: $0 kind-control-plane kube-system"
    exit 1
fi

KUBECTL="kubectl"
[[ -n "${KUBECONFIG:-}" ]] && KUBECTL="kubectl --kubeconfig=$KUBECONFIG"

echo "=== Node Current Usage Calculator ==="
echo "Node:         $NODE_NAME"
echo "Exclude NS:   $EXCLUDE_NS"
echo ""

if ! $KUBECTL get node "$NODE_NAME" &>/dev/null; then
    echo "Error: Node '$NODE_NAME' not found"
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# ── Fetch pods on node ──
echo "--- Fetching pods ---"
$KUBECTL get pods --all-namespaces --field-selector "spec.nodeName=$NODE_NAME" -o json > "$TMPDIR/pods.json" 2>&1 || {
    echo "Error: kubectl failed to fetch pods"
    exit 1
}

if ! jq empty "$TMPDIR/pods.json" 2>/dev/null; then
    echo "Error: kubectl produced invalid JSON for pods"
    [[ "$DEBUG" == "1" ]] && cat "$TMPDIR/pods.json" | head -5
    exit 1
fi

TOTAL=$(jq '.items | length' "$TMPDIR/pods.json")
EXCLUDED=$(jq --arg ns "$EXCLUDE_NS" '[.items[] | select(.metadata.namespace == $ns)] | length' "$TMPDIR/pods.json")
REMAINING=$((TOTAL - EXCLUDED))

echo "  Total pods:     $TOTAL"
echo "  Excluded:       $EXCLUDED ($EXCLUDE_NS)"
echo "  Counted:        $REMAINING"
[[ "$DEBUG" == "1" ]] && echo "  Temp dir:       $TMPDIR"
echo ""

# ── Fetch metrics ──
echo "--- Fetching metrics ---"
$KUBECTL get --raw /apis/metrics.k8s.io/v1beta1/pods 2>/dev/null > "$TMPDIR/metrics.json" || {
    echo "Error: Metrics API not available."
    echo ""
    echo "  Install metrics-server:"
    echo "    kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
    echo ""
    echo "  For kind clusters, add --kubelet-insecure-tls flag:"
    echo "    kubectl patch -n kube-system deployment metrics-server --type=json \\"
    echo "      -p='[{\"op\":\"add\",\"path\":\"/spec/template/spec/containers/0/args/-\",\"value\":\"--kubelet-insecure-tls\"}]'"
    echo ""
    exit 1
}

if ! jq empty "$TMPDIR/metrics.json" 2>/dev/null; then
    echo "Error: Metrics API returned invalid JSON"
    [[ "$DEBUG" == "1" ]] && cat "$TMPDIR/metrics.json" | head -5
    exit 1
fi

METRICS_COUNT=$(jq '.items | length' "$TMPDIR/metrics.json")
echo "  Metrics pods:   $METRICS_COUNT"
echo ""

[[ "$REMAINING" -eq 0 ]] && { echo "No pods to calculate after exclusion."; exit 0; }

# ── Resource Summary ──
echo "--- Current Usage Summary ---"
jq --slurpfile pods "$TMPDIR/pods.json" --arg node "$NODE_NAME" --arg exclude "$EXCLUDE_NS" -r -n -f - "$TMPDIR/metrics.json" <<'JQEOF'

def to_millicores:
    if . == null or . == "" then 0
    elif type == "number" then (. * 1000)
    elif type == "string" then
        if endswith("m") then (rtrimstr("m") | try tonumber catch 0)
        else (try tonumber catch 0 * 1000)
        end
    else 0
    end;

def to_bytes:
    if . == null or . == "" then 0
    elif type == "number" then .
    elif type == "string" then
        if endswith("m") then (rtrimstr("m") | try tonumber catch 0 / 1000)
        elif endswith("Ki") then (rtrimstr("Ki") | try tonumber catch 0 * 1024)
        elif endswith("Mi") then (rtrimstr("Mi") | try tonumber catch 0 * 1024 * 1024)
        elif endswith("Gi") then (rtrimstr("Gi") | try tonumber catch 0 * 1024 * 1024 * 1024)
        elif endswith("Ti") then (rtrimstr("Ti") | try tonumber catch 0 * 1024 * 1024 * 1024 * 1024)
        elif endswith("k")  then (rtrimstr("k") | try tonumber catch 0 * 1000)
        elif endswith("M")  then (rtrimstr("M") | try tonumber catch 0 * 1000 * 1000)
        elif endswith("G")  then (rtrimstr("G") | try tonumber catch 0 * 1000 * 1000 * 1000)
        else (try tonumber catch 0)
        end
    else 0
    end;

def to_mib:
    if . == null or . == "" then 0
    elif type == "number" then (. / 1024 / 1024)
    elif type == "string" then
        if endswith("m") then (rtrimstr("m") | try tonumber catch 0 / 1000 / 1024 / 1024)
        elif endswith("Ki") then (rtrimstr("Ki") | try tonumber catch 0 / 1024)
        elif endswith("Mi") then (rtrimstr("Mi") | try tonumber catch 0)
        elif endswith("Gi") then (rtrimstr("Gi") | try tonumber catch 0 * 1024)
        else (try tonumber catch 0 / 1024 / 1024)
        end
    else 0
    end;

# Build lookup: namespace/name -> pod metadata
($pods[0].items // []) |
map(select(.spec.nodeName == $node and .metadata.namespace != $exclude)) |
map({ key: "\(.metadata.namespace)/\(.metadata.name)", value: .metadata }) |
from_entries as $pod_lookup |

# Filter metrics to only pods on this node (excluding namespace)
(.items // []) |
map(select("\(.metadata.namespace)/\(.metadata.name)" | in($pod_lookup))) |
map(. + {
    _cpu:  ([.containers[]?.usage.cpu    // "0" | to_millicores] | add // 0),
    _mem:  ([.containers[]?.usage.memory // "0" | to_bytes]     | add // 0),
    _mem_mib: ([.containers[]?.usage.memory // "0" | to_mib] | add // 0)
}) as $usage |

# Totals
{
    pods:  ($usage | length),
    cpu:   ($usage | map(._cpu) | add // 0),
    mem:   ($usage | map(._mem) | add // 0),
    mem_mib: ($usage | map(._mem_mib) | add // 0)
} |
"  Pods with metrics:  \(.pods)",
"",
"  CPU Usage:          \(.cpu / 1000) cores  (\(.cpu) m)",
"",
"  Mem Usage:          \(.mem / 1024 / 1024 / 1024) GiB",
"  Mem Usage:          \(.mem_mib | floor) MiB"
JQEOF

# ── By Namespace ──
echo ""
echo "--- By Namespace ---"
jq --slurpfile pods "$TMPDIR/pods.json" --arg node "$NODE_NAME" --arg exclude "$EXCLUDE_NS" -r -n -f - "$TMPDIR/metrics.json" <<'JQEOF'

def to_millicores:
    if . == null or . == "" then 0
    elif type == "number" then (. * 1000)
    elif type == "string" then
        if endswith("m") then (rtrimstr("m") | try tonumber catch 0)
        else (try tonumber catch 0 * 1000)
        end
    else 0
    end;

def to_mib:
    if . == null or . == "" then 0
    elif type == "number" then (. / 1024 / 1024)
    elif type == "string" then
        if endswith("m") then (rtrimstr("m") | try tonumber catch 0 / 1000 / 1024 / 1024)
        elif endswith("Ki") then (rtrimstr("Ki") | try tonumber catch 0 / 1024)
        elif endswith("Mi") then (rtrimstr("Mi") | try tonumber catch 0)
        elif endswith("Gi") then (rtrimstr("Gi") | try tonumber catch 0 * 1024)
        else (try tonumber catch 0 / 1024 / 1024)
        end
    else 0
    end;

($pods[0].items // []) |
map(select(.spec.nodeName == $node and .metadata.namespace != $exclude)) |
map({ key: "\(.metadata.namespace)/\(.metadata.name)", value: .metadata.namespace }) |
from_entries as $ns_lookup |

(.items // []) |
map(select("\(.metadata.namespace)/\(.metadata.name)" | in($ns_lookup))) |
map(. + {
    _cpu:  ([.containers[]?.usage.cpu    // "0" | to_millicores] | add // 0),
    _mem:  ([.containers[]?.usage.memory // "0" | to_mib]      | add // 0)
}) |
group_by($ns_lookup["\(.metadata.namespace)/\(.metadata.name)"]) |
.[] |
{
    ns: .[0].metadata.namespace,
    pods: length,
    cpu: (map(._cpu) | add),
    mem: (map(._mem) | add)
} |
"  \(.ns)\t\(.pods) pods\t\(.cpu / 1000) cores\t\(.mem | floor) MiB"
JQEOF

# ── Top 10 Pods by CPU ──
echo ""
echo "--- Top 10 Pods by CPU Usage ---"
jq --slurpfile pods "$TMPDIR/pods.json" --arg node "$NODE_NAME" --arg exclude "$EXCLUDE_NS" -r -n -f - "$TMPDIR/metrics.json" <<'JQEOF'

def to_millicores:
    if . == null or . == "" then 0
    elif type == "number" then (. * 1000)
    elif type == "string" then
        if endswith("m") then (rtrimstr("m") | try tonumber catch 0)
        else (try tonumber catch 0 * 1000)
        end
    else 0
    end;

def to_mib:
    if . == null or . == "" then 0
    elif type == "number" then (. / 1024 / 1024)
    elif type == "string" then
        if endswith("m") then (rtrimstr("m") | try tonumber catch 0 / 1000 / 1024 / 1024)
        elif endswith("Ki") then (rtrimstr("Ki") | try tonumber catch 0 / 1024)
        elif endswith("Mi") then (rtrimstr("Mi") | try tonumber catch 0)
        elif endswith("Gi") then (rtrimstr("Gi") | try tonumber catch 0 * 1024)
        else (try tonumber catch 0 / 1024 / 1024)
        end
    else 0
    end;

($pods[0].items // []) |
map(select(.spec.nodeName == $node and .metadata.namespace != $exclude)) |
map({ key: "\(.metadata.namespace)/\(.metadata.name)", value: true }) |
from_entries as $pod_lookup |

(.items // []) |
map(select("\(.metadata.namespace)/\(.metadata.name)" | in($pod_lookup))) |
map({
    name: .metadata.name,
    ns: .metadata.namespace,
    cpu: ([.containers[]?.usage.cpu    // "0" | to_millicores] | add // 0),
    mem: ([.containers[]?.usage.memory // "0" | to_mib]      | add // 0)
}) |
sort_by(.cpu) | reverse | .[0:10] |
.[] |
"  \(.name)\t\(.ns)\t\(.cpu) m\t\(.mem | floor) MiB"
JQEOF

echo ""
echo "=== Done ==="
