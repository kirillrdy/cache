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

const model_size = 416;
const input_len = 3 * model_size * model_size;

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

pub fn detectObjects(allocator: std.mem.Allocator, image: Image, min_confidence: f32) []Detection {
    return runModel(allocator, image, min_confidence) catch &.{};
}

fn runModel(allocator: std.mem.Allocator, image: Image, min_confidence: f32) ![]Detection {
    const api_base = c.OrtGetApiBase() orelse return error.OnnxRuntime;
    const api: *const c.OrtApi = api_base.*.GetApi.?(c.ORT_API_VERSION) orelse return error.OnnxRuntime;

    var env: ?*c.OrtEnv = null;
    try check(api.CreateEnv.?(c.ORT_LOGGING_LEVEL_WARNING, "yolo_env", &env));
    defer api.ReleaseEnv.?(env);

    var opts: ?*c.OrtSessionOptions = null;
    try check(api.CreateSessionOptions.?(&opts));
    defer api.ReleaseSessionOptions.?(opts);

    var session: ?*c.OrtSession = null;
    try check(api.CreateSession.?(env, model_path, opts, &session));
    defer api.ReleaseSession.?(session);

    var mem: ?*c.OrtMemoryInfo = null;
    try check(api.CreateCpuMemoryInfo.?(c.OrtArenaAllocator, c.OrtMemTypeDefault, &mem));
    defer api.ReleaseMemoryInfo.?(mem);

    var input: [input_len]f32 = undefined;
    letterbox(image, &input);
    var shape_data = [_]f32{ @floatFromInt(image.height), @floatFromInt(image.width) };

    const input_tensor = try createTensor(api, mem, &input, &.{ 1, 3, model_size, model_size });
    defer api.ReleaseValue.?(input_tensor);

    const shape_tensor = try createTensor(api, mem, &shape_data, &.{ 1, 2 });
    defer api.ReleaseValue.?(shape_tensor);

    const in_names = [_][*:0]const u8{ "input_1", "image_shape" };
    const in_values = [_]?*const c.OrtValue{ input_tensor, shape_tensor };
    const out_names = [_][*:0]const u8{ "yolonms_layer_1", "yolonms_layer_1:1", "yolonms_layer_1:2" };
    var out_values = [_]?*c.OrtValue{ null, null, null };

    try check(api.Run.?(session, null, &in_names, &in_values, 2, &out_names, 3, &out_values));
    defer for (out_values) |o| api.ReleaseValue.?(o);

    const boxes = try tensorData(api, f32, out_values[0]);
    const scores = try tensorData(api, f32, out_values[1]);
    const indices = try tensorData(api, i32, out_values[2]);

    const num_boxes: usize = @intCast(try tensorDim(api, out_values[1], 2)); // [1, classes, boxes]
    const num_indices: usize = @intCast(try tensorDim(api, out_values[2], 1)); // [1, indices, 3]

    var found: [64]Detection = undefined;
    var count: usize = 0;

    for (0..num_indices) |i| {
        if (count >= found.len) break;
        const class_id: usize = @intCast(indices[i * 3 + 1]);
        const box_id: usize = @intCast(indices[i * 3 + 2]);
        const confidence = scores[class_id * num_boxes + box_id];
        if (confidence < min_confidence) continue;

        const b = boxes[box_id * 4 ..][0..4];
        found[count] = .{
            .class_id = @intCast(class_id),
            .confidence = confidence,
            .x1 = clamp(b[1], image.width),
            .y1 = clamp(b[0], image.height),
            .x2 = clamp(b[3], image.width),
            .y2 = clamp(b[2], image.height),
        };
        count += 1;
    }

    return allocator.dupe(Detection, found[0..count]);
}

fn letterbox(image: Image, out: *[input_len]f32) void {
    @memset(out, 128.0 / 255.0);

    const src_w: f32 = @floatFromInt(image.width);
    const src_h: f32 = @floatFromInt(image.height);
    const scale = @min(model_size / src_w, model_size / src_h);
    const dst_w: usize = @intFromFloat(src_w * scale);
    const dst_h: usize = @intFromFloat(src_h * scale);
    const pad_x = (model_size - dst_w) / 2;
    const pad_y = (model_size - dst_h) / 2;
    const plane = model_size * model_size;

    for (0..dst_h) |y| {
        const src_y = (y * image.height) / dst_h;
        const dst_row = (pad_y + y) * model_size + pad_x;
        for (0..dst_w) |x| {
            const src_x = (x * image.width) / dst_w;
            const src_idx = (src_y * image.width + src_x) * 3;
            for (0..3) |ch| {
                out[ch * plane + dst_row + x] = @as(f32, @floatFromInt(image.pixels[src_idx + ch])) / 255.0;
            }
        }
    }
}

