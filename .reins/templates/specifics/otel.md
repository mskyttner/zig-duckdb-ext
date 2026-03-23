# OpenTelemetry — Specific Rules

These rules apply when modifying Go files that use OpenTelemetry.
Loaded via `rules/INDEX.yaml` trigger: `**/*.go` with
`content_pattern: "go.opentelemetry.io"`.

---

## Initialization

- **S-OTEL-01** — MUST configure a single global `TracerProvider` at application
  startup via `otel.SetTracerProvider()`. Never create ad-hoc providers in
  library code.

- **S-OTEL-02** — MUST set a composite propagator containing `TraceContext{}`
  and `Baggage{}` via `otel.SetTextMapPropagator()` so W3C `traceparent` and
  `tracestate` headers are propagated across all boundaries.

- **S-OTEL-03** — MUST attach a `resource.Resource` with at least
  `semconv.ServiceNameKey` to the `TracerProvider` so spans are attributable in
  the backend.

## Span Lifecycle

- **S-OTEL-04** — MUST call `span.End()` exactly once for every
  `tracer.Start()`. Prefer `defer span.End()` immediately after creation.

- **S-OTEL-05** — MUST set the correct `SpanKind` when starting a span:
  `SpanKindServer` for inbound HTTP, `SpanKindClient` for outbound calls,
  `SpanKindProducer` for message sends, `SpanKindConsumer` for message receives,
  `SpanKindInternal` (default) for in-process work.

- **S-OTEL-06** — MUST record errors on spans with `span.RecordError(err)`
  before returning an error from instrumented functions.

## Context Propagation

- **S-OTEL-07** — MUST propagate trace context through `context.Context`, never
  through global variables or struct fields. Every function that creates or
  continues a span must accept and return `context.Context`.

- **S-OTEL-08** — MUST use `otel.GetTextMapPropagator().Inject(ctx, carrier)` to
  inject trace context into outbound carriers (HTTP headers, AMQP headers,
  CloudEvent extensions) and `.Extract(ctx, carrier)` to restore it on the
  receiving side.

## Semantic Conventions

- **S-OTEL-09** — MUST use OpenTelemetry semantic convention attribute keys
  (e.g., `messaging.system`, `messaging.destination`) instead of inventing
  custom attribute names. Import from `semconv/v1.*` packages.

## Shutdown

- **S-OTEL-10** — MUST call the `TracerProvider.Shutdown()` function on
  application exit to flush pending spans. Wire this into the graceful shutdown
  sequence.

## Exporter Configuration

- **S-OTEL-11** — MUST configure the OTLP exporter endpoint via environment
  variables or config struct, never hardcoded. Use `otlptracegrpc` for gRPC
  transport; only add `WithInsecure()` when the config explicitly opts in.

## Log-Trace Correlation

- **S-OTEL-12** — MUST configure a custom `slog.Handler` (or handler wrapper)
  that extracts the trace ID and span ID from the context via
  `trace.SpanFromContext(ctx).SpanContext().TraceID()` and adds them as
  structured log attributes (e.g., `"trace_id"`, `"span_id"`). This handler
  MUST be set as the default logger (`slog.SetDefault`) at application startup,
  before any logging occurs. Without this handler, even context-aware
  `slog.*Context` calls will not include trace IDs in their output.

- **S-OTEL-13** — MUST use `slog.InfoContext`, `slog.ErrorContext`, etc.
  (context-aware variants) in all instrumented code so the `TraceHandler` from
  S-OTEL-12 can extract trace/span IDs. This rule reinforces S-GO-13 in the
  specific context of OpenTelemetry-instrumented services.
