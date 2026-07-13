#!/bin/bash
# kind-trust-registry.sh
#
# Creates (or updates) a Kind cluster so its nodes can pull images from a
# private registry serving HTTPS with a self-signed or internal-CA certificate
# chain (root CA, optionally plus one or more intermediate CAs).
#
# Unlike disabling TLS verification, this installs the registry's CA chain
# into every node's system trust store, so containerd performs real
# certificate-chain validation. Man-in-the-middle protection is preserved;
# only the CAs you supply are trusted.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

CLUSTER_NAME="kind"
NUM_WORKERS=0
declare -a REGISTRIES=()      # one entry per --registry
declare -a CA_CERT_GROUPS=()  # parallel array: newline-separated cert paths for that registry

show_help() {
    cat << EOF
Usage: $0 --cluster-name <name> --registry <host:port> --ca-cert <path> [--ca-cert <path> ...] [--registry <host:port> --ca-cert <path> ...] [--workers N]

Configures a Kind cluster to trust one or more private registries that serve
HTTPS with a self-signed or internally-issued certificate, by installing each
registry's CA chain into every node's OS trust store. This performs real TLS
verification -- it does NOT disable certificate checking.

Required:
    --registry, -r    Private registry host:port (e.g. myregistry.local:5000).
                       Starts a new registry group.
    --ca-cert,  -k    Path to a CA certificate (PEM) for the CURRENT registry
                       group (the most recently given --registry). Repeat this
                       flag to supply a full chain, e.g. root CA + intermediate
                       CA, in any order -- both are installed as trust anchors.

Optional:
    --cluster-name, -c   Kind cluster name (default: kind)
    --workers, -w        Number of worker nodes if creating a new cluster (default: 0)
    --help, -h           Show this help

Examples:
    # Single self-signed CA
    $0 --registry registry.internal:5000 --ca-cert ./registry-ca.crt

    # Root + intermediate CA chain for one registry
    $0 --registry registry.internal:5000 --ca-cert ./root-ca.crt --ca-cert ./intermediate-ca.crt

    # Multiple registries, each with its own chain
    $0 -c dev -r reg1.local:5000 -k root1.crt -k intermediate1.crt \\
             -r reg2.local:5000 -k ca2.crt -w 2
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --cluster-name|-c)
            CLUSTER_NAME="$2"; shift 2 ;;
        --registry|-r)
            REGISTRIES+=("$2")
            CA_CERT_GROUPS+=("")
            shift 2 ;;
        --ca-cert|-k)
            [[ ${#REGISTRIES[@]} -gt 0 ]] || { echo -e "${RED}Error: --ca-cert must come after a --registry${NC}"; exit 1; }
            last=$(( ${#CA_CERT_GROUPS[@]} - 1 ))
            if [[ -z "${CA_CERT_GROUPS[$last]}" ]]; then
                CA_CERT_GROUPS[$last]="$2"
            else
                CA_CERT_GROUPS[$last]="${CA_CERT_GROUPS[$last]}"$'\n'"$2"
            fi
            shift 2 ;;
        --workers|-w)
            NUM_WORKERS="$2"; shift 2 ;;
        --help|-h)
            show_help; exit 0 ;;
        *)
            echo -e "${RED}Error: Unknown argument $1${NC}"; show_help; exit 1 ;;
    esac
done

if [[ ${#REGISTRIES[@]} -eq 0 ]]; then
    echo -e "${RED}Error: at least one --registry (with one or more --ca-cert) is required${NC}"
    show_help
    exit 1
fi
for i in "${!REGISTRIES[@]}"; do
    [[ -n "${CA_CERT_GROUPS[$i]}" ]] || { echo -e "${RED}Error: registry '${REGISTRIES[$i]}' has no --ca-cert${NC}"; exit 1; }
    while IFS= read -r cert; do
        [[ -f "$cert" ]] || { echo -e "${RED}Error: CA cert not found: $cert${NC}"; exit 1; }
        openssl x509 -in "$cert" -noout -subject >/dev/null 2>&1 \
            || { echo -e "${RED}Error: $cert is not a valid PEM certificate${NC}"; exit 1; }
    done <<< "${CA_CERT_GROUPS[$i]}"
done

total_certs=0
for group in "${CA_CERT_GROUPS[@]}"; do
    total_certs=$(( total_certs + $(echo "$group" | grep -c .) ))
done
echo -e "${GREEN}=== Configuring Kind cluster '${CLUSTER_NAME}' to trust ${#REGISTRIES[@]} registr$([[ ${#REGISTRIES[@]} -eq 1 ]] && echo y || echo ies) (${total_certs} CA cert(s) total) ===${NC}"

if ! kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    echo -e "${YELLOW}Cluster '$CLUSTER_NAME' doesn't exist. Creating it...${NC}"

    KIND_CONFIG=$(mktemp)
    trap 'rm -f "$KIND_CONFIG"' EXIT
    {
        echo "kind: Cluster"
        echo "apiVersion: kind.x-k8s.io/v1alpha4"
        echo "nodes:"
        echo "- role: control-plane"
        for ((i=0; i<NUM_WORKERS; i++)); do
            echo "- role: worker"
        done
    } > "$KIND_CONFIG"

    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
    echo -e "${GREEN}Cluster created.${NC}"
else
    echo -e "${YELLOW}Cluster '$CLUSTER_NAME' already exists. Installing CA(s) on its nodes...${NC}"
fi

NODES=$(docker ps --filter "label=io.x-k8s.kind.cluster=${CLUSTER_NAME}" --format "{{.Names}}")
[[ -n "$NODES" ]] || { echo -e "${RED}Error: no running containers found for cluster '$CLUSTER_NAME'${NC}"; exit 1; }

for NODE in $NODES; do
    echo -e "${BLUE}--- Node: $NODE ---${NC}"
    for i in "${!REGISTRIES[@]}"; do
        registry="${REGISTRIES[$i]}"
        safe_name=$(echo "$registry" | tr ':/' '__')
        cert_idx=0
        while IFS= read -r cert; do
            cert_idx=$(( cert_idx + 1 ))
            echo -e "  Installing CA for ${registry} [$cert_idx] (${cert})"
            docker cp "$cert" "${NODE}:/usr/local/share/ca-certificates/${safe_name}-${cert_idx}.crt"
        done <<< "${CA_CERT_GROUPS[$i]}"
    done

    echo -e "  Updating OS trust store..."
    docker exec "$NODE" update-ca-certificates >/dev/null

    echo -e "  Restarting containerd to pick up the updated trust store..."
    docker exec "$NODE" systemctl restart containerd

    echo -n "  Waiting for containerd to come back..."
    ready=false
    for _ in $(seq 1 30); do
        if docker exec "$NODE" sh -c 'test -S /run/containerd/containerd.sock'; then
            ready=true
            break
        fi
        echo -n "."
        sleep 1
    done
    echo
    if ! $ready; then
        echo -e "${RED}  containerd did not come back on $NODE within 30s${NC}"
        exit 1
    fi
    echo -e "${GREEN}  ✓ $NODE now trusts: ${REGISTRIES[*]}${NC}"
done

kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null 2>&1 || true

echo -e "\n${GREEN}=== Done ===${NC}"
echo -e "${BLUE}Registries trusted on cluster '${CLUSTER_NAME}' (real cert-chain validation, not skip-verify):${NC}"
for i in "${!REGISTRIES[@]}"; do
    n=$(echo "${CA_CERT_GROUPS[$i]}" | grep -c .)
    echo "  - ${REGISTRIES[$i]}   (${n} CA cert(s))"
done
echo
echo "Verify from a node:"
first_node=$(echo "$NODES" | head -1)
echo "  docker exec ${first_node} crictl pull <registry>/<image>:<tag>"
echo
echo "Verify from Kubernetes:"
echo "  kubectl run test --image=<registry>/<image>:<tag> --restart=Never --command -- sleep 10"
