# Git Workflow — Cross-Cutting Concern

Rules for Trunk Based Development (TBD) git workflow. Language-agnostic.
Load unconditionally or via `rules/INDEX.yaml` as a concern.

---

## Trunk Based Development

- **C-GIT-01** — MUST use a single trunk (`main`) as the source of truth.
  Trunk is always deployable. There are no long-lived `develop`, `staging`,
  or `release` branches. Environment promotion is handled by CI/CD
  pipelines, not git branches.

- **C-GIT-02** — MUST NOT create long-lived feature branches. If a feature
  takes more than a day, ship it in multiple small PRs behind a feature
  flag. Each PR is independently mergeable and deployable.

- **C-GIT-03** — MUST keep feature branches short-lived. Target 4 hours or
  less from branch creation to PR merge. A branch that lives longer than
  one working day is a branch that will cause merge pain. If the work
  takes longer, split it into smaller slices.

## Rebase Discipline

The single most important habit: rebase early, rebase often. A branch
diverges from trunk the moment you create it. Every hour without rebasing
increases the divergence.

- **C-GIT-04** — MUST rebase feature branches onto trunk before pushing.
  Never merge trunk into a feature branch — this creates merge commits
  that pollute linear history and break `git bisect`.

- **C-GIT-05** — MUST rebase at least every 2 hours of active work. The
  cadence is: create branch, work 1-2 hours, rebase, work 1-2 hours,
  rebase, push, PR.

- **C-GIT-06** — MUST use `--force-with-lease` after rebasing, never
  `--force`. The lease check verifies the remote ref has not moved since
  your last fetch, preventing accidental overwrites of a teammate's work.

- **C-GIT-07** — MUST fetch before any remote-dependent operation. Run
  `git fetch origin` before rebase, push, or comparing with trunk. Stale
  remote-tracking refs cause silent divergence.

- **C-GIT-08** — SHOULD use interactive rebase (`git rebase -i origin/main`)
  to clean up commits into logical units before opening a PR. Squash
  fixup commits, reword unclear messages, drop accidental commits.

## Branch Hygiene

- **C-GIT-09** — MUST delete feature branches after merge. Enable
  auto-delete on PR completion. Clean up local branches with
  `git branch -d <branch>` after the remote is merged.

- **C-GIT-10** — MUST NOT push directly to trunk. All changes reach trunk
  through pull requests with at least one reviewer.

## Linear History

- **C-GIT-11** — MUST maintain linear history on trunk. Use rebase and
  fast-forward merges only. Merge commits on trunk make `git log`,
  `git bisect`, and `git revert` harder to use.

- **C-GIT-12** — MUST make each commit independently reviewable and
  revertable. Do not mix unrelated changes in a single commit. A refactor,
  a bug fix, and a feature are three separate commits.

## Modern Commands

- **C-GIT-13** — MUST use modern git commands for clarity and safety:
  - `git switch -c <branch>` over `git checkout -b <branch>`
  - `git switch <branch>` over `git checkout <branch>`
  - `git restore <file>` over `git checkout -- <file>`
  - `git restore --staged <file>` over `git reset HEAD <file>`
  - `git stash push -m "description"` over bare `git stash`

## Secrets

- **C-GIT-14** — MUST NOT commit secrets (API keys, passwords, tokens,
  connection strings) to any branch. Use environment variables or a
  secrets manager. If a secret is accidentally committed, rotate it
  immediately — removing it from git history is not sufficient once
  pushed to a remote.

## Recommended Global Configuration

These settings align git defaults with trunk-based development:

```bash
git config --global pull.rebase true           # rebase on pull
git config --global fetch.prune true           # auto-prune stale refs
git config --global merge.conflictstyle zdiff3 # 3-way conflict markers
git config --global push.default current       # push only current branch
git config --global rerere.enabled true        # reuse recorded resolutions
git config --global branch.autoSetupRebase always
```
