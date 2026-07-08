#!/usr/bin/env bash
# ============================================================================
# setup.sh — full observability + MinIO stack on a local kind cluster
# ============================================================================
# What it does:
#   1. Preflight checks (tools, cluster, taint)
#   2. Install kube-prometheus-stack via Helm
#   3. Load Grafana dashboards (node-taint, pod-ns, chaos-dr)
#   4. Apply nginx ingress rules
#   5. Deploy MinIO instances 1 & 2
#   6. Seed minio1 with test data
#   7. Migrate minio1 → minio2 with mc mirror + verify
#   8. Print access URLs
# ============================================================================

set -euo pipefail

# ── colours ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}${BOLD}==>${RESET} $*"; }
success() { echo -e "${GREEN}${BOLD} ✓${RESET}  $*"; }
warn()    { echo -e "${YELLOW}${BOLD} !${RESET}  $*"; }
die()     { echo -e "${RED}${BOLD}ERR${RESET}  $*" >&2; exit 1; }
step()    { echo -e "\n${BLUE}${BOLD}────────────────────────────────────────${RESET}"; \
            echo -e "${BLUE}${BOLD}  $*${RESET}"; \
            echo -e "${BLUE}${BOLD}────────────────────────────────────────${RESET}"; }

# ── config ───────────────────────────────────────────────────────────────────
NAMESPACE_MONITORING=monitoring
NAMESPACE_MINIO=minio
HELM_RELEASE=kube-prom
TAINT_KEY=zone
TAINT_VALUE=local
TAINT_EFFECT=NoSchedule

MINIO1_USER=minio1admin
MINIO1_PASS=minio1secret
MINIO2_USER=minio2admin
MINIO2_PASS=minio2secret

MINIO1_PORT=9001
MINIO2_PORT=9002
GRAFANA_PORT=3000
INGRESS_PORT=8080

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_DIR="$(mktemp -d)"
trap 'rm -rf "$SEED_DIR"' EXIT

# ── helpers ──────────────────────────────────────────────────────────────────
require() {
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || die "'$cmd' is required but not found. Install it and retry."
  done
}

wait_rollout() {
  local kind=$1 name=$2 ns=$3
  info "Waiting for $kind/$name in $ns …"
  kubectl rollout status "$kind/$name" -n "$ns" --timeout=5m
}

port_forward_bg() {
  local svc=$1 local_port=$2 remote_port=$3 ns=$4
  # kill any existing forward on this port
  lsof -ti:"$local_port" | xargs kill -9 2>/dev/null || true
  sleep 1
  kubectl port-forward "svc/$svc" "${local_port}:${remote_port}" -n "$ns" \
    >/tmp/pf-${svc}.log 2>&1 &
  # wait until the port is actually open
  local i=0
  until lsof -ti:"$local_port" &>/dev/null; do
    sleep 1; (( i++ )); [[ $i -lt 15 ]] || die "port-forward svc/$svc never became ready"
  done
  success "port-forward svc/$svc → localhost:$local_port"
}

grafana_api() {
  curl -sf --user admin:admin "http://127.0.0.1:${GRAFANA_PORT}/api/$1" "${@:2}"
}

# ============================================================================
step "1 / 8  Preflight"
# ============================================================================

require kubectl helm mc curl lsof python3

# kind cluster reachable?
kubectl cluster-info &>/dev/null || die "No reachable Kubernetes cluster. Start kind first."
success "kubectl cluster reachable"

