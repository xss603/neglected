#!/usr/bin/env bash
# kgateway-healthcheck.sh
# Deep-check Gateway API + kgateway/Envoy xDS state
# Usage: ./kgateway-healthcheck.sh <namespace> <gateway-name> [admin-port]
#
# Changelog vs. original:
#   - set -u no longer crashes mid-run (EXT_IP/LISTENERS pre-initialized)
#   - trap EXIT kills the port-forward on any exit path, not just the happy path
#   - preflight check for kubectl/jq
#   - GatewayClass check added (step 0) - the #1 real-world root cause in this
#     failure class: kgateway ships no GatewayClass by default
#   - sections 7/8 filtered to routes that actually parentRef this Gateway
#   - multi-pod warning instead of silently picking items[0]
#   - per-run tmpdir (mktemp -d) + dynamic-ish admin port instead of fixed /tmp
#     paths and a hardcoded local port, so two runs don't collide
#   - port-forward readiness polled instead of a fixed sleep 2

set -uo pipefail
NS="${1:?Usage: $0 <namespace> <gateway-name> [admin-port]}"
GW="${2:?Usage: $0 <namespace> <gateway-name> [admin-port]}"
ADMIN_PORT="${3:-19000}"   # kgateway default; some builds expose Envoy admin on 9901 instead

PASS="\033[32mOK\033[0m"; FAIL="\033[31mFAIL\033[0m"; WARN="\033[33mWARN\033[0m"
ok(){ echo -e "[$PASS] $1"; }
ko(){ echo -e "[$FAIL] $1"; }
warn(){ echo -e "[$WARN] $1"; }

for bin in kubectl jq curl; do
  command -v "$bin" >/dev/null 2>&1 || { echo "missing required binary: $bin" >&2; exit 2; }
done

