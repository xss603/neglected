#!/usr/bin/env bash
# generate.sh — walks cue/jobs/ and exports each job.cue to generated/<name>.yaml
# Requires: cue >= 0.9  (https://cuelang.org/docs/install/)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOBS_DIR="$SCRIPT_DIR/cue/jobs"
OUT_DIR="$SCRIPT_DIR/generated"

mkdir -p "$OUT_DIR"

ok=0
fail=0

while IFS= read -r -d '' job_file; do
    job_dir="$(dirname "$job_file")"
    job_name="$(basename "$job_dir")"
    out_file="$OUT_DIR/${job_name}.yaml"

    if cue export --out yaml -e workflow "$job_dir" > "$out_file" 2>&1; then
        echo "  ✓ $job_name → generated/${job_name}.yaml"
        ok=$(( ok + 1 ))
    else
        echo "  ✗ $job_name — CUE export failed:" >&2
        cue export --out yaml -e workflow "$job_dir" >&2 || true
        fail=$(( fail + 1 ))
    fi
done < <(find "$JOBS_DIR" -name "job.cue" -print0 | sort -z)

echo ""
echo "Generated $ok workflow(s). Failures: $fail."
[ "$fail" -eq 0 ] || exit 1
