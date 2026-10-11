/// Unicode box-drawing connection encoding (U+2500–U+256C).
///
/// Each cell's connections are encoded as a u8:
///   bits [7:6] = U weight    bits [5:4] = D weight
///   bits [3:2] = L weight    bits [1:0] = R weight
///
/// Weight values:  0 = none   1 = thin   2 = heavy   3 = double
///
/// Compositing two cells: per-direction max (heavier weight wins).
/// Example: thin │ (0x50) merge thin ─ (0x05) → ┼ (0x55, U+253C).
const std = @import("std");
const testing = std.testing;

pub const NONE: u2 = 0;
pub const THIN: u2 = 1;
pub const HEAVY: u2 = 2;
pub const DOUBLE: u2 = 3;

// ─── Encoding helpers ─────────────────────────────────────────────────────────

/// Pack four per-direction weights into a u8.
pub fn encode(u: u2, d: u2, l: u2, r: u2) u8 {
    return (@as(u8, u) << 6) | (@as(u8, d) << 4) | (@as(u8, l) << 2) | @as(u8, r);
}

pub fn decodeU(c: u8) u2 {
    return @truncate(c >> 6);
}
pub fn decodeD(c: u8) u2 {
    return @truncate(c >> 4);
}
pub fn decodeL(c: u8) u2 {
    return @truncate(c >> 2);
}
pub fn decodeR(c: u8) u2 {
    return @truncate(c);
}

/// Merge two connection encodings: per-direction max so heavier weight wins.
/// thin ∪ heavy = heavy; thin ∪ thin = thin; none ∪ thin = thin.
pub fn merge(a: u8, b: u8) u8 {
    return encode(
        @max(decodeU(a), decodeU(b)),
        @max(decodeD(a), decodeD(b)),
        @max(decodeL(a), decodeL(b)),
        @max(decodeR(a), decodeR(b)),
    );
}

/// Override-merge: for each direction, use the incoming weight if it is > 0
/// (the new layer actively touches that direction), otherwise keep the existing
/// weight.  Used as a fallback when max-merge produces a gap combination that
/// has no Unicode glyph — e.g. ╚ (double U+R) overridden by ─ (thin L+R)
/// yields ╨ (double U, thin H) rather than a coverage hole.
pub fn overrideMerge(existing: u8, incoming: u8) u8 {
    return encode(
        if (decodeU(incoming) > 0) decodeU(incoming) else decodeU(existing),
        if (decodeD(incoming) > 0) decodeD(incoming) else decodeD(existing),
        if (decodeL(incoming) > 0) decodeL(incoming) else decodeL(existing),
        if (decodeR(incoming) > 0) decodeR(incoming) else decodeR(existing),
    );
}

// ─── Unicode lookup ───────────────────────────────────────────────────────────

/// Map a connection encoding to its Unicode box-drawing codepoint.
/// Returns ' ' for combinations that have no Unicode representation.
pub fn toChar(connections: u8) u21 {
    return CHAR_TABLE[connections];
}

/// Map a Unicode box-drawing codepoint back to its connection encoding.
/// Returns null if the codepoint is not in U+2500–U+256C.
pub fn fromChar(cp: u21) ?u8 {
    if (cp == ' ') return 0;
    for (CHAR_TABLE, 0..) |c, i| {
        if (c == cp) return @intCast(i);
    }
    return null;
}

// ─── Lookup table ─────────────────────────────────────────────────────────────
//
// Index = encode(U, D, L, R).  Space = no valid Unicode character.
//
// Thin/heavy entries cover U+2500–U+254B.
// Double entries (weight=3) cover U+2550–U+256C.

const CHAR_TABLE: [256]u21 = buildTable();

