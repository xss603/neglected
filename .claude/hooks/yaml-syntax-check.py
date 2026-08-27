#!/usr/bin/env python3
"""PostToolUse hook: after an Edit/Write to apps/ or manifests/, confirm the
file (and, for ArgoCD Application CRs, the embedded Helm values: block) is
still valid YAML. This repo has no CI - a broken block scalar indentation
inside `spec.source.helm.values: |` won't fail the outer YAML parse, it'll
just silently produce wrong/empty Helm values that ArgoCD renders without
complaint. This catches the outer-syntax case; the nested-values case still
needs a human/agent look if this reports clean but something still seems off.
"""
import json
import sys

try:
    import yaml
except ImportError:
    sys.exit(0)  # PyYAML not installed - don't block on a missing dependency


def main():
    payload = json.load(sys.stdin)
    tool_input = payload.get("tool_input", {})
    file_path = tool_input.get("file_path", "")

    if not file_path.endswith((".yaml", ".yml")):
        sys.exit(0)
    if not ("/apps/" in file_path or "/manifests/" in file_path
             or file_path.startswith("apps/") or file_path.startswith("manifests/")):
        sys.exit(0)

    try:
        with open(file_path) as f:
            docs = list(yaml.safe_load_all(f))
    except yaml.YAMLError as e:
        print(f"YAML syntax error in {file_path}: {e}", file=sys.stderr)
        sys.exit(1)  # non-blocking (PostToolUse) - surfaced as a warning
    except OSError:
        sys.exit(0)

    for doc in docs:
        if not isinstance(doc, dict):
            continue
        helm_values = doc.get("spec", {}).get("source", {}).get("helm", {}).get("values")
        if isinstance(helm_values, str):
            try:
                yaml.safe_load(helm_values)
            except yaml.YAMLError as e:
                print(
                    f"YAML syntax error inside spec.source.helm.values in {file_path}: {e}\n"
                    "This is the embedded Helm values block scalar - a bad indentation "
                    "here won't fail the outer parse, it silently produces wrong values.",
                    file=sys.stderr,
                )
                sys.exit(1)

    sys.exit(0)


if __name__ == "__main__":
    main()
