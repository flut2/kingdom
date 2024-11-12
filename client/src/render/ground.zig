const std = @import("std");
const base = @import("base.zig");
const map = @import("../game/map.zig");
const assets = @import("../assets.zig");
const main = @import("../main.zig");

const Square = @import("../game/square.zig").Square;

fn drawSquare(
    idx: u16,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    x3: f32,
    y3: f32,
    x4: f32,
    y4: f32,
    atlas_data: assets.AtlasData,
    u_offset: f32,
    v_offset: f32,
    blends: [4]Square.Blend,
    draw_data: base.DrawData,
) u16 {
    var new_idx = idx;
    if (new_idx == base.ground_batch_vert_size) {
        draw_data.encoder.writeBuffer(
            base.ground_vb,
            0,
            base.GroundVertexData,
            base.ground_vert_data[0..base.ground_batch_vert_size],
        );
        base.endDraw(
            draw_data,
            base.ground_batch_vert_size * @sizeOf(base.GroundVertexData),
            @divExact(base.ground_batch_vert_size, 4) * 6,
        );
        new_idx = 0;
    }

    base.ground_vert_data[new_idx] = .{
        .pos_uv = .{
            .x = x1,
            .y = y1,
            .z = atlas_data.tex_w,
            .w = atlas_data.tex_h,
        },
        .left_top_blend_uv = .{
            .x = blends[Square.left_blend_idx].u,
            .y = blends[Square.left_blend_idx].v,
            .z = blends[Square.top_blend_idx].u,
            .w = blends[Square.top_blend_idx].v,
        },
        .right_bottom_blend_uv = .{
            .x = blends[Square.right_blend_idx].u,
            .y = blends[Square.right_blend_idx].v,
            .z = blends[Square.bottom_blend_idx].u,
            .w = blends[Square.bottom_blend_idx].v,
        },
        .base_and_offset_uv = .{
            .x = atlas_data.tex_u,
            .y = atlas_data.tex_v,
            .z = u_offset,
            .w = v_offset,
        },
    };

    base.ground_vert_data[new_idx + 1] = .{
        .pos_uv = .{
            .x = x2,
            .y = y2,
            .z = 0,
            .w = atlas_data.tex_h,
        },
        .left_top_blend_uv = .{
            .x = blends[Square.left_blend_idx].u,
            .y = blends[Square.left_blend_idx].v,
            .z = blends[Square.top_blend_idx].u,
            .w = blends[Square.top_blend_idx].v,
        },
        .right_bottom_blend_uv = .{
            .x = blends[Square.right_blend_idx].u,
            .y = blends[Square.right_blend_idx].v,
            .z = blends[Square.bottom_blend_idx].u,
            .w = blends[Square.bottom_blend_idx].v,
        },
        .base_and_offset_uv = .{
            .x = atlas_data.tex_u,
            .y = atlas_data.tex_v,
            .z = u_offset,
            .w = v_offset,
        },
    };

    base.ground_vert_data[new_idx + 2] = .{
        .pos_uv = .{
            .x = x3,
            .y = y3,
            .z = 0,
            .w = 0,
        },
        .left_top_blend_uv = .{
            .x = blends[Square.left_blend_idx].u,
            .y = blends[Square.left_blend_idx].v,
            .z = blends[Square.top_blend_idx].u,
            .w = blends[Square.top_blend_idx].v,
        },
        .right_bottom_blend_uv = .{
            .x = blends[Square.right_blend_idx].u,
            .y = blends[Square.right_blend_idx].v,
            .z = blends[Square.bottom_blend_idx].u,
            .w = blends[Square.bottom_blend_idx].v,
        },
        .base_and_offset_uv = .{
            .x = atlas_data.tex_u,
            .y = atlas_data.tex_v,
            .z = u_offset,
            .w = v_offset,
        },
    };

    base.ground_vert_data[new_idx + 3] = .{
        .pos_uv = .{
            .x = x4,
            .y = y4,
            .z = atlas_data.tex_w,
            .w = 0,
        },
        .left_top_blend_uv = .{
            .x = blends[Square.left_blend_idx].u,
            .y = blends[Square.left_blend_idx].v,
            .z = blends[Square.top_blend_idx].u,
            .w = blends[Square.top_blend_idx].v,
        },
        .right_bottom_blend_uv = .{
            .x = blends[Square.right_blend_idx].u,
            .y = blends[Square.right_blend_idx].v,
            .z = blends[Square.bottom_blend_idx].u,
            .w = blends[Square.bottom_blend_idx].v,
        },
        .base_and_offset_uv = .{
            .x = atlas_data.tex_u,
            .y = atlas_data.tex_v,
            .z = u_offset,
            .w = v_offset,
        },
    };

    return new_idx + 4;
}

