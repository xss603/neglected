#!/usr/bin/env python3
"""
audit_routes.py - find FastAPI/Starlette routes that are reachable without authentication.

ROUTE SOURCES (use one or more; results are merged):
  --app module:attr     Introspect the app object. Best source: includes routes that never
                        received traffic. Detects fastapi.security dependencies (router-level,
                        app-level and per-route) and recurses into Mount()ed sub-apps.
  --openapi URL|FILE    Paths, methods and declared `security` from an OpenAPI document.
                        Omits routes with include_in_schema=False.
  --prometheus URL      Routes seen in starlette_exporter metrics over --window.

RUNTIME PROBE (only when --base-url is given):
  Sends each route a request WITHOUT credentials (unless --header is passed) and classifies
  the response. Any answer other than 401/403 means the request got past authentication,
  including 404/422/500 returned by the handler.

LIMITS (cannot be fixed from outside the app):
  * Static detection only sees fastapi.security classes. Auth done in middleware, or a
    custom dependency that reads headers by hand, shows as "none"; the probe settles it.
  * 404 is ambiguous: handler-level 404 (auth passed) or path/placeholder does not exist.
    Use --param NAME=VALUE with real IDs to resolve it.
  * Probing sends real requests. Unsafe methods need --allow-unsafe. Only run against
    systems you are authorized to test.

Examples:
  python audit_routes.py --app main:app
  python audit_routes.py --app main:app --base-url https://api.example.com --output via_ingress.json
  python audit_routes.py --openapi https://api.example.com/openapi.json --base-url https://api.example.com
  python audit_routes.py --prometheus http://prometheus:9090 --window 30d \\
        --base-url http://myapp.svc.cluster.local:8000 --param item_id=42
"""
from __future__ import annotations

import argparse
import importlib
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field

SAFE_METHODS = {"GET", "HEAD", "OPTIONS"}
HTTP_METHODS = {"GET", "HEAD", "OPTIONS", "POST", "PUT", "PATCH", "DELETE"}
UA = "route-audit/1.0"
LOGIN_RE = re.compile(r"login|signin|sign-in|sso|oauth|auth", re.I)
PARAM_RE = re.compile(r"\{([^{}:]+)(?::([^{}]+))?\}")


@dataclass
class Endpoint:
    method: str
    path: str
    sources: set = field(default_factory=set)
    static_protected: bool | None = None  # True/False from introspection/OpenAPI, None = unknown
    note: str = ""


def add_endpoint(routes, method, path, source, protected=None, note=""):
    method = method.upper()
    if method not in HTTP_METHODS or not path.startswith("/"):
        return
    ep = routes.setdefault((method, path), Endpoint(method, path))
    ep.sources.add(source)
    if ep.static_protected is None and protected is not None:
        ep.static_protected = protected
    if note and note not in ep.note:
        ep.note = f"{ep.note}; {note}" if ep.note else note


# --------------------------------------------------------------------------- sources
def load_app(spec):
    mod_name, _, attr = spec.partition(":")
    if not mod_name or not attr:
        raise SystemExit("--app must look like module:attribute (e.g. main:app)")
    sys.path.insert(0, os.getcwd())
    obj = getattr(importlib.import_module(mod_name), attr)
    if not hasattr(obj, "routes") and callable(obj):  # zero-arg app factory
        obj = obj()
    return obj


def has_security(dep):
    """True if the dependency tree contains a fastapi.security scheme."""
    from fastapi.security.base import SecurityBase

    if isinstance(getattr(dep, "call", None), SecurityBase):
        return True
    if getattr(dep, "security_requirements", None):
        return True
    return any(has_security(d) for d in dep.dependencies)


def walk_routes(routes, prefix=""):
    from fastapi.routing import APIRoute
    from starlette.routing import Mount
    from starlette.routing import Route as StarletteRoute

    for r in routes:
        if isinstance(r, APIRoute):  # must precede StarletteRoute (subclass)
            prot = has_security(r.dependant)
            for m in sorted(r.methods or ()):
                yield m, prefix + r.path, prot, ""
        elif isinstance(r, Mount):
            sub = list(r.routes or [])
            if sub:
                yield from walk_routes(sub, prefix + r.path)
            else:
                yield "GET", (prefix + r.path) or "/", None, "mounted app not introspectable"
        elif isinstance(r, StarletteRoute):
            for m in sorted(r.methods or ()):
                yield m, prefix + r.path, None, "plain Starlette route, auth not introspectable"
        # WebSocketRoute and others are skipped (not HTTP-probeable)


