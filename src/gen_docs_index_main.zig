///! Standalone tool that generates `docs/pages/index.html` from
///! `docs/pages/index.html.tmpl` + `description.yml` — see
///! `src/lib/description_yaml.zig`'s own doc comment for why
///! `description.yml` exists and what it is (and isn't) used for.
///!
///! Usage: gen_docs_index <description.yml> <index.html.tmpl> <output.html>
///!
///! Plain `{{TOKEN}}` substitution, nothing fancier — the template has a
///! small, fixed set of tokens (see `tokens` below), each replaced with a
///! value derived from the parsed `Description`. Unknown `{{...}}`-shaped
///! text in the template is left untouched (not an error): this isn't a
///! general templating engine, just enough to keep `description.yml` as
///! the single source of truth for the handful of fields it actually
///! covers, while everything else in the page (the Added Functions
///! table, platform support, etc.) stays hand-maintained directly in the
///! template, exactly as the real `description.yml` schema itself scopes
///! things ("documentation for functions ... is auto-detected rather
///! than declared in the file").
const std = @import("std");
const Io = std.Io;
const Dir = Io.Dir;
const description_yaml = @import("description_yaml");

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    var args = init.minimal.args.iterate();
    _ = args.next();
    const yaml_path = args.next() orelse return printUsage();
    const template_path = args.next() orelse return printUsage();
    const output_path = args.next() orelse return printUsage();

    const cwd = Dir.cwd();

    const yaml_contents = try cwd.readFileAlloc(io, yaml_path, gpa, .unlimited);
    defer gpa.free(yaml_contents);
    var desc = try description_yaml.parse(gpa, yaml_contents);
    defer desc.deinit(gpa);
    defer gpa.free(desc.description);
    defer gpa.free(desc.hello_world);
    defer gpa.free(desc.extended_description);

    const template = try cwd.readFileAlloc(io, template_path, gpa, .unlimited);
    defer gpa.free(template);

    const repo_url = try std.fmt.allocPrint(gpa, "https://github.com/{s}", .{desc.repo_github});
    defer gpa.free(repo_url);

    const maintainers_html = try maintainersHtml(gpa, desc.maintainers);
    defer gpa.free(maintainers_html);

    const hello_world_html = try escapeHtml(gpa, desc.hello_world);
    defer gpa.free(hello_world_html);

    const description_html = try escapeHtml(gpa, desc.description);
    defer gpa.free(description_html);

    const extended_description_html = try escapeHtml(gpa, desc.extended_description);
    defer gpa.free(extended_description_html);

    const tokens = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "{{NAME}}", .value = desc.name },
        .{ .name = "{{VERSION}}", .value = desc.version },
        .{ .name = "{{LICENSE}}", .value = desc.license },
        .{ .name = "{{REPO_REF}}", .value = desc.repo_ref },
        .{ .name = "{{REPO_URL}}", .value = repo_url },
        .{ .name = "{{MAINTAINERS_HTML}}", .value = maintainers_html },
        .{ .name = "{{HELLO_WORLD_HTML}}", .value = hello_world_html },
        .{ .name = "{{DESCRIPTION}}", .value = description_html },
        .{ .name = "{{EXTENDED_DESCRIPTION}}", .value = extended_description_html },
    };

    var result = try gpa.dupe(u8, template);
    defer gpa.free(result);
    for (tokens) |t| {
        const replaced = try std.mem.replaceOwned(u8, gpa, result, t.name, t.value);
        gpa.free(result);
        result = replaced;
    }

    try cwd.writeFile(io, .{ .sub_path = output_path, .data = result });
    return 0;
}

fn maintainersHtml(allocator: std.mem.Allocator, maintainers: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (maintainers, 0..) |m, i| {
        if (i > 0) try out.writer.writeAll(", ");
        try out.writer.print("<a href=\"https://github.com/{s}\">{s}</a>", .{ m, m });
    }
    return out.toOwnedSlice();
}

fn escapeHtml(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (text) |c| {
        switch (c) {
            '&' => try out.writer.writeAll("&amp;"),
            '<' => try out.writer.writeAll("&lt;"),
            '>' => try out.writer.writeAll("&gt;"),
            else => try out.writer.writeByte(c),
        }
    }
    return out.toOwnedSlice();
}

fn printUsage() u8 {
    std.debug.print("Usage: gen_docs_index <description.yml> <index.html.tmpl> <output.html>\n", .{});
    return 1;
}
