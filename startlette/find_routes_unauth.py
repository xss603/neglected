#!/usr/bin/env python3
"""
Enumerate FastAPI routes, flag ones lacking fastapi.security deps,
and verify at runtime with curl.

Two modes:
  --mode introspect   Import the app, walk app.routes (source of truth).
  --mode prometheus   Fall back to starlette_requests_total (traffic only).

Run introspect mode inside the app container / same venv, e.g.:
  kubectl exec -it deploy/myapp -- python probe_routes.py --mode introspect ...

Always run the probe twice - once without credentials, once with - and diff.
"""

import argparse
import importlib
import json
import re
import subprocess
import sys
import urllib.parse
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor, as_completed

SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}


# ---------- discovery: introspect ----------

def has_security(dep, _seen=None):
    """True if this dependant (or any child) uses a fastapi.security class."""
    if _seen is None:
        _seen = set()
    if id(dep) in _seen:
        return False
    _seen.add(id(dep))

    from fastapi.security.base import SecurityBase
    call = getattr(dep, "call", None)
    if call is not None and isinstance(call, SecurityBase):
        return True
    if getattr(dep, "security_requirements", None):
        return True
    if getattr(dep, "security_scopes", None):
        return True
    for sub in getattr(dep, "dependencies", []) or []:
        if has_security(sub, _seen):
            return True
    return False


def dep_names(dep, _seen=None):
    """Human-readable list of dependency callables, for manual review."""
    if _seen is None:
        _seen = set()
    if id(dep) in _seen:
        return []
    _seen.add(id(dep))
    out = []
    call = getattr(dep, "call", None)
    if call is not None:
        out.append(getattr(call, "__qualname__", getattr(call, "__name__", repr(call))))
    for sub in getattr(dep, "dependencies", []) or []:
        out.extend(dep_names(sub, _seen))
    return out


def iter_api_routes(app):
    from fastapi.routing import APIRoute
    from starlette.routing import Mount
    for r in app.routes:
        if isinstance(r, APIRoute):
            yield r
        elif isinstance(r, Mount):
            # mounted sub-app: recurse, but note auth on the mount itself is not visible here
            sub = getattr(r, "app", None)
            if sub is not None and hasattr(sub, "routes"):
                yield from iter_api_routes(sub)


def discover_introspect(app_path: str):
    module_name, _, attr = app_path.partition(":")
    if not attr:
        attr = "app"
    mod = importlib.import_module(module_name)
    app = getattr(mod, attr)

    routes = []
    for r in iter_api_routes(app):
        if getattr(r, "include_in_schema", True) is False:
            # still include; but flag it
            pass
        methods = sorted(m for m in r.methods if m not in {"HEAD"})
        protected = has_security(r.dependant)
        routes.append({
            "methods": methods,
            "path": r.path,
            "name": r.name,
            "protected_by_security": protected,
            "deps": dep_names(r.dependant),
            "include_in_schema": getattr(r, "include_in_schema", True),
        })
    return routes


# ---------- discovery: prometheus (secondary) ----------

def prom_query(prom_url, query):
    url = f"{prom_url.rstrip('/')}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(url, timeout=30) as r:
        payload = json.load(r)
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus error: {payload}")
    return payload["data"]["result"]


def discover_prometheus(prom_url, metric, label, status_filter):
    filt = f'{{status_code=~"{status_filter}"}}' if status_filter else ""
    query = f'count by (method, {label}) ({metric}{filt})'
    results = prom_query(prom_url, query)
    routes = []
    for r in results:
        m = r["metric"]
        routes.append({
            "methods": [m.get("method", "GET").upper()],
            "path": m.get(label),
            "name": None,
            "protected_by_security": None,
            "deps": [],
            "include_in_schema": None,
        })
    return routes


# ---------- probing ----------

def substitute_params(path, value):
    return re.sub(r"\{[^}]+\}", value, path)


def curl_status(url, method, timeout, insecure, headers, follow_redirects):
    cmd = ["curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
           "--max-time", str(timeout)]
    if insecure:
        cmd.append("-k")
    if follow_redirects:
        cmd.append("-L")
    for h in headers:
        cmd.extend(["-H", h])
    if method == "HEAD":
        cmd.append("-I")
    else:
        cmd.extend(["-X", method])
    cmd.append(url)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 5)
        return (out.stdout.strip() or "000")
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    except Exception as e:
        return f"ERR({e})"


def classify(code, sent_credentials, follow_redirects):
    """Only 401/403 count as 'protected by app'. Anything that reaches the
    handler without auth is reachable. Redirects depend on whether we followed."""
    if code in ("000", "TIMEOUT") or str(code).startswith("ERR"):
        return "error"
    if code in ("401", "403"):
        return "protected"
    if code.startswith("3"):
        if follow_redirects:
            return "redirect-unresolved"
        return "redirect-check"
    if code.startswith("2"):
        return "reachable-with-creds" if sent_credentials else "REACHABLE-WITHOUT-AUTH"
    if code in ("404", "405", "422", "400", "500", "502", "503"):
        # Reached the handler or router without auth being rejected.
        return "reachable-with-creds" if sent_credentials else "REACHABLE-WITHOUT-AUTH"
    return "other"


