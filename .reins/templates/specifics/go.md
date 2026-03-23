# Go — Specific Rules

These rules apply when modifying `.go` files in this project.
Loaded via `rules/INDEX.yaml` trigger: `**/*.go`.

**Minimum version: Go 1.26+.** The `go.mod` directive is the single
source of truth. All code MUST compile and pass `go vet` with the
declared toolchain version.

---

## Language

- **S-GO-01** — MUST use the Go toolchain version declared in `go.mod`.
- **S-GO-02** — MUST use generics for reusable algorithms and types where they make code clearer.
- **S-GO-03** — MUST wrap errors with `%w` and check with `errors.Is` / `errors.As`. Prefer `errors.AsType[T]()` (Go 1.26) over `errors.As` when the target is a concrete type. Use `errors.Join` when composing multiple errors.
- **S-GO-04** — MUST pass `context.Context` explicitly for cancellation and timeouts. Never store it in a struct.
- **S-GO-05** — MUST prefer small, well-named helper functions over inline repetition. Reuse existing `min`/`max` builtins or standard-library equivalents before adding new ones.
- **S-GO-06** — MUST use the appropriate loop form: `for i := range n` when iterating a count; `for _, v := range collection` when iterating elements.
- **S-GO-07** — MUST favor standard-library helpers (`time.Now().UnixMilli()`, `net/url.URL.Redacted()`, etc.) over reimplementing common behavior.
- **S-GO-08** — MUST format all code with `gofmt` and organize imports with `goimports`.
- **S-GO-09** — MUST pass `golangci-lint` with zero warnings before committing.

## Modernization (Go 1.22–1.26)

These rules enforce idiomatic patterns available in the minimum Go
version. Run `go fix ./...` (Go 1.26 modernizer) to auto-apply many
of these.

- **S-GO-20** — MUST run `go fix ./...` as part of the quality gate. The
  Go 1.26 modernizer rewrites legacy patterns automatically.
- **S-GO-21** — MUST use range-over-integer (`for i := range n`) instead
  of C-style `for i := 0; i < n; i++` when the loop body does not
  modify the index variable.  *(Go 1.22)*
- **S-GO-22** — MUST use enhanced `net/http.ServeMux` method-and-path
  patterns (e.g. `"GET /users/{id}"`) instead of manual method checks
  inside handlers.  *(Go 1.22)*
- **S-GO-23** — MUST use `errors.AsType[T]()` for type-safe error
  unwrapping instead of declaring a variable and calling `errors.As`.
  *(Go 1.26)*
- **S-GO-24** — MUST use `new(expr)` to create a pointer to a computed
  or literal value (e.g. `new(42)`, `new("default")`) instead of
  helper functions or address-of-local patterns.  *(Go 1.26)*
- **S-GO-25** — MUST use iterator-based helpers from `slices`, `maps`,
  and `strings` packages (`slices.All`, `slices.Collect`,
  `strings.Lines`, `strings.SplitSeq`, etc.) instead of
  hand-rolled loops where they improve clarity.  *(Go 1.23–1.24)*
- **S-GO-26** — MUST use `tool` directives in `go.mod` for executable
  dependencies instead of the `tools.go` blank-import pattern.
  *(Go 1.24)*
- **S-GO-27** — MUST use `testing.B.Loop()` for benchmarks instead of
  `for i := 0; i < b.N; i++` or `for range b.N`.  *(Go 1.24)*
- **S-GO-28** — MUST use `sync.WaitGroup.Go()` to spawn goroutines
  tracked by a WaitGroup instead of manual `wg.Add(1)` /
  `go func() { defer wg.Done(); ... }()`.  *(Go 1.25)*
- **S-GO-29** — MUST use `testing/synctest` for testing concurrent code
  with deterministic fake clocks instead of `time.Sleep` or polling
  loops in tests.  *(Go 1.25)*
- **S-GO-30** — MUST NOT use deprecated stdlib APIs when a modern
  replacement exists. Examples:
  - `math/rand` → `math/rand/v2`  *(Go 1.22)*
  - `runtime.SetFinalizer` → `runtime.AddCleanup`  *(Go 1.24)*
  - `io/ioutil` → `io` / `os` equivalents  *(deprecated since Go 1.16)*
- **S-GO-31** — SHOULD use `encoding/json` `omitzero` struct tag for
  zero-value omission instead of pointer-to-optional fields when the
  zero value is semantically absent.  *(Go 1.24)*

## Logging

- **S-GO-12** — MUST use `log/slog` for all application logging. No
  `fmt.Println`, `fmt.Printf`, `log.Print*`, or third-party loggers (`logrus`,
  `zap`, `zerolog`) for application-level output. The only exception is
  `log.Fatal` in `main()` for startup failures before `slog` is initialized.

- **S-GO-13** — MUST use context-aware slog variants (`slog.InfoContext`,
  `slog.WarnContext`, `slog.ErrorContext`, `slog.DebugContext`) whenever a
  `context.Context` is in scope. Never use the context-free variants
  (`slog.Info`, `slog.Warn`, `slog.Error`, `slog.Debug`) outside of `main()`
  or top-level initialization where no context exists. This ensures trace IDs
  and other context-carried metadata flow into every log record.

## CLI (Cobra)

- **S-GO-40** — MUST use `cobra` for CLI command structure. Define each
  command as a separate `*cobra.Command` variable or function. Register
  subcommands via `AddCommand` in an `init()` or explicit wiring function.
- **S-GO-41** — MUST use `cobra` flag binding (`cmd.Flags()`,
  `cmd.PersistentFlags()`) for all CLI options. Do not use `flag` package
  or manual `os.Args` parsing alongside Cobra.
- **S-GO-42** — MUST set `Use`, `Short`, and `Long` fields on every
  `cobra.Command`. The `Use` field MUST follow the pattern
  `"verb [flags] [args]"`. Include `Example` when the command has
  non-obvious usage.
- **S-GO-43** — MUST wire persistent flags (e.g., `--verbose`, `--output`)
  on the root command. Use `PersistentPreRunE` for shared setup
  (logger initialization, config loading) that all subcommands inherit.
- **S-GO-44** — MUST use `RunE` (not `Run`) for command execution to
  propagate errors up the call chain. Handle the error in `main()` and
  exit with a non-zero code.
- **S-GO-45** — MUST place each subcommand in its own file under `cmd/`
  (e.g., `cmd/serve.go`, `cmd/migrate.go`). Keep `cmd/root.go` minimal --
  only root command definition, persistent flags, and `PersistentPreRunE`.

## Verification

- **S-GO-10** — MUST run `task check:all` (format, fix, lint, unit tests) before every commit.
- **S-GO-11** — MUST fix all issues reported by `gofmt`, `goimports`, and `golangci-lint` before committing.
