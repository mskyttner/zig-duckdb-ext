# Autopilot

This file defines the goal, constraints, and iteration protocol for
autonomous agent sessions. When the agent is given this file as its
prompt, it operates in a self-directed loop until the goal is met or
the constraints are exhausted.

**This file is project-owned.** Reins creates it once during `reins init`.
Edit it freely to match your project's domain and workflow.

---

## Goal

Build a working DuckDB extension in Zig that:
1. Compiles as a shared library loadable by DuckDB v1.5.x via `LOAD`.
2. Registers at least one custom scalar function callable from SQL.
3. Passes both unit tests (`zig build test`) and integration tests
   (`task test:integration` — loads into DuckDB and runs SQL queries).

## Constraints

1. **Fixed boundaries** — The extension MUST use DuckDB's C extension
   API (`duckdb.h`). Do not vendor or modify DuckDB source code.

2. **Allowed changes** — All files under `src/`, `build.zig`,
   `build.zig.zon`, and `Taskfile.yml` may be created or modified.

3. **Time/resource budget** — Do not add external Zig dependencies
   beyond the standard library and DuckDB headers. Keep the dependency
   footprint minimal.

4. **Quality gate** — `task check:all` MUST pass after every change.

## Iteration Protocol

For each iteration:

1. **Hypothesize** — State what you will change and the expected effect.
2. **Implement** — Make the smallest change that tests the hypothesis.
3. **Verify** — Run `task check:all`. If it fails, fix or revert before
   proceeding.
4. **Evaluate** — Did the change move toward the goal? Record the result.
5. **Decide** — Continue with the next hypothesis, or stop if the goal
   is met or no viable hypotheses remain.

## Success Criteria

- `zig build` produces a `.duckdb_extension` shared library without errors.
- `zig build test` passes all unit tests.
- `task test:integration` loads the extension into DuckDB and successfully
  executes a SQL query using a Zig-implemented function.
- Zero compiler warnings.

## Notes

- If an iteration fails (tests break, build errors), revert to the last
  known-good state before trying a new approach.
- Prefer small, reversible changes over large speculative rewrites.
- The agent SHOULD consult `AGENTS.md` rules throughout — autopilot does
  not exempt the agent from TDD, commit discipline, or quality rules.
