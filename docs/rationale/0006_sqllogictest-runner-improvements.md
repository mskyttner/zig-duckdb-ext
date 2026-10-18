# 0006 — Improvements to the SQL test runner

## Status

Proposed. Nothing in this document is implemented. The observations come from writing about 900 test blocks (four suites) against the
runner (`src/sqllogictest_main.zig`, 418 lines); the proposals are ordered by how much each would have saved.

## Context

The runner compiles a whole `.test` file into one SQL script, each block followed by a sentinel query, runs it as a single
non-interactive `duckdb` process with `-jsonlines`, and splits the merged output on the sentinels. That design is simple and
fast (all four suites together run in seconds), and it needs nothing but the CLI. It also has sharp edges, and every one of them
was hit repeatedly:

1. **A `query` block whose SQL fails aborts the whole run.** The error is not a JSON row, `extractJsonRowValues` returns
   `MalformedJsonLine`, and the runner exits with a stack trace and no report of the other blocks. It happened for every typo
   in a query; the cause had to be found by running the SQL in the CLI by hand.
2. **Failures name the block by its index** (`[370] query MISMATCH`), not by line. Finding block 370 of a 4,700-line file means
   counting.
3. **A crash mid-script** ends as `MarkerDesync`, with the entire output dumped and no word on which block was running. (A
   CLI that dies is not hypothetical: an extension built for another alpha crashed the CLI when loaded by hand. The runner's own
   handling of that case was read from the code, not provoked.)
4. **`statement ok` fails when the statement returns rows.** In sqllogictest the result of a `statement ok` is ignored; here a
   `SELECT * FROM stats(reset := true)` is a failure, and tests use `SELECT count(*) …` plus an expected `1` instead.
5. **A warning on stderr counts as output.** `CALL enable_logging(storage = 'memory')` makes the CLI print a warning, which fails
   the `statement ok`; the tests use `SET` instead.
6. **JSON strings are not unescaped.** A value with a quote comes out as `\"select\"`, so tests wrap queries in
   `replace(x, '"', '#')` to compare. (No existing expected value contains `\"`, so unescaping costs nothing to adopt.)
7. **Multi-column rows are flattened** into one value per line, and the types after `query` (`query IIT`) are not checked, so a
   test with the wrong number of columns reports a mismatch of the whole flattened list.
8. **No way to run part of a file**, and no per-block timing; a hung CLI hangs the build.
9. **The runner has no tests**, and its parser (`parseBlocks`, `extractJsonRowValues`) is the kind of code that gets edited on a
   whim.

## Proposals

In order; the first five are about a day together and remove most of the friction.

1. **Attribute failures to `file:line`.** Record the line of each block in `parseBlocks` and print `test/sql/x.test:812: query
   MISMATCH …`, a form editors and CI annotate as a link. Replace the `[370]` prefix.
2. **Make an erroring `query` block a failure of that block.** In JSON mode DuckDB prints an error as a JSON object with an
   `exception_type` key (and `exception_message`), unlike a row. Recognise it before parsing rows and report `query FAILED:
   <message>` for the block. The rest of the file still runs and reports.
3. **Say which block was running when the CLI died.** On `MarkerDesync`, report the last marker seen, the line and SQL of the
   block after it, and the tail of the output, not all of it. Read the CLI's output as a stream so that this is known at the
   moment of the crash, and so that a **timeout** (a configurable limit, killing the process) can name the hanging block too.
4. **Follow sqllogictest on `statement ok`.** Ignore result rows; fail on an error object, and treat other stderr lines (warnings)
   as notes printed under the block, not failures. This is what the format means; the current behaviour was a simplification.
5. **Unescape JSON strings** (`\"`, `\\`, `\uXXXX`); keep `\n` and `\t` as the two characters, as now, so that the existing
   multi-line expectations still work.
6. **Filter and fail fast.** `--only 812` (a line), `--filter text` (a substring of the SQL) and `-x` (stop at the first failure),
   passed through the build as `-Dtest-filter=…`. A 427-block file takes a few seconds to run in full; the point is not speed
   but not having to read 400 passing lines to find the one that matters.
7. **Row-wise comparison.** Check the number of columns against the types after `query`, group the expected and the actual values
   into rows, and on a mismatch print the first differing row with both sides. Support `rowsort` (sort the rows of both before
   comparing) so that a query without `ORDER BY` can be tested honestly.
8. **Per-block timing.** The sentinel queries make it cheap: print the slowest blocks of the file at the end, always, and fail
   a block that exceeds its own `--slow` limit if one is given.
9. **Unit tests for the runner**: `parseBlocks` on the directive forms, `extractJsonRowValues` on scalar rows, strings with
   escapes and nulls, `splitByMarkers` on a stream that ends early. A pure function over strings is easy to test, which is why it
   is worth doing before the edits above, not after.
10. **Nested values.** A LIST or STRUCT column is not supported today. Parse each row with `std.json` and render nested values in
    a stable text form (`[1, 2]`, `{a: 1}`), so that results of those types can be compared without `CAST(… AS VARCHAR)`.
11. **Reusable by authors.** With ADR-0005 the runner is part of the package (`addSqlLogicTests`); the directives it supports and
    those it does not (`skipif`, `onlyif`, `halt`, `loop`, regular-expression results) belong in the package README, with the
    list of differences from DuckDB's own runner, since an author will know the format from that one.

## What is not proposed

- **Replacing it with DuckDB's own Python or C++ sqllogictest.** Those need Python or a build of DuckDB; the point of this one
  is that the CLI is enough.
- **One CLI process per block.** It would isolate every block and cost a process start each (tens of milliseconds), and the
  shared state is occasionally useful (the stats functions of the pushdown recipe depend on running in one session). If isolation
  is wanted, a directive that starts a fresh process for the blocks after it (`restart`) is the smaller change.
- **Parallel files.** The suites are fast; a faster runner is not the problem.

## Order of work

Tests for the parser (9) first, then 1, 2, 3 and 4 together, then 5 and 6. Items 7 to 11 when a test needs them or when the
runner ships in the package.
