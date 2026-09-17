//! The runtime half of zimo.
//!
//! `Memo(id, f).call` wraps any function in a memoised one. `id` is the
//! checksum derived for `f`; the cache key is
//!
//!     sha256( id || canonical encoding of the arguments )
//!
//! Everything about the argument encoding and the result layout is resolved by
//! `@typeInfo` at compile time. There is no reflection at run time and no
//! encoder: a type that cannot be hashed, or a result that cannot be stored,
//! is a compile error at the `Memo` call site rather than a surprise later.

const std = @import("std");
const identity = @import("identity.zig");
/// SHA-256, not one of the newer designs: on any CPU with the SHA extensions
/// it runs at ~1.4 GB/s, and its small-input latency -- the common case for an
/// argument tuple -- is several times lower than Blake3's.
const Hash = std.crypto.hash.sha2.Sha256;
const native_endian = @import("builtin").cpu.arch.endian();

/// The declaration a `.name` or `"name"` target refers to.
fn declName(comptime target: anytype) []const u8 {
    return switch (@typeInfo(@TypeOf(target))) {
        .enum_literal => @tagName(target),
        .pointer => target,
        else => @compileError("zimo: expected .name or \"name\", got " ++ @typeName(@TypeOf(target))),
    };
}

/// Binds a container scope and its source text, so each cached function costs one line.
///
///     const here = zimo.bind(@This(), @embedFile("demo.zig"));
///     here.call(.score, .{ xs, w });
///
/// The identity is derived from that source at compile time, so there is no
/// generated file to import and no build step to forget.
pub fn bind(comptime Container: type, comptime source: []const u8) type {
    return struct {
        /// Call the memoised form of `target`.
        pub fn call(comptime target: anytype, args: anytype) ReturnOf(target) {
            return Memo(id(target), @field(Container, declName(target))).call(args);
        }

        /// The cache identity of `target`, for display.
        pub fn id(comptime target: anytype) []const u8 {
            return identity.of(source, declName(target));
        }

        fn ReturnOf(comptime target: anytype) type {
            return @typeInfo(@TypeOf(@field(Container, declName(target)))).@"fn".return_type.?;
        }
    };
}

pub const Stats = struct { hits: usize = 0, misses: usize = 0 };
pub var stats: Stats = .{};

const Store = struct { allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir };
var store: ?Store = null;

/// Point the cache at a directory. Entries survive across processes.
pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    store = .{
        .allocator = allocator,
        .io = io,
        .dir = try std.Io.Dir.cwd().createDirPathOpen(io, path, .{}),
    };
}

pub fn close() void {
    if (store) |*s| s.dir.close(s.io);
    store = null;
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
        .pointer => |p| switch (p.size) {
            .slice => assertStorable(p.child),
            else => @compileError("zimo: result type " ++ @typeName(T) ++
                " contains a pointer; a cached result must be self-contained"),
        },
        else => @compileError("zimo: result type " ++ @typeName(T) ++ " cannot be stored"),
    }
}

/// The canonical bits of a float. A pure function cannot distinguish one NaN
/// from another, nor -0.0 from +0.0, so both collapse to a single value.
fn floatBits(comptime T: type, v: T) std.meta.Int(.unsigned, @bitSizeOf(T)) {
    if (std.math.isNan(v)) return @bitCast(std.math.nan(T));
    if (v == 0) return 0;
    return @bitCast(v);
}

/// True when the in-memory bytes of `T` are already its canonical encoding, so
/// a run of them can go into the hash in one update rather than one per
/// element. Padding, byte order, or any value that needs collapsing rules it
/// out.
fn plainBytes(comptime T: type) bool {
    if (native_endian != .little) return false;
    return switch (@typeInfo(T)) {
        .int => |i| @sizeOf(T) * 8 == i.bits,
        else => false,
    };
}

/// A float whose bytes need only NaN and zero collapsed, which a staging
/// buffer can do a block at a time.
fn packedFloat(comptime T: type) bool {
    if (native_endian != .little) return false;
    return @typeInfo(T) == .float and @sizeOf(T) * 8 == @bitSizeOf(T);
}

