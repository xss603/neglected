#!/usr/bin/env bash
# kgateway-healthcheck.sh
# Deep-check Gateway API + kgateway/Envoy xDS state
# Usage: ./kgateway-healthcheck.sh <namespace> <gateway-name> [domain] [admin-port]
#
# Optional env vars (control-plane pod usually lives in a different
# namespace/release than the Gateway's own auto-provisioned proxy pod -
# no reliable way to derive this from the Gateway object itself):
#   CONTROLLER_NS     default: kgateway-system
#   CONTROLLER_LABEL  default: app.kubernetes.io/name=kgateway
#
# Changelog vs. previous version:
#   - set -u no longer crashes mid-run (EXT_IP/LISTENERS pre-initialized)
#   - trap EXIT kills the port-forward on any exit path, not just the happy path
#   - preflight check for kubectl/jq/curl (+dig if a domain is passed)
#   - GatewayClass check added (step 0) - the #1 real-world root cause in this
#     failure class: kgateway ships no GatewayClass by default
#   - sections 7/8 filtered to routes that actually parentRef this Gateway
#   - multi-pod warning instead of silently picking items[0]
#   - per-run tmpdir (mktemp -d) instead of fixed /tmp paths
#   - port-forward readiness polled instead of a fixed sleep 2
#   - NEW 10: NodePort direct test, bypassing the LB entirely
#   - NEW 11: DNS resolution vs actual EXTERNAL-IP + curl --resolve (bypasses
#     DNS while still exercising the real Host header / SNI path)
#   - NEW 12: Envoy proxy pod log scan for known failure-signature strings
#   - NEW 13: kgateway controller pod log scan (translation/reconcile errors -
#     this is the thing that produces "Gateway looks fine, HTTPRoute looks
#     fine, but nothing actually got wired into Envoy" with zero status signal)

set -uo pipefail
NS="${1:?Usage: $0 <namespace> <gateway-name> [domain] [admin-port]}"
GW="${2:?Usage: $0 <namespace> <gateway-name> [domain] [admin-port]}"
DOMAIN="${3:-}"            # optional - enables sections 11's DNS/curl checks
ADMIN_PORT="${4:-19000}"   # kgateway default; some builds expose Envoy admin on 9901 instead
CONTROLLER_NS="${CONTROLLER_NS:-kgateway-system}"
CONTROLLER_LABEL="${CONTROLLER_LABEL:-app.kubernetes.io/name=kgateway}"

PASS="\033[32mOK\033[0m"; FAIL="\033[31mFAIL\033[0m"; WARN="\033[33mWARN\033[0m"
ok(){ echo -e "[$PASS] $1"; }
ko(){ echo -e "[$FAIL] $1"; }
warn(){ echo -e "[$WARN] $1"; }

REQUIRED_BINS=(kubectl jq curl)
[[ -n "$DOMAIN" ]] && REQUIRED_BINS+=(dig)
for bin in "${REQUIRED_BINS[@]}"; do
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
    warn "Envoy admin API not reachable on $ADMIN_PORT within 5s (try passing 9901 as \$4, or check GatewayParameters adminPort). port-forward log: $TMPDIR/pf.log"
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
echo "=== 10. NodePort direct test (bypass the LB entirely) ==="
if [[ -f "$TMPDIR/svc.json" ]]; then
  NODEPORTS=$(jq -r '.spec.ports[] | select(.nodePort != null) | "\(.port):\(.nodePort)"' "$TMPDIR/svc.json")
  if [[ -z "$NODEPORTS" ]]; then
    warn "No nodePort allocated on $GW_SVC (Service type is probably ClusterIP, or LoadBalancer without nodePorts) — skipping"
  else
    NODE_IPS=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
    if [[ -z "$NODE_IPS" ]]; then
      warn "No node InternalIP found — skipping NodePort test"
    else
      while IFS=: read -r SVC_PORT NODE_PORT; do
        for NODE_IP in $NODE_IPS; do
          echo "-- curl http://$NODE_IP:$NODE_PORT/ (svc port $SVC_PORT) --"
          CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$NODE_IP:$NODE_PORT/" 2>/dev/null)
          if [[ -n "$CODE" && "$CODE" != "000" ]]; then
            ok "NodePort $NODE_IP:$NODE_PORT answered HTTP $CODE — LB is the suspect if the external IP itself fails, not the cluster"
          else
            ko "NodePort $NODE_IP:$NODE_PORT unreachable (connection refused/timeout) — problem is inside the cluster (kube-proxy, NetworkPolicy, or Envoy not bound), not the cloud LB"
          fi
        done
      done <<< "$NODEPORTS"
    fi
  fi
else
  warn "Section 3 didn't resolve a Service — skipping NodePort test"
fi

echo
echo "=== 11. DNS vs EXTERNAL-IP, and curl --resolve (bypasses DNS, exercises real Host/SNI path) ==="
if [[ -z "$DOMAIN" ]]; then
  warn "No domain passed as \$3 — skipping. Re-run with: $0 $NS $GW <your-domain>"