fn buildTable() [256]u21 {
    var t: [256]u21 = @splat(' ');

    // ── Single-direction stubs ─────────────────────────────────────────────
    t[encode(0, 0, 0, 1)] = '╶'; // U+2576  light right
    t[encode(0, 0, 0, 2)] = '╺'; // U+257A  heavy right
    t[encode(0, 0, 1, 0)] = '╴'; // U+2574  light left
    t[encode(0, 0, 2, 0)] = '╸'; // U+2578  heavy left
    t[encode(0, 1, 0, 0)] = '╷'; // U+2577  light down
    t[encode(0, 2, 0, 0)] = '╻'; // U+257B  heavy down
    t[encode(1, 0, 0, 0)] = '╵'; // U+2575  light up
    t[encode(2, 0, 0, 0)] = '╹'; // U+2579  heavy up

    // ── Horizontal lines (L+R) ────────────────────────────────────────────
    t[encode(0, 0, 1, 1)] = '─'; // U+2500
    t[encode(0, 0, 2, 2)] = '━'; // U+2501
    t[encode(0, 0, 1, 2)] = '╼'; // U+257C  light-left + heavy-right
    t[encode(0, 0, 2, 1)] = '╾'; // U+257E  heavy-left + light-right
    t[encode(0, 0, 3, 3)] = '═'; // U+2550  double horizontal

    // ── Vertical lines (U+D) ──────────────────────────────────────────────
    t[encode(1, 1, 0, 0)] = '│'; // U+2502
    t[encode(2, 2, 0, 0)] = '┃'; // U+2503
    t[encode(1, 2, 0, 0)] = '╽'; // U+257D  light-up + heavy-down
    t[encode(2, 1, 0, 0)] = '╿'; // U+257F  heavy-up + light-down
    t[encode(3, 3, 0, 0)] = '║'; // U+2551  double vertical

    // ── Corners: D+R  U+250C–U+250F ───────────────────────────────────────
    t[encode(0, 1, 0, 1)] = '┌'; // U+250C  all thin
    t[encode(0, 1, 0, 2)] = '┍'; // U+250D  D-thin  R-heavy
    t[encode(0, 2, 0, 1)] = '┎'; // U+250E  D-heavy R-thin
    t[encode(0, 2, 0, 2)] = '┏'; // U+250F  all heavy
    t[encode(0, 1, 0, 3)] = '╒'; // U+2552  D-thin  R-double
    t[encode(0, 3, 0, 1)] = '╓'; // U+2553  D-double R-thin
    t[encode(0, 3, 0, 3)] = '╔'; // U+2554  all double

    // ── Corners: D+L  U+2510–U+2513 ───────────────────────────────────────
    t[encode(0, 1, 1, 0)] = '┐'; // U+2510
    t[encode(0, 1, 2, 0)] = '┑'; // U+2511  D-thin  L-heavy
    t[encode(0, 2, 1, 0)] = '┒'; // U+2512  D-heavy L-thin
    t[encode(0, 2, 2, 0)] = '┓'; // U+2513
    t[encode(0, 1, 3, 0)] = '╕'; // U+2555  D-thin  L-double
    t[encode(0, 3, 1, 0)] = '╖'; // U+2556  D-double L-thin
    t[encode(0, 3, 3, 0)] = '╗'; // U+2557

    // ── Corners: U+R  U+2514–U+2517 ───────────────────────────────────────
    t[encode(1, 0, 0, 1)] = '└'; // U+2514
    t[encode(1, 0, 0, 2)] = '┕'; // U+2515  U-thin  R-heavy
    t[encode(2, 0, 0, 1)] = '┖'; // U+2516  U-heavy R-thin
    t[encode(2, 0, 0, 2)] = '┗'; // U+2517
    t[encode(1, 0, 0, 3)] = '╘'; // U+2558  U-thin  R-double
    t[encode(3, 0, 0, 1)] = '╙'; // U+2559  U-double R-thin
    t[encode(3, 0, 0, 3)] = '╚'; // U+255A

    // ── Corners: U+L  U+2518–U+251B ───────────────────────────────────────
    t[encode(1, 0, 1, 0)] = '┘'; // U+2518
    t[encode(1, 0, 2, 0)] = '┙'; // U+2519  U-thin  L-heavy
    t[encode(2, 0, 1, 0)] = '┚'; // U+251A  U-heavy L-thin
    t[encode(2, 0, 2, 0)] = '┛'; // U+251B
    t[encode(1, 0, 3, 0)] = '╛'; // U+255B  U-thin  L-double
    t[encode(3, 0, 1, 0)] = '╜'; // U+255C  U-double L-thin
    t[encode(3, 0, 3, 0)] = '╝'; // U+255D

    // ── T-junction: U+D+R  U+251C–U+2523 ─────────────────────────────────
    t[encode(1, 1, 0, 1)] = '├'; // U+251C  all thin
    t[encode(1, 1, 0, 2)] = '┝'; // U+251D  R-heavy
    t[encode(2, 1, 0, 1)] = '┞'; // U+251E  U-heavy
    t[encode(1, 2, 0, 1)] = '┟'; // U+251F  D-heavy
    t[encode(2, 2, 0, 1)] = '┠'; // U+2520  U+D heavy
    t[encode(2, 1, 0, 2)] = '┡'; // U+2521  U+R heavy
    t[encode(1, 2, 0, 2)] = '┢'; // U+2522  D+R heavy
    t[encode(2, 2, 0, 2)] = '┣'; // U+2523  all heavy
    t[encode(1, 1, 0, 3)] = '╞'; // U+255E  V-thin  R-double
    t[encode(3, 3, 0, 1)] = '╟'; // U+255F  V-double R-thin
    t[encode(3, 3, 0, 3)] = '╠'; // U+2560

    // ── T-junction: U+D+L  U+2524–U+252B ─────────────────────────────────
    t[encode(1, 1, 1, 0)] = '┤'; // U+2524
    t[encode(1, 1, 2, 0)] = '┥'; // U+2525  L-heavy
    t[encode(2, 1, 1, 0)] = '┦'; // U+2526  U-heavy
    t[encode(1, 2, 1, 0)] = '┧'; // U+2527  D-heavy
    t[encode(2, 2, 1, 0)] = '┨'; // U+2528  U+D heavy
    t[encode(2, 1, 2, 0)] = '┩'; // U+2529  U+L heavy
    t[encode(1, 2, 2, 0)] = '┪'; // U+252A  D+L heavy
    t[encode(2, 2, 2, 0)] = '┫'; // U+252B
    t[encode(1, 1, 3, 0)] = '╡'; // U+2561  V-thin  L-double
    t[encode(3, 3, 1, 0)] = '╢'; // U+2562  V-double L-thin
    t[encode(3, 3, 3, 0)] = '╣'; // U+2563

    // ── T-junction: D+L+R  U+252C–U+2533 ─────────────────────────────────
    t[encode(0, 1, 1, 1)] = '┬'; // U+252C
    t[encode(0, 1, 2, 1)] = '┭'; // U+252D  L-heavy
    t[encode(0, 1, 1, 2)] = '┮'; // U+252E  R-heavy
    t[encode(0, 1, 2, 2)] = '┯'; // U+252F  L+R heavy
    t[encode(0, 2, 1, 1)] = '┰'; // U+2530  D-heavy
    t[encode(0, 2, 2, 1)] = '┱'; // U+2531  D+L heavy
    t[encode(0, 2, 1, 2)] = '┲'; // U+2532  D+R heavy
    t[encode(0, 2, 2, 2)] = '┳'; // U+2533
    t[encode(0, 1, 3, 3)] = '╤'; // U+2564  D-thin  H-double
    t[encode(0, 3, 1, 1)] = '╥'; // U+2565  D-double H-thin
    t[encode(0, 3, 3, 3)] = '╦'; // U+2566

    // ── T-junction: U+L+R  U+2534–U+253B ─────────────────────────────────
    t[encode(1, 0, 1, 1)] = '┴'; // U+2534
    t[encode(1, 0, 2, 1)] = '┵'; // U+2535  L-heavy
    t[encode(1, 0, 1, 2)] = '┶'; // U+2536  R-heavy
    t[encode(1, 0, 2, 2)] = '┷'; // U+2537  L+R heavy
    t[encode(2, 0, 1, 1)] = '┸'; // U+2538  U-heavy
    t[encode(2, 0, 2, 1)] = '┹'; // U+2539  U+L heavy
    t[encode(2, 0, 1, 2)] = '┺'; // U+253A  U+R heavy
    t[encode(2, 0, 2, 2)] = '┻'; // U+253B
    t[encode(1, 0, 3, 3)] = '╧'; // U+2567  U-thin  H-double
    t[encode(3, 0, 1, 1)] = '╨'; // U+2568  U-double H-thin
    t[encode(3, 0, 3, 3)] = '╩'; // U+2569

    // ── Cross: U+D+L+R  U+253C–U+254B ────────────────────────────────────
    t[encode(1, 1, 1, 1)] = '┼'; // U+253C  all thin
    t[encode(1, 1, 2, 1)] = '┽'; // U+253D  L-heavy
    t[encode(1, 1, 1, 2)] = '┾'; // U+253E  R-heavy
    t[encode(1, 1, 2, 2)] = '┿'; // U+253F  H-heavy
    t[encode(2, 1, 1, 1)] = '╀'; // U+2540  U-heavy
    t[encode(1, 2, 1, 1)] = '╁'; // U+2541  D-heavy
    t[encode(2, 2, 1, 1)] = '╂'; // U+2542  V-heavy
    t[encode(2, 1, 2, 1)] = '╃'; // U+2543  U+L heavy
    t[encode(2, 1, 1, 2)] = '╄'; // U+2544  U+R heavy
    t[encode(1, 2, 2, 1)] = '╅'; // U+2545  D+L heavy
    t[encode(1, 2, 1, 2)] = '╆'; // U+2546  D+R heavy
    t[encode(2, 1, 2, 2)] = '╇'; // U+2547  U+H heavy
    t[encode(1, 2, 2, 2)] = '╈'; // U+2548  D+H heavy
    t[encode(2, 2, 2, 1)] = '╉'; // U+2549  V+L heavy
    t[encode(2, 2, 1, 2)] = '╊'; // U+254A  V+R heavy
    t[encode(2, 2, 2, 2)] = '╋'; // U+254B  all heavy
    t[encode(1, 1, 3, 3)] = '╪'; // U+256A  V-thin  H-double
    t[encode(3, 3, 1, 1)] = '╫'; // U+256B  V-double H-thin
    t[encode(3, 3, 3, 3)] = '╬'; // U+256C  all double

    return t;
}

