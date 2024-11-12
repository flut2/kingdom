const std = @import("std");
const assets = @import("../assets.zig");
const utils = @import("shared").utils;
const map = @import("../game/map.zig");
const ui_systems = @import("../ui/systems.zig");
const base = @import("base.zig");
const main = @import("../main.zig");
const camera = @import("../camera.zig");

const Particle = @import("../game/particles.zig").Particle;
const Player = @import("../game/player.zig").Player;
const Entity = @import("../game/entity.zig").Entity;
const Enemy = @import("../game/enemy.zig").Enemy;
const Container = @import("../game/container.zig").Container;
const Portal = @import("../game/portal.zig").Portal;
const Projectile = @import("../game/projectile.zig").Projectile;

fn drawSide(
    idx: u16,
    x: f32,
    y: f32,
    atlas_data: assets.AtlasData,
    draw_data: base.DrawData,
    color: u32,
    color_intensity: f32,
    alpha: f32,
    x1: f32,
    y1: f32,
    x2: f32,
    y2: f32,
    x3: f32,
    y3: f32,
    x4: f32,
    y4: f32,
) u16 {
    var new_idx = idx;

    const atlas_data_new = atlas_data;
    _ = x;
    _ = y;

    new_idx = base.drawQuadVerts(
        new_idx,
        x1,
        y1,
        x2,
        y2,
        x3,
        y3,
        x4,
        y4,
        atlas_data_new,
        draw_data,
        .{ .base_color = color, .base_color_intensity = color_intensity, .alpha_mult = alpha },
    );

    return new_idx;
}

fn drawWall(
    idx: u16,
    x: f32,
    y: f32,
    alpha: f32,
    atlas_data: assets.AtlasData,
    top_atlas_data: assets.AtlasData,
    draw_data: base.DrawData,
    cam_data: base.CameraData,
) u16 {
    var idx_new: u16 = idx;

    const screen_pos = cam_data.rotateAroundCameraClip(x, y);
    const screen_x = screen_pos.x;
    const screen_y = -screen_pos.y;
    const px_per_tile = camera.px_per_tile * cam_data.scale;
    const screen_y_top = screen_y + px_per_tile;

    const radius = @sqrt(@as(f32, px_per_tile * px_per_tile / 2)) + 1;
    const pi_div_4 = std.math.pi / 4.0;
    const top_right_angle = pi_div_4;
    const bottom_right_angle = 3.0 * pi_div_4;
    const bottom_left_angle = 5.0 * pi_div_4;
    const top_left_angle = 7.0 * pi_div_4;

    const x1 = (screen_x + radius * @cos(top_left_angle + cam_data.angle)) * cam_data.clip_scale_x;
    const y1 = (screen_y + radius * @sin(top_left_angle + cam_data.angle)) * cam_data.clip_scale_y;
    const x2 = (screen_x + radius * @cos(bottom_left_angle + cam_data.angle)) * cam_data.clip_scale_x;
    const y2 = (screen_y + radius * @sin(bottom_left_angle + cam_data.angle)) * cam_data.clip_scale_y;
    const x3 = (screen_x + radius * @cos(bottom_right_angle + cam_data.angle)) * cam_data.clip_scale_x;
    const y3 = (screen_y + radius * @sin(bottom_right_angle + cam_data.angle)) * cam_data.clip_scale_y;
    const x4 = (screen_x + radius * @cos(top_right_angle + cam_data.angle)) * cam_data.clip_scale_x;
    const y4 = (screen_y + radius * @sin(top_right_angle + cam_data.angle)) * cam_data.clip_scale_y;

    const top_y1 = (screen_y_top + radius * @sin(top_left_angle + cam_data.angle)) * cam_data.clip_scale_y;
    const top_y2 = (screen_y_top + radius * @sin(bottom_left_angle + cam_data.angle)) * cam_data.clip_scale_y;
    const top_y3 = (screen_y_top + radius * @sin(bottom_right_angle + cam_data.angle)) * cam_data.clip_scale_y;
    const top_y4 = (screen_y_top + radius * @sin(top_right_angle + cam_data.angle)) * cam_data.clip_scale_y;

    const pi_div_2 = std.math.pi / 2.0;
    const bound_angle = utils.halfBound(cam_data.angle);
    const color = 0x000000;

    if (bound_angle >= pi_div_2 and bound_angle <= std.math.pi or bound_angle >= -std.math.pi and bound_angle <= -pi_div_2 and y > 0) {
        idx_new = drawSide(idx_new, x, y - 1, atlas_data, draw_data, color, 0.25, alpha, x3, top_y3, x4, top_y4, x4, y4, x3, y3);
    }

    if (bound_angle <= pi_div_2 and bound_angle >= -pi_div_2 and y < std.math.maxInt(u32)) {
        idx_new = drawSide(idx_new, x, y + 1, atlas_data, draw_data, color, 0.25, alpha, x1, top_y1, x2, top_y2, x2, y2, x1, y1);
    }

    if (bound_angle >= 0 and bound_angle <= std.math.pi and x > 0) {
        idx_new = drawSide(idx_new, x - 1, y, atlas_data, draw_data, color, 0.25, alpha, x3, top_y3, x2, top_y2, x2, y2, x3, y3);
    }

    if (bound_angle <= 0 and bound_angle >= -std.math.pi and x < std.math.maxInt(u32)) {
        idx_new = drawSide(idx_new, x + 1, y, atlas_data, draw_data, color, 0.25, alpha, x4, top_y4, x1, top_y1, x1, y1, x4, y4);
    }

    return drawSide(idx_new, -1.0, -1.0, top_atlas_data, draw_data, color, 0.1, alpha, x1, top_y1, x2, top_y2, x3, top_y3, x4, top_y4);
}

