const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimo_mod = b.addModule("zimo", .{
        .root_source_file = b.path("zimo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const demo_mod = b.createModule(.{
        .root_source_file = b.path("demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("zimo", zimo_mod);

    const demo = b.addExecutable(.{ .name = "demo", .root_module = demo_mod });
    b.installArtifact(demo);

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    b.step("run", "Run the caching demo").dependOn(&run_demo.step);

    const tests = b.addTest(.{ .root_module = zimo_mod });
    b.step("test", "Test the runtime").dependOn(&b.addRunArtifact(tests).step);
}
