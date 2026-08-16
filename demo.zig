const std = @import("std");
const zimo = @import("zimo");
const zigimg = @import("zigimg");

const c = @cImport({
    @cInclude("onnxruntime_c_api.h");
});

const here = zimo.bind(@This(), @embedFile("demo.zig"));

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
    const api_base = c.OrtGetApiBase();
    if (api_base == null) return &.{};
    const api = api_base.*.GetApi.?(c.ORT_API_VERSION);
    if (api == null) return &.{};

    var env: ?*c.OrtEnv = null;
    if (api.*.CreateEnv.?(c.ORT_LOGGING_LEVEL_WARNING, "yolo_env", &env) != null) return &.{};
    defer api.*.ReleaseEnv.?(env);

    var session_options: ?*c.OrtSessionOptions = null;
    if (api.*.CreateSessionOptions.?(&session_options) != null) return &.{};
    defer api.*.ReleaseSessionOptions.?(session_options);

    var session: ?*c.OrtSession = null;
    const model_path = "zig-out/models/tiny-yolov3-11.onnx";
    if (api.*.CreateSession.?(env, model_path, session_options, &session) != null) return &.{};
    defer api.*.ReleaseSession.?(session);

    var mem_info: ?*c.OrtMemoryInfo = null;
    if (api.*.CreateCpuMemoryInfo.?(c.OrtArenaAllocator, c.OrtMemTypeDefault, &mem_info) != null) return &.{};
    defer api.*.ReleaseMemoryInfo.?(mem_info);

    const model_w: usize = 416;
    const model_h: usize = 416;
    const input_tensor_size = 1 * 3 * model_h * model_w;
    var input_data: [input_tensor_size]f32 = undefined;
    @memset(&input_data, 128.0 / 255.0);

    const orig_w = image.width;
    const orig_h = image.height;

    // Preprocess: letterbox resize input RGB image into 416x416 float32 NCHW tensor
    const scale = @min(@as(f32, @floatFromInt(model_w)) / @as(f32, @floatFromInt(orig_w)), @as(f32, @floatFromInt(model_h)) / @as(f32, @floatFromInt(orig_h)));
    const nw: usize = @intFromFloat(@as(f32, @floatFromInt(orig_w)) * scale);
    const nh: usize = @intFromFloat(@as(f32, @floatFromInt(orig_h)) * scale);
    const pad_x = (model_w - nw) / 2;
    const pad_y = (model_h - nh) / 2;

    for (0..nh) |iy| {
        const sy = (iy * orig_h) / nh;
        const my = pad_y + iy;
        for (0..nw) |ix| {
            const sx = (ix * orig_w) / nw;
            const mx = pad_x + ix;
            const src_idx = (sy * orig_w + sx) * 3;
            const r: f32 = @as(f32, @floatFromInt(image.pixels[src_idx + 0])) / 255.0;
            const g: f32 = @as(f32, @floatFromInt(image.pixels[src_idx + 1])) / 255.0;
            const b: f32 = @as(f32, @floatFromInt(image.pixels[src_idx + 2])) / 255.0;

            input_data[0 * (model_h * model_w) + my * model_w + mx] = r;
            input_data[1 * (model_h * model_w) + my * model_w + mx] = g;
            input_data[2 * (model_h * model_w) + my * model_w + mx] = b;
        }
    }

    const input_shape = [_]i64{ 1, 3, model_h, model_w };
    var input_tensor: ?*c.OrtValue = null;
    if (api.*.CreateTensorWithDataAsOrtValue.?(
        mem_info,
        &input_data,
        input_tensor_size * @sizeOf(f32),
        &input_shape,
        4,
        c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &input_tensor,
    ) != null) return &.{};
    defer api.*.ReleaseValue.?(input_tensor);

    var shape_data = [_]f32{ @floatFromInt(orig_h), @floatFromInt(orig_w) };
    const shape_shape = [_]i64{ 1, 2 };
    var shape_tensor: ?*c.OrtValue = null;
    if (api.*.CreateTensorWithDataAsOrtValue.?(
        mem_info,
        &shape_data,
        2 * @sizeOf(f32),
        &shape_shape,
        2,
        c.ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,
        &shape_tensor,
    ) != null) return &.{};
    defer api.*.ReleaseValue.?(shape_tensor);

    const input_names = [_][*:0]const u8{ "input_1", "image_shape" };
    const in_tensors = [_]?*const c.OrtValue{ input_tensor, shape_tensor };

    const output_names = [_][*:0]const u8{ "yolonms_layer_1", "yolonms_layer_1:1", "yolonms_layer_1:2" };
    var out_tensors = [_]?*c.OrtValue{ null, null, null };

    if (api.*.Run.?(
        session,
        null,
        &input_names,
        &in_tensors,
        2,
        &output_names,
        3,
        &out_tensors,
    ) != null) return &.{};
    defer for (out_tensors) |ot| api.*.ReleaseValue.?(ot);

    var boxes_data: [*]f32 = undefined;
    if (api.*.GetTensorMutableData.?(out_tensors[0], @ptrCast(&boxes_data)) != null) return &.{};

    var scores_data: [*]f32 = undefined;
    if (api.*.GetTensorMutableData.?(out_tensors[1], @ptrCast(&scores_data)) != null) return &.{};

    var indices_data: [*]i32 = undefined;
    if (api.*.GetTensorMutableData.?(out_tensors[2], @ptrCast(&indices_data)) != null) return &.{};

    var tensor_info: ?*c.OrtTensorTypeAndShapeInfo = null;
    if (api.*.GetTensorTypeAndShape.?(out_tensors[2], &tensor_info) != null) return &.{};
    defer api.*.ReleaseTensorTypeAndShapeInfo.?(tensor_info);

    var num_dims: usize = 0;
    if (api.*.GetDimensionsCount.?(tensor_info, &num_dims) != null) return &.{};
    var dims: [8]i64 = undefined;
    if (api.*.GetDimensions.?(tensor_info, &dims, num_dims) != null) return &.{};

    const num_indices: usize = if (num_dims == 3)
        @intCast(dims[1])
    else if (num_dims == 2)
        @intCast(dims[0])
    else
        0;

    const num_boxes: usize = 2535;
    var candidates: [64]Detection = undefined;
    var count: usize = 0;

    for (0..num_indices) |i| {
        if (count >= candidates.len) break;
        const class_idx: usize = @intCast(indices_data[i * 3 + 1]);
        const box_idx: usize = @intCast(indices_data[i * 3 + 2]);

        const score = scores_data[class_idx * num_boxes + box_idx];
        if (score < min_confidence) continue;

        const y1 = boxes_data[box_idx * 4 + 0];
        const x1 = boxes_data[box_idx * 4 + 1];
        const y2 = boxes_data[box_idx * 4 + 2];
        const x2 = boxes_data[box_idx * 4 + 3];

        candidates[count] = .{
            .class_id = @intCast(class_idx),
            .confidence = score,
            .x1 = std.math.clamp(x1, 0.0, @as(f32, @floatFromInt(orig_w - 1))),
            .y1 = std.math.clamp(y1, 0.0, @as(f32, @floatFromInt(orig_h - 1))),
            .x2 = std.math.clamp(x2, 0.0, @as(f32, @floatFromInt(orig_w - 1))),
            .y2 = std.math.clamp(y2, 0.0, @as(f32, @floatFromInt(orig_h - 1))),
        };
        count += 1;
    }

    return allocator.dupe(Detection, candidates[0..count]) catch &.{};
}