fn drawParticle(idx: u16, pt: Particle, draw_data: base.DrawData, cam_data: base.CameraData) u16 {
    var new_idx = idx;

    switch (pt) {
        inline else => |particle| {
            if (!cam_data.visibleInCamera(particle.x, particle.y))
                return new_idx;

            const w = assets.particle.texWRaw() * particle.size * cam_data.scale;
            const h = assets.particle.texHRaw() * particle.size * cam_data.scale;
            const screen_pos = cam_data.rotateAroundCamera(particle.x, particle.y);
            const z_off = particle.z * (-camera.px_per_tile * cam_data.scale) - h - assets.padding * particle.size * cam_data.scale;

            new_idx = base.drawQuad(
                new_idx,
                screen_pos.x - w / 2.0,
                screen_pos.y + z_off,
                w,
                h,
                assets.particle,
                draw_data,
                cam_data,
                .{
                    .shadow_texel_mult = 1.0 / particle.size,
                    .alpha_mult = particle.alpha_mult,
                    .base_color = particle.color,
                    .base_color_intensity = 1.0,
                    .force_glow_off = true,
                },
            );
        },
    }

    return new_idx;
}

fn drawConditions(idx: u16, draw_data: base.DrawData, cam_data: base.CameraData, cond_int: @typeInfo(utils.Condition).@"struct".backing_integer.?, float_time_ms: f32, x: f32, y: f32) u16 {
    var new_idx = idx;

    var cond_len: f32 = 0.0;
    for (0..@bitSizeOf(utils.Condition)) |i| {
        if (cond_int & (@as(usize, 1) << @intCast(i)) != 0)
            cond_len += if (base.condition_rects[i].len > 0) 1.0 else 0.0;
    }

    var cond_new_idx: f32 = 0.0;
    for (0..@bitSizeOf(utils.Condition)) |i| {
        if (cond_int & (@as(usize, 1) << @intCast(i)) != 0) {
            const data = base.condition_rects[i];
            if (data.len > 0) {
                const frame_new_idx: usize = @intFromFloat(float_time_ms / (0.5 * std.time.us_per_s));
                const current_frame = data[@mod(frame_new_idx, data.len)];
                const cond_w = current_frame.texWRaw();
                const cond_h = current_frame.texHRaw();

                new_idx = base.drawQuad(
                    new_idx,
                    x - cond_len * (cond_w + 2) / 2 + cond_new_idx * (cond_w + 2),
                    y,
                    cond_w,
                    cond_h,
                    current_frame,
                    draw_data,
                    cam_data,
                    .{ .shadow_texel_mult = 1.0, .force_glow_off = true },
                );
                cond_new_idx += 1.0;
            }
        }
    }

    return new_idx;
}

