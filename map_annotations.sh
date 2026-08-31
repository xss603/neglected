#!/usr/bin/env bash
#
# illumio-labels.sh - extract Illumio-related annotations from
# Kubernetes namespaces and services.
#
# Namespaces are read for the namespaceoperator annotations:
#   namespaceoperator.<ORG>/applicative_tier
#   namespaceoperator.<ORG>/code_app
#   namespaceoperator.<ORG>/environment
#   namespaceoperator.<ORG>/middleware
#
# Services are read for the anp keys:
#   anp/appcode
#   anp/business-unit
#   anp/tier-app
#   anp/vipclass
#
# Only .metadata.annotations is read. Labels with the same keys are
# deliberately ignored.
#
# Requires: kubectl, jq.
#
set -euo pipefail

# --- configuration -----------------------------------------------------
# The namespace-annotation prefix is tenant-specific. Override with
# --ns-prefix or the ILLUMIO_NS_PREFIX environment variable.
NS_PREFIX="${ILLUMIO_NS_PREFIX:-namespaceoperator.ap24182}"
SVC_PREFIX="${ILLUMIO_SVC_PREFIX:-anp}"

NS_KEYS=(applicative_tier code_app environment middleware)
SVC_KEYS=(appcode business-unit tier-app vipclass)

MISSING_PLACEHOLDER="-"

# --- defaults ----------------------------------------------------------
TARGET="all"          # all | namespaces | services
NAMESPACE=""          # empty == all namespaces
OUTPUT="table"        # table | csv | json
MISSING_ONLY=0

usage() {
  cat <<EOF
Usage: ${0##*/} [options]

Options:
  -t, --target <what>     namespaces | services | all      (default: all)
  -n, --namespace <ns>    limit to one namespace           (default: all namespaces)
  -o, --output <fmt>      table | csv | json               (default: table)
  -m, --missing-only      only rows where at least one key is absent
      --ns-prefix <p>     namespace annotation prefix      (default: ${NS_PREFIX})
      --svc-prefix <p>    service annotation prefix        (default: ${SVC_PREFIX})
  -h, --help              show this help

Examples:
  ${0##*/}                                   # everything, as a table
  ${0##*/} -t namespaces -o csv > ns.csv     # namespace annotations to CSV
  ${0##*/} -t services -n my-app             # services in one namespace
  ${0##*/} -m                                # audit: what is not labelled yet
  ${0##*/} -o json | jq '.namespaces'        # machine-readable
EOF
}

# --- argument parsing --------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--target)      TARGET="${2:?--target needs a value}"; shift 2 ;;
    -n|--namespace)   NAMESPACE="${2:?--namespace needs a value}"; shift 2 ;;
    -o|--output)      OUTPUT="${2:?--output needs a value}"; shift 2 ;;
    -m|--missing-only) MISSING_ONLY=1; shift ;;
    --ns-prefix)      NS_PREFIX="${2:?--ns-prefix needs a value}"; shift 2 ;;
    --svc-prefix)     SVC_PREFIX="${2:?--svc-prefix needs a value}"; shift 2 ;;
    -h|--help)        usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

case "$TARGET" in
  all|namespaces|services) ;;
  *) echo "invalid --target '$TARGET' (want: all|namespaces|services)" >&2; exit 2 ;;
esac
case "$OUTPUT" in
  table|csv|json) ;;
  *) echo "invalid --output '$OUTPUT' (want: table|csv|json)" >&2; exit 2 ;;
esac

for bin in kubectl jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "required binary not found: $bin" >&2; exit 1; }
done

# --- helpers -----------------------------------------------------------

# Build a comma-separated list of jq value expressions, one per key,
# read from .metadata.annotations only.
jq_value_exprs() {
  local prefix="$1"; shift
  local out="" k
  for k in "$@"; do
    out+="(.metadata.annotations[\"${prefix}/${k}\"] // \"${MISSING_PLACEHOLDER}\"),"
  done
  printf '%s' "${out%,}"
}

# Build a jq object mapping bare key name -> value, for JSON output.
jq_object_expr() {
  local prefix="$1"; shift
  local out="" k
  for k in "$@"; do
    out+="\"${k}\": (.metadata.annotations[\"${prefix}/${k}\"] // null),"
  done
  printf '{%s}' "${out%,}"
}

# jq boolean: true when at least one of the keys is absent.
jq_missing_expr() {
  local prefix="$1"; shift
  local out="" k
  for k in "$@"; do
    out+="(.metadata.annotations[\"${prefix}/${k}\"]) == null or "
  done
  printf '(%s)' "${out%or }"
}

kubectl_get() {
  local kind="$1"
  if [[ -n "$NAMESPACE" ]]; then
    kubectl get "$kind" -n "$NAMESPACE" -o json
  else
    kubectl get "$kind" --all-namespaces -o json
  fi
}

render_table() { column -t -s $'\t'; }
render_csv()   { cat; }

