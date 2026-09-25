//! Derives a function's cache identity from source text using the Zig compiler's
//! own AST parser (`std.zig.Ast`).
//!
//! Declarations and their transitive dependencies are extracted cleanly and
//! accurately via `tree.rootDecls()` and token ranges, without manual brace-depth
//! tracking or heuristic parsing.

const std = @import("std");
const Ast = std.zig.Ast;

const DeclInfo = struct {
    name: []const u8,
    first_token: Ast.TokenIndex,
    last_token: Ast.TokenIndex,
};

fn findDecl(decls: []const DeclInfo, name: []const u8) ?DeclInfo {
    for (decls) |d| {
        if (std.mem.eql(u8, d.name, name)) return d;
    }
    return null;
}

/// The identity of `target_name` in `source`: a hex sha256 over the canonical tokens
/// of that declaration and of every container-level declaration it transitively
/// references.
pub fn of(source: []const u8, target_name: []const u8) [64]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const source_z = allocator.dupeZ(u8, source) catch @panic("OOM");
    var tree = std.zig.Ast.parse(allocator, source_z, .zig) catch @panic("identity: failed to parse Zig source");

    var decls: std.ArrayList(DeclInfo) = .empty;

    for (tree.rootDecls()) |decl_node| {
        var buf: [1]Ast.Node.Index = undefined;
        var name: ?[]const u8 = null;
        if (tree.fullFnProto(&buf, decl_node)) |fp| {
            if (fp.name_token) |nt| name = tree.tokenSlice(nt);
        } else if (tree.fullVarDecl(decl_node)) |vd| {
            name = tree.tokenSlice(vd.ast.mut_token + 1);
        }
        if (name) |n| {
            decls.append(allocator, .{
                .name = n,
                .first_token = tree.firstToken(decl_node),
                .last_token = tree.lastToken(decl_node),
            }) catch @panic("OOM");
        }
    }

    var wanted: std.ArrayList([]const u8) = .empty;
    wanted.append(allocator, target_name) catch @panic("OOM");

    var visited: std.StringHashMap(DeclInfo) = .init(allocator);

    while (wanted.items.len > 0) {
        const current_name = wanted.pop().?;
        if (visited.contains(current_name)) continue;
        const decl = findDecl(decls.items, current_name) orelse continue;
        visited.put(current_name, decl) catch @panic("OOM");

        var ti = decl.first_token;
        while (ti <= decl.last_token) : (ti += 1) {
            if (tree.tokens.items(.tag)[ti] == .identifier) {
                const ident = tree.tokenSlice(ti);
                if (!visited.contains(ident) and findDecl(decls.items, ident) != null) {
                    wanted.append(allocator, ident) catch @panic("OOM");
                }
            }
        }
    }

    if (visited.count() == 0) {
        std.debug.panic("zimo: no container-level declaration named '{s}' in the given source", .{target_name});
    }

    var sorted_names: std.ArrayList([]const u8) = .empty;
    var it = visited.keyIterator();
    while (it.next()) |k| sorted_names.append(allocator, k.*) catch @panic("OOM");
    std.mem.sort([]const u8, sorted_names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (sorted_names.items) |name| {
        const decl = visited.get(name).?;
        hasher.update(name);
        hasher.update("\x00");

        var ti = decl.first_token;
        while (ti <= decl.last_token) : (ti += 1) {
            const tag = tree.tokens.items(.tag)[ti];
            if (tag == .doc_comment) continue;
            const tok_text = tree.tokenSlice(ti);
            hasher.update(tok_text);
            hasher.update("\n");
        }
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

// --------------------------------------------------------------- tests ---

const testing = std.testing;

test "identity: unrelated changes do not affect target id" {
    const src1 = "pub fn foo() u32 { return bar(); } fn bar() u32 { return 42; } fn baz() void {}";
    const src2 = "pub fn foo() u32 { return bar(); } fn bar() u32 { return 42; } fn baz() void { _ = 123; }";
    const id1 = of(src1, "foo");
    const id2 = of(src2, "foo");
    try testing.expectEqualStrings(&id1, &id2);
}

test "identity: transitive dependency changes affect target id" {
    const src1 = "pub fn foo() u32 { return bar(); } fn bar() u32 { return 42; }";
    const src2 = "pub fn foo() u32 { return bar(); } fn bar() u32 { return 43; }";
    const id1 = of(src1, "foo");
    const id2 = of(src2, "foo");
    try testing.expect(!std.mem.eql(u8, &id1, &id2));
}

test "identity: whitespace and comments do not affect target id" {
    const src1 = "pub fn foo() u32 { return 42; }";
    const src2 = "  pub   fn   foo()   u32   {\n // a comment\n return 42; \n}";
    const id1 = of(src1, "foo");
    const id2 = of(src2, "foo");
    try testing.expectEqualStrings(&id1, &id2);
}