def routes_from_app(spec, routes):
    app = load_app(spec)
    for method, path, prot, note in walk_routes(app.routes):
        add_endpoint(routes, method, path, "app", prot, note)


def http_get_json(url, timeout, ctx):
    req = urllib.request.Request(url, headers={"User-Agent": UA, "Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as r:
        return json.load(r)


def routes_from_openapi(src, routes, timeout, ctx):
    if src.startswith(("http://", "https://")):
        doc = http_get_json(src, timeout, ctx)
    else:
        with open(src) as fh:
            doc = json.load(fh)
    global_sec = doc.get("security") or []
    for path, item in (doc.get("paths") or {}).items():
        for method, op in item.items():
            if method.upper() not in HTTP_METHODS or not isinstance(op, dict):
                continue
            sec = op["security"] if "security" in op else global_sec
            # `security: [{}]` (or a list containing {}) means auth is optional
            protected = bool(sec) and all(bool(req) for req in sec)
            add_endpoint(routes, method, path, "openapi", protected)


def routes_from_prometheus(a, routes, ctx):
    matchers = ([f'status_code=~"{a.status_filter}"'] if a.status_filter else []) + a.matcher
    selector = a.metric + ("{" + ",".join(matchers) + "}" if matchers else "")
    # last_over_time over a window: a bare instant query only returns series active in
    # the last ~5 minutes and would miss routes that were not hit recently.
    query = f"count by (method, {a.path_label}) (last_over_time({selector}[{a.window}]))"
    url = f"{a.prometheus.rstrip('/')}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    try:
        payload = http_get_json(url, a.timeout, ctx)
    except Exception as e:  # noqa: BLE001
        raise SystemExit(f"Prometheus query failed: {e}\nquery: {query}")
    if payload.get("status") != "success":
        raise SystemExit(f"Prometheus error: {payload}\nquery: {query}")
    for res in payload["data"]["result"]:
        m = res["metric"]
        if m.get(a.path_label) and m.get("method"):
            add_endpoint(routes, m["method"], m[a.path_label], "prometheus")


# --------------------------------------------------------------------------- probing
def fill_path(path, default, params):
    def rep(m):
        name, conv = m.group(1), (m.group(2) or "").lower()
        if name in params:
            val = params[name]
        elif conv == "uuid":
            val = "00000000-0000-0000-0000-000000000000"
        elif conv in ("int", "float"):
            val = "1"
        elif conv == "path":
            val = "x"
        else:
            val = default
        return urllib.parse.quote(val, safe="/")

    return PARAM_RE.sub(rep, path)


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None  # surface 3xx as HTTPError instead of following


def http_probe(url, method, timeout, ctx, headers):
    hdrs = {"User-Agent": UA, **headers}
    req = urllib.request.Request(url, method=method, headers=hdrs)
    opener = urllib.request.build_opener(NoRedirect, urllib.request.HTTPSHandler(context=ctx))
    try:
        with opener.open(req, timeout=timeout) as r:
            return r.status, r.headers.get("Location", "")
    except urllib.error.HTTPError as e:
        try:
            return e.code, e.headers.get("Location", "")
        finally:
            e.close()
    except Exception as e:  # noqa: BLE001
        return 0, f"{type(e).__name__}: {e}"


def slash_redirect(url, target):
    """True if target differs from url only by a trailing slash (FastAPI redirect_slashes)."""
    u, t = urllib.parse.urlparse(url), urllib.parse.urlparse(target)
    return (u.scheme, u.netloc) == (t.scheme, t.netloc) and u.path != t.path and \
        u.path.rstrip("/") == t.path.rstrip("/")


def classify(status, location):
    if status == 0:
        return "ERROR"
    if status in (401, 403):
        return "PROTECTED"
    if 300 <= status < 400:
        return "PROTECTED?" if LOGIN_RE.search(location or "") else "REDIRECT"
    if status == 404:
        return "AMBIGUOUS"
    if status == 405:
        return "NO_MATCH"
    if status in (408, 429, 502, 503, 504):
        return "INCONCLUSIVE"
    return "OPEN"  # 2xx, 400, 422, 500...: request passed the auth layer


def make_ctx(insecure):
    ctx = ssl.create_default_context()
    if insecure:
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
    return ctx


# --------------------------------------------------------------------------- main
def parse_args():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    s = ap.add_argument_group("route sources (at least one)")
    s.add_argument("--app", help="module:attribute of the FastAPI app, e.g. main:app")
    s.add_argument("--openapi", help="OpenAPI JSON URL or file")
    s.add_argument("--prometheus", help="Prometheus base URL, e.g. http://prometheus:9090")
    p = ap.add_argument_group("prometheus options")
    p.add_argument("--metric", default="starlette_requests_total")
    p.add_argument("--path-label", default="path")
    p.add_argument("--matcher", action="append", default=[], help='extra label matcher, e.g. app_name="api" (repeatable)')
    p.add_argument("--status-filter", default="", help="regex for status_code label, e.g. '2..'")
    p.add_argument("--window", default="7d", help="lookback for routes seen (default 7d)")
    q = ap.add_argument_group("runtime probe")
    q.add_argument("--base-url", help="probe routes against this base URL (omit for static report only)")
    q.add_argument("--methods", default="GET", help="comma-separated methods, or 'all' (default GET)")
    q.add_argument("--allow-unsafe", action="store_true", help="permit POST/PUT/PATCH/DELETE probes")
    q.add_argument("--replace-params", default="1", help="default value for {placeholders}")
    q.add_argument("--param", action="append", default=[], metavar="NAME=VALUE", help="value for a specific placeholder (repeatable)")
    q.add_argument("--header", action="append", default=[], metavar="'Name: value'", help="extra request header (repeatable); changes the verdict wording")
    q.add_argument("--exclude", action="append", default=[], metavar="REGEX", help="skip paths matching regex (repeatable)")
    q.add_argument("--insecure", action="store_true", help="skip TLS verification")
    q.add_argument("--timeout", type=int, default=10)
    q.add_argument("--concurrency", type=int, default=4)
    ap.add_argument("--output", help="write results as JSON")
    ap.add_argument("--fail-on-open", action="store_true", help="exit 1 if any route is OPEN")
    a = ap.parse_args()
    if not (a.app or a.openapi or a.prometheus):
        ap.error("give at least one of --app, --openapi, --prometheus")
    a.methods_set = None if a.methods.strip().lower() == "all" else {m.strip().upper() for m in a.methods.split(",") if m.strip()}
    if a.base_url and not a.allow_unsafe and (a.methods_set is None or a.methods_set - SAFE_METHODS):
        ap.error("unsafe methods requested; add --allow-unsafe if you really mean it")
    try:
        a.params = dict(p.split("=", 1) for p in a.param)
        a.headers = dict((k.strip(), v.strip()) for k, v in (h.split(":", 1) for h in a.header))
    except ValueError:
        ap.error("--param needs NAME=VALUE and --header needs 'Name: value'")
    return a


def main():
    a = parse_args()
    ctx = make_ctx(a.insecure)
    routes: dict = {}
    if a.app:
        routes_from_app(a.app, routes)
    if a.openapi:
        routes_from_openapi(a.openapi, routes, a.timeout, ctx)
    if a.prometheus:
        routes_from_prometheus(a, routes, ctx)

    excludes = [re.compile(x) for x in a.exclude]
    eps = [e for e in routes.values()
           if not any(x.search(e.path) for x in excludes)
           and (a.methods_set is None or e.method in a.methods_set)]
    eps.sort(key=lambda e: (e.path, e.method))
    print(f"[info] {len(eps)} route/method pairs selected", file=sys.stderr)
    if not eps:
        return 0

    static_lbl = {True: "auth", False: "none", None: "?"}

    if not a.base_url:  # static report only
        print(f"{'STATIC':<7} {'METHOD':<7} PATH  [sources] note")
        print("-" * 100)
        for e in eps:
            print(f"{static_lbl[e.static_protected]:<7} {e.method:<7} {e.path}  [{','.join(sorted(e.sources))}] {e.note}")
        flagged = [e for e in eps if e.static_protected is not True]
        print(f"\n[summary] {len(flagged)} of {len(eps)} have no fastapi.security dependency "
              f"(auth may still exist in middleware/custom dependencies; confirm with --base-url)")
        write_output(a, [{"method": e.method, "path": e.path, "static": static_lbl[e.static_protected],
                          "sources": sorted(e.sources), "note": e.note} for e in eps])
        return 0

    base = a.base_url.rstrip("/")
    creds = bool(a.headers)
    relabel = {"OPEN": "ACCESSIBLE", "PROTECTED": "REJECTED", "PROTECTED?": "REJECTED?"} if creds else {}

    def probe(e):
        url = base + fill_path(e.path, a.replace_params, a.params)
        status, loc = http_probe(url, e.method, a.timeout, ctx, a.headers)
        if 300 <= status < 400 and loc:
            target = urllib.parse.urljoin(url, loc)
            if slash_redirect(url, target):
                url = target
                status, loc = http_probe(url, e.method, a.timeout, ctx, a.headers)
        verdict = classify(status, loc)
        return {"verdict": relabel.get(verdict, verdict), "status": status, "method": e.method,
                "path": e.path, "url": url, "static": static_lbl[e.static_protected],
                "sources": sorted(e.sources), "note": e.note if status else e.note or loc,
                "location": loc if status else ""}

    with ThreadPoolExecutor(max_workers=max(1, a.concurrency)) as ex:
        results = list(ex.map(probe, eps))

    open_v = "ACCESSIBLE" if creds else "OPEN"
    order = {open_v: 0, "AMBIGUOUS": 1}
    results.sort(key=lambda r: (order.get(r["verdict"], 2), r["verdict"], r["path"], r["method"]))

    print(f"\n{'VERDICT':<13} {'CODE':<5} {'METHOD':<7} {'STATIC':<7} PATH")
    print("-" * 100)
    for r in results:
        print(f"{r['verdict']:<13} {r['status']:<5} {r['method']:<7} {r['static']:<7} {r['path']}")

    counts: dict = {}
    for r in results:
        counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
    print("\n[summary]", ", ".join(f"{k}={v}" for k, v in sorted(counts.items())))

    if creds:
        print("[note] --header supplied: verdicts show what these credentials can reach, "
              "not what is reachable unauthenticated.")
    else:
        opened = [r for r in results if r["verdict"] == "OPEN"]
        if opened:
            print(f"\n[!] {len(opened)} route(s) answered without credentials (got past auth):")
            for r in opened:
                print(f"  {r['status']} {r['method']:<6} {r['path']}")
            mism = [r for r in opened if r["static"] == "auth"]
            if mism:
                print("\n[!] Declared a security dependency yet reachable without credentials "
                      "(check the dependency logic, dependency_overrides, or a proxy injecting auth):")
                for r in mism:
                    print(f"  {r['method']:<6} {r['path']}")
        outside = [r for r in results if r["verdict"] == "PROTECTED" and r["static"] == "none"]
        if outside:
            print(f"\n[info] {len(outside)} route(s) have no fastapi.security dependency but returned 401/403: "
                  "auth is enforced by middleware, a custom dependency, or the gateway.")
        if any(r["verdict"] == "AMBIGUOUS" for r in results):
            print("[info] AMBIGUOUS = 404: handler-level 404 (auth passed) or the path/placeholder does not exist. "
                  "Re-run with --param NAME=<real id>.")

    write_output(a, results)
    return 1 if (a.fail_on_open and not creds and counts.get("OPEN")) else 0


def write_output(a, data):
    if a.output:
        with open(a.output, "w") as fh:
            json.dump(data, fh, indent=2)
        print(f"[info] wrote {len(data)} results to {a.output}", file=sys.stderr)


if __name__ == "__main__":
    sys.exit(main())
