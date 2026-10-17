# Vendored: gld-arrow-zig 0.2.0

Upstream: https://github.com/leo-gan/gld-arrow-zig (commit `9b3d8948747d761e748bdd95f7abcc796dcec07a`, MIT, see LICENSE).
Only `src/`, `testdata/` and `LICENSE` are copied.

Upstream targets Zig 0.16; this repository builds with 0.17, which rejects `[_]T{x} ** N` array repeats.
Patched, five lines, each replaced by `@as([N]T, @splat(x))`:

- `src/flatbuf.zig`   `.field_at = ...` (32 entries)
- `src/lz4.zig`        `var table = ...` (the hash table)
- `src/zstd.zig`      `rank`, `rank_start` (16 entries each)
- `src/roundtrip_test.zig` `var idx = ...`

Upstream's own `build.zig` (which uses `b.args`, gone in 0.17) is not copied; `build.zig` here builds the `arrow` module
from `src/arrow.zig` and runs the library's tests (`zig build test-arrow-vendor`) from this directory, because they read
`testdata/` relative to the working directory.
