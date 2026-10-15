# 0004 — Extension Distribution and Signing

## Status

Accepted — implemented and verified end-to-end (`.github/workflows/release.yml`,
live at https://mskyttner.github.io/zig-duckdb-ext/).

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
  hash, `openssl pkeyutl -verify -pubin` against a public key file. ~~DuckDB's
  own loader does the equivalent check at `LOAD` time against its own
  compiled-in set of trusted public keys — there is no documented
  mechanism for a user's DuckDB install to trust an arbitrary third
  party's public key at runtime.~~ **This was true for v1, and is
  wrong as a blanket statement — v2.0 adds exactly this mechanism.
  See "A real, confirmed exception: v2's `CREATE EXTENSION REPOSITORY`"
  below, found and verified live after this ADR's first draft.** For
  v1, the only way to get a custom key trusted without `-unsigned` is
  still the official [community-extensions](https://github.com/duckdb/community-extensions)
  program (DuckDB's CI rebuilds from source and re-signs with DuckDB's
  own key after review) — that part stands.
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

### A real, confirmed exception: v2's `CREATE EXTENSION REPOSITORY`

Prompted by [duckdb-wasm#2262](https://github.com/duckdb/duckdb-wasm/issues/2262),
which mentions in passing that "DuckDB v2.0 external extension
repositories let an organisation host and sign its own extensions."
Verified this is real, not aspirational, by reading DuckDB core's actual
source (`extension_repository_manager.{hpp,cpp}`,
`test/sql/extensions/extension_repositories.test`) and then testing it
live against both runtimes this branch has on hand:

- **`v1.5.6`: the feature does not exist.** `CREATE EXTENSION REPOSITORY`
  is a parser error; `allow_extension_repositories` isn't a recognized
  setting.
- **`v2.0.0-alpha46057`: the feature is real and already present**,
  confirmed live:
  ```sql
  SET allow_extension_repositories='allowed';   -- opt-in; a one-way ratchet at runtime
  CREATE EXTENSION REPOSITORY myrepo WITH PREFIX 'https://example.com/repo';
  -- with no USING PUBLIC KEY(S) clause, DuckDB fetches and pins the key(s)
  -- itself from <prefix>/.well-known/duckdb-extension-repo.json, a JSON
  -- file of the form {"signature_keys": ["-----BEGIN PUBLIC KEY-----..."]}
  -- (one or more PEM keys, enabling rotation). The pinned repo + keys are
  -- stored locally (~/.duckdb/extension_repositories/myrepo.duckdb_extension.repo.json)
  -- and SELECT * FROM duckdb_extension_repositories() lists the fingerprints.

  -- Alternative, also confirmed live: skip the network fetch entirely by
  -- supplying the PEM (or its base64-encoded body) directly —
  -- CREATE EXTENSION REPOSITORY myrepo WITH PREFIX 'https://example.com/repo'
  --     USING PUBLIC KEY '-----BEGIN PUBLIC KEY----- ...';
  -- verified this succeeds even against a prefix URL that serves nothing
  -- at all (no .well-known fetch attempted when a key is supplied inline).
  -- duckdb_extension_repositories()'s real columns (confirmed via
  -- DESCRIBE, not assumed): repository_name, prefix, type, key_fingerprints
  -- (VARCHAR[], formatted "sha256:<hex>", NULL for DuckDB's own built-in
  -- repos), public_keys. `type` is 'CORE'/'COMMUNITY' for the three
  -- built-in repos (core, core_nightly, community) and 'USER_PROVIDED'
  -- for anything added via CREATE EXTENSION REPOSITORY.
  ```
  Reproduced the whole flow end to end: generated an RSA keypair
  (`openssl genrsa`/`openssl rsa -pubout`), published a `.well-known/
  duckdb-extension-repo.json` alongside a local repo directory, opted in
  and created the repository — DuckDB correctly fetched and pinned the
  key, with the fingerprint it reported matching an independent
  `openssl dgst -sha256` of the key file.

  **Earlier attempts to sign the actual extension binary using the
  v1-documented algorithm failed** — `"its signature is either missing
  or invalid"` — even after independently confirming the signature was
  cryptographically valid against the key (`openssl pkeyutl -verify`)
  and, on 2026-10-15, after explicitly ruling out
  `allow_extension_repositories` not being `'allowed'` at `LOAD` time
  as the cause. That left a real, open question: was v2's loader
  actually computing or checking something different?

  **Resolved, 2026-10-15, by reading the actual verification code**
  (`src/main/extension/extension_load.cpp`,
  `third_party/mbedtls/mbedtls_wrapper.cpp` at the pinned commit): the
  hash algorithm (1MiB chunks hashed via an incremental SHA256 state,
  the raw 32-byte digests concatenated and SHA256'd once more — exactly
  the documented v1 algorithm, confirmed byte-for-byte against
  `FOOTER_SIZE=512`/`SIGNATURE_SIZE=256`) and the signature scheme
  (`mbedtls_pk_verify` with `MBEDTLS_MD_SHA256`, the same standard
  PKCS#1v1.5-with-SHA256-OID scheme `openssl pkeyutl -pkeyopt
  digest:sha256` already uses) are both exactly as documented — **the
  crypto was never the problem**. The actual cause, found in
  `ExtensionHelper::TryInitialLoad`'s own comments: a **bare** `LOAD
  <name>` (no `FROM <repo>`) — "which is also how autoloading loads —
  trusts only the fixed core/community keys, never a user-provided
  repository's own keys", by deliberate design, regardless of what a
  `.info` sidecar says the extension's real origin was. A **direct
  file-path** `LOAD '<path>'` is worse still: "extensions that are
  loaded directly have no install info: those are verified against the
  core keys" — a custom repository's key is never even considered.
  Every earlier test (in this session and the one that produced this
  ADR's first draft) used one of those two forms — neither was ever
  going to work, independent of whether the signature was correct.

  **Confirmed working, reproduced twice from a clean state with two
  different self-generated keys**: `LOAD <name> FROM <repo-name>;` —
  the explicit-origin form — succeeds and correctly registers real
  functions, with *no* `-unsigned` flag:
  ```sql
  SET allow_extension_repositories='allowed';
  CREATE EXTENSION REPOSITORY myrepo WITH PREFIX 'file:///path/to/repo'
      USING PUBLIC KEY '-----BEGIN PUBLIC KEY----- ...';
  INSTALL zig_ext_v2 FROM myrepo;
  LOAD zig_ext_v2 FROM myrepo;
  SELECT zig_hello('reproduced'), zig_add_numbers(2, 3);
  -- Hello, reproduced! | 5
  ```
  (A plain `LOAD <name>;` after this still won't trust `myrepo`'s key —
  that's the deliberate security behavior quoted above, not a bug: a
  repository merely redeploying a core-signed extension should still
  load, but one signed only by the repository's own key should not,
  unless the caller explicitly says which repository it trusts via
  `FROM`.) The `repositories/<repo-name>/` subdirectory `INSTALL FROM`
  caches into (noted as an unexplained gap in the 2026-10-15
  re-verification above) is also now explained by the same code: it's
  exactly where `ComputeLocalExtensionPath` looks when
  `expect_user_repo` is true, i.e. precisely when `FROM <user-repo>` is
  given — not a gap at all, just the other half of the same mechanism.

**What this changes for the actual decision below**: still nothing for
*today* — the real, currently-releasable v1 extension still can't use
this mechanism at all (confirmed: parser error), so the unsigned/GitHub-
Pages path remains right for distributing it now. But the future story
is now a confirmed, working mechanism, not an open question: once
DuckDB 2.0 ships and this extension's v2 port is the one being
distributed, self-hosted signing with a project-owned RSA key plus
`CREATE EXTENSION REPOSITORY ... USING PUBLIC KEY` genuinely lets users
`INSTALL`/`LOAD ... FROM <repo>` without `-unsigned` and without the
official community-extensions submission process — reproduced live,
end to end, with this project's own real `zig_ext_v2` binary. Worth
building for real once v2 ships, not before.

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
   footer) and document that users need the CLI's `-unsigned` flag (or
   the equivalent client config option set at connection/startup time —
   confirmed live that `SET allow_unsigned_extensions=true` fails at
   runtime with `"Cannot change ... while database is running"`; it's a
   startup-only option, same as `allow_extension_repositories` below) —
   exactly the flag this project's own test files and manual testing
   already rely on throughout this branch, so nothing new to explain.
   Self-signing with a project-generated RSA key remains a **later,
   optional** addition for *this v1 extension specifically* — v1 has no
   `CREATE EXTENSION REPOSITORY` mechanism at all (confirmed: parser
   error), so for v1 today a self-signature really is tamper-evidence
   only, not a way to avoid `-unsigned`. That is no longer true as a
   general statement about this project's future v2 port, though: see
   the confirmed, reproduced, working `LOAD ... FROM <repo>` mechanism
   above — a real, documented way to avoid `-unsigned` entirely once v2
   ships, worth building then.
5. **Treat the official community-extensions program as a separate,
   later decision, not part of this one.** Submitting there would
   require wiring into the Make/CMake build contract this ADR just
   decided to skip (their CI rebuilds from source, it doesn't accept
   pre-built binaries), gets reviewed on DuckDB's own timeline, and nets
   `INSTALL zig_ext;` with no `FROM`/`-unsigned` needed at all. Worth
   doing once this extension is mature enough to be worth that process,
   not before.

## Implementation notes (from actually standing this up)

- **A repository's version directory must match the installing client's
  own exact running DuckDB version, not the extension's ABI-compat
  minimum.** Confirmed live (an install against `v1.5.6` failed looking
  for a `v1.5.6` directory while the workflow published under `v1.2.0`)
  and in DuckDB's own source
  (`ExtensionHelper::GetVersionDirectoryName()` returns
  `DuckDB::LibraryVersion()` for a release build). This is a different
  thing from `target_duckdb_version` in `build.zig` (the minimum C-API
  version embedded in the extension's own metadata footer) — the
  workflow's `DUCKDB_VERSION` env var controls the *publishing* path and
  is pinned to `v1.5.6`, the latest stable release actually tested this
  session. Supporting more client versions means publishing the same
  build under more version directories (official extensions handle this
  by rebuilding/republishing per DuckDB release) — not done here, kept as
  a single pinned version for simplicity, matching the "simple and
  straightforward" goal this ADR set out with.
- **`mlugg/setup-zig@v1` can't resolve Zig 0.17.0; `@v2` can.** Not a
  Codeberg-vs-GitHub-mirror issue — [the action's own
  README](https://codeberg.org/mlugg/setup-zig#readme) says GitHub
  Actions can't use a non-GitHub-hosted action by direct URL at all
  (confirmed live: `uses: https://codeberg.org/mlugg/setup-zig@v2` fails
  with `"Unable to resolve action ..., repository not found"`), so the
  plain `github.com/mlugg/setup-zig` mirror reference is correct either
  way. The actual fix was simpler than first assumed: just the tag,
  `@v2` not `@v1`.
- **A freshly-enabled `github-pages` deployment environment has an empty
  branch/tag allowlist by default** (`custom_branch_policies: true`, no
  policies yet) — the first deploy fails with "not allowed to deploy...
  due to environment protection rules" until a policy is added (here:
  `gh api -X POST .../environments/github-pages/deployment-branch-policies
  -f name='v*' -F type=tag`, matching this workflow's own tag-based
  trigger).
- Verified past "the workflow turned green": `INSTALL zig_ext FROM
  'https://mskyttner.github.io/zig-duckdb-ext/'` followed by `LOAD
  zig_ext` against a real `v1.5.6` CLI (with `-unsigned` and `SET
  allow_extensions_metadata_mismatch=true`, consistent with everything
  else in this project) correctly ran `zig_add_numbers`/`tp_bar` end to
  end, from the actual published URL.

## Consequences

- Distribution becomes achievable with a GitHub Actions workflow this
  project fully owns and can keep in lockstep with `zig build cross`,
  rather than a second, parallel Make-based build path that would drift
  from the real one.
- Anyone can `INSTALL zig_ext FROM 'https://.../'` with `-unsigned` set,
  today, once the workflow + Pages are set up — no AWS account, no
  DuckDB-team review, no CMake.
- The `-unsigned` requirement is a permanent fact of *this v1 distribution
  path specifically* unless/until this extension goes through
  community-extensions — stated here so it isn't rediscovered as a
  surprise or mistaken for a bug in the signing setup. It is NOT a
  permanent fact of distributing this extension in general: v2's
  `CREATE EXTENSION REPOSITORY` mechanism (see above) is a real, already-
  confirmed path to self-signed, `-unsigned`-free distribution once this
  extension is built against a shipped 2.0 and the v2 signing procedure
  is worked out.
- This is scoped to the real v1 extension (the one `zig build cross`
  already targets) — the parallel v2 extension stays an unreleased,
  unpublished prototype until DuckDB 2.0 actually ships, consistent with
  `docs/v2-migration-plan.md`'s "parallel artifact, not replace" stance.
- Not yet implemented: this ADR records the decision; the actual
  `.github/workflows/*.yml` and Pages setup are a follow-up, since
  publishing a public URL and enabling Pages are visible, externally-
  reachable changes worth doing deliberately rather than as a side
  effect of writing this document.
