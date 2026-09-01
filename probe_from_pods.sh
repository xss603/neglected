#!/usr/bin/env bash
#
# probe_from_pods.sh - list Services/ports per namespace, and optionally
# probe them from pods that are ALREADY RUNNING. Nothing is created.
#
# Two modes:
#   (default)  inventory - every Service and port, per namespace
#   --probe    exec into an existing pod in each source namespace and
#              connect to each target Service
#
# Why exec instead of a probe pod: Illumio policy is per workload, so the
# source identity matters. A curl from the node is the NODE talking to the
# service, which is a different rule than "namespace A talks to namespace
# B". Only a pod already in namespace A tests the path you want to map.
#
# Existing pods are whatever image they happen to be, so the tool used is
# whatever the container has - curl, then wget, then nc, then bash's
# /dev/tcp. Containers with none of those (distroless, scratch) are
# reported as unusable rather than silently skipped.
#
# Results:
#   open      TCP handshake completed (regardless of what came back after)
#   refused   RST - routed fine, nothing listening. NOT a block.
#   filtered  silence until timeout - packet dropped. An Illumio deny and
#             a NetworkPolicy deny look IDENTICAL here; attribute it from
#             the PCE flow record or `kubectl get netpol`, not from this.
#   dns_fail  name did not resolve - CoreDNS or wrong FQDN, not policy.
#
# Remember that in Illumio Visibility Only mode nothing is ever dropped,
# so everything returns open and the run only produces flow records.
#
set -euo pipefail

TO=""
FROM=""
PROBE=0
SUMMARY=0
TIMEOUT=3
MAX_CANDIDATES="${MAX_CANDIDATES:-25}"
DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
OUTPUT="table"

usage() {
  cat <<EOF
Usage: ${0##*/} [--probe --from <ns>[,<ns>...]] [--to <ns>[,<ns>...]] [options]

Options:
      --to <ns,...>     namespaces to inventory / probe TOWARDS (default: all)
      --probe           actually connect, from existing pods
      --summary         one verdict line per namespace pair (implies --probe)
      --from <ns,...>   source namespaces to probe FROM (default: same as --to)
  -t, --timeout <sec>   per-connection timeout          (default: ${TIMEOUT})
      --max-candidates <n>  containers to try per namespace when hunting
                        for a usable tool           (default: ${MAX_CANDIDATES})
  -d, --domain <d>      cluster DNS domain              (default: ${DOMAIN})
  -o, --output <fmt>    table | csv                     (default: table)
  -h, --help            show this help

Examples:
  ${0##*/}                                  # inventory of every ns
  ${0##*/} --to vault,argocd -o csv         # just those two, as CSV
  ${0##*/} --probe --from argocd --to vault # argocd's pods -> vault's svcs
  ${0##*/} --summary --from ns1 --to ns2    # just: connectable or not
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)         TO="${2:?--to needs a value}"; shift 2 ;;
    --from)       FROM="${2:?--from needs a value}"; shift 2 ;;
    --probe)      PROBE=1; shift ;;
    --summary)    PROBE=1; SUMMARY=1; shift ;;
    -t|--timeout) TIMEOUT="${2:?--timeout needs a value}"; shift 2 ;;
    --max-candidates) MAX_CANDIDATES="${2:?--max-candidates needs a value}"; shift 2 ;;
    -d|--domain)  DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
    -o|--output)  OUTPUT="${2:?--output needs a value}"; shift 2 ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in table|csv) ;; *) echo "invalid --output '$OUTPUT'" >&2; exit 2 ;; esac
command -v kubectl >/dev/null 2>&1 || { echo "required binary not found: kubectl" >&2; exit 1; }

render() {
  if [[ "$OUTPUT" == "table" ]] && command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
}
row() { if [[ "$OUTPUT" == "csv" ]]; then (IFS=,; echo "$*"); else (IFS=$'\t'; echo "$*"); fi; }

ns_list() {
  local spec="$1"
  if [[ -z "$spec" || "$spec" == "all" ]]; then
    kubectl get namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'
  else
    tr ',' '\n' <<<"$spec"
  fi
}

