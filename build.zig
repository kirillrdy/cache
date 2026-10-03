const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimo_mod = b.addModule("zimo", .{
        .root_source_file = b.path("zimo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const demo = b.addExecutable(.{
        .name = "demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zimo", .module = zimo_mod },
            },
        }),
    });
    b.step("demo", "Build and install the caching demo").dependOn(&b.addInstallArtifact(demo, .{}).step);

    const run_demo = b.addRunArtifact(demo);
    b.step("run", "Run the caching demo").dependOn(&run_demo.step);

    const tests = b.addTest(.{ .root_module = zimo_mod });
    b.step("test", "Test the runtime").dependOn(&b.addRunArtifact(tests).step);
}
