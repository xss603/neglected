#!/usr/bin/env bash
#
# probe_ns_connectivity.sh - active TCP reachability matrix between
# namespaces, emitted as CSV so it can be joined with Illumio labels.
#
# For each source namespace it starts ONE short-lived probe pod (this box
# is a single 8GB node - see CLAUDE.md) and runs every target through it,
# then deletes the pod. Targets are the Services of the destination
# namespaces, because a Service FQDN is what real cross-namespace traffic
# uses; per-pod names are unstable (see pod_fqdns.sh).
#
# Each result is classified by HOW the connection failed, which is what
# separates a policy drop from an application problem:
#
#   open      TCP handshake completed.
#   refused   RST came back fast - something routed us to a host with no
#             listener on that port. NOT a firewall block.
#   filtered  No answer at all until timeout - the packet was silently
#             dropped. This is what an Illumio deny and a Kubernetes
#             NetworkPolicy deny both look like; they are NOT
#             distinguishable from inside the pod. Confirm which one in
#             the PCE flow record / `kubectl get netpol`.
#   dns_fail  Name did not resolve - CoreDNS or a wrong FQDN, not policy.
#
# IMPORTANT: what "open" proves depends on the Illumio enforcement mode of
# the workloads involved. In Visibility Only mode nothing is ever dropped,
# so every probe returns open and the run tells you nothing about policy -
# it only generates flow records. Check the mode in the PCE first.
#
# Requires: kubectl (with exec rights), and an image with nc + getent.
#
set -euo pipefail

FROM=""
TO=""
TIMEOUT=3
IMAGE="${PROBE_IMAGE:-nicolaka/netshoot:latest}"
DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
KEEP=0

usage() {
  cat <<EOF
Usage: ${0##*/} --from <ns>[,<ns>...] [--to <ns>[,<ns>...]|all] [options]

Options:
      --from <ns,...>   source namespace(s) to probe FROM   (required)
      --to <ns,...>     destination namespace(s), or "all"  (default: all)
  -t, --timeout <sec>   per-connection timeout             (default: ${TIMEOUT})
  -i, --image <img>     probe image                        (default: ${IMAGE})
  -d, --domain <d>      cluster DNS domain                 (default: ${DOMAIN})
      --keep            do not delete the probe pod (for manual poking)
  -h, --help            show this help

Output: CSV on stdout -
  src_ns,dst_ns,dst_svc,fqdn,port,result,elapsed_ms

Examples:
  ${0##*/} --from argocd --to vault
  ${0##*/} --from argocd,signoz --to all > flows.csv
  ${0##*/} --from argocd --to vault --keep    # then kubectl exec in yourself
EOF
}

while [[ \$# -gt 0 ]]; do
  case "\$1" in
    --from)        FROM="\${2:?--from needs a value}"; shift 2 ;;
    --to)          TO="\${2:?--to needs a value}"; shift 2 ;;
    -t|--timeout)  TIMEOUT="\${2:?--timeout needs a value}"; shift 2 ;;
    -i|--image)    IMAGE="\${2:?--image needs a value}"; shift 2 ;;
    -d|--domain)   DOMAIN="\${2:?--domain needs a value}"; shift 2 ;;
    --keep)        KEEP=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) echo "unknown option: \$1" >&2; usage >&2; exit 2 ;;
  esac
done

[[ -n "\$FROM" ]] || { echo "--from is required" >&2; usage >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "required binary not found: kubectl" >&2; exit 1; }

# --- build the target list: every ClusterIP/headless Service port -------
targets_for() {
  local ns="\$1"
  kubectl get services -n "\$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.type}{"\t"}{range .spec.ports[*]}{.port}{" "}{end}{"\n"}{end}' \
    | while IFS=\$'\t' read -r svc type ports; do
        [[ "\$type" == "ExternalName" ]] && continue   # nothing to connect to
        for p in \$ports; do
          printf '%s\t%s.%s.svc.%s\t%s\n' "\$svc" "\$svc" "\$ns" "\$DOMAIN" "\$p"
        done
      done
}

if [[ -z "\$TO" || "\$TO" == "all" ]]; then
  mapfile -t DST_NS < <(kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
else
  IFS=, read -r -a DST_NS <<<"\$TO"
fi
IFS=, read -r -a SRC_NS <<<"\$FROM"

# --- the probe, as run inside the pod -----------------------------------
# reads "dst_ns<TAB>svc<TAB>fqdn<TAB>port" lines, writes them back with a
# result and an elapsed time appended.
read -r -d '' PROBE_SH <<'INNER' || true
T="$1"
# The pod's /bin/sh may be dash or ash, where IFS=$'\t' is not a tab at
# all and every line would silently fail to split. Build a real one.
TAB=$(printf '\t')

# Only meaningful for names: getent on a bare IP does a REVERSE lookup,
# which fails for any address without a PTR and would look like a DNS
# problem when it is really a dropped packet.
resolves() {
  case "$1" in
    *[!0-9.]*) getent hosts "$1" >/dev/null 2>&1 ;;
    *)         return 0 ;;
  esac
}

while IFS="$TAB" read -r dns svc fqdn port; do
  [ -n "$fqdn" ] || continue
  start=$(date +%s%N)
  if nc -z -w"$T" "$fqdn" "$port" >/dev/null 2>&1; then
    res=open
  else
    res=pending
  fi
  ms=$(( ($(date +%s%N) - start) / 1000000 ))
  if [ "$res" = pending ]; then
    if ! resolves "$fqdn"; then
      res=dns_fail
    elif [ "$ms" -ge $(( T * 800 )) ]; then
      # Nothing came back before the timeout: the packet was dropped in
      # silence. Illumio deny and NetworkPolicy deny both land here.
      res=filtered
    else
      # An immediate RST - routed fine, nothing listening. Not a block.
      res=refused
    fi
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$dns" "$svc" "$fqdn" "$port" "$res" "$ms"
done
INNER

echo "src_ns,dst_ns,dst_svc,fqdn,port,result,elapsed_ms"

for src in "\${SRC_NS[@]}"; do
  # Collect this source's whole target list first, so one pod covers it all.
  targets="\$(for dst in "\${DST_NS[@]}"; do
      targets_for "\$dst" | while IFS=\$'\t' read -r svc fqdn port; do
        printf '%s\t%s\t%s\t%s\n' "\$dst" "\$svc" "\$fqdn" "\$port"
      done
    done)"

  if [[ -z "\$targets" ]]; then
    echo "no target services found for source \$src" >&2
    continue
  fi

  pod="netprobe-\$RANDOM"
  cleanup() { [[ \$KEEP -eq 1 ]] || kubectl delete pod "\$pod" -n "\$src" --wait=false >/dev/null 2>&1 || true; }
  trap cleanup EXIT

  kubectl run "\$pod" -n "\$src" --image="\$IMAGE" --restart=Never \
    --command -- sleep 900 >/dev/null
  kubectl wait --for=condition=Ready pod/"\$pod" -n "\$src" --timeout=120s >/dev/null

  printf '%s\n' "\$targets" \
    | kubectl exec -i "\$pod" -n "\$src" -- sh -c "\$PROBE_SH" _ "\$TIMEOUT" \
    | while IFS=\$'\t' read -r dns svc fqdn port res ms; do
        printf '%s,%s,%s,%s,%s,%s,%s\n' "\$src" "\$dns" "\$svc" "\$fqdn" "\$port" "\$res" "\$ms"
      done

  cleanup
  trap - EXIT
done
