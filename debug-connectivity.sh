#!/usr/bin/env bash
# ============================================================
# Full connectivity debug: DNS -> LB/VIP -> NodePort -> Pod -> TLS
# Usage: ./debug-connectivity.sh <hostname> <vip_or_lb_ip> [nodeport] [namespace] [svc_name]
# Example: ./debug-connectivity.sh app.example.com 10.0.1.50 30443 kgateway-system https-gw
# ============================================================
set -uo pipefail

HOSTNAME="${1:?Usage: $0 <hostname> <vip_ip> [nodeport] [namespace] [svc_name]}"
VIP="${2:?VIP/LB IP required}"
NODEPORT="${3:-443}"
NAMESPACE="${4:-kgateway-system}"
SVC="${5:-}"

pass() { echo -e "\e[32m[OK]\e[0m $1"; }
fail() { echo -e "\e[31m[FAIL]\e[0m $1"; }
info() { echo -e "\e[34m[INFO]\e[0m $1"; }
sep()  { echo "----------------------------------------"; }

sep; info "1) DNS resolution (A/CNAME chain)"
dig +short "$HOSTNAME" | tee /tmp/dns_result.txt
CNAME=$(dig +short CNAME "$HOSTNAME")
[ -n "$CNAME" ] && info "CNAME -> $CNAME"
RESOLVED_IP=$(dig +short A "$HOSTNAME" | tail -n1)
if [ "$RESOLVED_IP" == "$VIP" ]; then
  pass "DNS resolves to expected VIP ($VIP)"
else
  fail "DNS resolves to $RESOLVED_IP, expected $VIP (check TTL/propagation)"
fi

sep; info "2) VIP/LB reachability (TCP)"
nc -zv -w3 "$VIP" 443 2>&1 | tee /tmp/vip_tcp.txt
nc -zv -w3 "$VIP" 80  2>&1 | tee -a /tmp/vip_tcp.txt

sep; info "3) TLS handshake + cert validity on VIP (via --resolve, real SNI)"
curl -vk --resolve "$HOSTNAME:443:$VIP" "https://$HOSTNAME" -o /dev/null -w "HTTP: %{http_code}\n" 2>&1 | tee /tmp/curl_tls.txt
echo | openssl s_client -connect "$VIP:443" -servername "$HOSTNAME" 2>/dev/null | openssl x509 -noout -dates -subject -issuer

sep; info "4) NodePort direct reachability (bypass LB)"
if command -v kubectl &>/dev/null; then
  NODES=$(kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')
  for NODE in $NODES; do
    nc -zv -w3 "$NODE" "$NODEPORT" 2>&1 | tee -a /tmp/nodeport_tcp.txt
  done
fi

sep; info "5) K8s Service / Endpoints / Gateway status"
if [ -n "$SVC" ]; then
  kubectl get svc "$SVC" -n "$NAMESPACE" -o wide
  kubectl get endpoints "$SVC" -n "$NAMESPACE"
fi
kubectl get gateway -n "$NAMESPACE" -o wide
kubectl get gateway -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}: {.status.conditions[?(@.type=="Programmed")].status}{"\n"}{end}'
kubectl get httproute -A -o wide

sep; info "6) Certificate (cert-manager) status"
kubectl get certificate -n "$NAMESPACE" 2>/dev/null
kubectl describe certificate -n "$NAMESPACE" 2>/dev/null | grep -A3 "Status:"

sep; info "7) Gateway/Envoy pod health + logs (last 20 lines)"
kubectl get pods -n "$NAMESPACE" -o wide
GW_POD=$(kubectl get pods -n "$NAMESPACE" -l gateway.networking.k8s.io/gateway-name -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -n "$GW_POD" ] && kubectl logs "$GW_POD" -n "$NAMESPACE" --tail=20

sep; info "8) In-cluster pod-to-backend test"
kubectl run debug-curl --rm -it --restart=Never --image=curlimages/curl -- \
  curl -v http://nginx:8080 2>&1 | tail -n 20

sep; info "SUMMARY"
echo "DNS resolved:      $RESOLVED_IP (expected $VIP)"
echo "VIP TCP 443:       $(grep -q succeeded /tmp/vip_tcp.txt && echo OK || echo FAIL)"
echo "TLS/cert:          see /tmp/curl_tls.txt"
echo "Full logs in /tmp/*.txt"
