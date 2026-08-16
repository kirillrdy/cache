const std = @import("std");
const zimo = @import("zimo");
const zigimg = @import("zigimg");

const c = @cImport({
    @cInclude("onnxruntime_c_api.h");
});

const here = zimo.bind(@This(), @embedFile("demo.zig"));

const model_path = "zig-out/models/tiny-yolov3-11.onnx";
const image_path = "zig-out/images/street.jpg";
const annotated_path = "zig-out/images/street_annotated.jpg";

/// Tiny YOLOv3 takes a 416x416 letterboxed image and emits boxes in the
/// coordinates of the original image.
const model_size = 416;
const input_len = 3 * model_size * model_size;
const max_detections = 64;

pub const CLASS_NAMES = [_][]const u8{
    "person",       "bicycle",   "car",           "motorcycle", "airplane",     "bus",            "train",      "truck",      "boat",          "traffic light",
    "fire hydrant", "stop sign", "parking meter", "bench",      "bird",         "cat",            "dog",        "horse",      "sheep",         "cow",
    "elephant",     "bear",      "zebra",         "giraffe",    "backpack",     "umbrella",       "handbag",    "tie",        "suitcase",      "frisbee",
    "skis",         "snowboard", "sports ball",   "kite",       "baseball bat", "baseball glove", "skateboard", "surfboard",  "tennis racket", "bottle",
    "wine glass",   "cup",       "fork",          "knife",      "spoon",        "bowl",           "banana",     "apple",      "sandwich",      "orange",
    "broccoli",     "carrot",    "hot dog",       "pizza",      "donut",        "cake",           "chair",      "couch",      "potted plant",  "bed",
    "dining table", "toilet",    "tv",            "laptop",     "mouse",        "remote",         "keyboard",   "cell phone", "microwave",     "oven",
    "toaster",      "sink",      "refrigerator",  "book",       "clock",        "vase",           "scissors",   "teddy bear", "hair drier",    "toothbrush",
};

/// Packed RGB, three bytes per pixel.
pub const Image = struct {
    width: u32,
    height: u32,
    pixels: []const u8,
};

pub const Detection = struct {
    class_id: u32,
    confidence: f32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
};

/// The memoised entry point: everything below is pure, so a cache hit and a
/// real inference run are indistinguishable to the caller.
pub fn detectObjects(allocator: std.mem.Allocator, image: Image, min_confidence: f32) []Detection {
    return runModel(allocator, image, min_confidence) catch &.{};
}

fn runModel(allocator: std.mem.Allocator, image: Image, min_confidence: f32) ![]Detection {
    const api_base = c.OrtGetApiBase();
    if (api_base == null) return error.OnnxRuntime;
    const api: *const c.OrtApi = api_base.*.GetApi.?(c.ORT_API_VERSION) orelse return error.OnnxRuntime;

    var env: ?*c.OrtEnv = null;
    try check(api.CreateEnv.?(c.ORT_LOGGING_LEVEL_WARNING, "yolo_env", &env));
    defer api.ReleaseEnv.?(env);

    var session_options: ?*c.OrtSessionOptions = null;
    try check(api.CreateSessionOptions.?(&session_options));
    defer api.ReleaseSessionOptions.?(session_options);

    var session: ?*c.OrtSession = null;
    try check(api.CreateSession.?(env, model_path, session_options, &session));
    defer api.ReleaseSession.?(session);

    var mem_info: ?*c.OrtMemoryInfo = null;
    try check(api.CreateCpuMemoryInfo.?(c.OrtArenaAllocator, c.OrtMemTypeDefault, &mem_info));
    defer api.ReleaseMemoryInfo.?(mem_info);

    var input: [input_len]f32 = undefined;
    letterbox(image, &input);
    var original_size = [_]f32{ @floatFromInt(image.height), @floatFromInt(image.width) };

    const input_tensor = try floatTensor(api, mem_info, &input, &.{ 1, 3, model_size, model_size });
    defer api.ReleaseValue.?(input_tensor);

    const size_tensor = try floatTensor(api, mem_info, &original_size, &.{ 1, 2 });
    defer api.ReleaseValue.?(size_tensor);

    const input_names = [_][*:0]const u8{ "input_1", "image_shape" };
    const inputs = [_]?*const c.OrtValue{ input_tensor, size_tensor };
    const output_names = [_][*:0]const u8{ "yolonms_layer_1", "yolonms_layer_1:1", "yolonms_layer_1:2" };
    var outputs = [_]?*c.OrtValue{ null, null, null };

    try check(api.Run.?(session, null, &input_names, &inputs, inputs.len, &output_names, outputs.len, &outputs));
    defer for (outputs) |o| api.ReleaseValue.?(o);

    const boxes = try tensorData(api, f32, outputs[0]);
    const scores = try tensorData(api, f32, outputs[1]);
    const indices = try tensorData(api, i32, outputs[2]);

    // scores are [1, classes, boxes]; selected indices are [1, n, 3] (or [n, 3]).
    const num_boxes: usize = @intCast(try dimFromEnd(api, outputs[1], 0));
    const num_indices: usize = @intCast(try dimFromEnd(api, outputs[2], 1));

    var found: [max_detections]Detection = undefined;
    var count: usize = 0;

    for (0..num_indices) |i| {
        if (count == found.len) break;
        const class_id: usize = @intCast(indices[i * 3 + 1]);
        const box_id: usize = @intCast(indices[i * 3 + 2]);

        const confidence = scores[class_id * num_boxes + box_id];
        if (confidence < min_confidence) continue;

        // A box arrives as (y1, x1, y2, x2).
        const box = boxes[box_id * 4 ..][0..4];
        found[count] = .{
            .class_id = @intCast(class_id),
            .confidence = confidence,
            .x1 = clampToExtent(box[1], image.width),
            .y1 = clampToExtent(box[0], image.height),
            .x2 = clampToExtent(box[3], image.width),
            .y2 = clampToExtent(box[2], image.height),
        };
        count += 1;
    }

    return allocator.dupe(Detection, found[0..count]);
}