else
  RESOLVED_IP=$(dig +short "$DOMAIN" | tail -n1)
  echo "DNS $DOMAIN -> $RESOLVED_IP | Service EXTERNAL-IP=$EXT_IP"
  if [[ -n "$RESOLVED_IP" && "$RESOLVED_IP" == "$EXT_IP" ]]; then
    ok "DNS matches the Gateway's current EXTERNAL-IP"
  else
    ko "DNS ($RESOLVED_IP) does NOT match EXTERNAL-IP ($EXT_IP) — stale record, wrong zone, or LB IP changed after recreation; nothing cluster-side will fix this"
  fi

  if [[ "$EXT_IP" != "unknown" && "$EXT_IP" != "pending" && -n "$EXT_IP" ]]; then
    echo "-- curl --resolve $DOMAIN -> $EXT_IP directly (HTTP) --"
    curl -v --resolve "$DOMAIN:80:$EXT_IP" "http://$DOMAIN/" --max-time 5 2>&1 | tail -n 20
    echo "-- curl --resolve $DOMAIN -> $EXT_IP directly (HTTPS, -k to ignore cert trust chain, SNI still sent) --"
    curl -vk --resolve "$DOMAIN:443:$EXT_IP" "https://$DOMAIN/" --max-time 5 2>&1 | tail -n 20
    echo "  (this hits the real EXTERNAL-IP with the real Host header/SNI, independent of DNS —"
    echo "   if this works but the plain URL doesn't, it's pure DNS; if this also fails, it's LB/Envoy)"
  else
    warn "No usable EXTERNAL-IP ($EXT_IP) — skipping curl --resolve"
  fi
fi

echo
echo "=== 12. Envoy proxy pod logs — known failure-signature scan ==="
if [[ -n "$GW_POD" ]]; then
  kubectl logs -n "$NS" "$GW_POD" --tail=500 > "$TMPDIR/envoy.log" 2>/dev/null || warn "Could not fetch logs for $GW_POD"
  if [[ -s "$TMPDIR/envoy.log" ]]; then
    declare -A ENVOY_PATTERNS=(
      ["no healthy upstream"]="all endpoints for a cluster are down/unhealthy - check section 6 /clusters health_flags"
      ["upstream connect error"]="Envoy accepted the connection but couldn't reach the backend pod - stale EDS entry or NetworkPolicy blocking Envoy->pod"
      ["no cluster"]="route points at a cluster name that doesn't exist - backendRef port/name mismatch, see section 8"
      ["failed_outlier_check"]="Envoy locally ejected a pod after prior errors, independent of k8s Ready status"
      ["rbac"]="an Envoy RBAC/authz filter is denying the request - check any SecurityPolicy/RBAC filter attached to this route"
      ["tls"]="TLS handshake/cert issue at the listener - check the referenced Secret's validity and SNI match"
      ["deny"]="request explicitly denied by a filter - check ext_authz/RBAC/WAF-type policies on this route"
    )
    FOUND_ANY=0
    for pat in "${!ENVOY_PATTERNS[@]}"; do
      HITS=$(grep -ic "$pat" "$TMPDIR/envoy.log" || true)
      if [[ "$HITS" -gt 0 ]]; then
        FOUND_ANY=1
        ko "Envoy log: '$pat' seen $HITS time(s) — ${ENVOY_PATTERNS[$pat]}"
        grep -i "$pat" "$TMPDIR/envoy.log" | tail -n 3 | sed 's/^/    /'
      fi
    done
    [[ "$FOUND_ANY" -eq 0 ]] && ok "No known failure signatures in last 500 lines of Envoy proxy pod logs"
  else
    warn "Envoy proxy pod log is empty or unreadable"
  fi
else
  warn "No Gateway pod resolved — skipping Envoy log scan"
fi

echo
echo "=== 13. kgateway controller pod logs — translation/reconcile error scan ==="
echo "(control plane is a separate component from the Envoy data-plane pod above -"
echo " a silent RBAC/watch failure here produces a Gateway/HTTPRoute that both look"
echo " Accepted/ResolvedRefs=True in status, with nothing actually wired into Envoy)"
CTRL_POD=$(kubectl get pods -n "$CONTROLLER_NS" -l "$CONTROLLER_LABEL" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$CTRL_POD" ]]; then
  warn "No controller pod found in ns=$CONTROLLER_NS label=$CONTROLLER_LABEL — override with \$CONTROLLER_NS/\$CONTROLLER_LABEL env vars if kgateway is installed elsewhere"
else
  ok "Controller pod: $CTRL_POD (ns=$CONTROLLER_NS)"
  kubectl logs -n "$CONTROLLER_NS" "$CTRL_POD" --tail=500 > "$TMPDIR/controller.log" 2>/dev/null || warn "Could not fetch logs for $CTRL_POD"
  if [[ -s "$TMPDIR/controller.log" ]]; then
    declare -A CTRL_PATTERNS=(
      ["error"]="generic reconcile error - read the surrounding lines for which object it's about"
      ["forbidden"]="RBAC denial watching/reading a resource (commonly EndpointSlice/Service/Secret in another namespace) - controller silently stops translating that object with zero status signal on the Gateway/HTTPRoute itself"
      ["failed to"]="a specific translation/reconcile step failed"
      ["reject"]="a resource was rejected during translation"
      ["panic"]="controller crashed while processing an object - check for a restart/crashloop"
    )
    FOUND_ANY=0
    for pat in "${!CTRL_PATTERNS[@]}"; do
      HITS=$(grep -ic "$pat" "$TMPDIR/controller.log" || true)
      if [[ "$HITS" -gt 0 ]]; then
        FOUND_ANY=1
        ko "Controller log: '$pat' seen $HITS time(s) — ${CTRL_PATTERNS[$pat]}"
        grep -i "$pat" "$TMPDIR/controller.log" | tail -n 3 | sed 's/^/    /'
      fi
    done
    [[ "$FOUND_ANY" -eq 0 ]] && ok "No known failure signatures in last 500 lines of controller logs"
  else
    warn "Controller pod log is empty or unreadable"
  fi
fi

echo
echo "=== DONE ==="
