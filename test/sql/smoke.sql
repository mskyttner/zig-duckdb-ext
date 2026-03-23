-- e2e/smoke.sql — End-to-end smoke tests for zig_ext
--
-- Run via: task test:e2e
-- Requires: duckdb CLI with -unsigned flag

-- ── zig_add_numbers ──────────────────────────────────────────────────────────

-- Basic addition
SELECT zig_add_numbers(2, 3) AS result;
-- Expected: 5

-- Negative numbers
SELECT zig_add_numbers(100, -50) AS result;
-- Expected: 50

-- Zeroes
SELECT zig_add_numbers(0, 0) AS result;
-- Expected: 0

-- NULL propagation
SELECT zig_add_numbers(NULL, 5) AS result;
-- Expected: NULL

SELECT zig_add_numbers(5, NULL) AS result;
-- Expected: NULL

-- ── zig_hello ────────────────────────────────────────────────────────────────

-- Basic greeting
SELECT zig_hello('Zig') AS result;
-- Expected: Hello, Zig!

-- Empty string
SELECT zig_hello('') AS result;
-- Expected: Hello, !

-- NULL propagation
SELECT zig_hello(NULL) AS result;
-- Expected: NULL

-- ── Vectorized execution ─────────────────────────────────────────────────────

-- Multiple rows through zig_add_numbers
SELECT i, zig_add_numbers(i, i * 10) AS result
FROM generate_series(1, 5) t(i);

-- Multiple rows through zig_hello
SELECT zig_hello(name) AS greeting
FROM (VALUES ('Alice'), ('Bob'), ('Charlie')) AS t(name);
