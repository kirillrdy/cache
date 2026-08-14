//! zigcache -- the checksummer and purity checker.
//!
//!     zigcache <file.zig>
//!
//! A linter for functions marked `///cache:pure`. Cache identities themselves
//! are derived at compile time by identity.zig, so nothing here is required to
//! build or run a cached program -- this only reports what it can observe.
//!
//! `///cache:pure` is the author's assertion, not a conclusion this tool
//! reaches, and it is the *only* annotation. There is no allowlist of blessed
//! namespaces or builtins: deciding whether `std.foo.bar` is pure is not
//! something a syntactic pass can do, and a guess that is wrong in either
//! direction is worse than no guess -- a false positive blocks correct code, a
//! false negative reads as a guarantee that was never checked.
//!
//! Pointer and slice parameters need no separate opt-in either. Hashing them
//! by content is the only sound choice, and that nobody mutates the referent
//! behind the cache's back is part of what `///cache:pure` already asserts;
//! asking for the same promise twice is ceremony, not safety.
//!
//! What is still reported is only what the tool can observe directly, and only
//! as a service to the author: reaching container-level `var`, mutating
//! through a parameter, and parameters whose values cannot be hashed at all.
//!
//! Canonicalisation here is token-based rather than print-based: `//` comments
//! are not tokens in Zig at all, and `///` doc comments are skipped
//! explicitly, so the checksum is comment- and whitespace-insensitive by
//! construction.

const std = @import("std");
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const Kind = enum { func, value };

const Decl = struct {
    name: []const u8,
    node: Ast.Node.Index,
    kind: Kind,
    /// `var` at container scope: mutable global state, poison for purity.
    is_var: bool,
    /// `const x = @import("...")`.
    is_import: bool,
    pure: bool,
};

const Report = struct {
    gpa: Allocator,
    errors: std.ArrayList([]const u8) = .empty,
    warnings: std.ArrayList([]const u8) = .empty,

    fn err(r: *Report, comptime fmt: []const u8, args: anytype) !void {
        try r.errors.append(r.gpa, try std.fmt.allocPrint(r.gpa, fmt, args));
    }
    fn warn(r: *Report, comptime fmt: []const u8, args: anytype) !void {
        try r.warnings.append(r.gpa, try std.fmt.allocPrint(r.gpa, fmt, args));
    }
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;

    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 2) {
        std.debug.print("usage: zigcache <file.zig>\n", .{});
        std.process.exit(2);
    }
    const path = args[1];

    const source = try std.Io.Dir.cwd().readFileAllocOptions(
        io,
        path,
        gpa,
        .limited(std.zig.max_src_size),
        .of(u8),
        0,
    );

    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);
    if (tree.errors.len > 0) {
        std.debug.print("{s}: {d} parse error(s)\n", .{ path, tree.errors.len });
        std.process.exit(1);
    }

    var decls = try collectDecls(gpa, tree);

    var report: Report = .{ .gpa = gpa };
    var found: usize = 0;

    // Deterministic output order.
    var names: std.ArrayList([]const u8) = .empty;
    for (decls.keys()) |k| try names.append(gpa, k);
    std.mem.sort([]const u8, names.items, {}, lessThanStr);

    var lines: std.ArrayList([]const u8) = .empty;
    for (names.items) |name| {
        const d = decls.get(name).?;
        if (!d.pure) continue;
        found += 1;
        try checkPure(gpa, tree, &decls, d, &report);
        try lines.append(gpa, try std.fmt.allocPrint(gpa, "  {s}", .{name}));
    }

    if (report.errors.items.len > 0) {
        std.mem.sort([]const u8, report.errors.items, {}, lessThanStr);
        std.debug.print("zigcache: purity violations:\n", .{});
        var prev: []const u8 = "";
        for (report.errors.items) |e| {
            if (std.mem.eql(u8, e, prev)) continue;
            prev = e;
            std.debug.print("  {s}\n", .{e});
        }
        std.process.exit(1);
    }
    for (report.warnings.items) |w| std.debug.print("zigcache: warning: {s}\n", .{w});

    std.debug.print("zigcache: {s}: {d} function(s) claim purity, no violations found\n", .{ path, found });
    for (lines.items) |l| std.debug.print("{s}\n", .{l});
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

const DeclMap = std.StringArrayHashMapUnmanaged(Decl);

fn collectDecls(gpa: Allocator, tree: Ast) !DeclMap {
    var map: DeclMap = .empty;
    for (tree.rootDecls()) |node| {
        var buf: [1]Ast.Node.Index = undefined;
        var name: []const u8 = undefined;
        var kind: Kind = undefined;
        var is_var = false;
        var is_import = false;

        if (tree.fullFnProto(&buf, node)) |proto| {
            name = tree.tokenSlice(proto.name_token orelse continue);
            kind = .func;
        } else if (tree.fullVarDecl(node)) |vd| {
            name = tree.tokenSlice(vd.ast.mut_token + 1);
            kind = .value;
            is_var = std.mem.eql(u8, tree.tokenSlice(vd.ast.mut_token), "var");
            is_import = hasBuiltin(tree, node, "@import");
        } else continue;

        var pure = false;
        for (try docComments(gpa, tree, node)) |line| {
            if (std.mem.eql(u8, line, "cache:pure")) pure = true;
        }

        try map.put(gpa, name, .{
            .name = name,
            .node = node,
            .kind = kind,
            .is_var = is_var,
            .is_import = is_import,
            .pure = pure and kind == .func,
        });
    }
    return map;
}

