const std = @import("std");
const zimo = @import("zimo");

const here = zimo.bind(@This(), @embedFile("demo.zig"));

pub fn expensiveSquare(io: std.Io, number: u32) !u64 {
    try std.Io.sleep(io, .fromSeconds(1), .awake);
    return @as(u64, number) * number;
}

pub fn main(init: std.process.Init) !void {
    try zimo.open(init.gpa, init.io, ".zimo");
    defer zimo.close();

    std.debug.print("identity: expensiveSquare={s}\n\n", .{here.id(.expensiveSquare)[0..16]});

    for ([_]u32{ 12, 12, 13 }) |number| {
        const start = std.Io.Timestamp.now(init.io, .awake);
        const result = try here.call(.expensiveSquare, .{ init.io, number });
        const elapsed = start.untilNow(init.io, .awake);

        std.debug.print("expensiveSquare({d})    {f: >9} -> {d}\n", .{
            number,
            elapsed,
            result,
        });
    }

    std.debug.print("\nRun again to reuse the results stored in .zimo.\n", .{});
}
