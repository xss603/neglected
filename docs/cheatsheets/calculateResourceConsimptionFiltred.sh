#!/usr/bin/env bash
# calculate-node-resources-exclude-ns.sh
# Calculates resource requests/limits for pods on a node, excluding one namespace.
# Usage: ./calculate-node-resources-exclude-ns.sh <node-name> <namespace-to-exclude>

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

echo "=== Node Resource Calculator (Namespace Excluded) ==="
echo "Node:         $NODE_NAME"
echo "Exclude NS:   $EXCLUDE_NS"
echo ""

if ! $KUBECTL get node "$NODE_NAME" &>/dev/null; then
    echo "Error: Node '$NODE_NAME' not found"
    exit 1
fi

echo "--- Node Capacity ---"
$KUBECTL get node "$NODE_NAME" -o json | jq -r '
    .status.capacity |
    "  CPU:        \(.cpu // "N/A")",
    "  Memory:     \(.memory // "N/A")",
    "  Pods:       \(.pods // "N/A")",
    if .["nvidia.com/gpu"] then "  GPU:        \(.["nvidia.com/gpu"])" else empty end
'

echo ""
echo "--- Fetching pods ---"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

$KUBECTL get pods --all-namespaces --field-selector "spec.nodeName=$NODE_NAME" -o json > "$TMPDIR/all.json" 2>&1 || {
    echo "Error: kubectl failed to fetch pods"
    exit 1
}

if ! jq empty "$TMPDIR/all.json" 2>/dev/null; then
    echo "Error: kubectl produced invalid JSON"
    [[ "$DEBUG" == "1" ]] && head -5 "$TMPDIR/all.json"
    exit 1
fi

TOTAL=$(jq '.items | length' "$TMPDIR/all.json")
EXCLUDED=$(jq --arg ns "$EXCLUDE_NS" '[.items[] | select(.metadata.namespace == $ns)] | length' "$TMPDIR/all.json")
REMAINING=$((TOTAL - EXCLUDED))

echo "  Total pods:     $TOTAL"
echo "  Excluded:       $EXCLUDED ($EXCLUDE_NS)"
echo "  Counted:        $REMAINING"
[[ "$DEBUG" == "1" ]] && echo "  Temp dir:       $TMPDIR"
echo ""

[[ "$REMAINING" -eq 0 ]] && { echo "No pods to calculate after exclusion."; exit 0; }

if [[ "$EXCLUDED" -gt 0 ]]; then
    echo "--- Excluded pods ---"
    jq -r --arg ns "$EXCLUDE_NS" '.items[] | select(.metadata.namespace == $ns) | "  - \(.metadata.name)"' "$TMPDIR/all.json"
    echo ""
fi

jq --arg ns "$EXCLUDE_NS" '.items |= map(select(.metadata.namespace != $ns))' "$TMPDIR/all.json" > "$TMPDIR/filtered.json"
jq empty "$TMPDIR/filtered.json" 2>/dev/null || { echo "Error: filtered JSON is invalid"; exit 1; }

echo "--- Resource Summary ---"
jq -r '
def to_millicores:
    if type == "number" then
        (. * 1000)
    elif type == "string" then
        if endswith("m") then
            (rtrimstr("m") | tonumber)
        else
            (tonumber * 1000)
        end
    else
        0
    end;

def to_bytes:
    if type == "number" then
        .
    elif type == "string" then
        if endswith("Ki") then
            (rtrimstr("Ki") | tonumber * 1024)
        elif endswith("Mi") then
            (rtrimstr("Mi") | tonumber * 1048576)
        elif endswith("Gi") then
            (rtrimstr("Gi") | tonumber * 1073741824)
        elif endswith("Ti") then
            (rtrimstr("Ti") | tonumber * 1099511627776)
        elif endswith("k") then
            (rtrimstr("k") | tonumber * 1000)
        elif endswith("M") then
            (rtrimstr("M") | tonumber * 1000000)
        elif endswith("G") then
            (rtrimstr("G") | tonumber * 1000000000)
        else
            (tonumber)
        end
    else
        0
    end;

