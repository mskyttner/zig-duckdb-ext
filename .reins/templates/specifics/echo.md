# Echo Framework — Specific Rules

These rules apply when modifying Go files that use the Echo HTTP framework.
Loaded via `rules/INDEX.yaml` trigger: `**/*.go` with
`content_pattern: "labstack/echo"`.

---

- **S-ECHO-01** — MUST use Echo's built-in error handler (`e.HTTPErrorHandler`) for centralized error responses.
- **S-ECHO-02** — MUST follow Echo routing conventions: one handler function per HTTP method per route.
- **S-ECHO-03** — MUST use middleware for cross-cutting concerns (logging, recovery, CORS). Do not inline these in handlers.
- **S-ECHO-04** — MUST return consistent JSON response formats from all handlers.