fn drawPlayer(idx: u16, player: *Player, draw_data: base.DrawData, cam_data: base.CameraData, float_time_ms: f32, allocator: std.mem.Allocator) u16 {
    var new_idx = idx;

    if (ui_systems.screen == .editor or player.dead or !cam_data.visibleInCamera(player.x, player.y))
        return new_idx;

    const size = camera.size_mult * cam_data.scale * player.size_mult;

    var atlas_data = player.atlas_data;
    const x_offset = player.render_x_offset;

    var sink: f32 = 1.0;
    if (map.getSquare(player.x, player.y, true)) |square| {
        sink += if (square.data.sink) 0.75 else 0;
    }

    atlas_data.tex_h /= sink;

    const w = atlas_data.texWRaw() * size;
    const h = atlas_data.texHRaw() * size;

    var screen_pos = cam_data.rotateAroundCamera(player.x, player.y);
    screen_pos.x += x_offset;
    screen_pos.y += player.z * -camera.px_per_tile - h + assets.padding * size;

    var alpha_mult: f32 = player.alpha;
    if (player.condition.invisible)
        alpha_mult = 0.6;

    var color: u32 = 0;
    var color_intensity: f32 = 0.0;
    _ = &color;
    _ = &color_intensity;
    // flash

    if (main.settings.enable_lights and player.data.light.color != std.math.maxInt(u32)) {
        const light_size = player.data.light.radius + player.data.light.pulse *
            @sin(float_time_ms / 1000.0 * player.data.light.pulse_speed);

        const light_w = w * light_size * 4;
        const light_h = h * light_size * 4;
        base.lights.append(allocator, .{
            .x = screen_pos.x - light_w / 2.0,
            .y = screen_pos.y - h * light_size * 1.5,
            .w = light_w,
            .h = light_h,
            .color = player.data.light.color,
            .intensity = player.data.light.intensity,
        }) catch unreachable;
    }

    if (player.name_text_data) |*data| {
        const star_w = player.star_icon.texWRaw() * 2.0;
        const star_h = player.star_icon.texHRaw() * 2.0;
        const star_pad = 8;
        const total_w = (data.width + star_w - assets.padding * 6 + star_pad) * cam_data.scale;
        const max_h = @max(data.height - assets.padding * 2, star_h - assets.padding * 4) * cam_data.scale;
        const star_icon_x = screen_pos.x - x_offset - total_w / 2 - assets.padding * 2;

        new_idx = base.drawQuad(
            new_idx,
            star_icon_x,
            screen_pos.y - max_h - (star_h - assets.padding * 4 - max_h) / 2.0 - assets.padding * 2,
            star_w,
            star_h,
            player.star_icon,
            draw_data,
            cam_data,
            .{ .force_glow_off = true, .shadow_texel_mult = 0.5 },
        );

        new_idx = base.drawText(
            new_idx,
            star_icon_x + star_w - assets.padding * 4 + star_pad,
            screen_pos.y - max_h - (data.height - assets.padding * 2 - max_h) / 2.0 - assets.padding,
            data,
            draw_data,
            cam_data,
            .{},
            true,
        );
    }

    new_idx = base.drawQuad(
        new_idx,
        screen_pos.x - w / 2.0,
        screen_pos.y,
        w,
        h,
        atlas_data,
        draw_data,
        cam_data,
        .{
            .shadow_texel_mult = 2.0 / size,
            .alpha_mult = alpha_mult,
            .base_color = color,
            .base_color_intensity = color_intensity,
        },
    );

    var y_pos: f32 = if (sink != 1.0) 10.0 else 0.0;

    if (player.hp >= 0 and player.hp < player.max_hp) {
        const hp_bar_w = assets.hp_bar_data.texWRaw() * 2 * cam_data.scale;
        const hp_bar_h = assets.hp_bar_data.texHRaw() * 2 * cam_data.scale;
        const hp_bar_y = screen_pos.y + h + y_pos;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - x_offset - hp_bar_w / 2.0,
            hp_bar_y,
            hp_bar_w,
            hp_bar_h,
            assets.empty_bar_data,
            draw_data,
            cam_data,
            .{ .shadow_texel_mult = 0.5, .force_glow_off = true },
        );

        const float_hp: f32 = @floatFromInt(player.hp);
        const float_max_hp: f32 = @floatFromInt(player.max_hp);
        const left_pad = 2.0;
        const w_no_pad = 20.0;
        const total_w = 24.0;
        const hp_perc = (left_pad / total_w) + (w_no_pad / total_w) * (float_hp / float_max_hp);

        var hp_bar_data = assets.hp_bar_data;
        hp_bar_data.tex_w *= hp_perc;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - x_offset - hp_bar_w / 2.0,
            hp_bar_y,
            hp_bar_w * hp_perc,
            hp_bar_h,
            hp_bar_data,
            draw_data,
            cam_data,
            .{ .shadow_texel_mult = 0.5, .force_glow_off = true },
        );

        y_pos += hp_bar_h;
    }

    if (player.mp >= 0 and player.mp < player.max_mp) {
        const mp_bar_w = assets.mp_bar_data.width() * 2 * cam_data.scale;
        const mp_bar_h = assets.mp_bar_data.height() * 2 * cam_data.scale;
        const mp_bar_y = screen_pos.y + h + y_pos;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - x_offset - mp_bar_w / 2.0,
            mp_bar_y,
            mp_bar_w,
            mp_bar_h,
            assets.empty_bar_data,
            draw_data,
            cam_data,
            .{ .shadow_texel_mult = 0.5, .force_glow_off = true },
        );

        const float_mp: f32 = @floatFromInt(player.mp);
        const float_max_mp: f32 = @floatFromInt(player.max_mp);
        const left_pad = 2.0;
        const w_no_pad = 20.0;
        const total_w = 24.0;
        const mp_perc = (left_pad / total_w) + (w_no_pad / total_w) * (float_mp / float_max_mp);

        var mp_bar_data = assets.mp_bar_data;
        mp_bar_data.tex_w *= mp_perc;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - x_offset - mp_bar_w / 2.0,
            mp_bar_y,
            mp_bar_w * mp_perc,
            mp_bar_h,
            mp_bar_data,
            draw_data,
            cam_data,
            .{ .shadow_texel_mult = 0.5, .force_glow_off = true },
        );

        y_pos += mp_bar_h;
    }

    const cond_int: @typeInfo(utils.Condition).@"struct".backing_integer.? = @bitCast(player.condition);
    if (cond_int > 0) {
        new_idx = drawConditions(new_idx, draw_data, cam_data, cond_int, float_time_ms, screen_pos.x - x_offset, screen_pos.y + h + y_pos);
        y_pos += 20;
    }

    return new_idx;
}

