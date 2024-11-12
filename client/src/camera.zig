const pad = @import("assets.zig").padding;
const main = @import("main.zig");
const std = @import("std");
const map = @import("game/map.zig");
const utils = @import("shared").utils;

pub const SquareRenderData = struct {
    px_per_tile: f32 = @as(f32, px_per_tile),
    x1: f32 = 0.0,
    y1: f32 = 0.0,
    x2: f32 = 0.0,
    y2: f32 = 0.0,
    x3: f32 = 0.0,
    y3: f32 = 0.0,
    x4: f32 = 0.0,
    y4: f32 = 0.0,
};

pub const px_per_tile = 64;
pub const size_mult = 6.0;

pub var lock: std.Thread.Mutex = .{};
pub var x: f32 = 0.0;
pub var y: f32 = 0.0;
pub var z: f32 = 0.0;

pub var minimap_zoom: f32 = 4.0;
pub var quake = false;
pub var quake_amount: f32 = 0.0;

pub var cos: f32 = 0.0;
pub var sin: f32 = 0.0;
pub var clip_x: f32 = 0.0;
pub var clip_y: f32 = 0.0;

pub var angle: f32 = 0.0;
pub var min_x: u32 = 0;
pub var min_y: u32 = 0;
pub var max_x: u32 = 0;
pub var max_y: u32 = 0;
pub var max_dist_sq: f32 = 0.0;

pub var screen_width: f32 = 1280.0;
pub var screen_height: f32 = 720.0;
pub var clip_scale_x: f32 = 2.0 / 1280.0;
pub var clip_scale_y: f32 = 2.0 / 720.0;

pub var scale: f32 = 1.0;
pub var square_render_data: SquareRenderData = .{};

pub fn update(target_x: f32, target_y: f32, dt: f32, rotate: i8) void {
    const map_w = map.info.width;
    const map_h = map.info.height;
    if (map_w == 0 or map_h == 0) return;

    lock.lock();
    defer lock.unlock();

    var tx: f32 = target_x;
    var ty: f32 = target_y;
    if (quake) {
        const max_quake = 0.5;
        const quake_buildup = 10.0 * @as(f32, std.time.us_per_s);
        quake_amount += dt * max_quake / quake_buildup;
        if (quake_amount > max_quake)
            quake_amount = max_quake;
        tx += utils.plusMinus(quake_amount);
        ty += utils.plusMinus(quake_amount);
    }

    x = tx;
    y = ty;

    if (rotate != 0) {
        const float_rotate: f32 = @floatFromInt(rotate);
        angle = @mod(angle + dt * main.settings.rotate_speed * float_rotate, std.math.tau);
    }

    const cos_angle = @cos(angle);
    const sin_angle = @sin(angle);

    cos = cos_angle * px_per_tile * scale;
    sin = sin_angle * px_per_tile * scale;
    clip_x = (tx * cos_angle + ty * sin_angle) * -px_per_tile * scale;
    clip_y = (tx * -sin_angle + ty * cos_angle) * -px_per_tile * scale;

    const w_half = screen_width / (2 * px_per_tile * scale);
    const h_half = screen_height / (2 * px_per_tile * scale);
    max_dist_sq = w_half * w_half + h_half * h_half;
    const max_dist = @ceil(@sqrt(max_dist_sq) + 1);

    const min_x_dt = tx - max_dist;
    min_x = @max(0, if (min_x_dt < 0) 0 else @as(u32, @intFromFloat(min_x_dt)));
    max_x = @min(map_w - 1, @as(u32, @intFromFloat(tx + max_dist)));

    const min_y_dt = ty - max_dist;
    min_y = @max(0, if (min_y_dt < 0) 0 else @as(u32, @intFromFloat(min_y_dt)));
    max_y = @min(map_h - 1, @as(u32, @intFromFloat(ty + max_dist)));

    const px_per_tile_scaled = px_per_tile * scale;
    const radius = @sqrt(@as(f32, px_per_tile_scaled * px_per_tile_scaled / 2)) + 1;
    const pi_div_4 = std.math.pi / 4.0;
    const top_right_angle = pi_div_4;
    const bottom_right_angle = 3.0 * pi_div_4;
    const bottom_left_angle = 5.0 * pi_div_4;
    const top_left_angle = 7.0 * pi_div_4;
    square_render_data = .{
        .px_per_tile = px_per_tile_scaled,
        .x1 = radius * @cos(top_left_angle + angle) * clip_scale_x,
        .y1 = radius * @sin(top_left_angle + angle) * clip_scale_y,
        .x2 = radius * @cos(bottom_left_angle + angle) * clip_scale_x,
        .y2 = radius * @sin(bottom_left_angle + angle) * clip_scale_y,
        .x3 = radius * @cos(bottom_right_angle + angle) * clip_scale_x,
        .y3 = radius * @sin(bottom_right_angle + angle) * clip_scale_y,
        .x4 = radius * @cos(top_right_angle + angle) * clip_scale_x,
        .y4 = radius * @sin(top_right_angle + angle) * clip_scale_y,
    };
}

pub fn rotateAroundCameraClip(x_in: f32, y_in: f32) struct { x: f32, y: f32 } {
    return .{
        .x = x_in * cos + y_in * sin + clip_x,
        .y = x_in * -sin + y_in * cos + clip_y,
    };
}

pub fn rotateAroundCamera(x_in: f32, y_in: f32) struct { x: f32, y: f32 } {
    return .{
        .x = x_in * cos + y_in * sin + clip_x + screen_width / 2.0,
        .y = x_in * -sin + y_in * cos + clip_y + screen_height / 2.0,
    };
}

pub fn visibleInCamera(x_in: f32, y_in: f32) bool {
    if (std.math.isNan(x_in) or
        std.math.isNan(y_in) or
        x_in < 0 or
        y_in < 0 or
        x_in > std.math.maxInt(u32) or
        y_in > std.math.maxInt(u32))
        return false;

    const floor_x: u32 = @intFromFloat(@floor(x_in));
    const floor_y: u32 = @intFromFloat(@floor(y_in));
    return !(floor_x < min_x or floor_x > max_x or floor_y < min_y or floor_y > max_y);
}

pub fn screenToWorld(x_in: f32, y_in: f32) struct { x: f32, y: f32 } {
    const cos_angle = @cos(angle);
    const sin_angle = @sin(angle);
    const x_div = (x_in - screen_width / 2.0) / (px_per_tile * scale);
    const y_div = (y_in - screen_height / 2.0) / (px_per_tile * scale);
    return .{
        .x = x + x_div * cos_angle - y_div * sin_angle + 0.5,
        .y = y + x_div * sin_angle + y_div * cos_angle + 0.5,
    };
}
