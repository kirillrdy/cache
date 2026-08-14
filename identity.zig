//! Derives a function's cache identity from source text, entirely at compile
//! time.
//!
//! `std.zig.Tokenizer` does not allocate, so it runs at comptime. That removes
//! the need for a generated ids file, a build step, and an external analyser:
//! the checksum is computed from the source the compiler is already reading,
//! and so can never be stale with respect to it.
//!
//! Only a tokenizer is available here -- `std.zig.Ast` allocates -- so
//! declaration boundaries are found by tracking brace depth rather than by
//! parsing. That is enough for container-level declarations, which is all a
//! cache identity needs.

const std = @import("std");
const Tokenizer = std.zig.Tokenizer;
const Tag = std.zig.Token.Tag;

const Tok = struct {
    tag: Tag,
    text: []const u8,
};

const Decl = struct {
    name: []const u8,
    /// Canonical text: one `tag:slice` line per token, doc comments skipped.
    /// Regular comments and whitespace are absent because the tokenizer never
    /// produces them, so reformatting cannot change this.
    canonical: []const u8,
    /// Container-level names mentioned anywhere inside the declaration.
    refs: []const []const u8,
};

/// The identity of `name` in `source`: a hex sha256 over the canonical text of
/// that declaration and of every container-level declaration it transitively
/// references.
pub fn of(comptime source: []const u8, comptime name: []const u8) []const u8 {
    const hex = comptime blk: {
        @setEvalBranchQuota(2_000_000);

        const decls = collect(source);

        // Transitive closure, iterative so recursion cannot blow the stack.
        var wanted: []const []const u8 = &.{name};
        var seen: []const []const u8 = &.{};
        var units: []const []const u8 = &.{};

        while (wanted.len > 0) {
            const current = wanted[0];
            wanted = wanted[1..];
            if (contains(seen, current)) continue;
            seen = seen ++ [_][]const u8{current};

            const d = find(decls, current) orelse continue;
            units = units ++ [_][]const u8{d.name ++ "\x00" ++ d.canonical};
            for (d.refs) |r| wanted = wanted ++ [_][]const u8{r};
        }

        if (units.len == 0) @compileError("zimo: no container-level declaration named '" ++
            name ++ "' in the given source");

        // Discovery order must not affect the key.
        var sorted = units[0..units.len].*;
        std.mem.sort([]const u8, &sorted, {}, lessThan);

        var h = std.crypto.hash.sha2.Sha256.init(.{});
        for (sorted) |u| {
            h.update(std.mem.asBytes(&@as(u64, u.len)));
            h.update(u);
        }
        var digest: [32]u8 = undefined;
        h.final(&digest);

        break :blk std.fmt.comptimePrint("{x}", .{&digest});
    };
    return hex;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

fn find(decls: []const Decl, name: []const u8) ?Decl {
    for (decls) |d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

fn tokenize(comptime source: []const u8) []const Tok {
    comptime {
        // Slice out of the same sentinel-terminated buffer the tokenizer saw,
        // so a token that runs to the end stays in bounds.
        const buf = source ++ "\x00";
        var it: Tokenizer = .init(buf);
        var toks: []const Tok = &.{};
        while (true) {
            const t = it.next();
            if (t.tag == .eof) break;
            toks = toks ++ [_]Tok{.{
                .tag = t.tag,
                .text = buf[t.loc.start..t.loc.end],
            }};
        }
        return toks;
    }
}

/// Container-level declarations, found by tracking brace depth. A declaration
/// starts at `const` / `var` / `fn` at depth zero and runs to the `;` or `}`
/// that closes it.
fn collect(comptime source: []const u8) []const Decl {
    comptime {
        const toks = tokenize(source);
        var decls: []const Decl = &.{};

        var i: usize = 0;
        while (i < toks.len) {
            switch (toks[i].tag) {
                .keyword_const, .keyword_var, .keyword_fn => {},
                else => {
                    i += 1;
                    continue;
                },
            }
            if (i + 1 >= toks.len or toks[i + 1].tag != .identifier) {
                i += 1;
                continue;
            }

            const start = declStart(toks, i);
            const name = toks[i + 1].text;
            const end = declEnd(toks, i);

            decls = decls ++ [_]Decl{.{
                .name = name,
                .canonical = canonical(toks[start .. end + 1]),
                .refs = identifiers(toks[start .. end + 1]),
            }};
            i = end + 1;
        }
        return decls;
    }
}

/// Walk back over the modifiers that belong to the declaration, so that
/// changing `pub` or `export` is part of its identity.
fn declStart(comptime toks: []const Tok, comptime kw: usize) usize {
    comptime {
        var s = kw;
        while (s > 0) {
            switch (toks[s - 1].tag) {
                .keyword_pub, .keyword_export, .keyword_extern, .keyword_inline, .keyword_threadlocal => s -= 1,
                else => break,
            }
        }
        return s;
    }
}

fn declEnd(comptime toks: []const Tok, comptime kw: usize) usize {
    comptime {
        var depth: usize = 0;
        var i = kw;
        while (i < toks.len) : (i += 1) {
            switch (toks[i].tag) {
                .l_brace, .l_paren, .l_bracket => depth += 1,
                .r_brace, .r_paren, .r_bracket => {
                    depth -= 1;
                    // A declaration whose body is a block ends at its closing
                    // brace, with no trailing semicolon.
                    if (depth == 0 and toks[i].tag == .r_brace and
                        (i + 1 >= toks.len or toks[i + 1].tag != .semicolon)) return i;
                },
                .semicolon => if (depth == 0) return i,
                else => {},
            }
        }
        return toks.len - 1;
    }
}

fn canonical(comptime toks: []const Tok) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (toks) |t| {
            if (t.tag == .doc_comment) continue;
            out = out ++ @tagName(t.tag) ++ ":" ++ t.text ++ "\n";
        }
        return out;
    }
}

fn identifiers(comptime toks: []const Tok) []const []const u8 {
    comptime {
        var out: []const []const u8 = &.{};
        for (toks) |t| {
            if (t.tag != .identifier) continue;
            if (contains(out, t.text)) continue;
            out = out ++ [_][]const u8{t.text};
        }
        return out;
    }
}