/// Hashes a run of elements, in blocks where the element encoding allows it.
/// The element type is already part of the key via the array or slice type
/// name, so the per-element type name that `hashValue` writes is redundant
/// here and its absence cannot make two runs collide.
fn hashElems(h: *Hash, comptime T: type, elems: []const T) void {
    if (comptime plainBytes(T)) {
        h.update(std.mem.sliceAsBytes(elems));
    } else if (comptime packedFloat(T)) {
        var buf: [512]T = undefined;
        var rest = elems;
        while (rest.len > 0) {
            const n = @min(rest.len, buf.len);
            for (rest[0..n], buf[0..n]) |v, *out| out.* = @bitCast(floatBits(T, v));
            h.update(std.mem.sliceAsBytes(buf[0..n]));
            rest = rest[n..];
        }
    } else {
        for (elems) |elem| hashValue(h, T, elem);
    }
}

fn hashInt(h: *Hash, comptime T: type, v: T) void {
    var buf: [@divExact(@bitSizeOf(T), 8)]u8 = undefined;
    std.mem.writeInt(T, &buf, v, .little);
    h.update(&buf);
}

/// Canonical encoding of a value: two values hash the same exactly when a pure
/// function cannot tell them apart.
fn hashValue(h: *Hash, comptime T: type, v: T) void {
    if (T == std.mem.Allocator) {
        h.update("std.mem.Allocator");
        return;
    }

    switch (@typeInfo(T)) {
        // A struct is hashed structurally -- field names and field types --
        // rather than by @typeName. For an anonymous tuple holding
        // comptime-known values, @typeName embeds the values themselves, so
        // two argument tuples that a pure function cannot tell apart would
        // otherwise get different keys.
        .@"struct" => |s| {
            hashInt(h, u64, s.fields.len);
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
        .int => hashInt(h, T, v),
        .@"enum" => |e| hashInt(h, e.tag_type, @intFromEnum(v)),
        .float => |f| hashInt(h, std.meta.Int(.unsigned, f.bits), floatBits(T, v)),
        .optional => |o| if (v) |inner| {
            h.update(&[_]u8{1});
            hashValue(h, o.child, inner);
        } else h.update(&[_]u8{0}),
        .array => |a| hashElems(h, a.child, &v),
        .pointer => |p| switch (p.size) {
            // Contents, not address: identity is not observable to a pure
            // function, so hashing it would be wrong in every case.
            .one => {
                if (@typeInfo(p.child) == .@"fn") @compileError("zimo: cannot hash " ++
                    @typeName(T) ++ "; a function has no content a pure function could depend on");
                hashValue(h, p.child, v.*);
            },
            .slice => {
                hashInt(h, u64, v.len);
                hashElems(h, p.child, v);
            },
            .many, .c => @compileError("zimo: cannot hash " ++ @typeName(T) ++
                "; its length is not known"),
        },
        else => @compileError("zimo: cannot hash " ++ @typeName(T) ++
            "; it has no content a pure function could depend on"),
    }
}

// ---------------------------------------------------------------- memo ---

/// The cache key for one call: the function's identity plus its arguments.
pub fn keyFor(comptime id: []const u8, args: anytype) [64]u8 {
    var h = Hash.init(.{});
    h.update(id);
    hashValue(&h, @TypeOf(args), args);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
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

/// A slice result is stored as its raw elements; anything else as its bytes.
/// `assertStorable` guarantees the only pointer type that gets here is a slice.
fn isSlice(comptime R: type) bool {
    return @typeInfo(R) == .pointer;
}

fn get(comptime R: type, key: [64]u8) ?R {
    const s = store orelse return null;

    if (comptime isSlice(R)) {
        const Elem = @typeInfo(R).pointer.child;
        const bytes = s.dir.readFileAllocOptions(s.io, &key, s.allocator, .limited(64 * 1024 * 1024), .of(Elem), null) catch return null;
        if (bytes.len % @sizeOf(Elem) != 0) {
            s.allocator.free(bytes);
            return null;
        }
        return std.mem.bytesAsSlice(Elem, bytes);
    }

    // One spare byte so a file longer than the value is also rejected.
    var buf: [@sizeOf(R) + 1]u8 = undefined;
    const bytes = s.dir.readFile(s.io, &key, &buf) catch return null;
    if (bytes.len != @sizeOf(R)) return null;
    return std.mem.bytesToValue(R, buf[0..@sizeOf(R)]);
}

fn put(comptime R: type, key: [64]u8, value: R) void {
    const s = store orelse return;
    const bytes = if (comptime isSlice(R)) std.mem.sliceAsBytes(value) else std.mem.asBytes(&value);
    s.dir.writeFile(s.io, .{ .sub_path = &key, .data = bytes }) catch {};
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

test "block-hashed runs collapse NaN and -0.0 like single values do" {
    const nan_a = std.math.nan(f32);
    const nan_b: f32 = @bitCast(@as(u32, 0x7fc00009));
    const a: []const f32 = &.{ nan_a, -0.0, 1.5 };
    const b: []const f32 = &.{ nan_b, 0.0, 1.5 };
    try testing.expectEqual(keyFor("id", .{a}), keyFor("id", .{b}));

    const c: []const f32 = &.{ nan_a, 0.0, 1.5 };
    const d: []const f32 = &.{ nan_a, 0.0, 2.5 };
    try testing.expect(!std.mem.eql(u8, &keyFor("id", .{c}), &keyFor("id", .{d})));

    const arr_a: [3]f64 = .{ std.math.nan(f64), -0.0, 1 };
    const arr_b: [3]f64 = .{ @bitCast(@as(u64, 0x7ff8000000000009)), 0.0, 1 };
    try testing.expectEqual(keyFor("id", .{arr_a}), keyFor("id", .{arr_b}));
}

test "block-hashed runs still distinguish contents, length, and element type" {
    const a: []const u32 = &.{ 1, 2, 3 };
    const b: []const u32 = &.{ 1, 2, 4 };
    const c: []const u32 = &.{ 1, 2 };
    const d: []const u64 = &.{ 1, 2, 3 };
    try testing.expect(!std.mem.eql(u8, &keyFor("id", .{a}), &keyFor("id", .{b})));
    try testing.expect(!std.mem.eql(u8, &keyFor("id", .{a}), &keyFor("id", .{c})));
    try testing.expect(!std.mem.eql(u8, &keyFor("id", .{a}), &keyFor("id", .{d})));

    // A run of two u16 and a run of four u8 with the same bytes are different
    // arguments.
    const halves: []const u16 = &.{ 0x0201, 0x0403 };
    const bytes: []const u8 = &.{ 1, 2, 3, 4 };
    try testing.expect(!std.mem.eql(u8, &keyFor("id", .{halves}), &keyFor("id", .{bytes})));
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

test "bind: .symbol and string targets, pub or private" {
    const Mod = struct {
        pub fn inc(n: u32) u32 {
            return n + 1;
        }
        fn dec(n: u32) u32 {
            return n - 1;
        }
    };
    const here = bind(Mod, "pub fn inc(n: u32) u32 { return n + 1; } fn dec(n: u32) u32 { return n - 1; }");

    try testing.expectEqual(@as(u32, 11), here.call(.inc, .{10}));
    try testing.expectEqual(@as(u32, 11), here.call("inc", .{10}));
    try testing.expectEqual(@as(u32, 9), here.call(.dec, .{10}));
    try testing.expectEqual(@as(u32, 9), here.call("dec", .{10}));
    try testing.expect(!std.mem.eql(u8, here.id(.inc), here.id(.dec)));
}

test "slice return type with allocator parameter" {
    const Mod = struct {
        pub fn filterEvens(allocator: std.mem.Allocator, arr: []const u32) []const u32 {
            var count: usize = 0;
            for (arr) |x| {
                if (x % 2 == 0) count += 1;
            }
            const buf = allocator.alloc(u32, count) catch return &.{};
            var idx: usize = 0;
            for (arr) |x| {
                if (x % 2 == 0) {
                    buf[idx] = x;
                    idx += 1;
                }
            }
            return buf;
        }
    };
    const here = bind(Mod, "pub fn filterEvens(allocator: std.mem.Allocator, arr: []const u32) []const u32 { ... }");
    const input: []const u32 = &.{ 1, 2, 3, 4, 5, 6 };
    const res = here.call(.filterEvens, .{ testing.allocator, input });
    defer testing.allocator.free(res);
    try testing.expectEqualSlices(u32, &.{ 2, 4, 6 }, res);
}
