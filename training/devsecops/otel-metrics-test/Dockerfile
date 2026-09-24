# Minimal static build, distroless runtime - this is a one-shot connectivity
# probe, not a long-running service, so image size/attack-surface matters
# more than debuggability inside the container.
FROM golang:1.25-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 go build -o /out/otel-metrics-test .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/otel-metrics-test /otel-metrics-test
ENTRYPOINT ["/otel-metrics-test"]
