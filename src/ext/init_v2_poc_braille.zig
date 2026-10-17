///! Speculative, fully isolated v2-poc demo: converts an image (local path
///! or http(s) URL) to Unicode Braille art, via the vendored
///! `src/lib/braille_image.zig` (originally from the sibling
///! `../braille_image` scratch project). Builds as its own separate
///! `.duckdb_extension` (`zig build v2-poc-braille`), entirely independent
///! of `init_v2_poc.zig`/`zig_ext_v2_poc` — this is the only place in the
///! whole project that pulls in the `zignal` image-decoding dependency, so
///! keeping it fully separate means nothing else (the real extensions, the
///! main v2-poc, any other build step) is ever affected if this one has
///! trouble building or fetching that dependency.
///!
///! Registers three things:
///! - `braille_from_url_ct(url, width, height) -> VARCHAR`: the whole
///!   rendered image as one multi-line string. CAUTION: per
///!   `comptime_scalar_v2.zig`'s own documented VARCHAR-return convention,
///!   the framework boxes the returned slice into a `Value` right after
///!   this function returns but never frees it afterward — `brailleFromUrl`
///!   returns a fresh heap allocation every call, so this leaks one
///!   allocation per call. Acceptable for this POC, not something to
///!   carry into a real feature without an allocator-aware return
///!   convention this framework doesn't have yet.
///! - `braille_from_url_table_ct(url) -> TABLE(line VARCHAR)`: the same
///!   rendering, one row per line, at a fixed default size (see
///!   `default_width`/`default_height` below — the table-function State
///!   shape here has no obvious place to additionally thread width/height
///!   through the replacement-scan path below, so both are fixed for this
///!   POC rather than half-exposing them).
///! - A replacement scan recognizing `FROM '<url>.jpg'`/`.jpeg`/`.png`
///!   (case-insensitive extension, `http://`/`https://` prefix required)
///!   and redirecting to `braille_from_url_table_ct(url)` — the same
///!   name-claiming mechanism `init_v2_poc.zig`'s `zig_v2_range_<N>` demo
///!   already proved, applied to a URL-shaped "table name" instead of a
///!   bare identifier.
const std = @import("std");
const db = @import("duckdb_v2");
const v2 = @import("duckdb_v2_dynamic");
const helpers = @import("v2_helpers");
const comptime_scalar_v2 = @import("comptime_scalar_v2");
const comptime_table_v2 = @import("comptime_table_v2");
const braille_image = @import("braille_image");

const default_width: u32 = 60;
const default_height: u32 = 20;

/// Renders the whole image as one multi-line VARCHAR. See the module doc
/// comment's CAUTION on this leaking one allocation per call.
const BrailleFromUrlCt = comptime_scalar_v2.Function("braille_from_url_ct", struct {
    fn eval(url: []const u8, width: i64, height: i64) []const u8 {
        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();
        const w: u32 = @intCast(@max(width, 1));
        const h: u32 = @intCast(@max(height, 1));
        return braille_image.brailleFromUrl(threaded.io(), std.heap.c_allocator, url, w, h) catch |err| {
            return @errorName(err);
        };
    }
}.eval);

const BrailleTableState = struct {
    art: []u8,
    lines: []const []const u8,
    idx: usize,

    pub const Row = struct { line: []const u8 };

    /// `url` is an owned copy (per `comptime_table_v2`'s VARCHAR-init
    /// convention, same as `ct_tokenize_v2.zig`'s `input`/`delim`) — freed
    /// here, at the end of `init`, since nothing after this point needs
    /// it (unlike `ct_tokenize_v2`, which keeps its VARCHAR params alive
    /// across many `next()` calls and frees them in `deinit` instead).
    pub fn init(url: []const u8) @This() {
        defer std.heap.c_allocator.free(url);

        var threaded: std.Io.Threaded = .init(std.heap.c_allocator, .{});
        defer threaded.deinit();

        const art = braille_image.brailleFromUrl(threaded.io(), std.heap.c_allocator, url, default_width, default_height) catch {
            // No error-return convention available from `State.init` (see
            // `comptime_table_v2.zig`: `state.* = @call(.auto, State.init,
            // args)`, no `try`) — fail soft, zero rows, rather than panic.
            return .{ .art = &.{}, .lines = &.{}, .idx = 0 };
        };

        var line_list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.splitScalar(u8, art, '\n');
        while (it.next()) |line| {
            if (line.len == 0) continue;
            line_list.append(std.heap.c_allocator, line) catch break;
        }
        return .{ .art = art, .lines = line_list.toOwnedSlice(std.heap.c_allocator) catch &.{}, .idx = 0 };
    }

    pub fn next(self: *@This()) ?Row {
        if (self.idx >= self.lines.len) return null;
        defer self.idx += 1;
        return .{ .line = self.lines[self.idx] };
    }

    pub fn deinit(self: *@This()) void {
        std.heap.c_allocator.free(self.art);
        std.heap.c_allocator.free(self.lines);
    }
};