// ─── Tests ────────────────────────────────────────────────────────────────────

test "encode/decode round-trip" {
    const c = encode(1, 2, 3, 0);
    try testing.expectEqual(@as(u2, 1), decodeU(c));
    try testing.expectEqual(@as(u2, 2), decodeD(c));
    try testing.expectEqual(@as(u2, 3), decodeL(c));
    try testing.expectEqual(@as(u2, 0), decodeR(c));
}

test "toChar: key box-drawing characters" {
    try testing.expectEqual(@as(u21, '─'), toChar(encode(0, 0, 1, 1)));
    try testing.expectEqual(@as(u21, '│'), toChar(encode(1, 1, 0, 0)));
    try testing.expectEqual(@as(u21, '┼'), toChar(encode(1, 1, 1, 1)));
    try testing.expectEqual(@as(u21, '╋'), toChar(encode(2, 2, 2, 2)));
    try testing.expectEqual(@as(u21, '═'), toChar(encode(0, 0, 3, 3)));
    try testing.expectEqual(@as(u21, '║'), toChar(encode(3, 3, 0, 0)));
    try testing.expectEqual(@as(u21, '╬'), toChar(encode(3, 3, 3, 3)));
    try testing.expectEqual(@as(u21, '┌'), toChar(encode(0, 1, 0, 1)));
    try testing.expectEqual(@as(u21, '┐'), toChar(encode(0, 1, 1, 0)));
    try testing.expectEqual(@as(u21, '└'), toChar(encode(1, 0, 0, 1)));
    try testing.expectEqual(@as(u21, '┘'), toChar(encode(1, 0, 1, 0)));
}

