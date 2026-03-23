# Principles — Universal Quality Rules

These rules apply to every file modification, regardless of language
or framework. Loaded unconditionally via `rules/INDEX.yaml`.

---

- **P-01** — MUST handle errors explicitly. Never silently ignore an
  error return value, exception, or rejected promise.

- **P-02** — MUST keep functions focused on a single responsibility.
  If a function does two things, split it.

- **P-03** — MUST make dependencies explicit. No hidden coupling through
  global state, ambient singletons, or import side effects.

- **P-04** — MUST NOT hardcode secrets, credentials, URLs, or
  environment-specific values. Use configuration or environment variables.

- **P-05** — MUST name things for what they represent, not how they are
  implemented. Prefer `userCount` over `hashMapSize`.

- **P-06** — MUST NOT duplicate logic. If the same behavior exists in
  two places, extract it into a shared unit and reference it.

- **P-07** — MUST keep public interfaces small. Expose the minimum
  necessary; keep implementation details private.

- **P-08** — MUST NOT introduce a dependency without justification. Each
  new dependency is a maintenance and security liability.
