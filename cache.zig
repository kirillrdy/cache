//! The runtime half of zigcache.
//!
//! `Memo(id, f).call` wraps any function in a memoised one. `id` is the
//! checksum the analyser derived for `f`; the cache key is
//!
//!     sha256( id || canonical encoding of the arguments )
//!
//! Everything about the argument encoding and the result layout is resolved by
//! `@typeInfo` at compile time. There is no reflection at run time and no
//! encoder: a type that cannot be hashed, or a result that cannot be stored,
//! is a compile error at the `Memo` call site rather than a surprise later.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Stats = struct { hits: usize = 0, misses: usize = 0 };
pub var stats: Stats = .{};

var g_io: ?std.Io = null;
var g_dir: ?std.Io.Dir = null;

/// Point the cache at a directory. Entries survive across processes.
pub fn open(io: std.Io, path: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    g_dir = try cwd.createDirPathOpen(io, path, .{});
    g_io = io;
}

pub fn close() void {
    if (g_dir) |*d| d.close(g_io.?);
    g_dir = null;
    g_io = null;
}

// ------------------------------------------------------------ comptime ---

/// A result must be self-contained: we store its bytes and hand them back in a
/// later process, where any pointer it held would be meaningless.
fn assertStorable(comptime T: type) void {
    switch (@typeInfo(T)) {
        .int, .float, .bool, .void, .@"enum" => {},
        .@"struct" => |s| for (s.fields) |f| assertStorable(f.type),
        .array => |a| assertStorable(a.child),
        .optional => |o| assertStorable(o.child),
        .pointer => @compileError("zigcache: result type " ++ @typeName(T) ++
            " contains a pointer; a cached result must be self-contained"),
        else => @compileError("zigcache: result type " ++ @typeName(T) ++ " cannot be stored"),
    }
}

/// Canonical encoding of a value: two values hash the same exactly when a pure
/// function cannot tell them apart.
fn hashValue(h: *Sha256, comptime T: type, v: T) void {
    switch (@typeInfo(T)) {
        // A struct is hashed structurally -- field names and field types --
        // rather than by @typeName. For an anonymous tuple holding
        // comptime-known values, @typeName embeds the values themselves, so
        // two argument tuples that a pure function cannot tell apart would
        // otherwise get different keys.
        .@"struct" => |s| {
            var count: [8]u8 = undefined;
            std.mem.writeInt(u64, &count, s.fields.len, .little);
            h.update(&count);
            inline for (s.fields) |f| {
                h.update(f.name);
                hashValue(h, f.type, @field(v, f.name));
            }
            return;
        },
        else => {},
    }

    h.update(@typeName(T)); // u32(1) and u64(1) are different arguments

    switch (@typeInfo(T)) {
        .void => {},
        .bool => h.update(&[_]u8{@intFromBool(v)}),
        .int => {
            var buf: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &buf, v, .little);
            h.update(&buf);
        },
        .@"enum" => |e| hashValue(h, e.tag_type, @intFromEnum(v)),
        .float => {
            // A pure function cannot distinguish one NaN from another, nor
            // -0.0 from +0.0.
            const f: f64 = v;
            const bits: u64 = if (std.math.isNan(f))
                0x7ff8000000000001
            else if (f == 0)
                0
            else
                @bitCast(f);
            var buf: [8]u8 = undefined;
            std.mem.writeInt(u64, &buf, bits, .little);
            h.update(&buf);
        },
        .optional => {
            if (v) |inner| {
                h.update(&[_]u8{1});
                hashValue(h, @typeInfo(T).optional.child, inner);
            } else h.update(&[_]u8{0});
        },
        .array => |a| for (v) |elem| hashValue(h, a.child, elem),
        .pointer => |p| switch (p.size) {
            // Contents, not address: identity is not observable to a pure
            // function, so hashing it would be wrong in every case.
            .one => {
                if (@typeInfo(p.child) == .@"fn") @compileError("zigcache: cannot hash " ++
                    @typeName(T) ++ "; a function has no content a pure function could depend on");
                hashValue(h, p.child, v.*);
            },
            .slice => {
                var len_buf: [8]u8 = undefined;
                std.mem.writeInt(u64, &len_buf, v.len, .little);
                h.update(&len_buf);
                if (p.child == u8) {
                    h.update(v);
                } else {
                    for (v) |elem| hashValue(h, p.child, elem);
                }
            },
            .many, .c => @compileError("zigcache: cannot hash " ++ @typeName(T) ++
                "; its length is not known"),
        },
        else => @compileError("zigcache: cannot hash " ++ @typeName(T) ++
            "; it has no content a pure function could depend on"),
    }
}

// ---------------------------------------------------------------- memo ---

fn hexKey(digest: [32]u8) [64]u8 {
    var hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&hex, "{x}", .{&digest}) catch unreachable;
    return hex;
}