fn drawEntity(idx: u16, entity: *Entity, draw_data: base.DrawData, cam_data: base.CameraData, float_time_ms: f32, allocator: std.mem.Allocator) u16 {
    var new_idx = idx;

    if (entity.dead or !cam_data.visibleInCamera(entity.x, entity.y))
        return new_idx;

    var screen_pos = cam_data.rotateAroundCamera(entity.x, entity.y);
    const size = camera.size_mult * cam_data.scale * entity.size_mult;

    if (entity.data.draw_on_ground) {
        const tile_size = @as(f32, camera.px_per_tile) * cam_data.scale;
        const h_half = tile_size / 2.0;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - tile_size / 2.0,
            screen_pos.y - h_half,
            tile_size,
            tile_size,
            entity.atlas_data,
            draw_data,
            cam_data,
            .{ .rotation = cam_data.angle, .alpha_mult = entity.alpha, .force_glow_off = true },
        );

        if (entity.name_text_data) |*data| {
            new_idx = base.drawText(
                new_idx,
                screen_pos.x - data.width * cam_data.scale / 2,
                screen_pos.y - h_half - data.height * cam_data.scale - 5,
                data,
                draw_data,
                cam_data,
                .{},
                true,
            );
        }

        return new_idx;
    }

    if (entity.data.is_wall) {
        new_idx = drawWall(new_idx, entity.x, entity.y, entity.alpha, entity.atlas_data, entity.top_atlas_data, draw_data, cam_data);
        return new_idx;
    }

    var atlas_data = entity.atlas_data;
    var sink: f32 = 1.0;
    if (map.getSquare(entity.x, entity.y, true)) |square| {
        sink += if (square.data.sink) 0.75 else 0;
    }

    atlas_data.tex_h /= sink;

    const w = atlas_data.texWRaw() * size;
    const h = atlas_data.texHRaw() * size;

    screen_pos.y += entity.z * -camera.px_per_tile - h + assets.padding * size;

    var alpha_mult: f32 = entity.alpha;
    if (entity.condition.invisible)
        alpha_mult = 0.6;

    var color: u32 = 0;
    var color_intensity: f32 = 0.0;
    _ = &color;
    _ = &color_intensity;
    // flash

    if (main.settings.enable_lights and entity.data.light.color != std.math.maxInt(u32)) {
        const light_size = entity.data.light.radius + entity.data.light.pulse * @sin(float_time_ms / 1000.0 * entity.data.light.pulse_speed);
        const light_w = w * light_size * 4;
        const light_h = h * light_size * 4;
        base.lights.append(allocator, .{
            .x = screen_pos.x - light_w / 2.0,
            .y = screen_pos.y - h * light_size * 1.5,
            .w = light_w,
            .h = light_h,
            .color = entity.data.light.color,
            .intensity = entity.data.light.intensity,
        }) catch unreachable;
    }

    if (entity.data.show_name) {
        if (entity.name_text_data) |*data| {
            new_idx = base.drawText(
                new_idx,
                screen_pos.x - data.width * cam_data.scale / 2,
                screen_pos.y - data.height * cam_data.scale - 5,
                data,
                draw_data,
                cam_data,
                .{},
                true,
            );
        }
    }

    new_idx = base.drawQuad(
        new_idx,
        screen_pos.x - w / 2.0,
        screen_pos.y,
        w,
        h,
        atlas_data,
        draw_data,
        cam_data,
        .{
            .shadow_texel_mult = 2.0 / size,
            .alpha_mult = alpha_mult,
            .base_color = color,
            .base_color_intensity = color_intensity,
        },
    );

    var y_pos: f32 = if (sink != 1.0) 10.0 else 0.0;

    if (entity.hp >= 0 and entity.hp < entity.max_hp) {
        const hp_bar_w = assets.hp_bar_data.texWRaw() * 2 * cam_data.scale;
        const hp_bar_h = assets.hp_bar_data.texHRaw() * 2 * cam_data.scale;
        const hp_bar_y = screen_pos.y + h + y_pos;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - hp_bar_w / 2.0,
            hp_bar_y,
            hp_bar_w,
            hp_bar_h,
            assets.empty_bar_data,
            draw_data,
            cam_data,
            .{ .shadow_texel_mult = 0.5, .force_glow_off = true },
        );

        const float_hp: f32 = @floatFromInt(entity.hp);
        const float_max_hp: f32 = @floatFromInt(entity.max_hp);
        const hp_perc = 1.0 / (float_hp / float_max_hp);
        var hp_bar_data = assets.hp_bar_data;
        hp_bar_data.tex_w /= hp_perc;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - hp_bar_w / 2.0,
            hp_bar_y,
            hp_bar_w / hp_perc,
            hp_bar_h,
            hp_bar_data,
            draw_data,
            cam_data,
            .{},
        );

        y_pos += hp_bar_h;
    }

    return new_idx;
}