test "merge: thin V ∪ thin H → ┼ (U+253C)" {
    const vline = encode(1, 1, 0, 0);
    const hline = encode(0, 0, 1, 1);
    const result = merge(vline, hline);
    try testing.expectEqual(@as(u21, '┼'), toChar(result));
}

test "merge: heavy V ∪ thin H → ╂ (U+2542)" {
    const result = merge(encode(2, 2, 0, 0), encode(0, 0, 1, 1));
    try testing.expectEqual(@as(u21, '╂'), toChar(result));
}

test "merge: double H ∪ thin V → ╪ (U+256A)" {
    const result = merge(encode(0, 0, 3, 3), encode(1, 1, 0, 0));
    try testing.expectEqual(@as(u21, '╪'), toChar(result));
}

test "overrideMerge: ╚ + thin-H → ╨ (incoming wins horizontal, double-up preserved)" {
    // ╚ = double U + double R. ─ = thin L + thin R.
    // Horizontal directions are touched by ─ (L=1, R=1) → use incoming weight 1.
    // Vertical directions are not touched (U=0, D=0) → keep existing (U=3, D=0).
    const result = overrideMerge(encode(3, 0, 0, 3), encode(0, 0, 1, 1));
    try testing.expectEqual(@as(u21, '╨'), toChar(result));
}