# --- namespaces --------------------------------------------------------
emit_namespaces_rows() {
  local sep="$1"     # tsv | csv
  local filter="."
  [[ $MISSING_ONLY -eq 1 ]] && filter="select($(jq_missing_expr "$NS_PREFIX" "${NS_KEYS[@]}"))"

  # A single namespace is fetched with `kubectl get ns <name>` semantics via
  # the same all-namespaces call; namespaces are cluster-scoped so -n is
  # meaningless and we filter by name instead.
  local ns_json
  ns_json="$(kubectl get namespaces -o json)"
  if [[ -n "$NAMESPACE" ]]; then
    ns_json="$(jq --arg n "$NAMESPACE" '.items |= map(select(.metadata.name == $n))' <<<"$ns_json")"
  fi

  jq -r ".items[] | ${filter} | [.metadata.name, $(jq_value_exprs "$NS_PREFIX" "${NS_KEYS[@]}")] | @${sep}" <<<"$ns_json"
}

emit_namespaces() {
  local header_cols=(NAMESPACE)
  local k
  for k in "${NS_KEYS[@]}"; do header_cols+=("$(tr '[:lower:]' '[:upper:]' <<<"$k")"); done

  case "$OUTPUT" in
    table)
      { printf '%s\n' "$(IFS=$'\t'; echo "${header_cols[*]}")"
        emit_namespaces_rows tsv; } | render_table
      ;;
    csv)
      { printf '%s\n' "$(IFS=,; echo "${header_cols[*]}")"
        emit_namespaces_rows csv; } | render_csv
      ;;
  esac
}

emit_namespaces_json() {
  local filter="."
  [[ $MISSING_ONLY -eq 1 ]] && filter="select($(jq_missing_expr "$NS_PREFIX" "${NS_KEYS[@]}"))"

  local ns_json
  ns_json="$(kubectl get namespaces -o json)"
  if [[ -n "$NAMESPACE" ]]; then
    ns_json="$(jq --arg n "$NAMESPACE" '.items |= map(select(.metadata.name == $n))' <<<"$ns_json")"
  fi

  jq "[.items[] | ${filter} | {name: .metadata.name, annotations: $(jq_object_expr "$NS_PREFIX" "${NS_KEYS[@]}")}]" <<<"$ns_json"
}

# --- services ----------------------------------------------------------
emit_services_rows() {
  local sep="$1"
  local filter="."
  [[ $MISSING_ONLY -eq 1 ]] && filter="select($(jq_missing_expr "$SVC_PREFIX" "${SVC_KEYS[@]}"))"

  kubectl_get services \
    | jq -r ".items[] | ${filter} | [.metadata.namespace, .metadata.name, $(jq_value_exprs "$SVC_PREFIX" "${SVC_KEYS[@]}")] | @${sep}"
}

emit_services() {
  local header_cols=(NAMESPACE SERVICE)
  local k
  for k in "${SVC_KEYS[@]}"; do header_cols+=("$(tr '[:lower:]-' '[:upper:]_' <<<"$k")"); done

  case "$OUTPUT" in
    table)
      { printf '%s\n' "$(IFS=$'\t'; echo "${header_cols[*]}")"
        emit_services_rows tsv; } | render_table
      ;;
    csv)
      { printf '%s\n' "$(IFS=,; echo "${header_cols[*]}")"
        emit_services_rows csv; } | render_csv
      ;;
  esac
}

emit_services_json() {
  local filter="."
  [[ $MISSING_ONLY -eq 1 ]] && filter="select($(jq_missing_expr "$SVC_PREFIX" "${SVC_KEYS[@]}"))"

  kubectl_get services \
    | jq "[.items[] | ${filter} | {namespace: .metadata.namespace, name: .metadata.name, annotations: $(jq_object_expr "$SVC_PREFIX" "${SVC_KEYS[@]}")}]"
}

# --- main --------------------------------------------------------------
if [[ "$OUTPUT" == "json" ]]; then
  case "$TARGET" in
    namespaces) jq -n --argjson ns "$(emit_namespaces_json)" '{namespaces: $ns}' ;;
    services)   jq -n --argjson sv "$(emit_services_json)"   '{services: $sv}' ;;
    all)        jq -n \
                  --argjson ns "$(emit_namespaces_json)" \
                  --argjson sv "$(emit_services_json)" \
                  '{namespaces: $ns, services: $sv}' ;;
  esac
  exit 0
fi

if [[ "$TARGET" == "namespaces" || "$TARGET" == "all" ]]; then
  [[ "$TARGET" == "all" && "$OUTPUT" == "table" ]] && echo "== NAMESPACES =="
  emit_namespaces
fi

if [[ "$TARGET" == "all" ]]; then
  [[ "$OUTPUT" == "table" ]] && echo
fi

if [[ "$TARGET" == "services" || "$TARGET" == "all" ]]; then
  [[ "$TARGET" == "all" && "$OUTPUT" == "table" ]] && echo "== SERVICES =="
  emit_services
fi