TMPDIR=$(mktemp -d "/tmp/kgw-healthcheck.XXXXXX")
PF_PID=""
cleanup(){ [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null; rm -rf "$TMPDIR"; }
trap cleanup EXIT

# Pre-initialize everything referenced later under set -u so a failed lookup
# warns instead of silently killing the rest of the script's output.
EXT_IP="unknown"
LISTENERS=""
GW_POD=""
GW_SVC=""

echo "=== 0. GatewayClass (kgateway ships none by default - this is the #1 real cause) ==="
GWC=$(kubectl get gateway "$GW" -n "$NS" -o jsonpath='{.spec.gatewayClassName}' 2>/dev/null)
if [[ -z "$GWC" ]]; then
  ko "Gateway $GW not found in $NS, or has no gatewayClassName set"
else
  GWC_STATUS=$(kubectl get gatewayclass "$GWC" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  [[ "$GWC_STATUS" == "True" ]] && ok "GatewayClass $GWC Accepted=True" || ko "GatewayClass $GWC Accepted=$GWC_STATUS (missing/not owned by kgateway's controller -> Gateway will never Program)"
fi

echo
echo "=== 1. Gateway resource & status ==="
kubectl get gateway "$GW" -n "$NS" >/dev/null 2>&1 || { ko "Gateway $GW not found in $NS"; exit 1; }
GW_STATUS=$(kubectl get gateway "$GW" -n "$NS" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')
[[ "$GW_STATUS" == "True" ]] && ok "Gateway Programmed=True" || ko "Gateway Programmed=$GW_STATUS"

LISTENERS=$(kubectl get gateway "$GW" -n "$NS" -o json | jq -r '.spec.listeners[] | "\(.name):\(.port):\(.protocol)"')
echo "Declared listeners: $LISTENERS"

echo
echo "=== 2. GatewayParameters (deployment/service port mapping) ==="
GWP_NAME=$(kubectl get gateway "$GW" -n "$NS" -o jsonpath='{.spec.infrastructure.parametersRef.name}' 2>/dev/null)
if [[ -n "$GWP_NAME" ]]; then
  kubectl get gatewayparameters "$GWP_NAME" -n "$NS" -o json > "$TMPDIR/gwp.json" 2>/dev/null
  GWP_SVC_PORTS=$(jq -r '.spec.kube.service.ports[]? | "\(.port):\(.targetPort)"' "$TMPDIR/gwp.json")
  echo "GatewayParameters svc ports (port:targetPort): $GWP_SVC_PORTS"
else
  warn "No GatewayParameters parametersRef found — using controller defaults"
fi

echo
echo "=== 3. K8s Service (Gateway-generated) ==="
GW_PODS_COUNT=$(kubectl get pods -n "$NS" -l "gateway.networking.k8s.io/gateway-name=$GW" -o jsonpath='{.items[*].metadata.name}' | wc -w)
[[ "$GW_PODS_COUNT" -gt 1 ]] && warn "$GW_PODS_COUNT Gateway pods found - this script only inspects items[0]; re-run per-pod if they might differ"
GW_POD=$(kubectl get pods -n "$NS" -l "gateway.networking.k8s.io/gateway-name=$GW" -o jsonpath='{.items[0].metadata.name}')
GW_SVC=$(kubectl get svc -n "$NS" -l "gateway.networking.k8s.io/gateway-name=$GW" -o jsonpath='{.items[0].metadata.name}')

if [[ -z "$GW_POD" || -z "$GW_SVC" ]]; then
  ko "Could not find Gateway pod/svc via label selector — check labels manually"
else
  ok "Gateway pod: $GW_POD | Service: $GW_SVC"
  kubectl get svc "$GW_SVC" -n "$NS" -o json > "$TMPDIR/svc.json"
  SVC_TYPE=$(jq -r '.spec.type' "$TMPDIR/svc.json")
  EXT_IP=$(jq -r '.status.loadBalancer.ingress[0].ip // "pending"' "$TMPDIR/svc.json")
  echo "Service type: $SVC_TYPE | External IP: $EXT_IP"
  jq -r '.spec.ports[] | "  port=\(.port) targetPort=\(.targetPort) nodePort=\(.nodePort // "n/a")"' "$TMPDIR/svc.json"
fi

echo
echo "=== 4. Endpoints (Service -> Pod reachability) ==="
if [[ -n "$GW_SVC" ]]; then
  EP_COUNT=$(kubectl get endpoints "$GW_SVC" -n "$NS" -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null | wc -w)
  [[ "$EP_COUNT" -gt 0 ]] && ok "Endpoints populated ($EP_COUNT address(es))" || ko "Endpoints EMPTY — pod not Ready or selector mismatch"
fi

echo
echo "=== 5. Pod readiness & socket bind (netstat/ss inside pod) ==="
if [[ -n "$GW_POD" ]]; then
  READY=$(kubectl get pod "$GW_POD" -n "$NS" -o jsonpath='{.status.containerStatuses[0].ready}')
  [[ "$READY" == "true" ]] && ok "Pod Ready=true" || ko "Pod Ready=$READY"

  echo "-- Listening sockets inside pod (ss -tlnp) --"
  kubectl exec -n "$NS" "$GW_POD" -- sh -c "ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null" 2>/dev/null \
    || warn "Could not exec ss/netstat — expected if this is a distroless Envoy image with no shell; rely on section 6's admin API instead"

  echo "-- Cross-check: declared listener ports vs actually bound sockets --"
  for lp in $(echo "$LISTENERS" | cut -d: -f2); do
    BOUND=$(kubectl exec -n "$NS" "$GW_POD" -- sh -c "ss -tln 2>/dev/null | grep -c ':$lp '" 2>/dev/null)
    [[ "${BOUND:-0}" -gt 0 ]] && ok "Port $lp is bound in pod" || ko "Port $lp declared in Gateway but NOT bound in pod (check GatewayParameters container port, or image has no shell to verify)"
  done
fi

echo
echo "=== 6. Envoy Admin API — xDS state (LDS/RDS/CDS/EDS) ==="
if [[ -n "$GW_POD" ]]; then
  kubectl port-forward -n "$NS" "pod/$GW_POD" "$ADMIN_PORT:$ADMIN_PORT" >"$TMPDIR/pf.log" 2>&1 &
  PF_PID=$!

  READY_PF=0
  for _ in $(seq 1 10); do
    if curl -s --max-time 1 "http://localhost:$ADMIN_PORT/ready" 2>/dev/null | grep -q LIVE; then
      READY_PF=1; break
    fi
    sleep 0.5
  done

  if [[ "$READY_PF" -eq 1 ]]; then
    ok "Envoy admin API reachable on $ADMIN_PORT"

    echo "-- LDS: active listeners --"
    curl -s --max-time 3 "http://localhost:$ADMIN_PORT/listeners" || warn "listeners endpoint failed"

    echo "-- CDS: clusters + health --"
    curl -s --max-time 3 "http://localhost:$ADMIN_PORT/clusters" | grep -E "health_flags|::" | head -20 || warn "clusters endpoint failed"

    echo "-- RDS/config_dump: routes summary --"
    curl -s --max-time 3 "http://localhost:$ADMIN_PORT/config_dump?resource=dynamic_route_configs" \
      | jq -r '.. | .route?.action? // empty' 2>/dev/null | head -10
  else
    warn "Envoy admin API not reachable on $ADMIN_PORT within 5s (try passing 9901 as \$3, or check GatewayParameters adminPort). port-forward log: $TMPDIR/pf.log"
  fi

  kill "$PF_PID" 2>/dev/null; PF_PID=""
fi

echo
echo "=== 7. HTTPRoute status (Accepted / ResolvedRefs / Programmed) — filtered to routes parenting $GW ==="
for r in $(kubectl get httproute -n "$NS" -o json | jq -r --arg gw "$GW" '.items[] | select(.spec.parentRefs[]?.name == $gw) | .metadata.name'); do
  echo "-- HTTPRoute: $r --"
  kubectl get httproute "$r" -n "$NS" -o json \
    | jq -r '.status.parents[] | "  parent=\(.parentRef.name) Accepted=\(.conditions[]|select(.type=="Accepted").status) ResolvedRefs=\(.conditions[]|select(.type=="ResolvedRefs").status)"'
done

echo
echo "=== 8. Backend Service targetPort vs Pod containerPort — filtered to routes parenting $GW ==="
for r in $(kubectl get httproute -n "$NS" -o json | jq -r --arg gw "$GW" '.items[] | select(.spec.parentRefs[]?.name == $gw) | .metadata.name'); do
  BACKENDS=$(kubectl get httproute "$r" -n "$NS" -o json | jq -r '.spec.rules[].backendRefs[]? | "\(.name):\(.port)"')
  for b in $BACKENDS; do
    BSVC=$(echo "$b" | cut -d: -f1); BPORT=$(echo "$b" | cut -d: -f2)
    TARGET=$(kubectl get svc "$BSVC" -n "$NS" -o jsonpath="{.spec.ports[?(@.port==$BPORT)].targetPort}" 2>/dev/null)
    POD_SELECTOR=$(kubectl get svc "$BSVC" -n "$NS" -o jsonpath='{.spec.selector}' 2>/dev/null)
    echo "Backend $BSVC:$BPORT -> targetPort=$TARGET (selector=$POD_SELECTOR)"
    [[ -z "$TARGET" ]] && ko "Backend svc $BSVC has no matching port $BPORT" || ok "Backend $BSVC port mapping resolved"
  done
done

echo
echo "=== 9. LB/SG reachability hint (manual, cloud-dependent) ==="
warn "Run manually: cloud firewall/SG check for EXTERNAL-IP=$EXT_IP on ports: $LISTENERS"
echo "  AWS: aws ec2 describe-security-groups --group-ids <sg-id>"
echo "  GCP: gcloud compute firewall-rules list"
echo "  Azure: az network nsg rule list --nsg-name <nsg>"

echo
echo "=== DONE ==="
