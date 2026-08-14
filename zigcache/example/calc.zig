const std = @import("std");

/// scale is a container-level const. It is folded into the checksum of any
/// function that reads it, directly or through a callee.
const scale: f64 = 1000.0;

/// Weights is a container-level type. Changing a field changes the checksum of
/// every pure function that mentions it.
const Weights = struct {
    alpha: f64,
    beta: f64,
};

///cache:pure
pub fn slowFib(n: u64) u64 {
    if (n < 2) return n;
    return slowFib(n - 1) + slowFib(n - 2);
}

/// score depends on sum, normalise, scale and Weights. All four are part of
/// its cache identity.
///
///cache:pure
///cache:deep xs
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
