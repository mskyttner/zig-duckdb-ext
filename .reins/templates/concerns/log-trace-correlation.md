# Log-Trace Correlation — Cross-Cutting Concern

Activated when a Go file imports `log/slog`. These rules ensure structured
logs carry distributed tracing metadata so log lines can be correlated with
spans in the tracing backend.

---

## Context-Aware Logging

- **C-LOG-01** — MUST use `slog.InfoContext`, `slog.WarnContext`,
  `slog.ErrorContext`, `slog.DebugContext` whenever a `context.Context` is
  available. Never use the bare `slog.Info`, `slog.Error`, etc. outside of
  `main()` or top-level initialization where no context exists.

- **C-LOG-02** — MUST NOT discard the `echo.Context` parameter (as `_`) in
  Echo middleware callbacks. Use `c.Request().Context()` to obtain the
  request context for logging.

## Trace-ID Enrichment

- **C-LOG-03** — MUST register a custom `slog.Handler` (or wrapping handler)
  as the default logger via `slog.SetDefault()` at application startup. This
  handler MUST extract `trace_id` and `span_id` from the span context
  (`trace.SpanFromContext(ctx).SpanContext()`) and inject them as structured
  attributes into every log record.

- **C-LOG-04** — The `TraceHandler` MUST be a thin wrapper that delegates to
  an inner `slog.Handler` (e.g., `slog.NewJSONHandler`). It MUST implement
  all four `slog.Handler` interface methods (`Enabled`, `Handle`, `WithAttrs`,
  `WithGroup`) and preserve the wrapping in `WithAttrs`/`WithGroup` so
  trace enrichment is not lost when sub-loggers are derived.

- **C-LOG-05** — When no active span exists in the context, the handler MUST
  NOT inject empty or zero-value `trace_id`/`span_id` attributes. Only add
  them when `SpanContext.HasTraceID()` / `SpanContext.HasSpanID()` returns
  true.

## Verification

- **C-LOG-06** — MUST verify log-trace correlation with a unit test: create a
  real span, log via `slog.InfoContext(ctx, ...)`, and assert that the JSON
  output contains the expected `trace_id` and `span_id` values.

- **C-LOG-07** — MUST verify the absence case: log without a span context and
  assert that `trace_id` and `span_id` do NOT appear in the output.