/// Doc comment lines immediately preceding a declaration, `///` stripped.
fn docComments(gpa: Allocator, tree: Ast, node: Ast.Node.Index) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i = tree.firstToken(node);
    while (i > 0 and tree.tokenTag(i - 1) == .doc_comment) i -= 1;
    while (tree.tokenTag(i) == .doc_comment) : (i += 1) {
        const raw = tree.tokenSlice(i);
        try out.append(gpa, std.mem.trim(u8, std.mem.trimStart(u8, raw, "/"), " \t\r"));
    }
    return out.items;
}

fn hasBuiltin(tree: Ast, node: Ast.Node.Index, want: []const u8) bool {
    var i = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (i <= last) : (i += 1) {
        if (tree.tokenTag(i) == .builtin and std.mem.eql(u8, tree.tokenSlice(i), want)) return true;
    }
    return false;
}

// --------------------------------------------------------------- tokens ---

/// Canonical text of a declaration: one `tag:slice` line per token, doc
/// comments skipped. Regular comments and all whitespace are absent because
/// the tokenizer never produces them.
fn canonical(gpa: Allocator, tree: Ast, node: Ast.Node.Index) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (i <= last) : (i += 1) {
        const tag = tree.tokenTag(i);
        if (tag == .doc_comment) continue;
        try out.appendSlice(gpa, @tagName(tag));
        try out.append(gpa, ':');
        try out.appendSlice(gpa, tree.tokenSlice(i));
        try out.append(gpa, '\n');
    }
    return out.items;
}

/// Top-level declarations named anywhere inside a node.
///
/// This is a token scan, so it over-approximates: a local named `sum` pulls in
/// a top-level `sum`. Over-approximating is the safe direction -- it can cause
/// an unnecessary miss, never a stale hit.
fn refs(gpa: Allocator, tree: Ast, decls: *const DeclMap, node: Ast.Node.Index) ![][]const u8 {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    var i = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (i <= last) : (i += 1) {
        if (tree.tokenTag(i) != .identifier) continue;
        const s = tree.tokenSlice(i);
        if (decls.contains(s)) try seen.put(gpa, s, {});
    }
    var out: std.ArrayList([]const u8) = .empty;
    for (seen.keys()) |k| try out.append(gpa, k);
    std.mem.sort([]const u8, out.items, {}, lessThanStr);
    return out.items;
}

// ---------------------------------------------------------------- purity ---

fn checkPure(gpa: Allocator, tree: Ast, decls: *const DeclMap, target: Decl, report: *Report) !void {
    try checkParams(gpa, tree, target, report);

    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    var stack: std.ArrayList([]const u8) = .empty;
    try stack.append(gpa, target.name);

    while (stack.pop()) |name| {
        if (seen.contains(name)) continue;
        try seen.put(gpa, name, {});
        const d = decls.get(name) orelse continue;
        if (d.is_import) continue;
        try checkBody(tree, decls, target.name, d, report);
        for (try refs(gpa, tree, decls, d.node)) |r| try stack.append(gpa, r);
    }
}

fn checkParams(gpa: Allocator, tree: Ast, d: Decl, report: *Report) !void {
    var buf: [1]Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&buf, d.node) orelse return;

    var it = proto.iterate(&tree);
    while (it.next()) |param| {
        const pname = if (param.name_token) |t| tree.tokenSlice(t) else "_";

        if (param.anytype_ellipsis3) |_| {
            try report.err("{s}: parameter \"{s}\" is anytype; its content is not knowable here", .{ d.name, pname });
            continue;
        }
        const type_node = param.type_expr orelse continue;
        const ty = try canonical(gpa, tree, type_node);

        // Pointers and slices need no annotation. Hashing them by content is
        // the only sound choice -- a pure function cannot observe an address --
        // and that nobody mutates the referent behind the cache's back is part
        // of what ///cache:pure already asserts.
        if (std.mem.indexOf(u8, ty, "keyword_fn:") != null) {
            try report.err("{s}: parameter \"{s}\" is a function; it has no hashable content", .{ d.name, pname });
        }
    }
}

fn checkBody(tree: Ast, decls: *const DeclMap, root: []const u8, d: Decl, report: *Report) !void {
    var i = tree.firstToken(d.node);
    const last = tree.lastToken(d.node);
    while (i <= last) : (i += 1) {
        if (tree.tokenTag(i) != .identifier) continue;
        const s = tree.tokenSlice(i);
        const ref = decls.get(s) orelse continue;
        if (ref.is_var and !std.mem.eql(u8, s, d.name)) {
            try report.err("{s}: reaches container-level var \"{s}\" via {s}", .{ root, s, d.name });
        }
    }

    // Assignment through a pointer parameter. Structural in Go via ast.Inspect;
    // here it is a token pattern, because std.zig.Ast has no generic walker.
    var buf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&buf, d.node)) |proto| {
        var it = proto.iterate(&tree);
        while (it.next()) |param| {
            const pname = tree.tokenSlice(param.name_token orelse continue);
            var j = tree.firstToken(d.node);
            while (j < last) : (j += 1) {
                if (tree.tokenTag(j) != .identifier) continue;
                if (!std.mem.eql(u8, tree.tokenSlice(j), pname)) continue;
                // `p.* =` / `p.field =` / `p[i] =`
                var k = j + 1;
                while (k <= last) : (k += 1) {
                    switch (tree.tokenTag(k)) {
                        .period, .identifier, .asterisk, .l_bracket, .r_bracket, .number_literal => continue,
                        .equal => {
                            try report.err("{s}: mutates through parameter \"{s}\" in {s}", .{ root, pname, d.name });
                            break;
                        },
                        else => break,
                    }
                }
            }
        }
    }
}