/// Scale the image to fit inside model_size x model_size, centred on a grey
/// background, as planar RGB in [0, 1].
fn letterbox(image: Image, out: *[input_len]f32) void {
    @memset(out, 128.0 / 255.0);

    const src_w: usize = image.width;
    const src_h: usize = image.height;
    const scale = @min(
        model_size / @as(f32, @floatFromInt(src_w)),
        model_size / @as(f32, @floatFromInt(src_h)),
    );
    const dst_w: usize = @intFromFloat(@as(f32, @floatFromInt(src_w)) * scale);
    const dst_h: usize = @intFromFloat(@as(f32, @floatFromInt(src_h)) * scale);
    const pad_x = (model_size - dst_w) / 2;
    const pad_y = (model_size - dst_h) / 2;
    const plane = model_size * model_size;

    for (0..dst_h) |y| {
        const src_row = ((y * src_h) / dst_h) * src_w;
        const dst_row = (pad_y + y) * model_size + pad_x;
        for (0..dst_w) |x| {
            const src = (src_row + (x * src_w) / dst_w) * 3;
            for (0..3) |channel| {
                out[channel * plane + dst_row + x] = @as(f32, @floatFromInt(image.pixels[src + channel])) / 255.0;
            }
        }
    }
}

fn clampToExtent(v: f32, extent: usize) f32 {
    return std.math.clamp(v, 0.0, @as(f32, @floatFromInt(extent - 1)));
}

// ---------------------------------------------------------- onnxruntime ---

fn check(status: ?*c.OrtStatus) !void {
    if (status != null) return error.OnnxRuntime;
}

fn floatTensor(api: *const c.OrtApi, mem_info: ?*c.OrtMemoryInfo, data: []f32, shape: []const i64) !*c.OrtValue {
    var tensor: ?*c.OrtValue = null;
    try check(api.CreateTensorWithDataAsOrtValue.?(
        mem_info,
        data.ptr,
        data.len * @sizeOf(f32),
        shape.ptr,
        shape.len,
        c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &tensor,
    ));
    return tensor.?;
}

fn tensorData(api: *const c.OrtApi, comptime T: type, value: ?*c.OrtValue) ![*]T {
    var data: [*]T = undefined;
    try check(api.GetTensorMutableData.?(value, @ptrCast(&data)));
    return data;
}

/// A dimension of `value` counted from the end, so that a leading batch
/// dimension may be present or absent.
fn dimFromEnd(api: *const c.OrtApi, value: ?*c.OrtValue, from_end: usize) !i64 {
    var info: ?*c.OrtTensorTypeAndShapeInfo = null;
    try check(api.GetTensorTypeAndShape.?(value, &info));
    defer api.ReleaseTensorTypeAndShapeInfo.?(info);

    var rank: usize = 0;
    try check(api.GetDimensionsCount.?(info, &rank));

    var dims: [8]i64 = undefined;
    if (rank > dims.len or from_end >= rank) return error.OnnxRuntime;
    try check(api.GetDimensions.?(info, &dims, rank));
    return dims[rank - 1 - from_end];
}

// ---------------------------------------------------------------- image ---

fn loadImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Image {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);

    var decoded = try zigimg.Image.fromMemory(allocator, bytes);
    defer decoded.deinit(allocator);
    try decoded.convert(allocator, .rgb24);

    return .{
        .width = @intCast(decoded.width),
        .height = @intCast(decoded.height),
        .pixels = try allocator.dupe(u8, decoded.rawBytes()),
    };
}