const BrailleFromUrlTableCt = comptime_table_v2.FunctionNamed("braille_from_url_table_ct", BrailleTableState, &.{"url"});

fn registerBrailleReplacementScan(input: *const v2.duckdb_v2_extension_input) void {
    var err: v2.duckdb_v2_error_info_handle = undefined;

    var scan: v2.duckdb_v2_replacement_scan_handle = undefined;
    if (v2.duckdb_v2_replacement_scan_create_with_extension(input.extension, &scan, &err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_replacement_scan_destroy(&scan);

    if (v2.duckdb_v2_replacement_scan_set_callback(scan, braillereplacementScanCallback, &err) != .ERROR_NONE) return;
    _ = v2.duckdb_v2_replacement_scan_register(scan, &err);
}

const image_extensions = [_][]const u8{ ".jpg", ".jpeg", ".png" };

fn braillereplacementScanCallback(info: v2.duckdb_v2_replacement_scan_info_handle, context: v2.duckdb_v2_context_handle, err: *v2.duckdb_v2_error_info_handle) callconv(.c) void {
    var qname: v2.duckdb_v2_qname_handle = undefined;
    if (v2.duckdb_v2_replacement_scan_get_name(info, &qname, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_qname_destroy(&qname);

    var part_count: u64 = 0;
    if (v2.duckdb_v2_qname_get_part_count(qname, &part_count, err) != .ERROR_NONE) return;

    var object_name: v2.duckdb_v2_identifier_t = undefined;
    if (v2.duckdb_v2_qname_get_part(qname, part_count - 1, &object_name, err) != .ERROR_NONE) return;
    // SAFETY: `object_name` borrows from `qname`, valid until it's destroyed above.
    const name_slice: []const u8 = @as([*]const u8, @ptrCast(object_name.ptr))[0..object_name.len];

    const is_url = std.mem.startsWith(u8, name_slice, "http://") or std.mem.startsWith(u8, name_slice, "https://");
    if (!is_url) return; // decline — not a URL-shaped table reference

    var matches_extension = false;
    for (image_extensions) |ext| {
        if (std.ascii.endsWithIgnoreCase(name_slice, ext)) {
            matches_extension = true;
            break;
        }
    }
    if (!matches_extension) return; // decline — not an image-shaped URL

    var target: v2.duckdb_v2_qname_handle = undefined;
    const target_name = helpers.str("braille_from_url_table_ct");
    if (v2.duckdb_v2_qname_create(&.{target_name}, 1, &target, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_qname_destroy(&target);
    if (v2.duckdb_v2_replacement_scan_set_function_name(info, target, err) != .ERROR_NONE) return;

    var url_value: v2.duckdb_v2_value_handle = undefined;
    if (helpers.createVarcharValue(context, name_slice, &url_value, err) != .ERROR_NONE) return;
    defer _ = v2.duckdb_v2_value_destroy(&url_value);
    _ = v2.duckdb_v2_replacement_scan_add_argument(info, url_value, err);
}

export fn zig_ext_v2_poc_braille_init_c_api_v2(raw_input: *const db.ExtensionInput) callconv(.c) void {
    if (!db.initApi(raw_input, "v2.0.0")) return;
    // SAFETY: `db.ExtensionInput` is the translate-c'd `duckdb_v2_extension_input`, which the
    // generated struct mirrors field for field (checked by duckdb_v2_static_parity.zig).
    const input: *const v2.duckdb_v2_extension_input = @ptrCast(raw_input);
    BrailleFromUrlCt.register(input) catch {};
    BrailleFromUrlTableCt.register(input) catch {};
    registerBrailleReplacementScan(input);
}
