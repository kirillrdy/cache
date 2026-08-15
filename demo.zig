const std = @import("std");
const zimo = @import("zimo");
const zigimg = @import("zigimg");

const c = @cImport({
    @cInclude("onnxruntime_c_api.h");
});

const here = zimo.bind(@This(), @embedFile("demo.zig"));

pub const bus_jpg = @embedFile("inputs/bus.jpg");

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

pub fn detectObjects(image: Image, min_confidence: f32) []Detection {
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
    const model_path = "models/yolov8n.onnx";
    if (api.*.CreateSession.?(env, model_path, session_options, &session) != null) return &.{};
    defer api.*.ReleaseSession.?(session);

    var mem_info: ?*c.OrtMemoryInfo = null;
    if (api.*.CreateCpuMemoryInfo.?(c.OrtArenaAllocator, c.OrtMemTypeDefault, &mem_info) != null) return &.{};
    defer api.*.ReleaseMemoryInfo.?(mem_info);

    const model_w = 640;
    const model_h = 640;
    const input_tensor_size = 1 * 3 * model_h * model_w;
    var input_data: [input_tensor_size]f32 = undefined;

    const orig_w = image.width;
    const orig_h = image.height;

    // Preprocess: sample/resize input RGB image into 640x640 float32 NCHW tensor
    for (0..model_h) |my| {
        const sy = (my * orig_h) / model_h;
        for (0..model_w) |mx| {
            const sx = (mx * orig_w) / model_w;
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

    const input_names = [_][*:0]const u8{"images"};
    const output_names = [_][*:0]const u8{"output0"};
    var output_tensor: ?*c.OrtValue = null;

    if (api.*.Run.?(
        session,
        null,
        &input_names,
        &input_tensor,
        1,
        &output_names,
        1,
        &output_tensor,
    ) != null) return &.{};
    defer api.*.ReleaseValue.?(output_tensor);

    var output_data: [*]f32 = undefined;
    if (api.*.GetTensorMutableData.?(output_tensor, @ptrCast(&output_data)) != null) return &.{};

    const num_anchors = 8400;
    const num_classes = 80;

    var candidates: [64]Detection = undefined;
    var candidate_count: usize = 0;

    for (0..num_anchors) |i| {
        var best_score: f32 = 0;
        var best_class: u32 = 0;
        for (0..num_classes) |c_idx| {
            const score = output_data[(4 + c_idx) * num_anchors + i];
            if (score > best_score) {
                best_score = score;
                best_class = @intCast(c_idx);
            }
        }

        if (best_score >= min_confidence and candidate_count < candidates.len) {
            const cx = output_data[0 * num_anchors + i];
            const cy = output_data[1 * num_anchors + i];
            const w = output_data[2 * num_anchors + i];
            const h = output_data[3 * num_anchors + i];

            const norm = (cx <= 1.0 and w <= 1.0 and cy <= 1.0 and h <= 1.0);
            const scale_x: f32 = if (norm) @as(f32, @floatFromInt(orig_w)) else (@as(f32, @floatFromInt(orig_w)) / 640.0);
            const scale_y: f32 = if (norm) @as(f32, @floatFromInt(orig_h)) else (@as(f32, @floatFromInt(orig_h)) / 640.0);

            const x1 = std.math.clamp((cx - w / 2.0) * scale_x, 0.0, @as(f32, @floatFromInt(orig_w - 1)));
            const y1 = std.math.clamp((cy - h / 2.0) * scale_y, 0.0, @as(f32, @floatFromInt(orig_h - 1)));
            const x2 = std.math.clamp((cx + w / 2.0) * scale_x, 0.0, @as(f32, @floatFromInt(orig_w - 1)));
            const y2 = std.math.clamp((cy + h / 2.0) * scale_y, 0.0, @as(f32, @floatFromInt(orig_h - 1)));

            candidates[candidate_count] = .{
                .class_id = best_class,
                .confidence = best_score,
                .x1 = x1,
                .y1 = y1,
                .x2 = x2,
                .y2 = y2,
            };
            candidate_count += 1;
        }
    }

    // Sort candidates descending by confidence
    var a_idx: usize = 0;
    while (a_idx < candidate_count) : (a_idx += 1) {
        var max_pos = a_idx;
        var b_idx = a_idx + 1;
        while (b_idx < candidate_count) : (b_idx += 1) {
            if (candidates[b_idx].confidence > candidates[max_pos].confidence) {
                max_pos = b_idx;
            }
        }
        if (max_pos != a_idx) {
            const tmp = candidates[a_idx];
            candidates[a_idx] = candidates[max_pos];
            candidates[max_pos] = tmp;
        }
    }

    // Non-maximum suppression (NMS) with IoU threshold 0.45
    var count: u32 = 0;
    var selected: [16]Detection = undefined;
    for (0..candidate_count) |i| {
        if (count >= 16) break;
        const cand = candidates[i];
        var keep = true;
        for (0..count) |j| {
            if (selected[j].class_id == cand.class_id and iou(selected[j], cand) > 0.45) {
                keep = false;
                break;
            }
        }
        if (keep) {
            selected[count] = cand;
            count += 1;
        }
    }

    if (count == 0) return &.{};
    const out = std.heap.page_allocator.alloc(Detection, count) catch return &.{};
    @memcpy(out, selected[0..count]);
    return out;
}

fn iou(a: Detection, b: Detection) f32 {
    const x1 = @max(a.x1, b.x1);
    const y1 = @max(a.y1, b.y1);
    const x2 = @min(a.x2, b.x2);
    const y2 = @min(a.y2, b.y2);

    const intersection = @max(0.0, x2 - x1) * @max(0.0, y2 - y1);
    const area_a = (a.x2 - a.x1) * (a.y2 - a.y1);
    const area_b = (b.x2 - b.x1) * (b.y2 - b.y1);
    const union_area = area_a + area_b - intersection;

    if (union_area <= 0) return 0;
    return intersection / union_area;
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

        drawBoxRgb24(rgb_slice, image.width, image.height, @intFromFloat(d.x1), @intFromFloat(d.y1), @intFromFloat(d.x2), @intFromFloat(d.y2), color, 4);
    }

    var out_img: zigimg.Image = .{
        .width = image.width,
        .height = image.height,
        .pixels = .{ .rgb24 = rgb_slice },
    };

    const write_buf = try allocator.alloc(u8, 4 * 1024 * 1024);
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

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    try zimo.open(init.io, ".zimo");
    defer zimo.close();

    std.debug.print("identity: detectObjects={s}\n\n", .{here.id(.detectObjects)[0..16]});

    const bus_image = try loadJpeg(allocator, bus_jpg);
    defer allocator.free(bus_image.pixels);

    std.debug.print("Loaded inputs/bus.jpg ({d}x{d}, {d} bytes)\n\n", .{ bus_image.width, bus_image.height, bus_image.pixels.len });

    var t = Trace.start(init.io);
    const bus_res = here.call(.detectObjects, .{ bus_image, 0.40 });
    t.report("detectObjects(bus, 0.40)", bus_res);
    t.report("detectObjects(bus, 0.40)", here.call(.detectObjects, .{ bus_image, 0.40 }));
    t.report("detectObjects(bus, 0.60)", here.call(.detectObjects, .{ bus_image, 0.60 }));

    try saveAnnotatedJpeg(allocator, init.io, "inputs/bus_annotated.jpg", bus_image, bus_res);

    std.debug.print("\nhits={d} misses={d}\n", .{ zimo.stats.hits, zimo.stats.misses });
    std.debug.print("Saved annotated image to inputs/bus_annotated.jpg\n", .{});
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

