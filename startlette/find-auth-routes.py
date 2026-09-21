Here's a Python script that queries Prometheus for starlette_requests_total, extracts method/path (and host if you have that label), and curls each route to record the status code. It handles templated paths like /api/v1/items/{item_id} by substituting a test value, and skips obviously unsafe methods by default.

```python
#!/usr/bin/env python3
"""
Find routes from starlette_exporter metrics and probe them with curl.

Usage:
  python probe_routes.py \
      --prometheus http://prometheus:9090 \
      --base-url https://api.example.com \
      --status-filter '2..' \
      --methods GET,POST

Notes:
  - starlette_exporter templates paths (e.g. /items/{item_id}). We replace
    {placeholders} with --replace-params before curling.
  - The 'host' label is not standard in starlette_exporter; if you have it,
    pass --host-label host (default) and the script will group per host.
    If it's missing, the script falls back to path-only grouping.
"""

import argparse
import json
import subprocess
import sys
import urllib.parse
import urllib.request
from collections import defaultdict


def prom_query(prom_url: str, query: str):
    url = f"{prom_url.rstrip('/')}/api/v1/query?" + urllib.parse.urlencode({"query": query})
    with urllib.request.urlopen(url, timeout=30) as r:
        payload = json.load(r)
    if payload.get("status") != "success":
        raise RuntimeError(f"Prometheus error: {payload}")
    return payload["data"]["result"]


def fetch_routes(args):
    filt = f'{{status_code=~"{args.status_filter}"}}' if args.status_filter else ""
    # Try with host label first
    query_with_host = (
        f'count by (method, {args.label}, {args.host_label}) '
        f'({args.metric}{filt})'
    )
    try:
        return prom_query(args.prometheus, query_with_host), True
    except Exception as e:
        print(f"[warn] host-label query failed ({e}); retrying without host", file=sys.stderr)
        query_no_host = (
            f'count by (method, {args.label}) ({args.metric}{filt})'
        )
        return prom_query(args.prometheus, query_no_host), False


def substitute_params(path: str, replacement: str) -> str:
    # Replace {foo}, {foo:path}, {foo:int}, etc. with the replacement value
    import re
    return re.sub(r"\{[^}]+\}", replacement, path)


def curl_status(url: str, method: str, timeout: int, insecure: bool, extra_headers):
    cmd = [
        "curl", "-s", "-o", "/dev/null",
        "-w", "%{http_code}",
        "-X", method,
        "--max-time", str(timeout),
    ]
    if insecure:
        cmd.append("-k")
    for h in extra_headers:
        cmd.extend(["-H", h])
    cmd.append(url)
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout + 5)
        code = out.stdout.strip() or "000"
        return code
    except subprocess.TimeoutExpired:
        return "TIMEOUT"
    except Exception as e:
        return f"ERR({e})"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prometheus", required=True, help="Prometheus base URL, e.g. http://prometheus:9090")
    ap.add_argument("--base-url", required=True, help="Base URL to probe, e.g. https://api.example.com")
    ap.add_argument("--metric", default="starlette_requests_total")
    ap.add_argument("--label", default="path", help="Label holding the route path")
    ap.add_argument("--host-label", default="host", help="Optional label holding host")
    ap.add_argument("--status-filter", default="", help="Regex for status_code, e.g. '2..'")
    ap.add_argument("--methods", default="GET", help="Comma-separated methods to probe (default: GET)")
    ap.add_argument("--replace-params", default="1", help="Value to use for {param} placeholders")
    ap.add_argument("--timeout", type=int, default=10)
    ap.add_argument("--insecure", action="store_true", help="Pass -k to curl")
    ap.add_argument("--header", action="append", default=[], help="Extra header, repeatable")
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--output", default=None, help="Write results to a file (JSON)")
    args = ap.parse_args()

    results, has_host = fetch_routes(args)

    seen = set()
    routes = []
    for r in results:
        m = r["metric"]
        method = (m.get("method") or "GET").upper()
        path = m.get(args.label)
        host = m.get(args.host_label) if has_host else None
        if not path:
            continue
        key = (method, path, host)
        if key in seen:
            continue
        seen.add(key)
        routes.append((method, path, host))

    wanted_methods = {x.strip().upper() for x in args.methods.split(",") if x.strip()}
    routes = [r for r in routes if r[0] in wanted_methods]

    print(f"[info] {len(routes)} routes to probe", file=sys.stderr)
    if not routes:
        return

    # Probe sequentially with a simple thread pool
    from concurrent.futures import ThreadPoolExecutor, as_completed

    def probe(route):
        method, path, host = route
        real_path = substitute_params(path, args.replace_params)
        base = args.base_url.rstrip("/")
        if host:
            # If host is like api.example.com, prefer it over --base-url host
            parsed = urllib.parse.urlparse(base)
            base = f"{parsed.scheme}://{host}"
        url = base + real_path
        code = curl_status(url, method, args.timeout, args.insecure, args.header)
        return {"method": method, "path": path, "host": host, "url": url, "status": code}

    findings = []
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futs = {ex.submit(probe, r): r for r in routes}
        for fut in as_completed(futs):
            findings.append(fut.result())

    findings.sort(key=lambda x: (x["status"], x["path"]))

    print(f"\n{'STATUS':<8} {'METHOD':<7} {'PATH':<50} URL")
    print("-" * 120)
    for f in findings:
        print(f"{f['status']:<8} {f['method']:<7} {f['path']:<50} {f['url']}")

    # Summary
    summary = defaultdict(int)
    for f in findings:
        summary[f["status"]] += 1
    print("\n[summary] status -> count")
    for k, v in sorted(summary.items()):
        print(f"  {k}: {v}")

    # Highlight likely unauthenticated (2xx) endpoints
    unauth = [f for f in findings if str(f["status"]).startswith("2")]
    if unauth:
        print(f"\n[!] {len(unauth)} routes returned 2xx without credentials:")
        for f in unauth:
            print(f"  {f['method']:<6} {f['path']:<50} {f['url']}")

    if args.output:
        with open(args.output, "w") as fh:
            json.dump(findings, fh, indent=2)
        print(f"\n[info] wrote {len(findings)} results to {args.output}")


if __name__ == "__main__":
    main()
```

