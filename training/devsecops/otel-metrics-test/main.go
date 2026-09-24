// otel-metrics-test sends a handful of synthetic metrics (a counter, a
// histogram, and a gauge) to an OTLP endpoint and exits non-zero if the
// export fails. It exists to answer one question cheaply: "is anything
// between this pod and the collector broken (DNS, NetworkPolicy, TLS,
// collector down)?" - not to be a load generator or a permanent exporter.
//
// Usage:
//
//	OTEL_EXPORTER_OTLP_ENDPOINT=signoz-otel-collector.signoz.svc.cluster.local:4317 \
//	  go run . -protocol grpc -insecure -count 5 -interval 2s
//
// Flags mirror the standard OTEL_EXPORTER_OTLP_* env vars so this can also
// be pointed at any other OTLP-compatible collector (Grafana Alloy, the
// OTel Collector contrib image, Jaeger's OTLP receiver, etc.) without code
// changes - only the endpoint/protocol/TLS flags need to change.
package main

import (
	"context"
	"flag"
	"fmt"
	"log"
	"math/rand"
	"os"
	"time"

	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
	"go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetrichttp"
	"go.opentelemetry.io/otel/metric"
	sdkmetric "go.opentelemetry.io/otel/sdk/metric"
	"go.opentelemetry.io/otel/sdk/resource"
	semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

func main() {
	var (
		endpoint  = flag.String("endpoint", envOr("OTEL_EXPORTER_OTLP_ENDPOINT", "signoz-otel-collector.signoz.svc.cluster.local:4317"), "OTLP collector endpoint (host:port, no scheme)")
		protocol  = flag.String("protocol", envOr("OTEL_EXPORTER_OTLP_PROTOCOL", "grpc"), "grpc or http")
		insecure  = flag.Bool("insecure", true, "disable TLS (matches this cluster's in-cluster ClusterIP traffic - see README's 'plain HTTP internally' note)")
		count     = flag.Int("count", 5, "how many measurement rounds to emit before exiting")
		interval  = flag.Duration("interval", 2*time.Second, "delay between rounds")
		timeout   = flag.Duration("timeout", 10*time.Second, "per-export timeout")
		serviceNm = flag.String("service-name", "otel-metrics-test", "resource service.name attribute reported with every metric")
	)
	flag.Parse()

	ctx, cancel := context.WithTimeout(context.Background(), *timeout+time.Duration(*count)*(*interval)+*timeout)
	defer cancel()

	exporter, err := newExporter(ctx, *protocol, *endpoint, *insecure)
	if err != nil {
		log.Fatalf("build exporter: %v", err)
	}

	res, err := resource.Merge(resource.Default(), resource.NewSchemaless(
		semconv.ServiceNameKey.String(*serviceNm),
	))
	if err != nil {
		log.Fatalf("build resource: %v", err)
	}

	// Short export interval on purpose - this process lives for seconds,
	// not the usual 60s production default, so the reader must flush
	// before the process exits.
	reader := sdkmetric.NewPeriodicReader(exporter, sdkmetric.WithInterval(*interval))
	provider := sdkmetric.NewMeterProvider(
		sdkmetric.WithResource(res),
		sdkmetric.WithReader(reader),
	)
	defer func() {
		// Shutdown flushes any buffered metrics before returning - without
		// this, the last round emitted right before exit can be silently
		// dropped.
		shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), *timeout)
		defer shutdownCancel()
		if err := provider.Shutdown(shutdownCtx); err != nil {
			log.Printf("provider shutdown: %v", err)
		}
	}()

	meter := provider.Meter("otel-metrics-test")

	requestCounter, err := meter.Int64Counter(
		"otel_metrics_test_requests_total",
		metric.WithDescription("synthetic request count emitted by otel-metrics-test"),
	)
	if err != nil {
		log.Fatalf("create counter: %v", err)
	}

	latencyHistogram, err := meter.Float64Histogram(
		"otel_metrics_test_latency_seconds",
		metric.WithDescription("synthetic request latency emitted by otel-metrics-test"),
		metric.WithUnit("s"),
	)
	if err != nil {
		log.Fatalf("create histogram: %v", err)
	}

	// ObservableGauge reports on every collect - a fixed-ish value proves
	// the collector received a gauge point at all, independent of the
	// counter/histogram export path.
	_, err = meter.Float64ObservableGauge(
		"otel_metrics_test_up",
		metric.WithDescription("always 1 while this test process is running"),
		metric.WithFloat64Callback(func(_ context.Context, o metric.Float64Observer) error {
			o.Observe(1)
			return nil
		}),
	)
	if err != nil {
		log.Fatalf("create gauge: %v", err)
	}

	log.Printf("sending metrics to %s (%s, insecure=%v) for %d round(s) every %s",
		*endpoint, *protocol, *insecure, *count, *interval)

	for i := 0; i < *count; i++ {
		requestCounter.Add(ctx, 1)
		latencyHistogram.Record(ctx, 0.050+rand.Float64()*0.200)
		log.Printf("round %d/%d recorded", i+1, *count)
		if i < *count-1 {
			time.Sleep(*interval)
		}
	}

	// ForceFlush proves the export actually reached the collector (or
	// returns a real error) rather than exiting before the next periodic
	// tick would have fired.
	flushCtx, flushCancel := context.WithTimeout(ctx, *timeout)
	defer flushCancel()
	if err := reader.ForceFlush(flushCtx); err != nil {
		log.Fatalf("force flush (export failed): %v", err)
	}

	fmt.Println("OK: metrics exported successfully")
}

func newExporter(ctx context.Context, protocol, endpoint string, insecure bool) (sdkmetric.Exporter, error) {
	switch protocol {
	case "grpc":
		opts := []otlpmetricgrpc.Option{otlpmetricgrpc.WithEndpoint(endpoint)}
		if insecure {
			opts = append(opts, otlpmetricgrpc.WithInsecure())
		}
		return otlpmetricgrpc.New(ctx, opts...)
	case "http":
		opts := []otlpmetrichttp.Option{otlpmetrichttp.WithEndpoint(endpoint)}
		if insecure {
			opts = append(opts, otlpmetrichttp.WithInsecure())
		}
		return otlpmetrichttp.New(ctx, opts...)
	default:
		return nil, fmt.Errorf("unknown -protocol %q (want grpc or http)", protocol)
	}
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