fn drawEnemy(idx: u16, enemy: *Enemy, draw_data: base.DrawData, cam_data: base.CameraData, float_time_ms: f32, allocator: std.mem.Allocator) u16 {
    var new_idx = idx;

    if (enemy.dead or !cam_data.visibleInCamera(enemy.x, enemy.y))
        return new_idx;

    var screen_pos = cam_data.rotateAroundCamera(enemy.x, enemy.y);
    const size = camera.size_mult * cam_data.scale * enemy.size_mult;

    var atlas_data = enemy.atlas_data;
    const x_offset = enemy.render_x_offset;

    var sink: f32 = 1.0;
    if (map.getSquare(enemy.x, enemy.y, true)) |square| {
        sink += if (square.data.sink) 0.75 else 0;
    }

    atlas_data.tex_h /= sink;

    const w = atlas_data.texWRaw() * size;
    const h = atlas_data.texHRaw() * size;

    screen_pos.x += x_offset;
    screen_pos.y += enemy.z * -camera.px_per_tile - h + assets.padding * size;

    var alpha_mult: f32 = enemy.alpha;
    if (enemy.condition.invisible)
        alpha_mult = 0.6;

    var color: u32 = 0;
    var color_intensity: f32 = 0.0;
    _ = &color;
    _ = &color_intensity;
    // flash

    if (main.settings.enable_lights and enemy.data.light.color != std.math.maxInt(u32)) {
        const light_size = enemy.data.light.radius + enemy.data.light.pulse * @sin(float_time_ms / 1000.0 * enemy.data.light.pulse_speed);
        const light_w = w * light_size * 4;
        const light_h = h * light_size * 4;
        base.lights.append(allocator, .{
            .x = screen_pos.x - light_w / 2.0,
            .y = screen_pos.y - h * light_size * 1.5,
            .w = light_w,
            .h = light_h,
            .color = enemy.data.light.color,
            .intensity = enemy.data.light.intensity,
        }) catch unreachable;
    }

    if (enemy.data.show_name) {
        if (enemy.name_text_data) |*data| {
            new_idx = base.drawText(
                new_idx,
                screen_pos.x - x_offset - data.width * cam_data.scale / 2,
                screen_pos.y - data.height * cam_data.scale - 5,
                data,
                draw_data,
                cam_data,
                .{},
                true,
            );
        }
    }

    new_idx = base.drawQuad(
        new_idx,
        screen_pos.x - w / 2.0,
        screen_pos.y,
        w,
        h,
        atlas_data,
        draw_data,
        cam_data,
        .{
            .shadow_texel_mult = 2.0 / size,
            .alpha_mult = alpha_mult,
            .base_color = color,
            .base_color_intensity = color_intensity,
        },
    );

    var y_pos: f32 = if (sink != 1.0) 10.0 else 0.0;

    if (enemy.hp >= 0 and enemy.hp < enemy.max_hp) {
        const hp_bar_w = assets.hp_bar_data.texWRaw() * 2 * cam_data.scale;
        const hp_bar_h = assets.hp_bar_data.texHRaw() * 2 * cam_data.scale;
        const hp_bar_y = screen_pos.y + h + y_pos;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - x_offset - hp_bar_w / 2.0,
            hp_bar_y,
            hp_bar_w,
            hp_bar_h,
            assets.empty_bar_data,
            draw_data,
            cam_data,
            .{ .shadow_texel_mult = 0.5, .force_glow_off = true },
        );

        const float_hp: f32 = @floatFromInt(enemy.hp);
        const float_max_hp: f32 = @floatFromInt(enemy.max_hp);
        const hp_perc = 1.0 / (float_hp / float_max_hp);
        var hp_bar_data = assets.hp_bar_data;
        hp_bar_data.tex_w /= hp_perc;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - x_offset - hp_bar_w / 2.0,
            hp_bar_y,
            hp_bar_w / hp_perc,
            hp_bar_h,
            hp_bar_data,
            draw_data,
            cam_data,
            .{ .shadow_texel_mult = 0.5, .force_glow_off = true },
        );

        y_pos += hp_bar_h;
    }

    const cond_int: @typeInfo(utils.Condition).@"struct".backing_integer.? = @bitCast(enemy.condition);
    if (cond_int > 0) {
        new_idx = drawConditions(new_idx, draw_data, cam_data, cond_int, float_time_ms, screen_pos.x - x_offset, screen_pos.y + h + y_pos);
        y_pos += 20;
    }

    return new_idx;
}

