const std = @import("std");
const zigcache = @import("cache");

const here = zigcache.Source(@This(), @embedFile("demo.zig"));
const cache = here.call;

const scale: f64 = 1000.0;

pub const Weights = struct {
    alpha: f64,
    beta: f64,
};

pub fn slowFib(n: u64) u64 {
    if (n < 2) return n;
    return slowFib(n - 1) + slowFib(n - 2);
}

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

pub fn main(init: std.process.Init) !void {
    try zigcache.open(init.io, ".zigcache");
    defer zigcache.close();

    std.debug.print("identities: slowFib={s} score={s}\n\n", .{ here.id(.slowFib)[0..16], here.id(.score)[0..16] });

    const w: Weights = .{ .alpha = 2, .beta = 0.5 };
    const xs: []const f64 = &.{ 1, 2, 3, 4, 5 };
    const copy: []const f64 = &.{ 1, 2, 3, 4, 5 };
    const changed: []const f64 = &.{ 1, 2, 3, 4, 6 };

    var t = Trace.start(init.io);
    t.report("slowFib(34)", cache(.slowFib, .{34}));
    t.report("slowFib(34)", cache(.slowFib, .{34}));
    t.report("score", cache(.score, .{ xs, w }));
    t.report("score", cache(.score, .{ xs, w }));
    t.report("score (copy)", cache(.score, .{ copy, w }));
    t.report("score (changed)", cache(.score, .{ changed, w }));

    std.debug.print("\nhits={d} misses={d}\n", .{ zigcache.stats.hits, zigcache.stats.misses });
}

const Trace = struct {
    io: std.Io,
    mark: std.Io.Clock.Timestamp,
    hits: usize,

    fn start(io: std.Io) Trace {
        return .{
            .io = io,
            .mark = .now(io, .awake),
            .hits = zigcache.stats.hits,
        };
    }

    fn report(t: *Trace, label: []const u8, value: anytype) void {
        const now: std.Io.Clock.Timestamp = .now(t.io, .awake);
        const us: u64 = @intCast(@max(0, t.mark.durationTo(now).raw.toMicroseconds()));
        const status = if (zigcache.stats.hits > t.hits) "HIT " else "MISS";
        std.debug.print("{s: <18} {s} {d: >8}us -> {any}\n", .{ label, status, us, value });
        t.hits = zigcache.stats.hits;
        t.mark = .now(t.io, .awake);
    }
};
