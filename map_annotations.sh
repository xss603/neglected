#!/usr/bin/env bash
#
# map_annotations.sh - extract Illumio-related annotations from
# Kubernetes namespaces and services.
#
# Namespaces are read for the namespaceoperator annotations:
#   namespaceoperator.<ORG>/applicative_tier
#   namespaceoperator.<ORG>/code_app
#   namespaceoperator.<ORG>/environment
#   namespaceoperator.<ORG>/middleware
#
# <ORG> is tenant-specific and varies between clusters, so the default
# namespace prefix is the glob "namespaceoperator.*": whatever follows the
# dot is matched, as long as it does not cross the "/" separator.
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
# Prefixes are globs: "*" matches any run of characters except "/", every
# other character is literal. Override with --ns-prefix/--svc-prefix or the
# ILLUMIO_NS_PREFIX/ILLUMIO_SVC_PREFIX environment variables. A prefix
# without "*" (e.g. namespaceoperator.ap24182) still matches exactly.
NS_PREFIX="${ILLUMIO_NS_PREFIX:-namespaceoperator.*}"
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
      --ns-prefix <p>     namespace annotation prefix glob (default: ${NS_PREFIX})
      --svc-prefix <p>    service annotation prefix glob   (default: ${SVC_PREFIX})
  -h, --help              show this help

Prefixes are globs where "*" matches anything up to the "/" separator, so
the default matches namespaceoperator.<any-org>/<key>. Pin a single tenant
with --ns-prefix namespaceoperator.ap24182. When more than one prefix
carries the same key on one object, the values are joined with ",".

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

# Turn a glob into a regex fragment safe to paste inside a jq string
# literal: "*" becomes [^/]*, regex metacharacters are escaped, and the
# escaping backslash is doubled because jq re-reads the string first.
glob_to_regex() {
  local glob="$1" out="" i c
  for (( i = 0; i < ${#glob}; i++ )); do
    c="${glob:i:1}"
    case "$c" in
      '*')                              out+='[^/]*' ;;
      '.'|'\'|'+'|'?'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|'|'-') out+="\\\\$c" ;;
      *)                                out+="$c" ;;
    esac
  done
  printf '%s' "$out"
}

# jq expression yielding the array of annotation values whose key matches
# <prefix-glob>/<key>. Reads .metadata.annotations only.
jq_match_expr() {
  local prefix_re="$1" key_re="$2"
  printf '((.metadata.annotations // {}) | to_entries | map(select(.key | test("^%s/%s$")) | .value))' \
    "$prefix_re" "$key_re"
}

# Build a comma-separated list of jq value expressions, one per key.
jq_value_exprs() {
  local prefix_re; prefix_re="$(glob_to_regex "$1")"; shift
  local out="" k
  for k in "$@"; do
    out+="($(jq_match_expr "$prefix_re" "$(glob_to_regex "$k")") | if length == 0 then \"${MISSING_PLACEHOLDER}\" else join(\",\") end),"
  done
  printf '%s' "${out%,}"
}

# Build a jq object mapping bare key name -> value, for JSON output.
jq_object_expr() {
  local prefix_re; prefix_re="$(glob_to_regex "$1")"; shift
  local out="" k
  for k in "$@"; do
    out+="\"${k}\": ($(jq_match_expr "$prefix_re" "$(glob_to_regex "$k")") | if length == 0 then null else join(\",\") end),"
  done
  printf '{%s}' "${out%,}"
}

# jq boolean: true when at least one of the keys is absent.
jq_missing_expr() {
  local prefix_re; prefix_re="$(glob_to_regex "$1")"; shift
  local out="" k
  for k in "$@"; do
    out+="($(jq_match_expr "$prefix_re" "$(glob_to_regex "$k")") | length) == 0 or "
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

# column(1) is not present everywhere (busybox images, minimal jump hosts);
# fall back to the raw tab-separated rows rather than dying.
render_table() {
  if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
}
render_csv()   { cat; }

# --- namespaces --------------------------------------------------------
get_namespaces_json() {
  # Namespaces are cluster-scoped so -n is meaningless; filter by name.
  local ns_json
  ns_json="$(kubectl get namespaces -o json)"
  if [[ -n "$NAMESPACE" ]]; then
    ns_json="$(jq --arg n "$NAMESPACE" '.items |= map(select(.metadata.name == $n))' <<<"$ns_json")"
  fi
  printf '%s' "$ns_json"
}

emit_namespaces_rows() {
  local sep="$1"     # tsv | csv
  local filter="."
  [[ $MISSING_ONLY -eq 1 ]] && filter="select($(jq_missing_expr "$NS_PREFIX" "${NS_KEYS[@]}"))"

  jq -r ".items[] | ${filter} | [.metadata.name, $(jq_value_exprs "$NS_PREFIX" "${NS_KEYS[@]}")] | @${sep}" \
    <<<"$(get_namespaces_json)"
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

  jq "[.items[] | ${filter} | {name: .metadata.name, annotations: $(jq_object_expr "$NS_PREFIX" "${NS_KEYS[@]}")}]" \
    <<<"$(get_namespaces_json)"
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
