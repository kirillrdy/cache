const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library. Depending packages get it as `@import("zimo")`.
    const zimo_mod = b.addModule("zimo", .{
        .root_source_file = b.path("zimo.zig"),
        .target = target,
        .optimize = optimize,
    });

    // No codegen step: cache identities are derived at compile time from
    // @embedFile, so there is nothing to generate and nothing to wire in.
    const demo_mod = b.createModule(.{
        .root_source_file = b.path("demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("zimo", zimo_mod);

    const demo = b.addExecutable(.{ .name = "demo", .root_module = demo_mod });
    b.installArtifact(demo);

    const impure = b.addExecutable(.{
        .name = "impure",
        .root_module = b.createModule(.{
            .root_source_file = b.path("impure.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(impure);

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    b.step("run", "Run the caching demo").dependOn(&run_demo.step);

    const run_impure = b.addRunArtifact(impure);
    b.step("run-impure", "Show why the impure examples cannot be cached")
        .dependOn(&run_impure.step);

    const tests = b.addTest(.{ .root_module = zimo_mod });
    b.step("test", "Test the runtime").dependOn(&b.addRunArtifact(tests).step);
}