# ---------- main ----------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["introspect", "prometheus"], required=True)
    ap.add_argument("--app", help="module:attr for introspect mode, e.g. myapp.main:app")
    ap.add_argument("--prometheus", help="Prometheus base URL (prometheus mode)")
    ap.add_argument("--metric", default="starlette_requests_total")
    ap.add_argument("--label", default="path")
    ap.add_argument("--status-filter", default="")
    ap.add_argument("--base-url", required=True, help="Base URL to probe, e.g. https://api.example.com")
    ap.add_argument("--methods", default="GET", help="Comma-separated, default GET")
    ap.add_argument("--allow-unsafe", action="store_true",
                    help="Permit POST/PUT/PATCH/DELETE. Default: refuse.")
    ap.add_argument("--replace-params", default="1")
    ap.add_argument("--timeout", type=int, default=10)
    ap.add_argument("--insecure", action="store_true")
    ap.add_argument("--follow-redirects", action="store_true")
    ap.add_argument("--header", action="append", default=[],
                    help="Extra header. Presence toggles 'with credentials' mode.")
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--output", default=None)
    ap.add_argument("--only-unprotected", action="store_true",
                    help="In introspect mode, probe only routes without security deps.")
    args = ap.parse_args()

    sent_credentials = bool(args.header)

    # 1. discover
    if args.mode == "introspect":
        if not args.app:
            ap.error("--app is required in introspect mode")
        routes = discover_introspect(args.app)
    else:
        if not args.prometheus:
            ap.error("--prometheus is required in prometheus mode")
        routes = discover_prometheus(args.prometheus, args.metric, args.label, args.status_filter)

    # 2. filter methods
    wanted = {x.strip().upper() for x in args.methods.split(",") if x.strip()}
    unsafe_requested = wanted - SAFE_METHODS
    if unsafe_requested and not args.allow_unsafe:
        print(f"[refuse] {sorted(unsafe_requested)} are unsafe. "
              f"Pass --allow-unsafe to probe them.", file=sys.stderr)
        sys.exit(2)

    if args.only_unprotected and args.mode == "introspect":
        routes = [r for r in routes if r["protected_by_security"] is False]

    probes = []
    for r in routes:
        for m in r["methods"]:
            if m in wanted:
                probes.append((m, r["path"], r))

    print(f"[info] {len(probes)} route/method pairs to probe", file=sys.stderr)
    if not probes:
        return

    # 3. probe
    base = args.base_url.rstrip("/")

    def do(probe):
        method, path, meta = probe
        url = base + substitute_params(path, args.replace_params)
        code = curl_status(url, method, args.timeout, args.insecure,
                           args.header, args.follow_redirects)
        verdict = classify(code, sent_credentials, args.follow_redirects)
        return {
            "method": method,
            "path": path,
            "url": url,
            "status": code,
            "verdict": verdict,
            "protected_by_security": meta.get("protected_by_security"),
            "deps": meta.get("deps", []),
            "name": meta.get("name"),
        }

    findings = []
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futs = [ex.submit(do, p) for p in probes]
        for f in as_completed(futs):
            findings.append(f.result())

    order = {"REACHABLE-WITHOUT-AUTH": 0, "redirect-check": 1, "redirect-unresolved": 2,
             "protected": 3, "reachable-with-creds": 4, "other": 5, "error": 6}
    findings.sort(key=lambda f: (order.get(f["verdict"], 9), f["path"]))

    # 4. report
    print(f"\n{'STATUS':<8} {'VERDICT':<24} {'SEC?':<6} {'METHOD':<7} PATH")
    print("-" * 110)
    for f in findings:
        sec = {True: "yes", False: "no", None: "?"}[f["protected_by_security"]]
        print(f"{f['status']:<8} {f['verdict']:<24} {sec:<6} {f['method']:<7} {f['path']}")

    # 5. summary + targeted warnings
    summary = defaultdict(int)
    for f in findings:
        summary[f["verdict"]] += 1
    print("\n[summary]")
    for k in sorted(summary, key=lambda x: order.get(x, 9)):
        print(f"  {k}: {summary[k]}")

    if args.mode == "introspect":
        no_sec = [f for f in findings if f["protected_by_security"] is False]
        if no_sec:
            print(f"\n[!] {len(no_sec)} route/method pairs have no fastapi.security dep:")
            for f in no_sec:
                print(f"    {f['method']:<6} {f['path']}")
        # Routes with security dep but reachable without auth: misconfig
        mismatch = [f for f in findings
                    if f["protected_by_security"] is True
                    and f["verdict"] == "REACHABLE-WITHOUT-AUTH"]
        if mismatch:
            print(f"\n[!!] {len(mismatch)} routes declare security but returned 2xx/4xx without creds "
                  f"(check middleware, custom deps, or trailing-slash redirects):")
            for f in mismatch:
                print(f"    {f['method']:<6} {f['path']}  deps={f['deps']}")

    if not sent_credentials:
        unauth = [f for f in findings if f["verdict"] == "REACHABLE-WITHOUT-AUTH"]
        if unauth:
            print(f"\n[!] {len(unauth)} routes reachable without credentials")
    else:
        print("\n[info] credentials were sent; skipping 'without-auth' claims. "
              "Run again without --header to compare.")

    if args.output:
        with open(args.output, "w") as fh:
            json.dump(findings, fh, indent=2)
        print(f"\n[info] wrote {len(findings)} results to {args.output}")


if __name__ == "__main__":
    main()