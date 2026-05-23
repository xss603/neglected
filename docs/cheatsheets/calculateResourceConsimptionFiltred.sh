#!/bin/bash
# calculate-node-resources-filtered.sh
# Calculates total resource requests/limits for all pods running on a specific node,
# with optional regex-based pod name filtering (excluded pods are ignored).
# Usage: ./scripts/calculate-node-resources-filtered.sh <node-name> [exclude-regex]
# Example: ./scripts/calculate-node-resources-filtered.sh kind-control-plane "^app-"
# Example: ./scripts/calculate-node-resources-filtered.sh kind-control-plane "apps-demo.*"

set -euo pipefail

NODE_NAME="${1:-}"
EXCLUDE_REGEX="${2:-}"

if [ -z "$NODE_NAME" ]; then
    echo "Usage: $0 <node-name> [exclude-regex]"
    echo "Example: $0 kind-control-plane 'apps-demo.*'"
    exit 1
fi

KUBECTL="kubectl"
if [ -n "${KUBECONFIG:-}" ]; then
    KUBECTL="kubectl --kubeconfig=$KUBECONFIG"
fi

echo "=== Node Resource Calculator (Filtered) ==="
echo "Node: $NODE_NAME"
if [ -n "$EXCLUDE_REGEX" ]; then
    echo "Excluding pods matching regex: $EXCLUDE_REGEX"
fi
echo ""

# Verify node exists
if ! $KUBECTL get node "$NODE_NAME" > /dev/null 2>&1; then
    echo "Error: Node '$NODE_NAME' not found"
    exit 1
fi

# Get node capacity
echo "--- Node Capacity ---"
$KUBECTL get node "$NODE_NAME" -o json | jq -r '
  .status.capacity |
  "CPU:        \(.cpu // "N/A")",
  "Memory:     \(.memory // "N/A")",
  "Ephemeral:  \(.["ephemeral-storage"] // "N/A")",
  "Pods:       \(.pods // "N/A")",
  if .["nvidia.com/gpu"] then "GPU:        \(.["nvidia.com/gpu"])" else empty end
'

echo ""
echo "--- Fetching pods on node ---"

# Get all pods scheduled on this node
PODS_JSON=$($KUBECTL get pods --all-namespaces --field-selector spec.nodeName="$NODE_NAME" -o json)

