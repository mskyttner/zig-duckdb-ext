# badgerDB — Specific Rules

These rules apply when modifying Go files that use badgerDB.
Loaded via `rules/INDEX.yaml` trigger: `**/*.go` with
`content_pattern: "dgraph-io/badger"`.

---

- **S-BADGER-01** — MUST use badgerDB's native types and operations for key-value work. Do not wrap with unnecessary abstractions.
- **S-BADGER-02** — MUST handle badgerDB connection lifecycle properly (open, close, garbage collection).
- **S-BADGER-03** — MUST propagate errors from badgerDB operations without swallowing them.