fn drawPortal(idx: u16, portal: *Portal, draw_data: base.DrawData, cam_data: base.CameraData, float_time_ms: f32, allocator: std.mem.Allocator, int_id: u32) u16 {
    var new_idx = idx;

    if (!cam_data.visibleInCamera(portal.x, portal.y))
        return new_idx;

    var screen_pos = cam_data.rotateAroundCamera(portal.x, portal.y);
    const size = camera.size_mult * cam_data.scale * portal.size_mult;

    if (portal.data.draw_on_ground) {
        const tile_size = @as(f32, camera.px_per_tile) * cam_data.scale;
        const h_half = tile_size / 2.0;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - tile_size / 2.0,
            screen_pos.y - h_half,
            tile_size,
            tile_size,
            portal.atlas_data,
            draw_data,
            cam_data,
            .{ .rotation = cam_data.angle, .alpha_mult = portal.alpha, .force_glow_off = true },
        );

        if (portal.name_text_data) |*data| {
            new_idx = base.drawText(
                new_idx,
                screen_pos.x - data.width * cam_data.scale / 2,
                screen_pos.y - h_half - data.height * cam_data.scale - 5,
                data,
                draw_data,
                cam_data,
                .{},
                true,
            );
        }

        if (int_id == portal.map_id) {
            const button_w = 100 / 5;
            const button_h = 100 / 5;
            const total_w = base.enter_text_data.width * cam_data.scale + button_w;

            new_idx = base.drawQuad(
                new_idx,
                screen_pos.x - total_w / 2,
                screen_pos.y + h_half + 5,
                button_w,
                button_h,
                assets.interact_key_tex,
                draw_data,
                cam_data,
                .{ .force_glow_off = true },
            );

            new_idx = base.drawText(
                new_idx,
                screen_pos.x - total_w / 2 + button_w,
                screen_pos.y + h_half + 5,
                &base.enter_text_data,
                draw_data,
                cam_data,
                .{},
                true,
            );
        }

        return new_idx;
    }

    var atlas_data = portal.atlas_data;

    var sink: f32 = 1.0;
    if (map.getSquare(portal.x, portal.y, true)) |square| {
        sink += if (square.data.sink) 0.75 else 0;
    }

    atlas_data.tex_h /= sink;

    const w = atlas_data.texWRaw() * size;
    const h = atlas_data.texHRaw() * size;

    screen_pos.y += portal.z * -camera.px_per_tile - h + assets.padding * size;

    const alpha_mult: f32 = portal.alpha;
    var color: u32 = 0;
    var color_intensity: f32 = 0.0;
    _ = &color;
    _ = &color_intensity;
    // flash

    if (main.settings.enable_lights and portal.data.light.color != std.math.maxInt(u32)) {
        const light_size = portal.data.light.radius + portal.data.light.pulse * @sin(float_time_ms / 1000.0 * portal.data.light.pulse_speed);
        const light_w = w * light_size * 4;
        const light_h = h * light_size * 4;
        base.lights.append(allocator, .{
            .x = screen_pos.x - light_w / 2.0,
            .y = screen_pos.y - h * light_size * 1.5,
            .w = light_w,
            .h = light_h,
            .color = portal.data.light.color,
            .intensity = portal.data.light.intensity,
        }) catch unreachable;
    }

    if (portal.name_text_data) |*data| {
        new_idx = base.drawText(
            new_idx,
            screen_pos.x - data.width * cam_data.scale / 2,
            screen_pos.y - data.height * cam_data.scale - 5,
            data,
            draw_data,
            cam_data,
            .{},
            true,
        );
    }

    if (int_id == portal.map_id) {
        const button_w = 100 / 5;
        const button_h = 100 / 5;
        const total_w = base.enter_text_data.width * cam_data.scale + button_w;

        new_idx = base.drawQuad(
            new_idx,
            screen_pos.x - total_w / 2,
            screen_pos.y + h + 5,
            button_w,
            button_h,
            assets.interact_key_tex,
            draw_data,
            cam_data,
            .{ .force_glow_off = true },
        );

        new_idx = base.drawText(
            new_idx,
            screen_pos.x - total_w / 2 + button_w,
            screen_pos.y + h + 5,
            &base.enter_text_data,
            draw_data,
            cam_data,
            .{},
            true,
        );
    }

    new_idx = base.drawQuad(
        new_idx,
        screen_pos.x - w / 2.0,
        screen_pos.y,
        w,
        h,
        atlas_data,
        draw_data,
        cam_data,
        .{
            .shadow_texel_mult = 2.0 / size,
            .alpha_mult = alpha_mult,
            .base_color = color,
            .base_color_intensity = color_intensity,
        },
    );

    return new_idx;
}

