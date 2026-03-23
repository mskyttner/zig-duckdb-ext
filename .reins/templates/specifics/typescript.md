# TypeScript — Specific Rules

These rules apply when modifying `.ts` and `.tsx` files in this project.
Loaded via `rules/INDEX.yaml` trigger: `**/*.{ts,tsx}`.

---

## Language

- **S-TS-01** — MUST enable `strict: true` in `tsconfig.json`. Do not weaken strictness with `any` casts unless justified in a comment.
- **S-TS-02** — MUST prefer `interface` for object shapes and `type` for unions, intersections, and mapped types.
- **S-TS-03** — MUST use explicit return types on exported functions and public methods.
- **S-TS-04** — MUST use `unknown` instead of `any` when the type is not known. Narrow with type guards before use.
- **S-TS-05** — MUST use `readonly` for properties and parameters that should not be reassigned.
- **S-TS-06** — MUST prefer `const` over `let`. Never use `var`.
- **S-TS-07** — MUST handle `Promise` rejections explicitly. No unhandled promises or fire-and-forget async calls.
- **S-TS-08** — MUST use `Error` subclasses for domain errors. Do not throw strings or plain objects.

## Verification

- **S-TS-09** — MUST run `task check:all` (lint, typecheck, unit tests) before every commit.
- **S-TS-10** — MUST fix all issues reported by the linter and type checker before committing.
