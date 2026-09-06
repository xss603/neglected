**PromQL queries to isolate root cause (endpoint lag vs app SIGTERM handling vs Traefik timeout):**

```promql
# 1. Traefik 5xx/499 rate by service, during teardown window
sum(rate(traefik_service_requests_total{code=~"499|504"}[1m])) by (service, code)

# 2. Correlate with pod terminations (compare timestamps)
kube_pod_deletion_timestamp{namespace="<ns>", pod=~"api-.*"}

# 3. Endpoint churn — how fast endpoints update vs pod termination
changes(kube_endpoint_address_available{namespace="<ns>", endpoint="api"}[5m])

# 4. Traefik backend request duration (spot timeout clustering near teardown)
histogram_quantile(0.99,
  sum(rate(traefik_service_request_duration_seconds_bucket{service="api@kubernetes"}[1m])) by (le)
)

# 5. Traefik open connections to backend (should drop to 0 before pod dies)
traefik_service_open_connections{service="api@kubernetes"}

# 6. Pod readiness flapping right before termination
kube_pod_status_ready{namespace="<ns>", pod=~"api-.*"} == 0

# 7. Container SIGTERM-to-exit latency (are pods dying faster than grace period?)
(kube_pod_container_status_terminated_reason{reason="Completed"} 
  - on(pod) kube_pod_deletion_timestamp)

# 8. Traefik retries triggered (confirms middleware masking failures)
sum(rate(traefik_service_retries_total{service="api@kubernetes"}[1m]))
```

**How to read it:**
- If **#3 (endpoint changes)** lags behind **#2 (deletion timestamp)** by >1–2s → confirms endpoint propagation delay = root cause.
- If **#5 (open connections)** stays >0 after pod terminated → Traefik still routing to dead pod.
- If **#6** shows readiness flapping *before* deletion timestamp → app isn't failing readiness on SIGTERM (needs code fix, not just preStop).
- Spike in **#1** at same second as **#7 retries=0** → retries aren't even firing, middleware misconfigured.

**Caveat:** needs `kube-state-metrics` + Traefik metrics (`--metrics.prometheus=true`) enabled; confirm labels match your scrape config (`kubectl get servicemonitor -n traefik`).
