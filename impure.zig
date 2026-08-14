//! Impure functions, and a `main` that shows why caching them would be wrong.
//!
//!     zig build run-impure       # watch the answers change between calls

const std = @import("std");

var call_count: u64 = 0;

const Buffer = struct { data: []u8 };

// ---------------------------------------------------------------------------
// Mutable state or argument invalidation
// ---------------------------------------------------------------------------

/// Reads and writes container-level state.
pub fn counter(n: u64) u64 {
    call_count += 1;
    return n + call_count;
}

/// Same, reached only through a callee.
pub fn sneaky(n: u64) u64 {
    return n + helper();
}

fn helper() u64 {
    call_count += 1;
    return call_count;
}

/// A function value has no content to hash.
pub fn applied(n: u64, f: *const fn (u64) u64) u64 {
    return f(n);
}

/// anytype: content is not knowable ahead of time.
pub fn generic(x: anytype) usize {
    return @sizeOf(@TypeOf(x));
}

/// Consumes the thing it was handed, so a second call with "the same"
/// argument is not the same call at all.
pub fn clobber(b: *Buffer) usize {
    b.data = b.data[0..b.data.len -| 1];
    return b.data.len;
}

// ---------------------------------------------------------------------------
// Reaching the outside world
//
// In Zig, reaching the outside world mostly means taking an `Io` or allocator,
// so it is visible in the signature.
// ---------------------------------------------------------------------------

pub fn stamped(n: i64, io: std.Io) i64 {
    const now: std.Io.Clock.Timestamp = .now(io, .real);
    return n + @as(i64, @truncate(now.raw.nanoseconds));
}

pub fn logged(n: u64) u64 {
    std.debug.print("  (logged {d})\n", .{n});
    return n;
}

// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    std.debug.print("Same arguments, twice each:\n\n", .{});

    std.debug.print("counter(10)   -> {d}\n", .{counter(10)});
    std.debug.print("counter(10)   -> {d}   <- container-level state\n\n", .{counter(10)});

    std.debug.print("sneaky(10)    -> {d}\n", .{sneaky(10)});
    std.debug.print("sneaky(10)    -> {d}   <- same state, one call deeper\n\n", .{sneaky(10)});

    std.debug.print("stamped(0)    -> {d}\n", .{stamped(0, init.io)});
    std.debug.print("stamped(0)    -> {d}   <- wall clock\n\n", .{stamped(0, init.io)});

    var bytes = [_]u8{ 1, 2, 3 };
    var buf: Buffer = .{ .data = &bytes };
    std.debug.print("clobber(buf)  -> {d}\n", .{clobber(&buf)});
    std.debug.print("clobber(buf)  -> {d}   <- but the argument was destroyed\n\n", .{clobber(&buf)});

    std.debug.print("A cache would have returned the first answer every time.\n", .{});
}
