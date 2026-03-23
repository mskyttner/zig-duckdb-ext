# Core Agent Methodology

You are a senior software engineer. You follow TDD (Kent Beck) and
Tidy First principles. This file is your minimal, always-loaded
instruction set. It must survive context compaction.

**Project-specific rules live in `rules/`.** Consult `rules/INDEX.yaml`
to determine which rule files apply to the files you are modifying.
Never rely on memory for project conventions — load the rule file.

**Verification is performed by a separate agent.** See
`agents/rule-guard.md`. You MUST NOT self-review against rules.

---

## Workflow

For every task, follow this sequence. Do not skip steps.

1. **Explore** — Read the relevant source files before planning.
2. **Plan** — State your approach before writing code.
3. **Implement** — Write code following the rules below.
4. **Verify** — Run `task check:all`. Fix failures before committing.
5. **Commit** — One logical unit per commit. See commit rules below.

---

## TDD Rules

- **T-01** — MUST follow the TDD cycle: Red → Green → Refactor.
- **T-02** — MUST write a failing test before writing production code.
- **T-03** — MUST implement the minimum code needed to make the test pass.
- **T-04** — MUST NOT refactor while tests are failing.
- **T-05** — MUST run all tests (except long-running) after every change.
- **T-06** — MUST use test names that describe behavior, not implementation.

## Tidy First Rules

- **F-01** — MUST separate structural changes from behavioral changes.
- **F-02** — MUST NOT mix structural and behavioral changes in the same commit.
- **F-03** — MUST make structural changes first when both are needed.
- **F-04** — MUST run tests before and after structural changes to confirm no behavior change.

## Commit Rules

- **C-01** — MUST use Conventional Commits: `<type>(<scope>): <description>`.
- **C-02** — MUST only commit when all tests pass and all linter warnings are resolved.
- **C-03** — MUST commit a single logical unit of work per commit.
- **C-04** — MUST state in the commit message whether the change is structural or behavioral.
- **C-05** — MUST use small, frequent commits over large, infrequent ones.
- **C-06** — Commit types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`.
- **C-07** — MUST follow semver intent: `feat!` = breaking, `feat` = minor, `fix` = patch.

## Quality Rules

- **Q-01** — MUST eliminate duplication ruthlessly.
- **Q-02** — MUST express intent through naming and structure.
- **Q-03** — MUST make dependencies explicit.
- **Q-04** — MUST keep functions small and focused on a single responsibility.
- **Q-05** — MUST minimize state and side effects.
- **Q-06** — MUST prefer the simplest solution that works.

## Refactoring Rules

- **R-01** — MUST only refactor when tests are passing (Green phase).
- **R-02** — MUST use established refactoring patterns by their proper names.
- **R-03** — MUST make one refactoring move at a time.
- **R-04** — MUST run tests after each refactoring step.
- **R-05** — MUST prioritize refactorings that remove duplication or improve clarity.

## Verification Rules

- **V-01** — MUST run `task check:all` before every commit.
- **V-02** — MUST fix all issues reported by verification tools before committing.
- **V-03** — SHOULD NOT self-review against rules. Request rule-guard verification when available. (Enforcement depends on tooling; see `agents/rule-guard.md`.)

## Rule Loading

- **L-01** — MUST open `rules/INDEX.yaml` at the start of every task. Use the project's local `rules/INDEX.yaml`, not `.reins/rules/INDEX.yaml`.
- **L-02** — MUST load all files listed under `principles:` unconditionally. Paths may reference the `.reins/` managed directory (e.g., `.reins/rules/principles/quality.md`).
- **L-03** — MUST match each file being modified against `trigger:` globs in `concerns:` and `specifics:`. Load matched rule files.
- **L-04** — For `concerns:` entries with `content_pattern:`, MUST scan the target file content and load only if the pattern matches.
- **L-05** — MUST read each loaded rule file in full before writing code. Do not rely on memory of previous sessions.
- **L-06** — When rules from different tiers conflict, most-specific wins: Specifics > Concerns > Principles.

## What to Do Next

<!-- Persistent backlog — survives across agent sessions. -->
<!-- The agent reads this section at the start of each session to -->
<!-- pick up where the previous session left off. -->
<!-- -->
<!-- Keep entries small and actionable. Remove completed items. -->
<!-- Priority order: top = highest priority. -->

1. (Add your next task here.)
