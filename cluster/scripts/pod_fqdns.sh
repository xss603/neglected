#!/usr/bin/env bash
#
# pod_fqdns.sh - list the DNS names of every pod (and the services that
# front them) so cross-namespace connectivity can be tested by name.
#
# Kubernetes gives a pod up to two kinds of DNS name:
#
#   1. The pod-network A record, which every pod gets:
#        <pod-ip-with-dashes>.<namespace>.pod.cluster.local
#      This only resolves when CoreDNS runs with the "pods insecure" (or
#      "verified") option - it is the k3s default. It changes on every
#      pod restart, so it is fine for a one-off probe and useless in
#      config.
#
#   2. A stable per-pod name, only for pods that set spec.subdomain and
#      have a matching headless Service:
#        <hostname>.<subdomain>.<namespace>.svc.cluster.local
#      The StatefulSet controller sets both fields automatically, so
#      StatefulSet pods always have one.
#
# Ordinary Deployment pods have no stable name of their own - test them
# through their Service (--services), which is what real traffic uses.
#
# Input: `kubectl get pods -A -o json` on stdin, or the script calls
# kubectl itself when stdin is a terminal.
#
# Requires: jq (and kubectl, unless JSON is piped in).
#
set -euo pipefail

CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-cluster.local}"
OUTPUT="table"      # table | csv
WHAT="pods"         # pods | services | all
READY_ONLY=0

usage() {
  cat <<EOF
Usage: ${0##*/} [options] [< pods.json]

Options:
  -s, --services      list Service FQDNs and ports instead of pods
  -a, --all           list both pods and services
  -r, --ready-only    skip pods that are not Running with an IP
  -o, --output <fmt>  table | csv                    (default: table)
  -d, --domain <d>    cluster DNS domain             (default: ${CLUSTER_DOMAIN})
  -h, --help          show this help

Examples:
  kubectl get pods -A -o json | ${0##*/}
  kubectl get pods -A -o json | ${0##*/} -r -o csv > pod-fqdns.csv
  ${0##*/} --all                       # calls kubectl itself
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--services)   WHAT="services"; shift ;;
    -a|--all)        WHAT="all"; shift ;;
    -r|--ready-only) READY_ONLY=1; shift ;;
    -o|--output)     OUTPUT="${2:?--output needs a value}"; shift 2 ;;
    -d|--domain)     CLUSTER_DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$OUTPUT" in
  table|csv) ;;
  *) echo "invalid --output '$OUTPUT' (want: table|csv)" >&2; exit 2 ;;
esac

command -v jq >/dev/null 2>&1 || { echo "required binary not found: jq" >&2; exit 1; }

render() {
  if [[ "$OUTPUT" == "table" ]] && command -v column >/dev/null 2>&1; then
    column -t -s $'\t'
  else
    cat
  fi
}

sep() { [[ "$OUTPUT" == "csv" ]] && printf 'csv' || printf 'tsv'; }
hdr() {
  if [[ "$OUTPUT" == "csv" ]]; then (IFS=,;  echo "$*"); else (IFS=$'\t'; echo "$*"); fi
}

# Pods JSON: stdin when piped, otherwise ask the cluster.
pods_json() {
  if [[ -t 0 ]]; then kubectl get pods --all-namespaces -o json; else cat; fi
}

emit_pods() {
  local ready_filter="."
  [[ $READY_ONLY -eq 1 ]] && ready_filter='select(.status.phase == "Running" and (.status.podIP // "") != "")'

  hdr NAMESPACE POD POD_IP POD_FQDN STABLE_FQDN
  jq -r --arg d "$CLUSTER_DOMAIN" --arg sep "$(sep)" "
    .items[]
    | ${ready_filter}
    | . as \$p
    | (\$p.status.podIP // \"\") as \$ip
    | (\$ip | gsub(\"[.:]\"; \"-\")) as \$dashed
    | (\$p.metadata.namespace) as \$ns
    | (if \$ip == \"\" then \"-\" else \"\(\$dashed).\(\$ns).pod.\(\$d)\" end) as \$podfqdn
    | (\$p.spec.subdomain // \"\") as \$sub
    | ((\$p.spec.hostname // \$p.metadata.name)) as \$host
    | (if \$sub == \"\" then \"-\" else \"\(\$host).\(\$sub).\(\$ns).svc.\(\$d)\" end) as \$stable
    | [\$ns, \$p.metadata.name, (if \$ip == \"\" then \"-\" else \$ip end), \$podfqdn, \$stable]
    | if \$sep == \"csv\" then @csv else @tsv end
  " <<<"$(pods_json)"
}

emit_services() {
  hdr NAMESPACE SERVICE TYPE CLUSTER_IP SERVICE_FQDN PORTS
  kubectl get services --all-namespaces -o json \
    | jq -r --arg d "$CLUSTER_DOMAIN" --arg sep "$(sep)" '
      .items[]
      | . as $s
      | ($s.metadata.namespace) as $ns
      | ($s.spec.clusterIP // "-") as $cip
      | [ $ns,
          $s.metadata.name,
          ($s.spec.type // "ClusterIP"),
          (if $cip == "None" then "headless" else $cip end),
          "\($s.metadata.name).\($ns).svc.\($d)",
          ([($s.spec.ports // [])[] | "\(.port)/\(.protocol // "TCP")"] | join(",") | if . == "" then "-" else . end)
        ]
      | if $sep == "csv" then @csv else @tsv end
    '
}

case "$WHAT" in
  pods)     emit_pods | render ;;
  services) emit_services | render ;;
  all)
    { echo "== PODS =="; emit_pods; echo; echo "== SERVICES =="; emit_services; } | render
    ;;
esac
