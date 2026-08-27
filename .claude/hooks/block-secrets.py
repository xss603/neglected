#!/usr/bin/env python3
"""PreToolUse hook: block Edit/Write from committing a literal secret value
into this repo. This repo's hard rule (see CLAUDE.md) is that secrets live
only as cluster Secrets or references to them, never as values in git -
this is a backstop against a copy-paste mistake, not a replacement for that
discipline.
"""
import json
import re
import sys

PATTERNS = [
    re.compile(r"BEGIN (RSA |EC |OPENSSH |)PRIVATE KEY"),
    re.compile(r"AKIA[0-9A-Z]{16}"),  # AWS access key id
    # A YAML-style `password:`/`secret:`/`token:` key followed by a quoted
    # or bare literal value that isn't obviously a reference (existingSecret,
    # secretKeyRef, envValueFrom, a Secret name, or a template placeholder).
    re.compile(
        r"(?im)^\s*(password|secret|token|client-secret|root_token)\s*:\s*"
        r"(?!.*(existingSecret|secretKeyRef|envValueFrom|\{\{|<|\$\{|CHANGEME))"
        r"['\"]?[A-Za-z0-9+/=_\-]{12,}['\"]?\s*$"
    ),
]


def main():
    payload = json.load(sys.stdin)
    tool_input = payload.get("tool_input", {})
    content = tool_input.get("content") or tool_input.get("new_string") or ""
    if not content:
        sys.exit(0)

    for pattern in PATTERNS:
        match = pattern.search(content)
        if match:
            print(
                f"Blocked: content matches a likely-secret pattern ({pattern.pattern[:50]}...).\n"
                "This repo's rule is that secrets never land in git - reference a "
                "Secret name (existingSecret/secretKeyRef/envValueFrom) instead. "
                "If this is a false positive (e.g. a placeholder or hash, not a "
                "real secret), rephrase it so it doesn't match a plausible-secret "
                "shape, or ask the user to confirm before proceeding.",
                file=sys.stderr,
            )
            sys.exit(2)

    sys.exit(0)


if __name__ == "__main__":
    main()