fn drawContainer(idx: u16, container: *Container, draw_data: base.DrawData, cam_data: base.CameraData, float_time_ms: f32, allocator: std.mem.Allocator) u16 {
    var new_idx = idx;

    if (!cam_data.visibleInCamera(container.x, container.y))
        return new_idx;

    var screen_pos = cam_data.rotateAroundCamera(container.x, container.y);
    const size = camera.size_mult * cam_data.scale * container.size_mult;

    var atlas_data = container.atlas_data;

    var sink: f32 = 1.0;
    if (map.getSquare(container.x, container.y, true)) |square| {
        sink += if (square.data.sink) 0.75 else 0;
    }

    atlas_data.tex_h /= sink;

    const w = atlas_data.texWRaw() * size;
    const h = atlas_data.texHRaw() * size;

    screen_pos.y += container.z * -camera.px_per_tile - h + assets.padding * size;

    const alpha_mult: f32 = container.alpha;
    var color: u32 = 0;
    var color_intensity: f32 = 0.0;
    _ = &color;
    _ = &color_intensity;
    // flash

    if (main.settings.enable_lights and container.data.light.color != std.math.maxInt(u32)) {
        const light_size = container.data.light.radius + container.data.light.pulse * @sin(float_time_ms / 1000.0 * container.data.light.pulse_speed);
        const light_w = w * light_size * 4;
        const light_h = h * light_size * 4;
        base.lights.append(allocator, .{
            .x = screen_pos.x - light_w / 2.0,
            .y = screen_pos.y - h * light_size * 1.5,
            .w = light_w,
            .h = light_h,
            .color = container.data.light.color,
            .intensity = container.data.light.intensity,
        }) catch unreachable;
    }

    if (container.data.show_name) {
        if (container.name_text_data) |*data| {
            new_idx = base.drawText(
                new_idx,
                screen_pos.x - data.width * cam_data.scale / 2,
                screen_pos.y - data.height * cam_data.scale - 5,
                data,
                draw_data,
                cam_data,
                .{},
                true,
            );
        }
    }

    new_idx = base.drawQuad(
        new_idx,
        screen_pos.x - w / 2.0,
        screen_pos.y,
        w,
        h,
        atlas_data,
        draw_data,
        cam_data,
        .{
            .shadow_texel_mult = 2.0 / size,
            .alpha_mult = alpha_mult,
            .base_color = color,
            .base_color_intensity = color_intensity,
        },
    );

    return new_idx;
}

