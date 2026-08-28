# Envoy proxy pod → [L7 routing via HTTPRoute] → backend Service ClusterIP — the hop, precisely

This hop is **not actually a proxy-to-ClusterIP hop** the way a simple L4 LB would work. That's the source of a lot of confusion here.

## What actually happens

kgateway's control plane (a separate component from the Envoy data-plane pod) watches your `HTTPRoute`, the backend `Service`, and its `EndpointSlice`, and translates all of it into Envoy xDS config:

- **Route config (RDS)**: match rules (host/path/headers from the HTTPRoute) → pointing at a named **Cluster**.
- **Cluster config (CDS/EDS)**: the cluster's actual member list — and this is the key part — is usually populated via **EDS directly from the Service's `EndpointSlice`**, i.e. **real pod IPs**, not the Service's ClusterIP. Envoy connects straight to pods and load-balances itself; it deliberately bypasses kube-proxy/iptables for the final hop, because L7 features (retries, outlier detection, weighted routing) need per-pod visibility that a single ClusterIP hides.

So "Service ClusterIP works" tells you kube-proxy's path is fine, but it tells you **nothing** about whether Envoy's own EDS view is correct — those are two independent code paths to the same pods.

## Where this specifically breaks

```bash
kubectl exec -n <gateway-ns> <envoy-pod> -c <envoy-container> -- curl -s localhost:19000/clusters | grep -A10 <backend-cluster-name>
```

Look at what you actually get back:

1. **No cluster at all for this backend** → the HTTPRoute→Cluster translation never happened. Check `HTTPRoute.status` for `ResolvedRefs`, and check the kgateway **control-plane pod's own logs** (not Envoy's) — if its ServiceAccount lacks RBAC to watch `EndpointSlice`/`Service` in your backend's namespace, it silently produces no cluster, with zero error surfaced anywhere in the HTTPRoute status.

2. **Cluster exists, but the listed hosts are stale pod IPs** (an IP that no longer belongs to any live pod) → EndpointSlice updates aren't propagating to Envoy — check the control-plane pod is actually Running/healthy, not just the Envoy data-plane pod. This is the classic "pod restarted, Envoy still has the old IP cached" failure, and it looks exactly like "not forwarding correctly" from the outside.

3. **Cluster exists, IPs are current, but marked unhealthy** — look for `health_flags` in that same output:
   ```
   10.42.1.23:8080  healthy
   10.42.1.24:8080  /failed_outlier_check
   ```
   `failed_outlier_check` means Envoy **locally ejected** that pod after prior 5xx/connect errors — independent of Kubernetes readiness, which can still say the pod is Ready. This is a real, common false-positive: k8s says fine, Envoy has silently blacklisted it anyway.

4. **Route exists but points at a cluster name that doesn't match anything in `/clusters`** — check via:
   ```bash
   kubectl exec -n <gateway-ns> <envoy-pod> -c <envoy-container> -- curl -s localhost:19000/config_dump | grep -B3 -A15 '"cluster":'
   ```
   A mismatch here (usually from a `backendRef` port that doesn't match the Service's actual port name/number) produces a route that resolves to nothing — Envoy responds with its own `503 no_healthy_upstream`, not a raw TCP refuse, so if what's seen client-side is an HTTP 503 rather than a socket-level refusal, this is almost certainly it.

## One diagnostic distinction worth keeping in mind

A genuine TCP-level refuse/reset from the client usually means the failure is at the LB-VIP-to-Envoy hop (hop 1) or DNS — Envoy itself, once it accepts the connection, responds with **HTTP-level errors** (503/404) for routing/cluster problems, not a TCP RST. So:

- Seeing an actual **connection-refused** at the browser → re-check hop 1 (LB VIP → Envoy pod) first.
- Seeing a **503** → squarely in this hop; `/clusters` + `/config_dump` above will show exactly why.
