# otel-metrics-test

A small Go program that emits a counter, a histogram, and an
`ObservableGauge` over OTLP and exits non-zero on export failure. It exists
to answer one cheap question - "is anything between here and the collector
broken?" (DNS, NetworkPolicy, TLS mismatch, collector down/paused) - not to
be a load generator or a persistent exporter.

## Files

- `main.go` - the test client (flags mirror `OTEL_EXPORTER_OTLP_*` env vars)
- `go.mod` / `go.sum` - pinned deps (`go.opentelemetry.io/otel` v1.46.0)
- `Dockerfile` - optional prebuilt image (distroless, multi-stage) if you'd
  rather push an image to Harbor than `go run` from source in-cluster
- `job.yaml` - a `kubectl apply`-by-hand one-off Job (same convention as
  `../sbom/generate-sbom-job.yaml` - not ArgoCD-managed) that runs
  `go run .` against a ConfigMap-mounted copy of the source, defaulting to
  `signoz-otel-collector.signoz.svc.cluster.local:4317`

## Run it locally first (fastest inner loop)

```bash
go run . -endpoint localhost:4317 -protocol grpc -insecure -count 3
```

Point `-endpoint`/`-protocol` at anything OTLP-compatible - a local
`otel/opentelemetry-collector` container, Jaeger, Grafana Alloy, etc.

## Run it inside the cluster over SSH

**Check the target collector is actually up first** - this repo's SigNoz
Application intentionally sits `paused`/scaled-to-0 for RAM reasons (see
the main README). Don't unpause/scale it just to run this test unless you
already intend to leave it running:

```bash
ssh root@89.117.54.54 -p 1337 'kubectl -n signoz get deploy signoz-otel-collector -o jsonpath="replicas={.spec.replicas} paused={.spec.paused}\n"'
```

If it's down, either scale it up deliberately (and remember to scale back
down) or point this test at a disposable throwaway collector instead - see
"Testing without touching SigNoz" below.

```bash
# from this directory
scp -P 1337 main.go go.mod go.sum job.yaml root@89.117.54.54:/tmp/
ssh root@89.117.54.54 -p 1337 '
  cd /tmp
  kubectl create configmap otel-metrics-test-src \
    --from-file=main.go --from-file=go.mod --from-file=go.sum \
    -n default --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f job.yaml
  kubectl wait --for=condition=complete job/otel-metrics-test --timeout=240s
  kubectl logs job/otel-metrics-test
  kubectl delete job otel-metrics-test
  kubectl delete configmap otel-metrics-test-src
'
```

A `Completed` pod whose logs end with `OK: metrics exported successfully`
is proof the OTLP path works end to end. Cross-check the collector side
too if you have access to it (SigNoz's UI, or its own logs) - a `0`
exit code only proves the SDK's `ForceFlush` didn't error, not that the
collector persisted anything.

`go run` pulls ~30 transitive OTel/gRPC dependencies from the module
proxy on first run inside the pod (no local module cache in a fresh
container) - budget a few minutes on this box, it is not a hung pod.

## Testing without touching SigNoz

Stand up a disposable debug collector in `default` (logs every metric it
receives, verbosity `detailed`) instead of pointing at SigNoz:

```bash
cat <<'YAML' | ssh root@89.117.54.54 -p 1337 'kubectl apply -f -'
apiVersion: v1
kind: ConfigMap
metadata:
  name: otel-debug-collector-config
  namespace: default
data:
  config.yaml: |
    receivers:
      otlp:
        protocols:
          grpc: { endpoint: 0.0.0.0:4317 }
          http: { endpoint: 0.0.0.0:4318 }
    exporters:
      debug: { verbosity: detailed }
    service:
      pipelines:
        metrics: { receivers: [otlp], exporters: [debug] }
---
apiVersion: v1
kind: Pod
metadata:
  name: otel-debug-collector
  namespace: default
  labels: { app: otel-debug-collector }
spec:
  restartPolicy: Never
  containers:
    - name: collector
      image: otel/opentelemetry-collector:0.111.0
      args: ["--config=/conf/config.yaml"]
      volumeMounts: [{ name: config, mountPath: /conf }]
  volumes:
    - name: config
      configMap: { name: otel-debug-collector-config }
---
apiVersion: v1
kind: Service
metadata:
  name: otel-debug-collector
  namespace: default
spec:
  selector: { app: otel-debug-collector }
  ports:
    - { name: grpc, port: 4317, targetPort: 4317 }
    - { name: http, port: 4318, targetPort: 4318 }
YAML
```

Then run the Job with the endpoint overridden:

```bash
sed 's#signoz-otel-collector.signoz.svc.cluster.local:4317#otel-debug-collector.default.svc.cluster.local:4317#' job.yaml \
  | ssh root@89.117.54.54 -p 1337 'kubectl apply -f -'
```

Check `kubectl logs otel-debug-collector -n default | grep -A3 otel_metrics_test`
for `-> Name: otel_metrics_test_requests_total` (and the histogram/gauge
counterparts) to confirm the collector actually received every metric
type, not just that the Job exited `0`.

Clean up when done:

```bash
ssh root@89.117.54.54 -p 1337 '
  kubectl delete job otel-metrics-test -n default --ignore-not-found
  kubectl delete configmap otel-metrics-test-src -n default --ignore-not-found
  kubectl delete pod,service otel-debug-collector -n default --ignore-not-found
  kubectl delete configmap otel-debug-collector-config -n default --ignore-not-found
'
```

**Verified**: this exact flow was run against a throwaway debug collector
on the live cluster - the Job completed, logged
`OK: metrics exported successfully`, and the collector's own logs showed
all three metric names (`otel_metrics_test_requests_total`,
`otel_metrics_test_latency_seconds`, `otel_metrics_test_up`) received
across 5 export rounds.