test "overrideMerge: ╝ + thin-H → ╨" {
    const result = overrideMerge(encode(3, 0, 3, 0), encode(0, 0, 1, 1));
    try testing.expectEqual(@as(u21, '╨'), toChar(result));
}

test "overrideMerge: untouched directions keep existing weight" {
    // ║ = double V. ─ = thin H. Override: H=thin, V=double (untouched) → ╫.
    const result = overrideMerge(encode(3, 3, 0, 0), encode(0, 0, 1, 1));
    try testing.expectEqual(@as(u21, '╫'), toChar(result));
}

test "merge: heavier weight wins per direction" {
    // thin-right merge heavy-right → heavy-right
    const a = encode(0, 0, 0, 1); // thin R
    const b = encode(0, 0, 0, 2); // heavy R
    try testing.expectEqual(@as(u8, encode(0, 0, 0, 2)), merge(a, b));
}

test "fromChar: round-trip for common chars" {
    for (&[_]u21{ '─', '│', '┼', '╋', '═', '║', '╬', '┌', '╔' }) |cp| {
        const enc = fromChar(cp) orelse {
            std.debug.print("fromChar failed for U+{X}\n", .{cp});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqual(cp, toChar(enc));
    }
}

test "rectangle junction: ╟─╫╢ merges correctly" {
    // ╟ = V-double + R-thin: merge double-V into thin-cross-right
    // Row: ╟ ─ ╫ ╢ from left to right
    // ╟ (U+255F): encode(3,3,0,1) — V double, R thin
    // ─ (U+2500): encode(0,0,1,1)
    // ╫ (U+256B): encode(3,3,1,1) — V double, H thin
    // ╢ (U+2562): encode(3,3,1,0) — V double, L thin
    const left_t = merge(encode(3, 3, 0, 0), encode(0, 0, 0, 1)); // double-V + thin-R = ╟
    try testing.expectEqual(@as(u21, '╟'), toChar(left_t));
    const center = merge(encode(3, 3, 0, 0), encode(0, 0, 1, 1)); // double-V + thin-H = ╫
    try testing.expectEqual(@as(u21, '╫'), toChar(center));
    const right_t = merge(encode(3, 3, 0, 0), encode(0, 0, 1, 0)); // double-V + thin-L = ╢
    try testing.expectEqual(@as(u21, '╢'), toChar(right_t));
}