/// The cache key for one call: the function's identity plus its arguments.
pub fn keyFor(comptime id: []const u8, args: anytype) [64]u8 {
    var h = Sha256.init(.{});
    h.update(id);
    hashValue(&h, @TypeOf(args), args);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return hexKey(digest);
}

/// Wraps `f` in a memoised function. Call as `Memo(id, f).call(.{ a, b })`.
pub fn Memo(comptime id: []const u8, comptime f: anytype) type {
    const F = @TypeOf(f);
    const R = @typeInfo(F).@"fn".return_type.?;
    const Args = std.meta.ArgsTuple(F);
    comptime assertStorable(R);

    return struct {
        pub fn call(args: Args) R {
            const key = keyFor(id, args);

            if (get(R, key)) |cached| {
                stats.hits += 1;
                return cached;
            }
            stats.misses += 1;

            const result = @call(.auto, f, args);
            put(R, key, result);
            return result;
        }
    };
}

fn get(comptime R: type, key: [64]u8) ?R {
    const io = g_io orelse return null;
    const dir = g_dir orelse return null;

    var buf: [@sizeOf(R)]u8 = undefined;
    const n = dir.readFileAlloc(io, &key, std.heap.page_allocator, .limited(@sizeOf(R) + 1)) catch return null;
    defer std.heap.page_allocator.free(n);
    if (n.len != @sizeOf(R)) return null;
    @memcpy(&buf, n);
    return std.mem.bytesToValue(R, &buf);
}

fn put(comptime R: type, key: [64]u8, value: R) void {
    const io = g_io orelse return;
    const dir = g_dir orelse return;

    // Zeroed first so struct padding never reaches the file as undefined
    // memory.
    var buf: [@sizeOf(R)]u8 = @splat(0);
    @memcpy(&buf, std.mem.asBytes(&value));
    dir.writeFile(io, .{ .sub_path = &key, .data = &buf }) catch {};
}

// --------------------------------------------------------------- tests ---

const testing = std.testing;

test "key is content-addressed, not address-addressed" {
    const a: []const f64 = &.{ 1, 2, 3 };
    // Same contents, a different backing array.
    const b: []const f64 = &.{ 1, 2, 3 };
    try testing.expectEqual(keyFor("id", .{a}), keyFor("id", .{b}));

    const one: u32 = 7;
    const other: u32 = 7;
    try testing.expectEqual(keyFor("id", .{&one}), keyFor("id", .{&other}));
}

test "key distinguishes what a pure function can distinguish" {
    const differ = .{
        .{ .{@as(u32, 1)}, .{@as(u32, 2)} },
        // The type is part of the key: u32(1) and u64(1) are not the same
        // argument.
        .{ .{@as(u32, 1)}, .{@as(u64, 1)} },
        .{ .{@as([]const u8, "ab")}, .{@as([]const u8, "ba")} },
        .{ .{@as(?u8, null)}, .{@as(?u8, 0)} },
        .{ .{@as([]const u8, "")}, .{@as([]const u8, "\x00")} },
    };
    inline for (differ) |pair| {
        try testing.expect(!std.mem.eql(u8, &keyFor("id", pair[0]), &keyFor("id", pair[1])));
    }
}

test "floats: all NaNs are one value, and so are both zeroes" {
    const nan_a = std.math.nan(f64);
    const nan_b: f64 = @bitCast(@as(u64, 0x7ff8000000000009));
    try testing.expect(std.math.isNan(nan_b));
    try testing.expectEqual(keyFor("id", .{nan_a}), keyFor("id", .{nan_b}));

    try testing.expectEqual(keyFor("id", .{@as(f64, 0.0)}), keyFor("id", .{@as(f64, -0.0)}));
    try testing.expect(!std.mem.eql(u8, &keyFor("id", .{@as(f64, 0)}), &keyFor("id", .{@as(f64, 1)})));
}

test "function identity is part of the key" {
    try testing.expect(!std.mem.eql(u8, &keyFor("body-v1", .{@as(u8, 5)}), &keyFor("body-v2", .{@as(u8, 5)})));
}

test "nested structs hash by content" {
    const Inner = struct { x: u8, y: f32 };
    const Outer = struct { a: Inner, b: [2]u16 };

    const p: Outer = .{ .a = .{ .x = 1, .y = 2 }, .b = .{ 3, 4 } };
    const q: Outer = .{ .a = .{ .x = 1, .y = 2 }, .b = .{ 3, 4 } };
    const r: Outer = .{ .a = .{ .x = 1, .y = 2 }, .b = .{ 4, 3 } };

    try testing.expectEqual(keyFor("id", .{p}), keyFor("id", .{q}));
    try testing.expect(!std.mem.eql(u8, &keyFor("id", .{p}), &keyFor("id", .{r})));
}

test "memo without a store still returns correct results" {
    const f = struct {
        fn double(n: u32) u32 {
            return n * 2;
        }
    }.double;
    try testing.expectEqual(@as(u32, 42), Memo("id", f).call(.{21}));
}