fn loadJpeg(allocator: std.mem.Allocator, bytes: []const u8) !Image {
    var raw = try zigimg.Image.fromMemory(allocator, bytes);
    defer raw.deinit(allocator);

    try raw.convert(allocator, .rgb24);

    const num_pixels = raw.width * raw.height;
    const pixel_bytes = try allocator.alloc(u8, num_pixels * 3);
    const rgb = raw.pixels.rgb24;
    for (0..num_pixels) |i| {
        pixel_bytes[i * 3 + 0] = rgb[i].r;
        pixel_bytes[i * 3 + 1] = rgb[i].g;
        pixel_bytes[i * 3 + 2] = rgb[i].b;
    }

    return .{
        .width = @intCast(raw.width),
        .height = @intCast(raw.height),
        .pixels = pixel_bytes,
    };
}

fn saveAnnotatedJpeg(allocator: std.mem.Allocator, io: std.Io, path: []const u8, image: Image, detections: []const Detection) !void {
    const total_pixels = image.width * image.height;
    const rgb_slice = try allocator.alloc(zigimg.color.Rgb24, total_pixels);
    defer allocator.free(rgb_slice);

    for (0..total_pixels) |i| {
        rgb_slice[i] = .{
            .r = image.pixels[i * 3 + 0],
            .g = image.pixels[i * 3 + 1],
            .b = image.pixels[i * 3 + 2],
        };
    }

    for (detections) |d| {
        const color: zigimg.color.Rgb24 = if (d.class_id == 0)
            .{ .r = 0, .g = 255, .b = 0 } // green for person
        else if (d.class_id == 5)
            .{ .r = 255, .g = 120, .b = 0 } // orange for bus
        else
            .{ .r = 0, .g = 180, .b = 255 }; // cyan for others

        drawBoxRgb24(rgb_slice, image.width, image.height, @intFromFloat(d.x1), @intFromFloat(d.y1), @intFromFloat(d.x2), @intFromFloat(d.y2), color, 8);
    }

    var out_img: zigimg.Image = .{
        .width = image.width,
        .height = image.height,
        .pixels = .{ .rgb24 = rgb_slice },
    };

    const write_buf = try allocator.alloc(u8, 32 * 1024 * 1024);
    defer allocator.free(write_buf);

    try out_img.writeToFilePath(allocator, io, path, write_buf, .{ .jpeg = .{ .quality = 85 } });
}

