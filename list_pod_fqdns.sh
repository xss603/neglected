#!/usr/bin/env bash
# List the DNS name of every pod, plus the service FQDNs that
# cross-namespace traffic actually uses. No jq needed.
set -euo pipefail

DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"

echo "== POD FQDNs =="
kubectl get pods --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{.status.podIP}{"\t"}{.spec.hostname}{"\t"}{.spec.subdomain}{"\n"}{end}' |
while IFS=$'\t' read -r ns pod ip host sub; do
  [ -n "$ip" ] || continue                       # not scheduled yet
  # Every pod: <pod-ip-dashed>.<ns>.pod.<domain>  (changes on restart)
  echo "$ns/$pod	${ip//./-}.$ns.pod.$DOMAIN"
  # StatefulSet / subdomain pods also get a stable name
  [ -n "$sub" ] && echo "$ns/$pod	${host:-$pod}.$sub.$ns.svc.$DOMAIN"
done

echo
echo "== SERVICE FQDNs (use these for real tests) =="
kubectl get services --all-namespaces -o jsonpath='{range .items[*]}{.metadata.namespace}{"\t"}{.metadata.name}{"\t"}{range .spec.ports[*]}{.port}{","}{end}{"\n"}{end}' |
while IFS=$'\t' read -r ns svc ports; do
  echo "$ns/$svc	$svc.$ns.svc.$DOMAIN	ports=${ports%,}"
done
