const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The library. Depending packages get it as `@import("cache")`.
    const cache_mod = b.addModule("cache", .{
        .root_source_file = b.path("cache.zig"),
        .target = target,
        .optimize = optimize,
    });

    // The analyser: parses a source file, checksums each ///cache:pure
    // function over its transitive dependencies, writes the ids out.
    const analyser = b.addExecutable(.{
        .name = "zigcache",
        .root_module = b.createModule(.{
            .root_source_file = b.path("analyser.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(analyser);

    // Running it is a build step, so the checksums are regenerated whenever
    // the analysed source changes and never land in the source tree.
    const gen = b.addRunArtifact(analyser);
    gen.addFileArg(b.path("demo.zig"));
    const ids_file = gen.addOutputFileArg("cache_ids.zig");

    const demo_mod = b.createModule(.{
        .root_source_file = b.path("demo.zig"),
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("cache", cache_mod);
    demo_mod.addAnonymousImport("cache_ids", .{ .root_source_file = ids_file });

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

    const tests = b.addTest(.{ .root_module = cache_mod });
    b.step("test", "Test the runtime").dependOn(&b.addRunArtifact(tests).step);
}
