//! A program whose expensive functions are cached.
//!
//! Everything here is one file on purpose: the pure functions, the memoised
//! wrappers around them, and a `main` that exercises both. Each function's
//! cache identity is derived from this file at compile time -- no generated
//! file, no build step.

const std = @import("std");
const cache = @import("cache");

/// One binding for the whole file; each cached function then costs one line.
const here = cache.Source(@embedFile("demo.zig"));

// ------------------------------------------------------ the pure functions ---

/// A container-level const. It is folded into the checksum of any function
/// that reads it, directly or through a callee.
const scale: f64 = 1000.0;

/// A container-level type. Changing a field changes the checksum of every pure
/// function that mentions it.
pub const Weights = struct {
    alpha: f64,
    beta: f64,
};

/// Deliberately slow, so the cache has something to save.
pub fn slowFib(n: u64) u64 {
    if (n < 2) return n;
    return slowFib(n - 1) + slowFib(n - 2);
}

/// Depends on sum, normalise, scale and Weights. All four are part of its
/// cache identity, so editing any of them invalidates its entries.
///
/// `xs` is a slice and needs no extra annotation: it is hashed by content,
/// which is the only sound choice for a pure function.
pub fn score(xs: []const f64, w: Weights) f64 {
    return normalise(sum(xs)) * w.alpha + @as(f64, @floatFromInt(xs.len)) * w.beta;
}

fn sum(xs: []const f64) f64 {
    var total: f64 = 0;
    for (xs) |x| total += x;
    return total;
}

fn normalise(v: f64) f64 {
    return v / scale;
}

// ----------------------------------------------------------- the wrappers ---

/// The checksum is derived from this file at compile time, covering each
/// function and everything it transitively references. The originals stay
/// callable and uncached.
const cachedSlowFib = here.memo("slowFib", slowFib);
const cachedScore = here.memo("score", score);

// ----------------------------------------------------------------- main ---

pub fn main(init: std.process.Init) !void {
    try cache.open(init.io, ".zigcache");
    defer cache.close();

    std.debug.print("identities: slowFib={s} score={s}\n\n", .{ here.id("slowFib")[0..16], here.id("score")[0..16] });

    const w: Weights = .{ .alpha = 2, .beta = 0.5 };
    const xs: []const f64 = &.{ 1, 2, 3, 4, 5 };
    // Same contents, a different backing array.
    const copy: []const f64 = &.{ 1, 2, 3, 4, 5 };
    const changed: []const f64 = &.{ 1, 2, 3, 4, 6 };

    var t = Trace.start(init.io);
    t.report("slowFib(34)", cachedSlowFib(.{34}));
    t.report("slowFib(34)", cachedSlowFib(.{34}));
    t.report("score", cachedScore(.{ xs, w }));
    t.report("score", cachedScore(.{ xs, w }));
    t.report("score (copy)", cachedScore(.{ copy, w }));
    t.report("score (changed)", cachedScore(.{ changed, w }));

    std.debug.print("\nhits={d} misses={d}\n", .{ cache.stats.hits, cache.stats.misses });
}

const Trace = struct {
    io: std.Io,
    mark: std.Io.Clock.Timestamp,
    hits: usize,

    fn start(io: std.Io) Trace {
        return .{
            .io = io,
            .mark = .now(io, .awake),
            .hits = cache.stats.hits,
        };
    }

    /// Zig evaluates the argument before the call, so the elapsed time read
    /// here covers exactly the call that produced `value`.
    fn report(t: *Trace, label: []const u8, value: anytype) void {
        const now: std.Io.Clock.Timestamp = .now(t.io, .awake);
        const us: u64 = @intCast(@max(0, t.mark.durationTo(now).raw.toMicroseconds()));
        const status = if (cache.stats.hits > t.hits) "HIT " else "MISS";
        std.debug.print("{s: <18} {s} {d: >8}us -> {any}\n", .{ label, status, us, value });
        t.hits = cache.stats.hits;
        t.mark = .now(t.io, .awake);
    }
};