# taint
TAINTED=$(kubectl get nodes -o json \
  | python3 -c "
import sys, json
nodes = json.load(sys.stdin)['items']
for n in nodes:
  for t in (n['spec'].get('taints') or []):
    if t['key']=='${TAINT_KEY}' and t.get('value')=='${TAINT_VALUE}':
      print(n['metadata']['name'])
" 2>/dev/null || true)

if [[ -z "$TAINTED" ]]; then
  warn "No node has taint ${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT} — applying to all nodes"
  for node in $(kubectl get nodes -o jsonpath='{.items[*].metadata.name}'); do
    kubectl taint node "$node" "${TAINT_KEY}=${TAINT_VALUE}:${TAINT_EFFECT}" \
      --overwrite &>/dev/null
    success "tainted $node"
  done
else
  success "taint ${TAINT_KEY}=${TAINT_VALUE} already present on: $TAINTED"
fi

# helm repo
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts &>/dev/null
helm repo update prometheus-community &>/dev/null
success "helm repo up to date"

# ============================================================================
step "2 / 8  kube-prometheus-stack"
# ============================================================================

kubectl create namespace "$NAMESPACE_MONITORING" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

# clear any stuck admission webhook jobs from prior failed installs
kubectl delete job \
  kube-prom-kube-prometheus-admission-patch \
  kube-prom-kube-prometheus-admission-create \
  -n "$NAMESPACE_MONITORING" 2>/dev/null || true

helm upgrade --install "$HELM_RELEASE" \
  prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE_MONITORING" \
  --values "$SCRIPT_DIR/values.yaml" \
  --timeout 5m \
  --atomic
success "kube-prometheus-stack installed (release: $HELM_RELEASE)"

wait_rollout deployment "${HELM_RELEASE}-grafana"           "$NAMESPACE_MONITORING"
wait_rollout deployment "${HELM_RELEASE}-kube-state-metrics" "$NAMESPACE_MONITORING"
wait_rollout statefulset "prometheus-${HELM_RELEASE}-kube-prometheus-prometheus" \
  "$NAMESPACE_MONITORING" 2>/dev/null || \
wait_rollout statefulset "prometheus-kube-prom-kube-prometheus-prometheus" \
  "$NAMESPACE_MONITORING"

# ============================================================================
step "3 / 8  Grafana dashboards"
# ============================================================================

port_forward_bg "${HELM_RELEASE}-grafana" "$GRAFANA_PORT" 80 "$NAMESPACE_MONITORING"

for dashboard in \
  node-taint-monitor \
  node-taint-monitor-export \
  pod-namespace-resources \
  chaos-dr-monitor; do

  json_file="$SCRIPT_DIR/dashboards/${dashboard}.json"
  [[ -f "$json_file" ]] || { warn "Dashboard $dashboard.json not found — skipping"; continue; }

  result=$(python3 - <<PYEOF
import urllib.request, json, sys
dash = json.load(open('${json_file}'))
payload = json.dumps({'dashboard': dash, 'overwrite': True, 'folderId': 0}).encode()
req = urllib.request.Request(
    'http://127.0.0.1:${GRAFANA_PORT}/api/dashboards/db',
    data=payload,
    headers={
      'Content-Type': 'application/json',
      'Authorization': 'Basic YWRtaW46YWRtaW4='
    }
)
with urllib.request.urlopen(req) as r:
    print(json.loads(r.read()).get('status','?'))
PYEOF
)
  success "dashboard $dashboard → $result"
done

# also apply via ConfigMap for sidecar auto-reload
kubectl create configmap node-taint-monitor-dashboard \
  --namespace "$NAMESPACE_MONITORING" \
  --from-file=node-taint-monitor.json="$SCRIPT_DIR/dashboards/node-taint-monitor.json" \
  --dry-run=client -o yaml \
  | kubectl label --local -f - grafana_dashboard=1 -o yaml \
  | kubectl apply -f - &>/dev/null
success "dashboard ConfigMap applied"

# ============================================================================
step "4 / 8  Nginx ingress"
# ============================================================================

# verify ingress class exists
kubectl get ingressclass nginx &>/dev/null || \
  die "nginx IngressClass not found. Install ingress-nginx first:\n  kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml"

kubectl apply -f "$SCRIPT_DIR/ingress.yaml"
success "ingress resources applied (grafana.local, prometheus.local, alertmanager.local)"

# wait for nginx to sync
sleep 3
kubectl get ingress -n "$NAMESPACE_MONITORING" \
  | awk '{printf "  %-16s %-25s %s\n", $1, $3, $4}'

# port-forward the ingress controller
port_forward_bg ingress-nginx-controller "$INGRESS_PORT" 80 ingress-nginx

# quick smoke test
for host in grafana.local prometheus.local alertmanager.local; do
  code=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $host" \
         "http://localhost:${INGRESS_PORT}/")
  [[ "$code" =~ ^(200|301|302)$ ]] \
    && success "ingress $host → HTTP $code" \
    || warn    "ingress $host → HTTP $code (unexpected)"
done

# /etc/hosts hint
if ! grep -q "grafana.local" /etc/hosts 2>/dev/null; then
  warn "/etc/hosts missing — run once to enable browser access:"
  echo -e "  ${BOLD}sudo sh -c 'echo \"127.0.0.1  grafana.local prometheus.local alertmanager.local\" >> /etc/hosts'${RESET}"
fi

# ============================================================================
step "5 / 8  Deploy MinIO instances"
# ============================================================================

kubectl create namespace "$NAMESPACE_MINIO" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null
kubectl apply -f "$SCRIPT_DIR/minio/minio.yaml"

wait_rollout deployment minio1 "$NAMESPACE_MINIO"
wait_rollout deployment minio2 "$NAMESPACE_MINIO"
success "minio1 and minio2 running"

# ============================================================================
step "6 / 8  Seed minio1 with test data"
# ============================================================================

port_forward_bg minio1 "$MINIO1_PORT" 9000 "$NAMESPACE_MINIO"
port_forward_bg minio2 "$MINIO2_PORT" 9000 "$NAMESPACE_MINIO"

mc alias set minio1 "http://localhost:${MINIO1_PORT}" "$MINIO1_USER" "$MINIO1_PASS" \
  --api S3v4 &>/dev/null
mc alias set minio2 "http://localhost:${MINIO2_PORT}" "$MINIO2_USER" "$MINIO2_PASS" \
  --api S3v4 &>/dev/null
success "mc aliases configured"

# create buckets on both instances
for bucket in logs configs backups; do
  mc mb --ignore-existing "minio1/$bucket" &>/dev/null
  mc mb --ignore-existing "minio2/$bucket" &>/dev/null
done
success "buckets created on minio1 and minio2"

# generate seed files
mkdir -p "$SEED_DIR"/{logs,configs,backups}

# logs — 5 daily app log files
for i in $(seq 1 5); do
  cat > "$SEED_DIR/logs/app-2026-06-2${i}.log" <<EOF
2026-06-2${i}T00:01:00Z INFO  service=api    msg="startup complete"
2026-06-2${i}T00:05:12Z INFO  service=api    msg="health check OK"
2026-06-2${i}T12:00:00Z WARN  service=worker msg="queue depth=450 threshold=400"
2026-06-2${i}T14:32:01Z ERROR service=db     msg="connection retry" attempt=${i}
2026-06-2${i}T23:59:59Z INFO  service=api    msg="graceful shutdown"
EOF
done

# configs — yaml + json
cat > "$SEED_DIR/configs/app-config.yaml" <<'EOF'
environment: production
replicas: 3
db:
  host: postgres.internal
  port: 5432
  name: appdb
cache:
  ttl: 300
  backend: redis
EOF

cat > "$SEED_DIR/configs/feature-flags.json" <<'EOF'
{
  "chaos_mode": false,
  "new_dashboard": true,
  "migration_v2": true,
  "max_retries": 5
}
EOF

# backups — two binary-like snapshots
dd if=/dev/urandom bs=1k count=128 2>/dev/null | base64 > "$SEED_DIR/backups/snapshot-20260620.bak"
dd if=/dev/urandom bs=1k count=64  2>/dev/null | base64 > "$SEED_DIR/backups/snapshot-20260621.bak"

# upload
for bucket in logs configs backups; do
  mc cp --recursive "$SEED_DIR/$bucket/" "minio1/$bucket/" &>/dev/null
done

obj_count=$(mc ls --recursive minio1 | wc -l | tr -d ' ')
success "seeded minio1 — $obj_count objects across 3 buckets"

# ============================================================================
step "7 / 8  Migrate minio1 → minio2"
# ============================================================================

for bucket in logs configs backups; do
  info "  mirroring bucket: $bucket"
  mc mirror --preserve --watch=false "minio1/$bucket" "minio2/$bucket"
done

# verify
echo ""
info "Verification:"
all_ok=true
for bucket in logs configs backups; do
  src=$(mc ls --recursive "minio1/$bucket" | awk '{print $NF,$3}' | sort)
  dst=$(mc ls --recursive "minio2/$bucket" | awk '{print $NF,$3}' | sort)
  if [[ "$src" == "$dst" ]]; then
    n=$(echo "$src" | wc -l | tr -d ' ')
    success "  $bucket — $n objects match"
  else
    warn "  $bucket — MISMATCH"
    diff <(echo "$src") <(echo "$dst") || true
    all_ok=false
  fi
done

# ETag spot-check on largest file
src_etag=$(mc stat minio1/backups/snapshot-20260620.bak 2>/dev/null | awk '/ETag/{print $3}')
dst_etag=$(mc stat minio2/backups/snapshot-20260620.bak 2>/dev/null | awk '/ETag/{print $3}')
if [[ "$src_etag" == "$dst_etag" && -n "$src_etag" ]]; then
  success "  ETag match on snapshot-20260620.bak ($src_etag)"
else
  warn "  ETag mismatch! src=$src_etag dst=$dst_etag"
  all_ok=false
fi

$all_ok && success "Migration complete — all objects verified" \
         || die    "Migration had errors — check output above"

# ============================================================================
step "8 / 9  Argo Workflows"
# ============================================================================

NAMESPACE_ARGO=argo
ARGO_PORT=2746

helm repo add argo https://argoproj.github.io/argo-helm &>/dev/null || true
helm repo update argo &>/dev/null

kubectl create namespace "$NAMESPACE_ARGO" --dry-run=client -o yaml | kubectl apply -f - &>/dev/null

helm upgrade --install argo-workflows argo/argo-workflows \
  --namespace "$NAMESPACE_ARGO" \
  -f "$SCRIPT_DIR/argo-workflows-helm-values.yaml" \
  --timeout 5m \
  --atomic
success "argo-workflows installed"

wait_rollout deployment argo-workflows-server     "$NAMESPACE_ARGO"
wait_rollout deployment argo-workflows-controller "$NAMESPACE_ARGO"

kubectl apply -f "$SCRIPT_DIR/argo-workflows.yaml"
success "argo namespace, ingress, and minio-artifact-pipeline workflow applied"

if ! grep -q "argo.local" /etc/hosts 2>/dev/null; then
  warn "/etc/hosts missing — run once to enable browser access:"
  echo -e "  ${BOLD}sudo sh -c 'echo \"127.0.0.1  argo.local\" >> /etc/hosts'${RESET}"
fi

info "Waiting for minio-artifact-pipeline to finish"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded \
  workflow/minio-artifact-pipeline -n "$NAMESPACE_ARGO" --timeout=3m \
  && success "minio-artifact-pipeline Succeeded" \
  || warn    "minio-artifact-pipeline did not reach Succeeded — check: kubectl get workflow -n $NAMESPACE_ARGO"

port_forward_bg argo-workflows-server "$ARGO_PORT" 2746 "$NAMESPACE_ARGO"

# ============================================================================
step "9 / 9  Access summary"
# ============================================================================

cat <<EOF

${BOLD}${GREEN}All components deployed successfully.${RESET}

${BOLD}Monitoring${RESET}
  Grafana       http://localhost:${GRAFANA_PORT}            admin / admin
  Grafana       http://grafana.local:${INGRESS_PORT}        (needs /etc/hosts)
  Prometheus    http://prometheus.local:${INGRESS_PORT}     (needs /etc/hosts)
  Alertmanager  http://alertmanager.local:${INGRESS_PORT}  (needs /etc/hosts)

${BOLD}Grafana dashboards loaded${RESET}
  • Node Taint Monitor
  • Pod & Namespace Resource Consumption
  • Chaos DR Monitor

${BOLD}MinIO${RESET}
  Instance 1    http://localhost:${MINIO1_PORT}    ${MINIO1_USER} / ${MINIO1_PASS}
  Instance 2    http://localhost:${MINIO2_PORT}    ${MINIO2_USER} / ${MINIO2_PASS}

${BOLD}Useful mc commands${RESET}
  mc ls minio1                              # list all buckets
  mc diff minio1/backups minio2/backups     # diff instances
  mc mirror --watch minio1/logs minio2/logs # live replication

${BOLD}Argo Workflows${RESET}
  UI            http://localhost:${ARGO_PORT}
  UI            http://argo.local:${INGRESS_PORT}          (needs /etc/hosts)
  Sample workflow: minio-artifact-pipeline (mirrors minio1 → minio2 as a DAG)
    kubectl get workflow -n ${NAMESPACE_ARGO}
    argo logs minio-artifact-pipeline -n ${NAMESPACE_ARGO}
    argo submit --watch ${SCRIPT_DIR}/argo-workflows.yaml -n ${NAMESPACE_ARGO}   # re-run it

${BOLD}Note:${RESET} port-forwards are running in the background.
  To stop all:  kill \$(lsof -ti:${GRAFANA_PORT},${INGRESS_PORT},${MINIO1_PORT},${MINIO2_PORT},${ARGO_PORT})

EOF