# Apply regex filter in jq
FILTERED_JSON=$(echo "$PODS_JSON" | jq --arg regex "$EXCLUDE_REGEX" '
    if $regex != "" then
        .items |= map(select(.metadata.name | test($regex) | not))
    else
        .
    end
')

TOTAL_PODS=$(echo "$PODS_JSON" | jq '.items | length')
FILTERED_PODS=$(echo "$FILTERED_JSON" | jq '.items | length')
EXCLUDED_COUNT=$((TOTAL_PODS - FILTERED_PODS))

echo "Total pods: $TOTAL_PODS"
if [ "$EXCLUDED_COUNT" -gt 0 ]; then
    echo "Excluded by regex: $EXCLUDED_COUNT"
fi
echo "Pods counted: $FILTERED_PODS"
echo ""

if [ "$FILTERED_PODS" -eq 0 ]; then
    echo "No pods match the criteria."
    exit 0
fi

# Show excluded pod names
if [ "$EXCLUDED_COUNT" -gt 0 ]; then
    echo "--- Excluded Pods ---"
    echo "$PODS_JSON" | jq --arg regex "$EXCLUDE_REGEX" -r '
        .items[] | select(.metadata.name | test($regex)) |
        "  - \(.metadata.name) (\(.metadata.namespace))"
    '
    echo ""
fi

# Calculate totals using jq
echo "--- Resource Summary ---"
echo "$FILTERED_JSON" | jq -r '
def to_millicores:
    if . == null then 0
    elif type == "string" then
        if endswith("m") then (.[:-1] | tonumber)
        elif . == "0" then 0
        else (tonumber * 1000)
        end
    else (tonumber * 1000)
    end;

def to_bytes:
    if . == null then 0
    elif type == "string" then
        if endswith("Ki") then (.[:-2] | tonumber * 1024)
        elif endswith("Mi") then (.[:-2] | tonumber * 1024 * 1024)
        elif endswith("Gi") then (.[:-2] | tonumber * 1024 * 1024 * 1024)
        elif endswith("Ti") then (.[:-2] | tonumber * 1024 * 1024 * 1024 * 1024)
        elif endswith("k") then (.[:-1] | tonumber * 1000)
        elif endswith("M") then (.[:-1] | tonumber * 1000 * 1000)
        elif endswith("G") then (.[:-1] | tonumber * 1000 * 1000 * 1000)
        else (tonumber)
        end
    else tonumber
    end;

def to_gib:
    to_bytes / 1024 / 1024 / 1024;

def to_gpu:
    if . == null then 0 else tonumber end;

.items |
reduce .[] as $pod ({
    cpu_req: 0, cpu_lim: 0,
    mem_req: 0, mem_lim: 0,
    gpu_req: 0, gpu_lim: 0,
    pod_count: 0
};
    .pod_count += 1 |
    reduce ($pod.spec.containers // [])[] as $c (.;
        .cpu_req  += (($c.resources.requests.cpu    // "0") | to_millicores) |
        .cpu_lim  += (($c.resources.limits.cpu      // "0") | to_millicores) |
        .mem_req  += (($c.resources.requests.memory // "0") | to_bytes) |
        .mem_lim  += (($c.resources.limits.memory   // "0") | to_bytes) |
        .gpu_req  += (($c.resources.requests["nvidia.com/gpu"] // "0") | to_gpu) |
        .gpu_lim  += (($c.resources.limits["nvidia.com/gpu"]   // "0") | to_gpu)
    )
) |
"Total Pods:         \(.pod_count)",
"",
"CPU Requests:       \(.cpu_req / 1000 | floor) cores (\(.cpu_req) m)",
"CPU Limits:         \(.cpu_lim / 1000 | floor) cores (\(.cpu_lim) m)",
"CPU Utilization:    \(if .cpu_lim > 0 then (.cpu_req / .cpu_lim * 100 | floor) else 0 end)% of limits requested",
"",
"Memory Requests:    \(.mem_req | to_gib | .*100 | floor / 100) GiB (\(.mem_req) bytes)",
"Memory Limits:      \(.mem_lim | to_gib | .*100 | floor / 100) GiB (\(.mem_lim) bytes)",
"Memory Utilization: \(if .mem_lim > 0 then (.mem_req / .mem_lim * 100 | floor) else 0 end)% of limits requested",
"",
if .gpu_req > 0 or .gpu_lim > 0 then
    "GPU Requests:       \(.gpu_req)",
    "GPU Limits:         \(.gpu_lim)",
    ""
else empty end
'

echo ""
echo "--- Breakdown by Namespace ---"
echo "$FILTERED_JSON" | jq -r '
def to_millicores:
    if . == null then 0
    elif type == "string" then
        if endswith("m") then (.[:-1] | tonumber)
        else (tonumber * 1000)
        end
    else (tonumber * 1000)
    end;

def to_bytes:
    if . == null then 0
    elif type == "string" then
        if endswith("Ki") then (.[:-2] | tonumber * 1024)
        elif endswith("Mi") then (.[:-2] | tonumber * 1024 * 1024)
        elif endswith("Gi") then (.[:-2] | tonumber * 1024 * 1024 * 1024)
        else tonumber
        end
    else tonumber
    end;

.items |
group_by(.metadata.namespace) |
.[] |
{
    ns: .[0].metadata.namespace,
    pods: length,
    cpu: ([.[] | .spec.containers[]?.resources.requests.cpu | to_millicores] | add // 0),
    mem: ([.[] | .spec.containers[]?.resources.requests.memory | to_bytes] | add // 0)
} |
"\(.ns)\t\(.pods) pods\t\(.cpu / 1000 * 10 | floor / 10) cores\t\(.mem / 1024 / 1024 | floor) MiB"
'

echo ""
echo "--- Breakdown by Pod (Top 10 by CPU request) ---"
echo "$FILTERED_JSON" | jq -r '
def to_millicores:
    if . == null then 0
    elif type == "string" then
        if endswith("m") then (.[:-1] | tonumber)
        else (tonumber * 1000)
        end
    else (tonumber * 1000)
    end;

def to_mib:
    if . == null then 0
    elif type == "string" then
        if endswith("Ki") then (.[:-2] | tonumber / 1024)
        elif endswith("Mi") then (.[:-2] | tonumber)
        elif endswith("Gi") then (.[:-2] | tonumber * 1024)
        else (tonumber / 1024 / 1024)
        end
    else (. / 1024 / 1024)
    end;

.items |
map({
    name: .metadata.name,
    ns: .metadata.namespace,
    cpu: ([.spec.containers[]?.resources.requests.cpu | to_millicores] | add // 0),
    mem: ([.spec.containers[]?.resources.requests.memory | to_mib] | add // 0)
}) |
sort_by(.cpu) |
reverse |
.[0:10] |
.[] |
"\(.name)\t\(.ns)\t\(.cpu) m\t\(.mem | floor) MiB"
'

echo ""
echo "=== Done ==="
