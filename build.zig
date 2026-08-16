const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zimo_mod = b.addModule("zimo", .{
        .root_source_file = b.path("zimo.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ort_include = b.option([]const u8, "ort-include", "Path to ONNX Runtime include directory") orelse "/nix/store/7lh21x4rrkg3dc8wdpzrwpghv6j70jys-onnxruntime-1.27.1-dev/include";
    const ort_lib = b.option([]const u8, "ort-lib", "Path to ONNX Runtime lib directory") orelse "/nix/store/rqp078dsvlbq1rhg82kwlazq5xys3046-onnxruntime-1.27.1/lib";

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
    demo_mod.addIncludePath(.{ .cwd_relative = ort_include });
    demo_mod.addLibraryPath(.{ .cwd_relative = ort_lib });
    demo_mod.addRPath(.{ .cwd_relative = ort_lib });
    demo_mod.linkSystemLibrary("onnxruntime", .{});
    demo_mod.link_libc = true;

    const demo = b.addExecutable(.{ .name = "demo", .root_module = demo_mod });
    b.installArtifact(demo);

    // Download Tiny YOLOv3 ONNX model from official ONNX Model Zoo (github.com/onnx/models)
    const download_model = b.addSystemCommand(&.{
        "curl",
        "-sL",
        "https://media.githubusercontent.com/media/onnx/models/main/validated/vision/object_detection_segmentation/tiny-yolov3/model/tiny-yolov3-11.onnx",
    });
    const model_onnx = download_model.addPrefixedOutputFileArg("-o", "tiny-yolov3-11.onnx");
    const install_model = b.addInstallFile(model_onnx, "models/tiny-yolov3-11.onnx");
    b.getInstallStep().dependOn(&install_model.step);

    // Download test image (street.jpg) via build system into zig-out/images/
    const download_img = b.addSystemCommand(&.{
        "curl",
        "-sL",
        "https://upload.wikimedia.org/wikipedia/commons/c/c5/Tokyo_Shibuya_Scramble_Crossing_2018-10-09.jpg",
    });
    const street_jpg = download_img.addPrefixedOutputFileArg("-o", "street.jpg");
    const install_img = b.addInstallFile(street_jpg, "images/street.jpg");
    b.getInstallStep().dependOn(&install_img.step);

    const run_demo = b.addRunArtifact(demo);
    run_demo.step.dependOn(b.getInstallStep());
    b.step("run", "Run the caching demo").dependOn(&run_demo.step);

    const tests = b.addTest(.{ .root_module = zimo_mod });
    b.step("test", "Test the runtime").dependOn(&b.addRunArtifact(tests).step);
}