# --- Service/port inventory -------------------------------------------
# Emits: ns <TAB> svc <TAB> type <TAB> clusterIP <TAB> port <TAB> proto <TAB> fqdn
# ExternalName has nothing to connect to; UDP ports cannot be probed with
# an HTTP client, but they are listed so the inventory stays complete.
services_in() {
  local ns="$1"
  kubectl get services -n "$ns" -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.type}{"\t"}{.spec.clusterIP}{"\t"}{range .spec.ports[*]}{.port}{"/"}{.protocol}{" "}{end}{"\n"}{end}' 2>/dev/null \
    | while IFS=$'\t' read -r svc type cip ports; do
        [[ -n "$svc" ]] || continue
        [[ "$type" == "ExternalName" ]] && continue
        for pp in $ports; do
          printf '%s\t%s\t%s\t%s\t%s\t%s\t%s.%s.svc.%s\n' \
            "$ns" "$svc" "${type:-ClusterIP}" "${cip:--}" \
            "${pp%%/*}" "${pp##*/}" "$svc" "$ns" "$DOMAIN"
        done
      done
}

if [[ $PROBE -eq 0 ]]; then
  { row NAMESPACE SERVICE TYPE CLUSTER_IP PORT PROTOCOL FQDN
    while read -r ns; do
      [[ -n "$ns" ]] || continue
      while IFS=$'\t' read -r a b c d e f g; do
        row "$a" "$b" "$c" "$d" "$e" "$f" "$g"
      done < <(services_in "$ns")
    done < <(ns_list "$TO")
  } | render
  exit 0
fi

# ====================== probe mode ====================================
[[ -n "$FROM" ]] || FROM="$TO"

# Every Running pod in the namespace, and every container in each - all
# containers of a pod share one network namespace, so any of them is an
# equally valid vantage point for a connectivity test.
candidates() {
  local ns="$1"
  # Emitted as "pod<TAB>container", one line per container.
  kubectl get pods -n "$ns" \
    --field-selector=status.phase=Running \
    -o go-template='{{range .items}}{{$pod := .metadata.name}}{{range .spec.containers}}{{$pod}}{{"\t"}}{{.name}}{{"\n"}}{{end}}{{end}}' 2>/dev/null
}

# Walk the namespace until a container with a usable tool turns up.
#
# A pod without curl/wget/nc/bash is common (distroless, scratch,
# purpose-built images) and so is a pod that refuses exec entirely, so
# giving up on the first one would silently drop whole namespaces from
# the map. Scanning continues past a usable-but-weak tool in the hope of
# finding curl, which is the only one that separates an open non-HTTP
# port from a dropped packet; anything else falls back to timing.
#
# Echoes "pod<TAB>container<TAB>tool", or nothing if the namespace has no
# usable vantage point at all.
select_source() {
  local ns="$1" checked=0
  local best_pod="" best_ctr="" best_tool=""
  local pod ctr tool

  while IFS=$'\t' read -r pod ctr; do
    [[ -n "$pod" && -n "$ctr" ]] || continue
    (( checked >= MAX_CANDIDATES )) && break
    checked=$(( checked + 1 ))

    tool="$(detect_tool "$ns" "$pod" "$ctr")"
    case "$tool" in
      curl)
        printf '%s\t%s\t%s\n' "$pod" "$ctr" "$tool"   # best available, stop
        return 0 ;;
      wget|nc|devtcp)
        if [[ -z "$best_tool" ]]; then
          best_pod="$pod"; best_ctr="$ctr"; best_tool="$tool"
        fi ;;
      *) : ;;   # none / noexec - keep looking
    esac
  done < <(candidates "$ns")

  if [[ -n "$best_tool" ]]; then
    echo "no curl found in $ns after $checked container(s); using $best_tool in $best_pod" >&2
    printf '%s\t%s\t%s\n' "$best_pod" "$best_ctr" "$best_tool"
    return 0
  fi
  return 1
}

# Which connect tool does this container actually have?
detect_tool() {
  local ns="$1" pod="$2" ctr="$3"
  kubectl exec -n "$ns" "$pod" -c "$ctr" -- sh -c '
    if command -v curl >/dev/null 2>&1; then echo curl
    elif command -v wget >/dev/null 2>&1; then echo wget
    elif command -v nc   >/dev/null 2>&1; then echo nc
    elif [ -n "$BASH_VERSION" ] || command -v bash >/dev/null 2>&1; then echo devtcp
    else echo none; fi' 2>/dev/null || echo noexec
}

# One connection attempt, classified. Runs inside the borrowed pod.
#
# curl is preferred because %{time_connect} is non-zero as soon as the TCP
# handshake lands, which distinguishes "port open but not HTTP" (exit 28
# WITH a connect time) from "packet dropped" (exit 28, no connect time).
probe_curl() {
  local ns="$1" pod="$2" ctr="$3" host="$4" port="$5"
  kubectl exec -n "$ns" "$pod" -c "$ctr" -- sh -c "
    tc=\$(curl -sS --noproxy '*' -o /dev/null -m $TIMEOUT \
           -w '%{time_connect}' 'http://$host:$port' 2>/dev/null); rc=\$?
    case \"\$rc\" in
      6) echo dns_fail ;;
      7) echo refused ;;
      *) case \"\${tc:-0.000000}\" in
           0.000000|0|'') [ \"\$rc\" = 28 ] && echo filtered || echo error_\$rc ;;
           *) echo open ;;
         esac ;;
    esac" 2>/dev/null || echo exec_fail
}

