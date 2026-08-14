//! Functions that claim `///cache:pure` but are not, and a `main` that shows
//! why caching them would be wrong.
//!
//! Split by who is responsible for catching them. `///cache:pure` is a promise
//! by the author; the analyser checks only what it can observe directly and
//! takes the rest on trust.
//!
//!     zig build run-impure       # watch the answers change between calls
//!     zig-out/bin/zigcache impure.zig    # exits 1 with 6 violations

const std = @import("std");

var call_count: u64 = 0;

const Buffer = struct { data: []u8 };

// ---------------------------------------------------------------------------
// Reported. These are direct observations, not judgements about other code.
// ---------------------------------------------------------------------------

/// Reads and writes container-level state.
///cache:pure
pub fn counter(n: u64) u64 {
    call_count += 1;
    return n + call_count;
}

/// Same, reached only through a callee.
///cache:pure
pub fn sneaky(n: u64) u64 {
    return n + helper();
}

fn helper() u64 {
    call_count += 1;
    return call_count;
}

/// A function value has no content to hash.
///cache:pure
pub fn applied(n: u64, f: *const fn (u64) u64) u64 {
    return f(n);
}

/// anytype: the analyser cannot know what will be passed.
///cache:pure
pub fn generic(x: anytype) usize {
    return @sizeOf(@TypeOf(x));
}

/// Mutates through a parameter, so the `///cache:deep` promise is false.
///cache:pure
///cache:deep b
pub fn clobber(b: *Buffer) usize {
    b.data = b.data[0..b.data.len -| 1];
    return b.data.len;
}

/// Reference parameter with no `///cache:deep` promise.
///cache:pure
pub fn unmarked(xs: []const u64) usize {
    return xs.len;
}

// ---------------------------------------------------------------------------
// Not reported, by design. Each is impure, and each would need the analyser to
// judge code it cannot see. `///cache:pure` here is simply a false promise.
//
// Worth noting how visible these are in Zig anyway: reaching the outside world
// mostly means taking an `Io`, so it shows up in the signature.
// ---------------------------------------------------------------------------

///cache:pure
pub fn stamped(n: i64, io: std.Io) i64 {
    const now: std.Io.Clock.Timestamp = .now(io, .real);
    return n + @as(i64, @truncate(now.raw.nanoseconds));
}

///cache:pure
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
