# Rust — Specific Rules

These rules apply when modifying `.rs` files in this project.
Loaded via `rules/INDEX.yaml` trigger: `**/*.rs`.

**Minimum version: Rust 1.94+ (edition 2024).** The `Cargo.toml`
`rust-version` field is the single source of truth. All code MUST compile
and pass `cargo clippy` with the declared MSRV.

---

## Language

- **S-RS-01** — MUST use Rust edition 2024 as declared in `Cargo.toml`. Use edition 2024 idioms throughout.
- **S-RS-02** — MUST use `Result<T, E>` for fallible operations. Propagate errors with `?`; do not `.unwrap()` or `.expect()` outside of tests.
- **S-RS-03** — MUST use `anyhow::Result` and `anyhow::Context` for application error types. Use `thiserror` only for library crate error enums exposed in the public API. Do not implement `std::error::Error` manually unless justified.
- **S-RS-04** — MUST prefer borrowing (`&T`, `&mut T`) over cloning. Clone only when ownership transfer is required.
- **S-RS-05** — MUST use `clippy` at the `pedantic` lint level. Suppress individual lints with `#[allow(...)]` and a justification comment.
- **S-RS-06** — MUST format all code with `rustfmt`. Do not use `#[rustfmt::skip]` without justification.
- **S-RS-07** — MUST use `unsafe` only when strictly necessary. Each `unsafe` block MUST have a `// SAFETY:` comment explaining the invariant.
- **S-RS-08** — MUST prefer iterator combinators (`.map`, `.filter`, `.collect`) over manual loops when they improve clarity.
- **S-RS-09** — MUST use `#[must_use]` on functions whose return value should not be silently discarded.

## Modernization (Rust 1.80–1.94)

These rules enforce idiomatic patterns available in the minimum Rust
version. Prefer modern Rust constructs over legacy patterns.

- **S-RS-20** — MUST use `LazyLock` and `LazyCell` (stable since 1.80) instead of `lazy_static!` or `once_cell::sync::Lazy`. Remove `lazy_static` and `once_cell` dependencies when migrating.
- **S-RS-21** — MUST use `#[diagnostic::on_unimplemented]` (stable since 1.78) to provide clear error messages on trait bounds failures in library crates.
- **S-RS-22** — MUST use `impl Trait` in return position for trait methods and `async fn` in traits (stable since 1.75) instead of `Box<dyn Future>` or `#[async_trait]`. Remove `async-trait` dependency when migrating.
- **S-RS-23** — MUST use `let ... else` (stable since 1.65) for early returns on pattern match failure instead of `match` + single-arm + `return`/`continue`.
- **S-RS-24** — MUST NOT use deprecated patterns:
  - `lazy_static!` → `std::sync::LazyLock` *(1.80)*
  - `#[async_trait]` → native `async fn` in traits *(1.75)*
  - `once_cell` crate → `std::sync::OnceLock` / `std::cell::OnceCell` *(1.70)*

## Error Handling (anyhow)

- **S-RS-30** — MUST use `anyhow::Result<T>` as the return type for application functions. Use `.context("descriptive message")` or `.with_context(|| format!(...))` to wrap errors with actionable context.
- **S-RS-31** — MUST use `anyhow::bail!` for early error returns instead of `return Err(anyhow!(...))`.
- **S-RS-32** — MUST use `anyhow::ensure!` for precondition checks instead of `if !cond { bail!(...) }`.
- **S-RS-33** — MUST downcast with `.downcast_ref::<ConcreteError>()` when matching specific error types from anyhow errors. Do not pattern-match anyhow errors directly.

## Observability (tracing)

- **S-RS-40** — MUST use the `tracing` crate for structured logging and diagnostics. Do not use `log`, `env_logger`, `println!`, or `eprintln!` for application-level output.
- **S-RS-41** — MUST use `#[tracing::instrument]` on public functions and async entry points. Set `skip` for large/non-Display arguments and `err` for fallible functions.
- **S-RS-42** — MUST use structured fields in tracing events: `tracing::info!(user_id = %id, "request processed")` instead of `tracing::info!("request processed for {}", id)`.
- **S-RS-43** — MUST initialize `tracing-subscriber` with `EnvFilter` for runtime log level control via `RUST_LOG`.

## Async Runtime (tokio)

- **S-RS-50** — MUST use `tokio` as the async runtime. Use `#[tokio::main]` for the entry point and `#[tokio::test]` for async tests.
- **S-RS-51** — MUST NOT block the tokio runtime with synchronous I/O or CPU-bound work. Use `tokio::task::spawn_blocking` for blocking operations and `tokio::task::block_in_place` only when justified.
- **S-RS-52** — MUST use `tokio::select!` for concurrent branch selection. Always include a cancellation-safe note when using `select!` with stateful futures.
- **S-RS-53** — MUST prefer `tokio::sync` primitives (`Mutex`, `RwLock`, `mpsc`, `oneshot`, `watch`, `broadcast`) over `std::sync` equivalents when the lock guard crosses an `.await` point.
- **S-RS-54** — MUST use `tokio::signal` for graceful shutdown. Wire `ctrl_c()` or signal handlers into the application lifecycle.

## Web (axum)

- **S-RS-60** — MUST use `axum` for HTTP services. Prefer axum's extractor pattern (`Path`, `Query`, `Json`, `State`) over manual request parsing.
- **S-RS-61** — MUST use `axum::extract::State` with a shared `AppState` struct (wrapped in `Arc`) for dependency injection. Do not use global mutable state.
- **S-RS-62** — MUST implement `IntoResponse` for custom error types to control HTTP status codes and response bodies. Do not leak internal error details in responses.
- **S-RS-63** — MUST use `tower` middleware layers for cross-cutting concerns (tracing, CORS, timeout, rate limiting). Register them via `Router::layer`.
- **S-RS-64** — MUST use axum's `Router::nest` for route grouping and `Router::merge` for composing sub-routers. Keep route definitions close to their handler modules.

## TUI (ratatui)

- **S-RS-70** — MUST use `ratatui` with the `crossterm` backend for terminal UI. Do not mix backends within the same application.
- **S-RS-71** — MUST separate application state, event handling, and rendering into distinct modules. Follow the Model-View-Update (Elm architecture) pattern: state mutation in the update step, pure rendering in the view step.
- **S-RS-72** — MUST restore the terminal to its original state on both normal exit and panic. Use a panic hook or `Drop` impl to call `disable_raw_mode()` and `LeaveAlternateScreen`.
- **S-RS-73** — MUST use `ratatui::layout::Layout` with `Constraint` arrays for responsive widget positioning. Do not hardcode absolute positions.
- **S-RS-74** — MUST keep the render function (`draw` / `render_widget`) free of I/O and side effects. All state changes happen in the event loop, not during rendering.

## Verification

- **S-RS-10** — MUST run `task check:all` (fmt, clippy, test) before every commit.
- **S-RS-11** — MUST fix all warnings reported by `cargo clippy -- -D warnings` before committing.