def safe_tonumber:
    if type == "number" then .
    elif type == "string" then (tonumber // 0)
    else 0
    end;

def container_res:
    {
        cpu_req: ((.resources.requests.cpu // "0") | to_millicores),
        cpu_lim: ((.resources.limits.cpu // "0") | to_millicores),
        mem_req: ((.resources.requests.memory // "0") | to_bytes),
        mem_lim: ((.resources.limits.memory // "0") | to_bytes),
        gpu_req: ((.resources.requests["nvidia.com/gpu"] // "0") | safe_tonumber),
        gpu_lim: ((.resources.limits["nvidia.com/gpu"] // "0") | safe_tonumber)
    };

def pod_res:
    (.spec.containers // []) | 
    map(container_res) | 
    if length > 0 then add else {cpu_req:0,cpu_lim:0,mem_req:0,mem_lim:0,gpu_req:0,gpu_lim:0} end;

.items |
map(. + {_res: pod_res}) |
{
    pods: length,
    cpu_req: (map(._res.cpu_req) | add // 0),
    cpu_lim: (map(._res.cpu_lim) | add // 0),
    mem_req: (map(._res.mem_req) | add // 0),
    mem_lim: (map(._res.mem_lim) | add // 0),
    gpu_req: (map(._res.gpu_req) | add // 0),
    gpu_lim: (map(._res.gpu_lim) | add // 0)
} |
"  Pods:           \(.pods)",
"",
"  CPU Requests:   \((.cpu_req / 1000 * 100 | floor) / 100) cores  (\(.cpu_req) m)",
"  CPU Limits:     \((.cpu_lim / 1000 * 100 | floor) / 100) cores  (\(.cpu_lim) m)",
"",
"  Mem Requests:   \((.mem_req / 1073741824 * 100 | floor) / 100) GiB",
"  Mem Limits:     \((.mem_lim / 1073741824 * 100 | floor) / 100) GiB",
"",
(if .gpu_req > 0 or .gpu_lim > 0 then
    "  GPU Requests:   \(.gpu_req)\n  GPU Limits:     \(.gpu_lim)\n"
else
    ""
end)
' "$TMPDIR/filtered.json"

echo ""
echo "--- By Namespace ---"
jq -r '
def to_millicores:
    if type == "number" then (. * 1000)
    elif type == "string" then
        if endswith("m") then (rtrimstr("m") | tonumber)
        else (tonumber * 1000)
        end
    else 0
    end;

def to_bytes:
    if type == "number" then .
    elif type == "string" then
        if endswith("Ki") then (rtrimstr("Ki") | tonumber * 1024)
        elif endswith("Mi") then (rtrimstr("Mi") | tonumber * 1048576)
        elif endswith("Gi") then (rtrimstr("Gi") | tonumber * 1073741824)
        else (tonumber)
        end
    else 0
    end;

def container_res:
    {
        cpu_req: ((.resources.requests.cpu // "0") | to_millicores),
        mem_req: ((.resources.requests.memory // "0") | to_bytes)
    };

def pod_res:
    (.spec.containers // []) |
    map(container_res) |
    if length > 0 then add else {cpu_req:0,mem_req:0} end;

.items |
map(. + {_res: pod_res}) |
group_by(.metadata.namespace) |
.[] |
{
    ns: .[0].metadata.namespace,
    pods: length,
    cpu: (map(._res.cpu_req) | add // 0),
    mem: (map(._res.mem_req) | add // 0)
} |
"  \(.ns)\t\(.pods) pods\t\((.cpu / 1000 * 100 | floor) / 100) cores\t\(.mem / 1048576 | floor) MiB"
' "$TMPDIR/filtered.json"

echo ""
echo "--- Top 10 Pods by CPU Request ---"
jq -r '
def to_millicores:
    if type == "number" then (. * 1000)
    elif type == "string" then
        if endswith("m") then (rtrimstr("m") | tonumber)
        else (tonumber * 1000)
        end
    else 0
    end;

def to_mib:
    if type == "number" then (. / 1048576)
    elif type == "string" then
        if endswith("Ki") then (rtrimstr("Ki") | tonumber / 1024)
        elif endswith("Mi") then (rtrimstr("Mi") | tonumber)
        elif endswith("Gi") then (rtrimstr("Gi") | tonumber * 1024)
        else (tonumber / 1048576)
        end
    else 0
    end;

def container_res:
    {
        cpu_req: ((.resources.requests.cpu // "0") | to_millicores),
        mem_req: ((.resources.requests.memory // "0") | to_mib)
    };

def pod_res:
    (.spec.containers // []) |
    map(container_res) |
    if length > 0 then add else {cpu_req:0,mem_req:0} end;

.items |
map({
    name: .metadata.name,
    ns: .metadata.namespace,
    cpu: pod_res.cpu_req,
    mem: pod_res.mem_req
}) |
sort_by(.cpu) | reverse | .[0:10] |
.[] |
"  \(.name)\t\(.ns)\t\(.cpu) m\t\(.mem | floor) MiB"
' "$TMPDIR/filtered.json"

echo ""
echo "=== Done ==="