fn drawProjectile(idx: u16, proj: Projectile, draw_data: base.DrawData, cam_data: base.CameraData, float_time_ms: f32, allocator: std.mem.Allocator) u16 {
    var new_idx = idx;

    if (!cam_data.visibleInCamera(proj.x, proj.y))
        return new_idx;

    const size = camera.size_mult * cam_data.scale * proj.data.size_mult;
    const w = proj.atlas_data.texWRaw() * size;
    const h = proj.atlas_data.texHRaw() * size;
    const screen_pos = cam_data.rotateAroundCamera(proj.x, proj.y);
    const z_offset = proj.z * -camera.px_per_tile - h + assets.padding * size;
    const rotation = proj.data.rotation;
    const angle_correction = @as(f32, @floatFromInt(proj.data.angle_correction)) * std.math.degreesToRadians(45);
    const angle = -(proj.visual_angle + angle_correction +
        (if (rotation == 0.0) 0.0 else float_time_ms / rotation) - cam_data.angle);

    if (main.settings.enable_lights and proj.data.light.color != std.math.maxInt(u32)) {
        const light_size = proj.data.light.radius + proj.data.light.pulse * @sin(float_time_ms / 1000.0 * proj.data.light.pulse_speed);
        const light_w = w * light_size * 4;
        const light_h = h * light_size * 4;
        base.lights.append(allocator, .{
            .x = screen_pos.x - light_w / 2.0,
            .y = screen_pos.y + z_offset - h * light_size * 1.5,
            .w = light_w,
            .h = light_h,
            .color = proj.data.light.color,
            .intensity = proj.data.light.intensity,
        }) catch unreachable;
    }

    new_idx = base.drawQuad(
        new_idx,
        screen_pos.x - w / 2.0,
        screen_pos.y + z_offset,
        w,
        h,
        proj.atlas_data,
        draw_data,
        cam_data,
        .{ .shadow_texel_mult = 2.0 / size, .rotation = angle, .force_glow_off = true },
    );

    return new_idx;
}

pub fn drawEntities(
    idx: u16,
    draw_data: base.DrawData,
    cam_data: base.CameraData,
    float_time_ms: f32,
    allocator: std.mem.Allocator,
) u16 {
    var new_idx = idx;

    {
        var lock = map.useLockForType(Entity);
        lock.lock();
        defer lock.unlock();
        for (map.listForType(Entity).items) |*e| new_idx = drawEntity(new_idx, e, draw_data, cam_data, float_time_ms, allocator);
    }

    {
        var lock = map.useLockForType(Enemy);
        lock.lock();
        defer lock.unlock();
        for (map.listForType(Enemy).items) |*e| new_idx = drawEnemy(new_idx, e, draw_data, cam_data, float_time_ms, allocator);
    }

    {
        var lock = map.useLockForType(Portal);
        lock.lock();
        defer lock.unlock();
        for (map.listForType(Portal).items) |*p| new_idx = drawPortal(new_idx, p, draw_data, cam_data, float_time_ms, allocator, map.interactive.map_id.load(.acquire));
    }

    {
        var lock = map.useLockForType(Container);
        lock.lock();
        defer lock.unlock();
        for (map.listForType(Container).items) |*c| new_idx = drawContainer(new_idx, c, draw_data, cam_data, float_time_ms, allocator);
    }

    {
        var lock = map.useLockForType(Projectile);
        lock.lock();
        defer lock.unlock();
        for (map.listForType(Projectile).items) |p| new_idx = drawProjectile(new_idx, p, draw_data, cam_data, float_time_ms, allocator);
    }

    {
        var lock = map.useLockForType(Player);
        lock.lock();
        defer lock.unlock();
        for (map.listForType(Player).items) |*p| new_idx = drawPlayer(new_idx, p, draw_data, cam_data, float_time_ms, allocator);
    }

    {
        var lock = map.useLockForType(Particle);
        lock.lock();
        defer lock.unlock();
        for (map.listForType(Particle).items) |p| new_idx = drawParticle(new_idx, p, draw_data, cam_data);
    }

    return new_idx;
}
