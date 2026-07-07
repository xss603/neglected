#!/usr/bin/env bash
# timoni.sh — thin wrapper around timoni that converts values.yaml to CUE on the fly.
#
# timoni v0.26.0 has a bug where --values *.yaml files produce "undefined value"
# because Go's JSON/YAML API creates closed CUE structs that conflict with open schema
# definitions. This script converts values.yaml to valid CUE (JSON is a CUE superset)
# and passes it to timoni via process substitution.
#
# Usage (mirrors timoni CLI):
#   ./timoni.sh build grafana-stack ./modules/stack [extra flags]
#   ./timoni.sh apply grafana-stack ./modules/stack [extra flags]
#   ./timoni.sh diff  grafana-stack ./modules/stack [extra flags]
#
# To override a specific values.yaml:
#   VALUES=my-values.yaml ./timoni.sh apply grafana-stack ./modules/stack

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALUES_FILE="${VALUES:-${SCRIPT_DIR}/values.yaml}"

if [[ ! -f "$VALUES_FILE" ]]; then
  echo "ERROR: values file not found: $VALUES_FILE" >&2
  exit 1
fi

# Convert YAML → JSON → CUE (JSON is a strict subset of CUE)
_yaml_to_cue() {
  python3 - "$VALUES_FILE" <<'PYEOF'
import sys, json
try:
    import yaml
    data = yaml.safe_load(open(sys.argv[1]))
except ImportError:
    # Fall back to json if PyYAML not installed (values.yaml must be strict JSON-compat)
    import re, json as j
    text = open(sys.argv[1]).read()
    # Strip YAML comments
    text = re.sub(r'(?m)^\s*#.*$', '', text)
    data = j.loads(text)

print("package main")
print("values:", json.dumps(data, indent=2))
PYEOF
}

# Build a temp CUE file, pipe to timoni via --values
TMP_CUE=$(mktemp /tmp/timoni-values-XXXXXX.cue)
trap 'rm -f "$TMP_CUE"' EXIT

_yaml_to_cue > "$TMP_CUE"

exec timoni "$@" --values "$TMP_CUE"