probe_other() {
  local ns="$1" pod="$2" ctr="$3" host="$4" port="$5" tool="$6"
  # Coarser: these tools cannot separate a slow-but-open port from a drop,
  # so the elapsed time decides, same heuristic as a raw TCP probe.
  kubectl exec -n "$ns" "$pod" -c "$ctr" -- sh -c "
    start=\$(date +%s)
    case '$tool' in
      wget)   wget -q -T $TIMEOUT -O /dev/null 'http://$host:$port' 2>/dev/null ;;
      nc)     nc -z -w $TIMEOUT '$host' '$port' >/dev/null 2>&1 ;;
      devtcp) timeout $TIMEOUT bash -c 'exec 3<>/dev/tcp/$host/$port' 2>/dev/null ;;
    esac
    rc=\$?
    el=\$(( \$(date +%s) - start ))
    if [ \$rc -eq 0 ]; then echo open
    elif [ \$el -ge $TIMEOUT ]; then echo filtered
    else echo refused; fi" 2>/dev/null || echo exec_fail
}

# Emits raw TSV rows; the callers below format them.
probe_rows() {
  local src pod ctr tool dst svc port proto fqdn res
  while read -r src; do
    [[ -n "$src" ]] || continue

    if ! read -r pod ctr tool < <(select_source "$src"); then
      echo "namespace $src: no Running pod with curl/wget/nc/bash (checked up to $MAX_CANDIDATES containers) - cannot probe FROM it" >&2
      continue
    fi

    while read -r dst; do
      [[ -n "$dst" ]] || continue
      while IFS=$'\t' read -r _ns svc _type _cip port proto fqdn; do
        [[ "$proto" == "TCP" ]] || continue      # curl/nc here are TCP only
        if [[ "$tool" == "curl" ]]; then
          res="$(probe_curl "$src" "$pod" "$ctr" "$fqdn" "$port")"
        else
          res="$(probe_other "$src" "$pod" "$ctr" "$fqdn" "$port" "$tool")"
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$src" "$pod" "$ctr" "$tool" "$dst" "$svc" "$fqdn" "$port" "$res"
      done < <(services_in "$dst")
    done < <(ns_list "$TO")
  done < <(ns_list "$FROM")
}

# Collapse per-port results into one verdict per namespace pair.
#
# The key judgement: "refused" means the packet REACHED a host that sent
# back an RST, so the network path is permitted - there is just nothing
# listening on that port. For connectivity mapping that counts as open.
# Only "filtered" (silence) is evidence of a block.
#
#   YES       nothing filtered, and at least one port answered
#   NO        every port filtered
#   PARTIAL   some ports allowed, some filtered - policy is port-specific
#   UNKNOWN   only DNS failures or errors; nothing was actually tested
summarize() {
  awk -F'\t' '
    { pair = $1 " -> " $5
      if (!(pair in seen)) { seen[pair] = 1; order[++n] = pair }
      total[pair]++
      c[pair "|" $9]++
    }
    END {
      for (i = 1; i <= n; i++) {
        p = order[i]
        o = c[p "|open"]; r = c[p "|refused"]
        f = c[p "|filtered"]; d = c[p "|dns_fail"]
        reachable = o + r
        if (reachable > 0 && f == 0)      v = "YES"
        else if (f > 0 && reachable == 0) v = "NO"
        else if (f > 0 && reachable > 0)  v = "PARTIAL"
        else                              v = "UNKNOWN"
        detail = "open=" o+0 " refused=" r+0 " filtered=" f+0 " dns_fail=" d+0
        print p "\t" v "\t" reachable "/" total[p] "\t" detail
      }
    }'
}

if [[ $SUMMARY -eq 1 ]]; then
  { row PAIR CONNECTABLE REACHABLE_PORTS DETAIL
    probe_rows | summarize \
      | while IFS=$'\t' read -r pair verdict ratio detail; do
          row "$pair" "$verdict" "$ratio" "$detail"
        done
  } | render
else
  { row SRC_NS SRC_POD SRC_CTR TOOL DST_NS DST_SVC FQDN PORT RESULT
    probe_rows | while IFS=$'\t' read -r a b cc d e f g h i; do
      row "$a" "$b" "$cc" "$d" "$e" "$f" "$g" "$h" "$i"
    done
  } | render
fi