fn clamp(v: f32, max: u32) f32 {
    return std.math.clamp(v, 0.0, @as(f32, @floatFromInt(max - 1)));
}

fn check(status: ?*c.OrtStatus) !void {
    if (status != null) return error.OnnxRuntime;
}

fn createTensor(api: *const c.OrtApi, mem: ?*c.OrtMemoryInfo, data: []f32, shape: []const i64) !*c.OrtValue {
    var tensor: ?*c.OrtValue = null;
    try check(api.CreateTensorWithDataAsOrtValue.?(
        mem,
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

fn tensorDim(api: *const c.OrtApi, value: ?*c.OrtValue, dim_idx: usize) !i64 {
    var info: ?*c.OrtTensorTypeAndShapeInfo = null;
    try check(api.GetTensorTypeAndShape.?(value, &info));
    defer api.ReleaseTensorTypeAndShapeInfo.?(info);

    var dims: [8]i64 = undefined;
    var rank: usize = 0;
    try check(api.GetDimensionsCount.?(info, &rank));
    if (dim_idx >= rank) return error.OnnxRuntime;
    try check(api.GetDimensions.?(info, &dims, rank));
    return dims[dim_idx];
}

fn loadImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Image {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);

    var img = try zigimg.Image.fromMemory(allocator, bytes);
    defer img.deinit(allocator);
    try img.convert(allocator, .rgb24);

    return .{
        .width = @intCast(img.width),
        .height = @intCast(img.height),
        .pixels = try allocator.dupe(u8, img.rawBytes()),
    };
}

fn saveAnnotatedImage(allocator: std.mem.Allocator, io: std.Io, path: []const u8, image: Image, detections: []const Detection) !void {
    const pixels = try allocator.dupe(u8, image.pixels);
    defer allocator.free(pixels);
    const rgb = std.mem.bytesAsSlice(zigimg.color.Rgb24, pixels);

    for (detections) |d| {
        const color = if (d.class_id == 0) zigimg.color.Rgb24{ .r = 0, .g = 255, .b = 0 } else zigimg.color.Rgb24{ .r = 0, .g = 180, .b = 255 };
        const x1: usize = @intFromFloat(d.x1);
        const y1: usize = @intFromFloat(d.y1);
        const x2: usize = @intFromFloat(d.x2);
        const y2: usize = @intFromFloat(d.y2);
        const thickness = 8;

        for (y1..@min(y2 + 1, image.height)) |y| {
            const is_edge_y = y < y1 + thickness or y + thickness > y2;
            for (x1..@min(x2 + 1, image.width)) |x| {
                if (is_edge_y or x < x1 + thickness or x + thickness > x2) {
                    rgb[y * image.width + x] = color;
                }
            }
        }
    }

    const annotated: zigimg.Image = .{
        .width = image.width,
        .height = image.height,
        .pixels = .{ .rgb24 = rgb },
    };

    const write_buf = try allocator.alloc(u8, 1024 * 1024);
    defer allocator.free(write_buf);
    try annotated.writeToFilePath(allocator, io, path, write_buf, .{ .jpeg = .{ .quality = 85 } });
}

pub fn main(init: std.process.Init) !void {
    try zimo.open(init.gpa, init.io, ".zimo");
    defer zimo.close();

    std.debug.print("identity: detectObjects={s}\n\n", .{here.id(.detectObjects)[0..16]});

    const image = try loadImage(init.gpa, init.io, image_path);
    defer init.gpa.free(image.pixels);

    std.debug.print("Loaded {s} ({d}x{d}, {d} bytes)\n\n", .{ image_path, image.width, image.height, image.pixels.len });

    var first_result: []Detection = &.{};
    defer init.gpa.free(first_result);

    for ([_]f32{ 0.40, 0.40, 0.60 }, 0..) |min_confidence, run| {
        const hits_before = zimo.stats.hits;
        const start = std.Io.Timestamp.now(init.io, .awake);

        const detections = here.call(.detectObjects, .{ init.gpa, image, min_confidence });
        const elapsed = start.untilNow(init.io, .awake);
        const status = if (zimo.stats.hits > hits_before) "HIT " else "MISS";

        std.debug.print("detectObjects(street, {d:.2})    {s}  {f: >9} -> {d} detections\n", .{
            min_confidence,
            status,
            elapsed,
            detections.len,
        });

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

        if (run == 0) first_result = detections else init.gpa.free(detections);
    }

    try saveAnnotatedImage(init.gpa, init.io, annotated_path, image, first_result);
    std.debug.print("\nhits={d} misses={d}\nSaved annotated image to {s}\n", .{ zimo.stats.hits, zimo.stats.misses, annotated_path });
}