pub fn drawSquares(idx: u16, draw_data: base.DrawData, float_time_ms: f32, cam_data: base.CameraData, allocator: std.mem.Allocator) u16 {
    var new_idx = idx;

    map.square_lock.lock();
    defer map.square_lock.unlock();
    for (cam_data.min_y..cam_data.max_y) |y| {
        for (cam_data.min_x..cam_data.max_x) |x| {
            const float_x: f32 = @floatFromInt(x);
            const float_y: f32 = @floatFromInt(y);
            if (map.getSquare(float_x, float_y, false)) |square| {
                if (square.data_id == Square.empty_tile)
                    continue;

                const screen_x = square.x * cam_data.cos + square.y * cam_data.sin + cam_data.clip_x;
                const screen_y = -(square.x * -cam_data.sin + square.y * cam_data.cos + cam_data.clip_y);

                var u_offset = square.u_offset;
                var v_offset = square.v_offset;
                if (main.settings.enable_lights) {
                    const light_color = square.data.light.color;
                    if (light_color != std.math.maxInt(u32)) {
                        const size = cam_data.square_render_data.px_per_tile * (square.data.light.radius + square.data.light.pulse *
                            @sin(float_time_ms / 1000.0 * square.data.light.pulse_speed));

                        const light_w = size * 4;
                        const light_h = size * 4;
                        base.lights.append(allocator, .{
                            .x = (screen_x + cam_data.screen_width / 2.0) - light_w / 2.0,
                            .y = (-screen_y + cam_data.screen_height / 2.0) - size * 1.5,
                            .w = light_w,
                            .h = light_h,
                            .color = light_color,
                            .intensity = square.data.light.intensity,
                        }) catch unreachable;
                    }
                }

                switch (square.data.animation.type) {
                    .wave => {
                        u_offset += @sin(square.data.animation.delta_x * float_time_ms / 1000.0) * assets.base_texel_w;
                        v_offset += @sin(square.data.animation.delta_y * float_time_ms / 1000.0) * assets.base_texel_h;
                    },
                    .flow => {
                        u_offset += (square.data.animation.delta_x * float_time_ms / 1000.0) * assets.base_texel_w;
                        v_offset += (square.data.animation.delta_y * float_time_ms / 1000.0) * assets.base_texel_h;
                    },
                    else => {},
                }

                const scaled_x = screen_x * cam_data.clip_scale_x;
                const scaled_y = screen_y * cam_data.clip_scale_y;

                new_idx = drawSquare(
                    new_idx,
                    scaled_x + cam_data.square_render_data.x1,
                    scaled_y + cam_data.square_render_data.y1,
                    scaled_x + cam_data.square_render_data.x2,
                    scaled_y + cam_data.square_render_data.y2,
                    scaled_x + cam_data.square_render_data.x3,
                    scaled_y + cam_data.square_render_data.y3,
                    scaled_x + cam_data.square_render_data.x4,
                    scaled_y + cam_data.square_render_data.y4,
                    square.atlas_data,
                    u_offset,
                    v_offset,
                    square.blends,
                    draw_data,
                );
            } else continue;
        }
    }

    return new_idx;
}