fn drawBoxRgb24(pixels: []zigimg.color.Rgb24, width: u32, height: u32, x1_in: i32, y1_in: i32, x2_in: i32, y2_in: i32, color: zigimg.color.Rgb24, thickness: usize) void {
    const x1 = @as(usize, @intCast(std.math.clamp(x1_in, 0, @as(i32, @intCast(width)) - 1)));
    const x2 = @as(usize, @intCast(std.math.clamp(x2_in, 0, @as(i32, @intCast(width)) - 1)));
    const y1 = @as(usize, @intCast(std.math.clamp(y1_in, 0, @as(i32, @intCast(height)) - 1)));
    const y2 = @as(usize, @intCast(std.math.clamp(y2_in, 0, @as(i32, @intCast(height)) - 1)));

    var t: usize = 0;
    while (t < thickness) : (t += 1) {
        const ty1 = @min(y1 + t, height - 1);
        const ty2 = if (y2 >= t) y2 - t else 0;
        const tx1 = @min(x1 + t, width - 1);
        const tx2 = if (x2 >= t) x2 - t else 0;

        var x = tx1;
        while (x <= tx2) : (x += 1) {
            pixels[ty1 * width + x] = color;
            pixels[ty2 * width + x] = color;
        }

        var y = ty1;
        while (y <= ty2) : (y += 1) {
            pixels[y * width + tx1] = color;
            pixels[y * width + tx2] = color;
        }
    }
}

fn loadJpegFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Image {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    return loadJpeg(allocator, bytes);
}

pub fn main(init: std.process.Init) !void {
    try zimo.open(init.gpa, init.io, ".zimo");
    defer zimo.close();

    std.debug.print("identity: detectObjects={s}\n\n", .{here.id(.detectObjects)[0..16]});

    const street_image = try loadJpegFile(init.gpa, init.io, "zig-out/images/street.jpg");
    defer init.gpa.free(street_image.pixels);

    std.debug.print("Loaded zig-out/images/street.jpg ({d}x{d}, {d} bytes)\n\n", .{ street_image.width, street_image.height, street_image.pixels.len });

    var t = Trace.start(init.io);
    const res1 = here.call(.detectObjects, .{ init.gpa, street_image, 0.40 });
    defer init.gpa.free(res1);
    t.report("detectObjects(street, 0.40)", res1);

    const res2 = here.call(.detectObjects, .{ init.gpa, street_image, 0.40 });
    defer init.gpa.free(res2);
    t.report("detectObjects(street, 0.40)", res2);

    const res3 = here.call(.detectObjects, .{ init.gpa, street_image, 0.60 });
    defer init.gpa.free(res3);
    t.report("detectObjects(street, 0.60)", res3);

    try saveAnnotatedJpeg(init.gpa, init.io, "zig-out/images/street_annotated.jpg", street_image, res1);

    std.debug.print("\nhits={d} misses={d}\n", .{ zimo.stats.hits, zimo.stats.misses });
    std.debug.print("Saved annotated image to zig-out/images/street_annotated.jpg\n", .{});
}

fn formatDuration(buf: []u8, us: u64) []const u8 {
    if (us >= 1_000_000) {
        const s = @as(f64, @floatFromInt(us)) / 1_000_000.0;
        return std.fmt.bufPrint(buf, "{d:.2}s", .{s}) catch unreachable;
    } else if (us >= 1_000) {
        const ms = @as(f64, @floatFromInt(us)) / 1_000.0;
        return std.fmt.bufPrint(buf, "{d:.2}ms", .{ms}) catch unreachable;
    } else {
        return std.fmt.bufPrint(buf, "{d}us", .{us}) catch unreachable;
    }
}

const Trace = struct {
    io: std.Io,
    mark: std.Io.Clock.Timestamp,
    hits: usize,

    fn start(io: std.Io) Trace {
        return .{
            .io = io,
            .mark = .now(io, .awake),
            .hits = zimo.stats.hits,
        };
    }

    fn report(t: *Trace, label: []const u8, detections: []const Detection) void {
        const now: std.Io.Clock.Timestamp = .now(t.io, .awake);
        const us: u64 = @intCast(@max(0, t.mark.durationTo(now).raw.toMicroseconds()));
        const status = if (zimo.stats.hits > t.hits) "HIT " else "MISS";
        var dur_buf: [16]u8 = undefined;
        const dur_str = formatDuration(&dur_buf, us);
        std.debug.print("{s: <30} {s} {s: >9} -> {d} detections\n", .{ label, status, dur_str, detections.len });
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

