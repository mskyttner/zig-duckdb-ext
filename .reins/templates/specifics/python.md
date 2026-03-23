# Python — Specific Rules

These rules apply when modifying `.py` files in this project.
Loaded via `rules/INDEX.yaml` trigger: `**/*.py`.

---

## Toolchain

- **S-PY-01** — MUST use `uv` as the package manager and virtual environment tool. Do not use pip, poetry, or conda directly.
- **S-PY-02** — MUST use `ruff` for linting and formatting. Do not use flake8, black, isort, or pylint.
- **S-PY-03** — MUST use `ty` for type checking. Do not use mypy or pyright.
- **S-PY-04** — MUST declare all dependencies in `pyproject.toml`. Do not use `requirements.txt` for dependency management.

## Language

- **S-PY-05** — MUST include type annotations on all function signatures (parameters and return types).
- **S-PY-06** — MUST use `pathlib.Path` instead of `os.path` for filesystem operations.
- **S-PY-07** — MUST use context managers (`with`) for resource lifecycle (files, connections, locks).
- **S-PY-08** — MUST prefer explicit exception types over bare `except:` or `except Exception:`.
- **S-PY-09** — MUST use `dataclasses` or `pydantic` models for structured data. Do not pass raw dicts across module boundaries.
- **S-PY-10** — MUST prefer standard-library solutions (`collections`, `itertools`, `functools`) over reimplementing common patterns.

## Verification

- **S-PY-11** — MUST run `task check:all` (ruff check, ruff format, ty, unit tests) before every commit.
- **S-PY-12** — MUST fix all issues reported by `ruff` and `ty` before committing.