fn saveAnnotatedImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8, image: Image, detections: []const Detection) !void {
    const pixels = try allocator.dupe(u8, image.pixels);
    defer allocator.free(pixels);
    const rgb = std.mem.bytesAsSlice(zigimg.color.Rgb24, pixels);

    for (detections) |d| drawBox(rgb, image.width, image.height, d, boxColor(d.class_id));

    const annotated: zigimg.Image = .{
        .width = image.width,
        .height = image.height,
        .pixels = .{ .rgb24 = rgb },
    };

    const write_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(write_buf);

    try annotated.writeToFilePath(allocator, io, path, write_buf, .{ .jpeg = .{ .quality = 85 } });
}

fn boxColor(class_id: u32) zigimg.color.Rgb24 {
    return switch (class_id) {
        0 => .{ .r = 0, .g = 255, .b = 0 }, // person
        5 => .{ .r = 255, .g = 120, .b = 0 }, // bus
        else => .{ .r = 0, .g = 180, .b = 255 },
    };
}

fn drawBox(pixels: []zigimg.color.Rgb24, width: usize, height: usize, d: Detection, color: zigimg.color.Rgb24) void {
    const thickness = 8;
    const x1: usize = @intFromFloat(clampToExtent(@min(d.x1, d.x2), width));
    const x2: usize = @intFromFloat(clampToExtent(@max(d.x1, d.x2), width));
    const y1: usize = @intFromFloat(clampToExtent(@min(d.y1, d.y2), height));
    const y2: usize = @intFromFloat(clampToExtent(@max(d.y1, d.y2), height));

    for (y1..y2 + 1) |y| {
        const whole_row = y < y1 + thickness or y + thickness > y2;
        for (x1..x2 + 1) |x| {
            if (whole_row or x < x1 + thickness or x + thickness > x2) {
                pixels[y * width + x] = color;
            }
        }
    }
}

// ----------------------------------------------------------------- demo ---

pub fn main(init: std.process.Init) !void {
    try zimo.open(init.gpa, init.io, ".zimo");
    defer zimo.close();

    std.debug.print("identity: detectObjects={s}\n\n", .{here.id(.detectObjects)[0..16]});

    const image = try loadImage(init.gpa, init.io, image_path);
    defer init.gpa.free(image.pixels);

    std.debug.print("Loaded {s} ({d}x{d}, {d} bytes)\n\n", .{ image_path, image.width, image.height, image.pixels.len });

    var trace = Trace.start(init.io);
    var annotate: []Detection = &.{};
    defer init.gpa.free(annotate);

    // The same arguments twice, then a different threshold: only the first of
    // each pair can miss.
    for ([_]f32{ 0.40, 0.40, 0.60 }, 0..) |min_confidence, run| {
        const detections = here.call(.detectObjects, .{ init.gpa, image, min_confidence });
        trace.report(min_confidence, detections);
        if (run == 0) annotate = detections else init.gpa.free(detections);
    }

    try saveAnnotatedImage(init.gpa, init.io, annotated_path, image, annotate);

    std.debug.print("\nhits={d} misses={d}\n", .{ zimo.stats.hits, zimo.stats.misses });
    std.debug.print("Saved annotated image to {s}\n", .{annotated_path});
}

const Trace = struct {
    io: std.Io,
    mark: std.Io.Timestamp,
    hits: usize,

    fn start(io: std.Io) Trace {
        return .{
            .io = io,
            .mark = .now(io, .awake),
            .hits = zimo.stats.hits,
        };
    }

    fn report(t: *Trace, min_confidence: f32, detections: []const Detection) void {
        const status = if (zimo.stats.hits > t.hits) "HIT " else "MISS";
        var label_buf: [64]u8 = undefined;
        var elapsed_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "detectObjects(street, {d:.2})", .{min_confidence}) catch unreachable;
        const elapsed = std.fmt.bufPrint(&elapsed_buf, "{f}", .{t.mark.untilNow(t.io, .awake)}) catch unreachable;

        std.debug.print("{s: <30} {s} {s: >9} -> {d} detections\n", .{ label, status, elapsed, detections.len });
        for (detections, 1..) |d, i| {
            std.debug.print("   [{d}] {s: <12} ({d:.0}%) box=[{d:.0}, {d:.0}, {d:.0}, {d:.0}]\n", .{
                i,
                CLASS_NAMES[d.class_id],
                d.confidence * 100.0,
                d.x1,
                d.y1,
                d.x2,
                d.y2,
            });
        }

        t.hits = zimo.stats.hits;
        t.mark = .now(t.io, .awake);
    }
};