How to use it

```bash
# Simplest run - only GET routes with 2xx history
python probe_routes.py \
  --prometheus http://prometheus:9090 \
  --base-url https://api.example.com \
  --status-filter '2..' \
  --output routes.json

# All methods, include auth headers to compare protected vs. public
python probe_routes.py \
  --prometheus http://prometheus:9090 \
  --base-url https://api.example.com \
  --methods GET,POST,PUT,DELETE \
  --header "Authorization: Bearer $TOKEN" \
  --output with_token.json

# Insecure (self-signed TLS) + higher concurrency
python probe_routes.py \
  --prometheus http://prometheus:9090 \
  --base-url https://internal.svc.cluster.local \
  --insecure --concurrency 16
```

What it does

1. Queries Prometheus for count by (method, path[, host]) (starlette_requests_total{status_code=~"..."}).
2. Falls back to path-only grouping if the host label doesn't exist.
3. Substitutes {param} placeholders with --replace-params (default 1).
4. Probes each route with curl, capturing the HTTP status.
5. Prints a table, a status summary, and explicitly calls out routes returning 2xx without credentials — the likely unauthenticated ones.
6. Optionally writes JSON output for further processing.

Interpretation

· 2xx without credentials → candidate unauthenticated route. Verify it isn't just returning public data intentionally.
· 401/403 → protected by the app (or ingress, if you curl through Traefik).
· 404 → route exists in metrics but is no longer registered, or path substitution is wrong (templated param needs a real value).
· 000/TIMEOUT → network/DNS issue.

Tips for your Traefik setup

· Run this through Traefik (using --base-url https://your-public-host) to test the full path including ingress middleware.
· Run it against the service directly (e.g. http://myapp.svc.cluster.local:8000) to see whether FastAPI itself enforces auth.
· Diff the two runs: a route that's 403 via Traefik but 200 directly is protected only at the ingress layer — if someone bypasses Traefik (e.g. via kubectl port-forward), it's open.

If you tell me the exact label names on your starlette_requests_total (some setups use app_name or add custom labels like service), I can adjust the --label/--host-label defaults to match.