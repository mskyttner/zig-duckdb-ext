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

-- ── zig_tokenize (table function) ────────────────────────────────────────────

-- Basic CSV split
SELECT * FROM zig_tokenize('alice,bob,charlie', ',');
-- Expected: (0,'alice'), (1,'bob'), (2,'charlie')

-- Multi-char delimiter
SELECT * FROM zig_tokenize('one::two::three', '::');
-- Expected: (0,'one'), (1,'two'), (2,'three')

-- Trailing delimiter — should emit empty final token
SELECT * FROM zig_tokenize('a,b,', ',');
-- Expected: (0,'a'), (1,'b'), (2,'')

-- Leading delimiter — should emit empty first token
SELECT * FROM zig_tokenize(',a,b', ',');
-- Expected: (0,''), (1,'a'), (2,'b')

-- Consecutive delimiters — empty tokens between them
SELECT * FROM zig_tokenize('a,,b', ',');
-- Expected: (0,'a'), (1,''), (2,'b')

-- No delimiter found — single token
SELECT * FROM zig_tokenize('hello world', ',');
-- Expected: (0,'hello world')

-- Empty input — single empty token
SELECT * FROM zig_tokenize('', ',');
-- Expected: (0,'')

-- Empty delimiter — entire input as one token
SELECT * FROM zig_tokenize('hello', '');
-- Expected: (0,'hello')

-- Use in a join / subquery
SELECT t.token_pos, t.token, length(t.token) AS len
FROM zig_tokenize('the,quick,brown,fox', ',') t
WHERE length(t.token) > 3;
-- Expected: (1,'quick'), (2,'brown')

-- ── ct_add_numbers (comptime scalar) ────────────────────────────────────────

-- Basic addition
SELECT ct_add_numbers(2, 3) AS result;
-- Expected: 5

-- Negative numbers
SELECT ct_add_numbers(100, -50) AS result;
-- Expected: 50

-- Zeroes
SELECT ct_add_numbers(0, 0) AS result;
-- Expected: 0

-- NULL propagation
SELECT ct_add_numbers(NULL, 5) AS result;
-- Expected: NULL

SELECT ct_add_numbers(5, NULL) AS result;
-- Expected: NULL

-- Vectorized execution
SELECT i, ct_add_numbers(i, i * 10) AS result
FROM generate_series(1, 5) t(i);

-- Parity check: comptime matches hand-written
SELECT ct_add_numbers(i, i * 10) = zig_add_numbers(i, i * 10) AS match
FROM generate_series(1, 100) t(i)
GROUP BY match;
-- Expected: single row with match = true

-- ── ct_tokenize (comptime table function) ───────────────────────────────────

-- Basic CSV split
SELECT * FROM ct_tokenize('alice,bob,charlie', ',');
-- Expected: (0,'alice'), (1,'bob'), (2,'charlie')

-- Multi-char delimiter
SELECT * FROM ct_tokenize('one::two::three', '::');
-- Expected: (0,'one'), (1,'two'), (2,'three')

-- Trailing delimiter
SELECT * FROM ct_tokenize('a,b,', ',');
-- Expected: (0,'a'), (1,'b'), (2,'')

-- No delimiter found
SELECT * FROM ct_tokenize('hello world', ',');
-- Expected: (0,'hello world')

-- Parity check: comptime matches hand-written
SELECT ct.token_pos = hw.token_pos AND ct.token = hw.token AS match
FROM ct_tokenize('the,quick,brown,fox', ',') ct
JOIN zig_tokenize('the,quick,brown,fox', ',') hw ON ct.token_pos = hw.token_pos
GROUP BY match;
-- Expected: single row with match = true
