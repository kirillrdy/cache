//! Functions that claim purity but are not. zigcache must reject every one.

const std = @import("std");

var call_count: u64 = 0;

const Buffer = struct { data: []u8 };

///cache:pure
pub fn counter(n: u64) u64 {
    call_count += 1;
    return n + call_count;
}

///cache:pure
pub fn stamped(n: i64) i64 {
    return n + std.time.timestamp();
}

///cache:pure
pub fn noisy(n: u64) u64 {
    return n + std.crypto.random.int(u8);
}

///cache:pure
pub fn logged(n: u64) u64 {
    std.debug.print("{d}\n", .{n});
    return n;
}

///cache:pure
pub fn applied(n: u64, f: *const fn (u64) u64) u64 {
    return f(n);
}

///cache:pure
///cache:deep b
pub fn clobber(b: *Buffer) usize {
    b.data = b.data[0..0];
    return b.data.len;
}

///cache:pure
pub fn unmarked(xs: []const u64) usize {
    return xs.len;
}

///cache:pure
pub fn generic(x: anytype) usize {
    return @sizeOf(@TypeOf(x));
}

///cache:pure
pub fn peeked(addr: usize) u8 {
    const p: *const u8 = @ptrFromInt(addr);
    return p.*;
}

///cache:pure
pub fn sneaky(n: u64) u64 {
    return n + helper();
}

fn helper() u64 {
    return @intFromPtr(&call_count);
}
