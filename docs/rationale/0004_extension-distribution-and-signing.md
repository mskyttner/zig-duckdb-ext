# 0004 — Extension Distribution and Signing

## Status

Proposed

## Context

This project has no distribution mechanism yet: `zig build ext`/`zig
build cross` produce `.duckdb_extension` files locally, but there's no
way for anyone outside this machine to `INSTALL`/`LOAD` them. DuckDB
supports installing from a [custom
repository](https://duckdb.org/docs/preview/extensions/extension_distribution)
— a directory tree reachable over HTTP/HTTPS/S3/local path — via
`INSTALL <name> FROM '<repository>'`. [duckdb/extension-ci-tools](https://github.com/duckdb/extension-ci-tools)
is the official tooling DuckDB's own core/community extensions use to
build and publish that tree; this ADR looks at how much of it applies to
a Zig-built, non-CMake extension, and recommends the simplest path that
actually gets this extension installable from a plain `git clone`-able
GitHub repo.

### What a custom repository needs (confirmed against the docs)

```
base_repository_path_or_url
└── v1.2.0                          # DuckDB version this binary targets
    └── linux_amd64                 # one of the 6 official platform names
        └── zig_ext.duckdb_extension   (or .duckdb_extension.gz)
```

`INSTALL zig_ext FROM 'https://.../'` looks for `zig_ext.duckdb_extension.gz`
first, falling back to the uncompressed file. HTTPS/S3 sources need the
`httpfs` extension, which DuckDB auto-loads. Nothing in the doc requires
a specific server — any static HTTPS host serving this directory
structure works, which is why GitHub Pages (or even raw.githubusercontent.com
directly, no Pages needed) is a legitimate target, not a workaround.

### What extension-ci-tools actually provides, and why most of it doesn't apply here

Read the real scripts, not just the README, to avoid assuming:

- `scripts/append_extension_metadata.py` — writes the exact same
  footer format `src/append_metadata_main.zig` already writes (confirmed
  byte-for-byte identical earlier in this branch's history, independent
  of this ADR). **Nothing to adopt here — already done, already verified.**
- **Signing is a separate step**, not part of metadata appending:
  `extension-upload-single.sh` (in DuckDB core, not extension-ci-tools)
  strips the trailing 256-byte signature placeholder, hashes the
  remaining bytes (`compute-extension-hash.sh`: split into 1MB chunks,
  SHA256 each chunk, SHA256 the concatenation of those digests — a
  streaming-friendly composite hash, not a single whole-file hash), then
  `openssl pkeyutl -sign -inkey <private_key.pem> -pkeyopt digest:sha256`
  over that composite hash, producing exactly 256 bytes (an RSA-2048
  signature) written into the footer's signature field. If no signing
  key is supplied, it defaults to 256 zero bytes — unsigned, exactly
  what this project already produces.
- **Verification is symmetric** (`verify-extension-signing.sh`): same
  hash, `openssl pkeyutl -verify -pubin` against a public key file.
  DuckDB's own loader does the equivalent check at `LOAD` time against
  **its own compiled-in set of trusted public keys** — there is no
  documented mechanism, in the distribution docs or in these scripts, for
  a user's DuckDB install to trust an arbitrary third party's public key
  at runtime. **Signing this extension with our own key would prove
  integrity (the binary wasn't tampered with in transit) but would NOT
  make a stock DuckDB load it without `-unsigned`/
  `allow_unsigned_extensions=true`** — that only happens today via the
  official [community-extensions](https://github.com/duckdb/community-extensions)
  program, where DuckDB's own CI rebuilds the extension from source and
  re-signs it with DuckDB's own key after a review/merge. This is worth
  stating plainly since it's easy to assume self-signing solves the
  `-unsigned` requirement — it doesn't, independent of how simple or
  elaborate the signing setup is.
- **The build tooling assumes CMake or a Makefile wrapping a C/C++
  toolchain.** The `C API` usage example
  ([odbc-scanner](https://github.com/duckdb/odbc-scanner)) still wires in
  via `extension-ci-tools/makefiles/c_api_extensions/*.Makefile`, calling
  `make debug`/`make release` — a GNU Make + C compiler pipeline. There is
  no Zig-targeted path. Shoehorning `zig build` to satisfy that Makefile
  contract would be more complex than just writing our own, much smaller
  GitHub Actions workflow calling `zig build cross` directly — this
  project already *has* the cross-build step (see the "Version × platform
  build matrix" section of `docs/v2-migration-plan.md`); CMake/Make adds
  nothing we don't already have.
- `_extension_distribution.yml` (the one reusable CI workflow the
  README actually documents) builds and tests across the official
  platform matrix, but again assumes the Makefile/CMake build path.
  `deploy_artifacts.py` + `extension-upload-single.sh` upload to an
  **S3 bucket** (via `rclone`, AWS credentials required) — appropriate
  for DuckDB's own officially-hosted extensions, unnecessary machinery
  for a project that just needs a public HTTPS URL.

## Decision

Don't adopt extension-ci-tools' Make/CMake/S3 pipeline — it solves
problems this project doesn't have (a C/C++ build needing a shared build
system across dozens of DuckDB-maintained extensions; S3-hosted official
distribution at DuckDB's own scale) while adding real new dependencies
(Make, a C toolchain shim, AWS credentials) this project's Zig-native
build doesn't need. Instead:

1. **Keep the existing `zig build cross` output format as-is** — it
   already produces exactly what `INSTALL ... FROM` needs per-platform,
   and the metadata footer is already independently verified correct.
2. **Add a small, project-specific GitHub Actions workflow**, triggered
   on a tagged release, that: runs `zig build cross` (plus the host
   build for whatever `cross_targets` doesn't cover), `gzip`s each
   `.duckdb_extension` file, and arranges them into
   `<duckdb-version>/<platform>/zig_ext.duckdb_extension.gz` under a
   repo-relative `dist/` (or similar) directory.
3. **Publish that directory tree via GitHub Pages** from the same repo
   (either the `gh-pages` branch or a `docs/`-style Pages source,
   whichever this org's Pages settings prefer) — zero additional
   infrastructure, a stable `https://<org>.github.io/<repo>/` URL, no S3
   bucket or AWS credentials needed. `INSTALL zig_ext FROM
   'https://<org>.github.io/<repo>/';` then works for anyone, from a
   plain public URL.
4. **Leave the extension unsigned** (the existing all-zero signature
   footer) and document that users need
   `SET allow_unsigned_extensions=true;` (or the CLI's `-unsigned` flag)
   — exactly the flag this project's own test files and manual testing
   already rely on throughout this branch, so nothing new to explain.
   Self-signing with a project-generated RSA key is a **later, optional**
   addition purely for tamper-evidence (a security-conscious user could
   verify the signature against a published public key before loading),
   not a way to avoid `-unsigned` — don't build or document it as if it
   were.
5. **Treat the official community-extensions program as a separate,
   later decision, not part of this one.** Submitting there would
   require wiring into the Make/CMake build contract this ADR just
   decided to skip (their CI rebuilds from source, it doesn't accept
   pre-built binaries), gets reviewed on DuckDB's own timeline, and nets
   `INSTALL zig_ext;` with no `FROM`/`-unsigned` needed at all. Worth
   doing once this extension is mature enough to be worth that process,
   not before.

## Consequences

- Distribution becomes achievable with a GitHub Actions workflow this
  project fully owns and can keep in lockstep with `zig build cross`,
  rather than a second, parallel Make-based build path that would drift
  from the real one.
- Anyone can `INSTALL zig_ext FROM 'https://.../'` with `-unsigned` set,
  today, once the workflow + Pages are set up — no AWS account, no
  DuckDB-team review, no CMake.
- The `-unsigned` requirement is a permanent fact of this distribution
  path unless/until this extension goes through community-extensions —
  stated here so it isn't rediscovered as a surprise or mistaken for a
  bug in the signing setup.
- This is scoped to the real v1 extension (the one `zig build cross`
  already targets) — the parallel v2 extension stays an unreleased,
  unpublished prototype until DuckDB 2.0 actually ships, consistent with
  `docs/v2-migration-plan.md`'s "parallel artifact, not replace" stance.
- Not yet implemented: this ADR records the decision; the actual
  `.github/workflows/*.yml` and Pages setup are a follow-up, since
  publishing a public URL and enabling Pages are visible, externally-
  reachable changes worth doing deliberately rather than as a side
  effect of writing this document.
