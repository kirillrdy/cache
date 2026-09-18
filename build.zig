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
    const zigimg_dep = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });
    demo_mod.addImport("zigimg", zigimg_dep.module("zigimg"));
    demo_mod.addImport("zimo", zimo_mod);

    const backend = b.option(
        []const u8,
        "backend",
        "GPU backend for inference: opencl, cuda, or metal (defaults to metal on macOS and opencl elsewhere)",
    ) orelse if (target.result.os.tag == .macos) "metal" else "opencl";
    const onnx = b.dependency("onnx", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        // The model works in pixel coordinates of the full image, which are
        // past what a half holds exactly.
        .half = false,
    });
    demo_mod.addImport("onnx", onnx.module("onnx"));

    const demo = b.addExecutable(.{ .name = "demo", .root_module = demo_mod });
    b.installArtifact(demo);

    fetch(b, "https://media.githubusercontent.com/media/onnx/models/main/validated/vision/object_detection_segmentation/tiny-yolov3/model/tiny-yolov3-11.onnx", "models/tiny-yolov3-11.onnx");
    fetch(b, "https://upload.wikimedia.org/wikipedia/commons/c/c5/Tokyo_Shibuya_Scramble_Crossing_2018-10-09.jpg", "images/street.jpg");

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    b.step("run", "Run the caching demo").dependOn(&run_demo.step);

    const tests = b.addTest(.{ .root_module = zimo_mod });
    b.step("test", "Test the runtime").dependOn(&b.addRunArtifact(tests).step);
}

/// Downloads `url` at build time and installs it at `dest` under the prefix.
fn fetch(b: *std.Build, url: []const u8, dest: []const u8) void {
    const curl = b.addSystemCommand(&.{ "curl", "-sL", url });
    const file = curl.addPrefixedOutputFileArg("-o", std.fs.path.basename(dest));
    b.getInstallStep().dependOn(&b.addInstallFile(file, dest).step);
}
