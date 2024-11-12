const std = @import("std");
const element = @import("../ui/element.zig");
const base = @import("base.zig");
const map = @import("../game/map.zig");
const assets = @import("../assets.zig");
const ui_systems = @import("../ui/systems.zig");

fn drawMinimap(
    idx: u16,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    target_x: f32,
    target_y: f32,
    tex_w: f32,
    tex_h: f32,
    rotation: f32,
    draw_data: base.DrawData,
    cam_data: base.CameraData,
    scissor: element.ScissorRect,
) u16 {
    var new_idx = idx;

    if (new_idx == base.base_batch_vert_size) {
        @branchHint(.unlikely);
        draw_data.encoder.writeBuffer(
            draw_data.buffer,
            0,
            base.BaseVertexData,
            base.base_vert_data[0..base.base_batch_vert_size],
        );
        base.endDraw(
            draw_data,
            base.base_batch_vert_size * @sizeOf(base.BaseVertexData),
            @divExact(base.base_batch_vert_size, 4) * 6,
        );
        new_idx = 0;
    }

    const scaled_w = w * cam_data.clip_scale_x;
    const scaled_h = h * cam_data.clip_scale_y;
    const scaled_x = (x - cam_data.screen_width / 2.0 + w / 2.0) * cam_data.clip_scale_x;
    const scaled_y = -(y - cam_data.screen_height / 2.0 + h / 2.0) * cam_data.clip_scale_y;

    const cos_angle = @cos(rotation);
    const sin_angle = @sin(rotation);
    const x_cos = cos_angle * scaled_w * 0.5;
    const x_sin = sin_angle * scaled_w * 0.5;
    const y_cos = cos_angle * scaled_h * 0.5;
    const y_sin = sin_angle * scaled_h * 0.5;

    const tex_u = target_x / 1024.0;
    const tex_v = target_y / 1024.0;
    const tex_w_scale = tex_w / 1024.0;
    const tex_h_scale = tex_h / 1024.0;
    const tex_w_half = tex_w_scale / 2.0;
    const tex_h_half = tex_h_scale / 2.0;

    const dont_scissor = element.ScissorRect.dont_scissor;
    const scaled_min_x = if (scissor.min_x != dont_scissor)
        (scissor.min_x + x - cam_data.screen_width / 2.0) * cam_data.clip_scale_x
    else if (rotation == 0) @as(f32, -1.0) else @as(f32, -2.0);
    const scaled_max_x = if (scissor.max_x != dont_scissor)
        (scissor.max_x + x - cam_data.screen_width / 2.0) * cam_data.clip_scale_x
    else if (rotation == 0) @as(f32, 1.0) else @as(f32, 2.0);

    // have to flip these, y is inverted... should be fixed later
    const scaled_min_y = if (scissor.max_y != dont_scissor)
        -(scissor.max_y + y - cam_data.screen_height / 2.0) * cam_data.clip_scale_y
    else if (rotation == 0) @as(f32, -1.0) else @as(f32, -2.0);
    const scaled_max_y = if (scissor.min_y != dont_scissor)
        -(scissor.min_y + y - cam_data.screen_height / 2.0) * cam_data.clip_scale_y
    else if (rotation == 0) @as(f32, 1.0) else @as(f32, 2.0);

    var x1 = -x_cos + x_sin + scaled_x;
    var tex_u1 = tex_u - tex_w_half;
    if (x1 < scaled_min_x) {
        const scale = (scaled_min_x - x1) / scaled_w;
        x1 = scaled_min_x;
        tex_u1 += scale * tex_w_scale;
    } else if (x1 > scaled_max_x) {
        const scale = (x1 - scaled_max_x) / scaled_w;
        x1 = scaled_max_x;
        tex_u1 -= scale * tex_w_scale;
    }

    var y1 = -y_sin - y_cos + scaled_y;
    var tex_v1 = tex_v + tex_h_half;
    if (y1 < scaled_min_y) {
        const scale = (scaled_min_y - y1) / scaled_h;
        y1 = scaled_min_y;
        tex_v1 -= scale * tex_h_scale;
    } else if (y1 > scaled_max_y) {
        const scale = (y1 - scaled_max_y) / scaled_h;
        y1 = scaled_max_y;
        tex_v1 += scale * tex_h_scale;
    }

    base.base_vert_data[new_idx] = base.BaseVertexData{
        .pos_uv = .{
            .x = x1,
            .y = y1,
            .z = tex_u1,
            .w = tex_v1,
        },
        .render_type = base.minimap_render_type,
    };

    var x2 = x_cos + x_sin + scaled_x;
    var tex_u2 = tex_u + tex_w_half;
    if (x2 < scaled_min_x) {
        const scale = (scaled_min_x - x2) / scaled_w;
        x2 = scaled_min_x;
        tex_u2 += scale * tex_w_scale;
    } else if (x2 > scaled_max_x) {
        const scale = (x2 - scaled_max_x) / scaled_w;
        x2 = scaled_max_x;
        tex_u2 -= scale * tex_w_scale;
    }

    var y2 = y_sin - y_cos + scaled_y;
    var tex_v2 = tex_v + tex_h_half;
    if (y2 < scaled_min_y) {
        const scale = (scaled_min_y - y2) / scaled_h;
        y2 = scaled_min_y;
        tex_v2 -= scale * tex_h_scale;
    } else if (y2 > scaled_max_y) {
        const scale = (y2 - scaled_max_y) / scaled_h;
        y2 = scaled_max_y;
        tex_v2 += scale * tex_h_scale;
    }

    base.base_vert_data[new_idx + 1] = base.BaseVertexData{
        .pos_uv = .{
            .x = x2,
            .y = y2,
            .z = tex_u2,
            .w = tex_v2,
        },
        .render_type = base.minimap_render_type,
    };

    var x3 = x_cos - x_sin + scaled_x;
    var tex_u3 = tex_u + tex_w_half;
    if (x3 < scaled_min_x) {
        const scale = (scaled_min_x - x3) / scaled_w;
        x3 = scaled_min_x;
        tex_u3 += scale * tex_w_scale;
    } else if (x3 > scaled_max_x) {
        const scale = (x3 - scaled_max_x) / scaled_w;
        x3 = scaled_max_x;
        tex_u3 -= scale * tex_w_scale;
    }

    var y3 = y_sin + y_cos + scaled_y;
    var tex_v3 = tex_v - tex_h_half;
    if (y3 < scaled_min_y) {
        const scale = (scaled_min_y - y3) / scaled_h;
        y3 = scaled_min_y;
        tex_v3 -= scale * tex_h_scale;
    } else if (y3 > scaled_max_y) {
        const scale = (y3 - scaled_max_y) / scaled_h;
        y3 = scaled_max_y;
        tex_v3 += scale * tex_h_scale;
    }

    base.base_vert_data[new_idx + 2] = base.BaseVertexData{
        .pos_uv = .{
            .x = x3,
            .y = y3,
            .z = tex_u3,
            .w = tex_v3,
        },
        .render_type = base.minimap_render_type,
    };

    var x4 = -x_cos - x_sin + scaled_x;
    var tex_u4 = tex_u - tex_w_half;
    if (x4 < scaled_min_x) {
        const scale = (scaled_min_x - x4) / scaled_w;
        x4 = scaled_min_x;
        tex_u4 += scale * tex_w_scale;
    } else if (x4 > scaled_max_x) {
        const scale = (x4 - scaled_max_x) / scaled_w;
        x4 = scaled_max_x;
        tex_u4 -= scale * tex_w_scale;
    }

    var y4 = -y_sin + y_cos + scaled_y;
    var tex_v4 = tex_v - tex_h_half;
    if (y4 < scaled_min_y) {
        const scale = (scaled_min_y - y4) / scaled_h;
        y4 = scaled_min_y;
        tex_v4 -= scale * tex_h_scale;
    } else if (y4 > scaled_max_y) {
        const scale = (y4 - scaled_max_y) / scaled_h;
        y4 = scaled_max_y;
        tex_v4 += scale * tex_h_scale;
    }

    base.base_vert_data[new_idx + 3] = base.BaseVertexData{
        .pos_uv = .{
            .x = x4,
            .y = y4,
            .z = tex_u4,
            .w = tex_v4,
        },
        .render_type = base.minimap_render_type,
    };

    return new_idx + 4;
}

fn drawMenuBackground(
    idx: u16,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    rotation: f32,
    draw_data: base.DrawData,
    cam_data: base.CameraData,
    scissor: element.ScissorRect,
) u16 {
    var new_idx = idx;

    if (new_idx == base.base_batch_vert_size) {
        @branchHint(.unlikely);
        draw_data.encoder.writeBuffer(
            draw_data.buffer,
            0,
            base.BaseVertexData,
            base.base_vert_data[0..base.base_batch_vert_size],
        );
        base.endDraw(
            draw_data,
            base.base_batch_vert_size * @sizeOf(base.BaseVertexData),
            @divExact(base.base_batch_vert_size, 4) * 6,
        );
        new_idx = 0;
    }

    const scaled_w = w * cam_data.clip_scale_x;
    const scaled_h = h * cam_data.clip_scale_y;
    const scaled_x = (x - cam_data.screen_width / 2.0 + w / 2.0) * cam_data.clip_scale_x;
    const scaled_y = -(y - cam_data.screen_height / 2.0 + h / 2.0) * cam_data.clip_scale_y;

    const cos_angle = @cos(rotation);
    const sin_angle = @sin(rotation);
    const x_cos = cos_angle * scaled_w * 0.5;
    const x_sin = sin_angle * scaled_w * 0.5;
    const y_cos = cos_angle * scaled_h * 0.5;
    const y_sin = sin_angle * scaled_h * 0.5;

    const dont_scissor = element.ScissorRect.dont_scissor;
    const scaled_min_x = if (scissor.min_x != dont_scissor)
        (scissor.min_x + x - cam_data.screen_width / 2.0) * cam_data.clip_scale_x
    else if (rotation == 0) @as(f32, -1.0) else @as(f32, -2.0);
    const scaled_max_x = if (scissor.max_x != dont_scissor)
        (scissor.max_x + x - cam_data.screen_width / 2.0) * cam_data.clip_scale_x
    else if (rotation == 0) @as(f32, 1.0) else @as(f32, 2.0);

    // have to flip these, y is inverted... should be fixed later
    const scaled_min_y = if (scissor.max_y != dont_scissor)
        -(scissor.max_y + y - cam_data.screen_height / 2.0) * cam_data.clip_scale_y
    else if (rotation == 0) @as(f32, -1.0) else @as(f32, -2.0);
    const scaled_max_y = if (scissor.min_y != dont_scissor)
        -(scissor.min_y + y - cam_data.screen_height / 2.0) * cam_data.clip_scale_y
    else if (rotation == 0) @as(f32, 1.0) else @as(f32, 2.0);

    const tex_w = 1.0;
    const tex_h = 1.0;

    var x1 = -x_cos + x_sin + scaled_x;
    var tex_u1: f32 = 0;
    if (x1 < scaled_min_x) {
        const scale = (scaled_min_x - x1) / scaled_w;
        x1 = scaled_min_x;
        tex_u1 += scale * tex_w;
    } else if (x1 > scaled_max_x) {
        const scale = (x1 - scaled_max_x) / scaled_w;
        x1 = scaled_max_x;
        tex_u1 -= scale * tex_w;
    }

    var y1 = -y_sin - y_cos + scaled_y;
    var tex_v1: f32 = 1;
    if (y1 < scaled_min_y) {
        const scale = (scaled_min_y - y1) / scaled_h;
        y1 = scaled_min_y;
        tex_v1 -= scale * tex_h;
    } else if (y1 > scaled_max_y) {
        const scale = (y1 - scaled_max_y) / scaled_h;
        y1 = scaled_max_y;
        tex_v1 += scale * tex_h;
    }

    base.base_vert_data[new_idx] = base.BaseVertexData{
        .pos_uv = .{
            .x = x1,
            .y = y1,
            .z = tex_u1,
            .w = tex_v1,
        },
        .render_type = base.menu_bg_render_type,
    };

    var x2 = x_cos + x_sin + scaled_x;
    var tex_u2: f32 = 1;
    if (x2 < scaled_min_x) {
        const scale = (scaled_min_x - x2) / scaled_w;
        x2 = scaled_min_x;
        tex_u2 += scale * tex_w;
    } else if (x2 > scaled_max_x) {
        const scale = (x2 - scaled_max_x) / scaled_w;
        x2 = scaled_max_x;
        tex_u2 -= scale * tex_w;
    }

    var y2 = y_sin - y_cos + scaled_y;
    var tex_v2: f32 = 1;
    if (y2 < scaled_min_y) {
        const scale = (scaled_min_y - y2) / scaled_h;
        y2 = scaled_min_y;
        tex_v2 -= scale * tex_h;
    } else if (y2 > scaled_max_y) {
        const scale = (y2 - scaled_max_y) / scaled_h;
        y2 = scaled_max_y;
        tex_v2 += scale * tex_h;
    }

    base.base_vert_data[new_idx + 1] = base.BaseVertexData{
        .pos_uv = .{
            .x = x2,
            .y = y2,
            .z = tex_u2,
            .w = tex_v2,
        },
        .render_type = base.menu_bg_render_type,
    };

    var x3 = x_cos - x_sin + scaled_x;
    var tex_u3: f32 = 1;
    if (x3 < scaled_min_x) {
        const scale = (scaled_min_x - x3) / scaled_w;
        x3 = scaled_min_x;
        tex_u3 += scale * tex_w;
    } else if (x3 > scaled_max_x) {
        const scale = (x3 - scaled_max_x) / scaled_w;
        x3 = scaled_max_x;
        tex_u3 -= scale * tex_w;
    }

    var y3 = y_sin + y_cos + scaled_y;
    var tex_v3: f32 = 0;
    if (y3 < scaled_min_y) {
        const scale = (scaled_min_y - y3) / scaled_h;
        y3 = scaled_min_y;
        tex_v3 -= scale * tex_h;
    } else if (y3 > scaled_max_y) {
        const scale = (y3 - scaled_max_y) / scaled_h;
        y3 = scaled_max_y;
        tex_v3 += scale * tex_h;
    }

    base.base_vert_data[new_idx + 2] = base.BaseVertexData{
        .pos_uv = .{
            .x = x3,
            .y = y3,
            .z = tex_u3,
            .w = tex_v3,
        },
        .render_type = base.menu_bg_render_type,
    };

    var x4 = -x_cos - x_sin + scaled_x;
    var tex_u4: f32 = 0;
    if (x4 < scaled_min_x) {
        const scale = (scaled_min_x - x4) / scaled_w;
        x4 = scaled_min_x;
        tex_u4 += scale * tex_w;
    } else if (x4 > scaled_max_x) {
        const scale = (x4 - scaled_max_x) / scaled_w;
        x4 = scaled_max_x;
        tex_u4 -= scale * tex_w;
    }

    var y4 = -y_sin + y_cos + scaled_y;
    var tex_v4: f32 = 0;
    if (y4 < scaled_min_y) {
        const scale = (scaled_min_y - y4) / scaled_h;
        y4 = scaled_min_y;
        tex_v4 -= scale * tex_h;
    } else if (y4 > scaled_max_y) {
        const scale = (y4 - scaled_max_y) / scaled_h;
        y4 = scaled_max_y;
        tex_v4 += scale * tex_h;
    }

    base.base_vert_data[new_idx + 3] = base.BaseVertexData{
        .pos_uv = .{
            .x = x4,
            .y = y4,
            .z = tex_u4,
            .w = tex_v4,
        },
        .render_type = base.menu_bg_render_type,
    };

    return new_idx + 4;
}

fn drawNineSlice(
    idx: u16,
    x: f32,
    y: f32,
    image_data: element.NineSliceImageData,
    draw_data: base.DrawData,
    cam_data: base.CameraData,
) u16 {
    var new_idx = idx;

    var opts: base.QuadOptions = .{
        .alpha_mult = image_data.alpha,
        .base_color = image_data.color,
        .base_color_intensity = image_data.color_intensity,
        .scissor = image_data.scissor,
    };

    const w = image_data.w;
    const h = image_data.h;

    const top_left = image_data.topLeft();
    const top_left_w = top_left.texWRaw();
    const top_left_h = top_left.texHRaw();
    new_idx = base.drawQuad(new_idx, x, y, top_left_w, top_left_h, top_left, draw_data, cam_data, opts);

    const top_right = image_data.topRight();
    const top_right_w = top_right.texWRaw();
    if (image_data.scissor.min_x != element.ScissorRect.dont_scissor)
        opts.scissor.min_x = image_data.scissor.min_x - (w - top_right_w);
    if (image_data.scissor.max_x != element.ScissorRect.dont_scissor)
        opts.scissor.max_x = image_data.scissor.max_x - (w - top_right_w);
    new_idx = base.drawQuad(new_idx, x + (w - top_right_w), y, top_right_w, top_right.texHRaw(), top_right, draw_data, cam_data, opts);

    const bottom_left = image_data.bottomLeft();
    const bottom_left_w = bottom_left.texWRaw();
    const bottom_left_h = bottom_left.texHRaw();
    opts.scissor.min_x = image_data.scissor.min_x;
    opts.scissor.max_x = image_data.scissor.max_x;
    if (image_data.scissor.min_y != element.ScissorRect.dont_scissor)
        opts.scissor.min_y = image_data.scissor.min_y - (h - bottom_left_h);
    if (image_data.scissor.max_y != element.ScissorRect.dont_scissor)
        opts.scissor.max_y = image_data.scissor.max_y - (h - bottom_left_h);
    new_idx = base.drawQuad(new_idx, x, y + (h - bottom_left_h), bottom_left_w, bottom_left_h, bottom_left, draw_data, cam_data, opts);

    const bottom_right = image_data.bottomRight();
    const bottom_right_w = bottom_right.texWRaw();
    const bottom_right_h = bottom_right.texHRaw();
    opts.scissor.min_x = if (image_data.scissor.min_x != element.ScissorRect.dont_scissor)
        image_data.scissor.min_x - (w - top_right_w)
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_x = if (image_data.scissor.max_x != element.ScissorRect.dont_scissor)
        image_data.scissor.max_x - (w - top_right_w)
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.min_y = if (image_data.scissor.min_y != element.ScissorRect.dont_scissor)
        image_data.scissor.min_y - (h - bottom_left_h)
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_y = if (image_data.scissor.max_y != element.ScissorRect.dont_scissor)
        image_data.scissor.max_y - (h - bottom_left_h)
    else
        element.ScissorRect.dont_scissor;
    new_idx = base.drawQuad(new_idx, x + (w - bottom_right_w), y + (h - bottom_right_h), bottom_right_w, bottom_right_h, bottom_right, draw_data, cam_data, opts);

    const top_center = image_data.topCenter();
    opts.scissor.min_x = if (image_data.scissor.min_x != element.ScissorRect.dont_scissor)
        image_data.scissor.min_x - top_left_w
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_x = if (image_data.scissor.max_x != element.ScissorRect.dont_scissor)
        image_data.scissor.max_x - top_left_w
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.min_y = image_data.scissor.min_y;
    opts.scissor.max_y = image_data.scissor.max_y;
    new_idx = base.drawQuad(new_idx, x + top_left_w, y, w - top_left_w - top_right_w, top_center.texHRaw(), top_center, draw_data, cam_data, opts);

    const bottom_center = image_data.bottomCenter();
    const bottom_center_h = bottom_center.texHRaw();
    opts.scissor.min_x = if (image_data.scissor.min_x != element.ScissorRect.dont_scissor)
        image_data.scissor.min_x - bottom_left_w
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_x = if (image_data.scissor.max_x != element.ScissorRect.dont_scissor)
        image_data.scissor.max_x - bottom_left_w
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.min_y = if (image_data.scissor.min_y != element.ScissorRect.dont_scissor)
        image_data.scissor.min_y - (h - bottom_center_h)
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_y = if (image_data.scissor.max_y != element.ScissorRect.dont_scissor)
        image_data.scissor.max_y - (h - bottom_center_h)
    else
        element.ScissorRect.dont_scissor;
    new_idx = base.drawQuad(new_idx, x + bottom_left_w, y + (h - bottom_center_h), w - bottom_left_w - bottom_right_w, bottom_center_h, bottom_center, draw_data, cam_data, opts);

    const middle_center = image_data.middleCenter();
    opts.scissor.min_x = if (image_data.scissor.min_x != element.ScissorRect.dont_scissor)
        image_data.scissor.min_x - top_left_w
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_x = if (image_data.scissor.max_x != element.ScissorRect.dont_scissor)
        image_data.scissor.max_x - top_left_w
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.min_y = if (image_data.scissor.min_y != element.ScissorRect.dont_scissor)
        image_data.scissor.min_y - top_left_h
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_y = if (image_data.scissor.max_y != element.ScissorRect.dont_scissor)
        image_data.scissor.max_y - top_left_h
    else
        element.ScissorRect.dont_scissor;
    new_idx = base.drawQuad(new_idx, x + top_left_w, y + top_left_h, w - top_left_w - top_right_w, h - top_left_h - bottom_left_h, middle_center, draw_data, cam_data, opts);

    const middle_left = image_data.middleLeft();
    opts.scissor.min_x = image_data.scissor.min_x;
    opts.scissor.max_x = image_data.scissor.max_x;
    opts.scissor.min_y = if (image_data.scissor.min_y != element.ScissorRect.dont_scissor)
        image_data.scissor.min_y - top_left_h
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_y = if (image_data.scissor.max_y != element.ScissorRect.dont_scissor)
        image_data.scissor.max_y - top_left_h
    else
        element.ScissorRect.dont_scissor;
    new_idx = base.drawQuad(new_idx, x, y + top_left_h, middle_left.texWRaw(), h - top_left_h - bottom_left_h, middle_left, draw_data, cam_data, opts);

    const middle_right = image_data.middleRight();
    const middle_right_w = middle_right.texWRaw();
    opts.scissor.min_x = if (image_data.scissor.min_x != element.ScissorRect.dont_scissor)
        image_data.scissor.min_x - (w - middle_right_w)
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_x = if (image_data.scissor.max_x != element.ScissorRect.dont_scissor)
        image_data.scissor.max_x - (w - middle_right_w)
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.min_y = if (image_data.scissor.min_y != element.ScissorRect.dont_scissor)
        image_data.scissor.min_y - top_left_h
    else
        element.ScissorRect.dont_scissor;
    opts.scissor.max_y = if (image_data.scissor.max_y != element.ScissorRect.dont_scissor)
        image_data.scissor.max_y - top_left_h
    else
        element.ScissorRect.dont_scissor;
    new_idx = base.drawQuad(new_idx, x + (w - middle_right_w), y + top_left_h, middle_right_w, h - top_left_h - bottom_left_h, middle_right, draw_data, cam_data, opts);

    return new_idx;
}

fn drawImage(idx: u16, image: *element.Image, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32) u16 {
    var new_idx = idx;

    if (!image.visible)
        return new_idx;

    switch (image.image_data) {
        .nine_slice => |nine_slice| new_idx = drawNineSlice(new_idx, image.x + x_offset, image.y + y_offset, nine_slice, draw_data, cam_data),
        .normal => |image_data| {
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = image.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(
                new_idx,
                image.x + x_offset,
                image.y + y_offset,
                image_data.texWRaw(),
                image_data.texHRaw(),
                image_data.atlas_data,
                draw_data,
                cam_data,
                opts,
            );
        },
    }

    if (image.is_minimap_decor) {
        const float_w: f32 = @floatFromInt(map.info.width);
        const float_h: f32 = @floatFromInt(map.info.height);
        const zoom = cam_data.minimap_zoom;
        new_idx = drawMinimap(
            new_idx,
            image.x + image.minimap_offset_x + x_offset + assets.padding,
            image.y + image.minimap_offset_y + y_offset + assets.padding,
            image.minimap_width,
            image.minimap_height,
            cam_data.x,
            cam_data.y,
            float_w / zoom,
            float_h / zoom,
            0,
            draw_data,
            cam_data,
            .{
                .min_x = 0,
                .min_y = 0,
                .max_x = image.minimap_width,
                .max_y = image.minimap_height,
            },
        );

        const player_icon = assets.minimap_icons[0];
        const scale = 2.0;
        const player_icon_w = player_icon.texWRaw() * scale;
        const player_icon_h = player_icon.texHRaw() * scale;
        new_idx = base.drawQuad(
            new_idx,
            image.x + image.minimap_offset_x + x_offset + (image.minimap_width - player_icon_w) / 2.0,
            image.y + image.minimap_offset_y + y_offset + (image.minimap_height - player_icon_h) / 2.0,
            player_icon_w,
            player_icon_h,
            player_icon,
            draw_data,
            cam_data,
            .{ .shadow_texel_mult = 0.5, .rotation = -cam_data.angle, .force_glow_off = true },
        );
    }

    return new_idx;
}

fn drawItem(idx: u16, item: *element.Item, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32) u16 {
    var new_idx = idx;

    if (!item.visible)
        return new_idx;

    if (item.background_image_data) |background_image_data| {
        switch (background_image_data) {
            .nine_slice => |nine_slice| {
                new_idx = drawNineSlice(new_idx, item.background_x + x_offset, item.background_y + y_offset, nine_slice, draw_data, cam_data);
            },
            .normal => |image_data| {
                const opts: base.QuadOptions = .{
                    .alpha_mult = image_data.alpha,
                    .scissor = item.scissor,
                    .base_color = image_data.color,
                    .base_color_intensity = image_data.color_intensity,
                    .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
                };
                new_idx = base.drawQuad(
                    new_idx,
                    item.background_x + x_offset,
                    item.background_y + y_offset,
                    image_data.texWRaw(),
                    image_data.texHRaw(),
                    image_data.atlas_data,
                    draw_data,
                    cam_data,
                    opts,
                );
            },
        }
    }

    switch (item.image_data) {
        .nine_slice => |nine_slice| {
            new_idx = drawNineSlice(new_idx, item.x + x_offset, item.y + y_offset, nine_slice, draw_data, cam_data);
        },
        .normal => |image_data| {
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = item.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(
                new_idx,
                item.x + x_offset,
                item.y + y_offset,
                image_data.texWRaw(),
                image_data.texHRaw(),
                image_data.atlas_data,
                draw_data,
                cam_data,
                opts,
            );
        },
    }

    return new_idx;
}

fn drawBar(idx: u16, bar: *element.Bar, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32) u16 {
    var new_idx = idx;

    if (!bar.visible)
        return new_idx;

    var w: f32 = 0;
    var h: f32 = 0;
    switch (bar.image_data) {
        .nine_slice => |nine_slice| {
            w = nine_slice.w;
            h = nine_slice.h;
            new_idx = drawNineSlice(new_idx, bar.x + x_offset, bar.y + y_offset, nine_slice, draw_data, cam_data);
        },
        .normal => |image_data| {
            w = image_data.texWRaw();
            h = image_data.texHRaw();
            const atlas_data = image_data.atlas_data;
            const scale: f32 = 1.0;

            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = bar.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(new_idx, bar.x + x_offset, bar.y + y_offset, w * scale, h, atlas_data, draw_data, cam_data, opts);
        },
    }

    new_idx = base.drawText(
        new_idx,
        bar.x + (w - bar.text_data.width) / 2 + x_offset,
        bar.y + (h - bar.text_data.height) / 2 + y_offset,
        &bar.text_data,
        draw_data,
        cam_data,
        .{},
        false,
    );

    return new_idx;
}

fn drawButton(idx: u16, button: *element.Button, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32) u16 {
    var new_idx = idx;

    if (!button.visible)
        return new_idx;

    var w: f32 = 0;
    var h: f32 = 0;

    switch (button.image_data.current(button.state)) {
        .nine_slice => |nine_slice| {
            w = nine_slice.w;
            h = nine_slice.h;
            new_idx = drawNineSlice(new_idx, button.x + x_offset, button.y + y_offset, nine_slice, draw_data, cam_data);
        },
        .normal => |image_data| {
            w = image_data.texWRaw();
            h = image_data.texHRaw();
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = button.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(new_idx, button.x + x_offset, button.y + y_offset, w, h, image_data.atlas_data, draw_data, cam_data, opts);
        },
    }

    if (button.text_data) |*text_data| {
        new_idx = base.drawText(
            new_idx,
            button.x + x_offset,
            button.y + y_offset,
            text_data,
            draw_data,
            cam_data,
            button.scissor,
            false,
        );
    }

    return new_idx;
}

fn drawCharacterBox(idx: u16, char_box: *element.CharacterBox, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32) u16 {
    var new_idx = idx;

    if (!char_box.visible)
        return new_idx;

    var w: f32 = 0;
    var h: f32 = 0;

    switch (char_box.image_data.current(char_box.state)) {
        .nine_slice => |nine_slice| {
            w = nine_slice.w;
            h = nine_slice.h;
            new_idx = drawNineSlice(new_idx, char_box.x + x_offset, char_box.y + y_offset, nine_slice, draw_data, cam_data);
        },
        .normal => |image_data| {
            w = image_data.texWRaw();
            h = image_data.texHRaw();
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = char_box.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(
                new_idx,
                char_box.x + x_offset,
                char_box.y + y_offset,
                image_data.width(),
                image_data.height(),
                image_data.atlas_data,
                draw_data,
                cam_data,
                opts,
            );
        },
    }

    if (char_box.text_data) |*text_data| {
        new_idx = base.drawText(
            new_idx,
            char_box.x + (w - text_data.width) / 2 + x_offset,
            char_box.y + (h - text_data.height) / 2 + y_offset,
            text_data,
            draw_data,
            cam_data,
            char_box.scissor,
            false,
        );
    }

    return new_idx;
}

fn drawInputField(idx: u16, input_field: *element.Input, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32, time: i64) u16 {
    var new_idx = idx;

    if (!input_field.visible)
        return new_idx;

    var w: f32 = 0;
    var h: f32 = 0;

    switch (input_field.image_data.current(input_field.state)) {
        .nine_slice => |nine_slice| {
            w = nine_slice.w;
            h = nine_slice.h;
            new_idx = drawNineSlice(new_idx, input_field.x + x_offset, input_field.y + y_offset, nine_slice, draw_data, cam_data);
        },
        .normal => |image_data| {
            w = image_data.texWRaw();
            h = image_data.texHRaw();
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = input_field.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(new_idx, input_field.x + x_offset, input_field.y + y_offset, w, h, image_data.atlas_data, draw_data, cam_data, opts);
        },
    }

    const text_x = input_field.x + input_field.text_inlay_x + assets.padding + x_offset + input_field.x_offset;
    const text_y = input_field.y + input_field.text_inlay_y + assets.padding + y_offset;
    new_idx = base.drawText(
        new_idx,
        text_x,
        text_y,
        &input_field.text_data,
        draw_data,
        cam_data,
        input_field.scissor,
        false,
    );

    const flash_delay = 500 * std.time.us_per_ms;
    if (input_field.last_input != -1 and (time - input_field.last_input < flash_delay or @mod(@divFloor(time, flash_delay), 2) == 0)) {
        const cursor_x = @floor(text_x + input_field.text_data.width);
        switch (input_field.cursor_image_data) {
            .nine_slice => |nine_slice| new_idx = drawNineSlice(new_idx, cursor_x, text_y, nine_slice, draw_data, cam_data),
            .normal => |image_data| {
                const opts: base.QuadOptions = .{
                    .alpha_mult = image_data.alpha,
                    .scissor = input_field.scissor,
                    .base_color = image_data.color,
                    .base_color_intensity = image_data.color_intensity,
                    .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
                };
                new_idx = base.drawQuad(
                    new_idx,
                    cursor_x,
                    text_y,
                    image_data.width(),
                    image_data.height(),
                    image_data.atlas_data,
                    draw_data,
                    cam_data,
                    opts,
                );
            },
        }
    }

    return new_idx;
}

fn drawToggle(idx: u16, toggle: *element.Toggle, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32) u16 {
    var new_idx = idx;

    if (!toggle.visible)
        return new_idx;

    var w: f32 = 0;
    var h: f32 = 0;

    switch (if (toggle.toggled.*)
        toggle.on_image_data.current(toggle.state)
    else
        toggle.off_image_data.current(toggle.state)) {
        .nine_slice => |nine_slice| {
            w = nine_slice.w;
            h = nine_slice.h;
            new_idx = drawNineSlice(new_idx, toggle.x + x_offset, toggle.y + y_offset, nine_slice, draw_data, cam_data);
        },
        .normal => |image_data| {
            w = image_data.texWRaw();
            h = image_data.texHRaw();
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = toggle.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(new_idx, toggle.x + x_offset, toggle.y + y_offset, w, h, image_data.atlas_data, draw_data, cam_data, opts);
        },
    }

    if (toggle.text_data) |*text_data| {
        const pad = 5;
        new_idx = base.drawText(
            new_idx,
            toggle.x + w + pad + x_offset,
            toggle.y + (h - text_data.height) / 2 + y_offset,
            text_data,
            draw_data,
            cam_data,
            toggle.scissor,
            false,
        );
    }

    return new_idx;
}

fn drawKeyMapper(idx: u16, key_mapper: *element.KeyMapper, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32) u16 {
    var new_idx = idx;

    if (!key_mapper.visible)
        return new_idx;

    var w: f32 = 0;
    var h: f32 = 0;

    switch (key_mapper.image_data.current(key_mapper.state)) {
        .nine_slice => |nine_slice| {
            w = nine_slice.w;
            h = nine_slice.h;
            // new_idx = drawNineSlice(new_idx, key_mapper.x + x_offset, key_mapper.y + y_offset, nine_slice, draw_data);
        },
        .normal => |image_data| {
            w = image_data.texWRaw();
            h = image_data.texHRaw();
            // const opts: base.QuadOptions = .{
            //     .alpha_mult = image_data.alpha,
            //     .scissor = key_mapper.scissor,
            //     .base_color = image_data.color,
            //     .base_color_intensity = image_data.color_intensity,
            // };
            // new_idx = base.drawQuad(new_idx, key_mapper.x + x_offset, key_mapper.y + y_offset, w, h, image_data.atlas_data, draw_data, cam_data, opts);
        },
    }

    new_idx = base.drawQuad(
        new_idx,
        key_mapper.x + x_offset,
        key_mapper.y + y_offset,
        w,
        h,
        assets.getKeyTexture(key_mapper.settings_button.*),
        draw_data,
        cam_data,
        .{},
    );

    if (key_mapper.title_text_data) |*text_data| {
        const pad = 5;
        new_idx = base.drawText(
            new_idx,
            key_mapper.x + w + pad + x_offset,
            key_mapper.y + (h - text_data.height) / 2 + y_offset,
            text_data,
            draw_data,
            cam_data,
            key_mapper.scissor,
            false,
        );
    }

    return new_idx;
}

fn drawSlider(idx: u16, slider: *element.Slider, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32) u16 {
    var new_idx = idx;

    if (!slider.visible)
        return new_idx;

    switch (slider.decor_image_data) {
        .nine_slice => |nine_slice| new_idx = drawNineSlice(
            new_idx,
            slider.x + x_offset,
            slider.y + y_offset,
            nine_slice,
            draw_data,
            cam_data,
        ),
        .normal => |image_data| {
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = slider.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(
                new_idx,
                slider.x + x_offset,
                slider.y + y_offset,
                slider.w,
                slider.h,
                image_data.atlas_data,
                draw_data,
                cam_data,
                opts,
            );
        },
    }

    const knob_image_data = slider.knob_image_data.current(slider.state);
    const knob_x = slider.x + slider.knob_x + x_offset;
    const knob_y = slider.y + slider.knob_y + y_offset;
    var knob_w: f32 = 0.0;
    var knob_h: f32 = 0.0;
    switch (knob_image_data) {
        .nine_slice => |nine_slice| {
            new_idx = drawNineSlice(new_idx, knob_x, knob_y, nine_slice, draw_data, cam_data);
            knob_w = nine_slice.w;
            knob_h = nine_slice.h;
        },
        .normal => |image_data| {
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = slider.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(
                new_idx,
                knob_x,
                knob_y,
                slider.w,
                slider.h,
                image_data.atlas_data,
                draw_data,
                cam_data,
                opts,
            );

            knob_w = image_data.texWRaw();
            knob_h = image_data.texHRaw();
        },
    }

    if (slider.title_text_data) |*text_data| {
        new_idx = base.drawText(
            new_idx,
            slider.x + x_offset,
            slider.y + y_offset - slider.title_offset,
            text_data,
            draw_data,
            cam_data,
            slider.scissor,
            false,
        );
    }

    if (slider.value_text_data) |*text_data| {
        new_idx = base.drawText(
            new_idx,
            knob_x + if (slider.vertical) knob_w else 0,
            knob_y + if (slider.vertical) 0 else knob_h,
            text_data,
            draw_data,
            cam_data,
            slider.scissor,
            false,
        );
    }

    return new_idx;
}

fn drawDropdown(idx: u16, dropdown: *element.Dropdown, draw_data: base.DrawData, cam_data: base.CameraData, x_offset: f32, y_offset: f32) u16 {
    var new_idx = idx;

    if (!dropdown.visible)
        return new_idx;

    const base_x = dropdown.x + x_offset;
    const base_y = dropdown.y + y_offset;

    var title_w: f32 = 0.0;
    var title_h: f32 = 0.0;
    switch (dropdown.title_data) {
        .nine_slice => |nine_slice| {
            new_idx = drawNineSlice(new_idx, base_x, base_y, nine_slice, draw_data, cam_data);
            title_w = nine_slice.w;
            title_h = nine_slice.h;
        },
        .normal => |image_data| {
            title_w = image_data.texWRaw();
            title_h = image_data.texHRaw();
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = dropdown.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(
                new_idx,
                base_x,
                base_y,
                title_w,
                title_h,
                image_data.atlas_data,
                draw_data,
                cam_data,
                opts,
            );
        },
    }

    new_idx = base.drawText(new_idx, base_x, base_y, &dropdown.title_text, draw_data, cam_data, dropdown.scissor, false);

    const toggled = dropdown.toggled;
    const button_image_data = (if (toggled) dropdown.button_data_extended else dropdown.button_data_collapsed).current(dropdown.button_state);
    switch (button_image_data) {
        .nine_slice => |nine_slice| new_idx = drawNineSlice(new_idx, base_x + title_w, base_y, nine_slice, draw_data, cam_data),
        .normal => |image_data| {
            const opts: base.QuadOptions = .{
                .alpha_mult = image_data.alpha,
                .scissor = dropdown.scissor,
                .base_color = image_data.color,
                .base_color_intensity = image_data.color_intensity,
                .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
            };
            new_idx = base.drawQuad(
                new_idx,
                base_x + title_w,
                base_y,
                image_data.width(),
                image_data.height(),
                image_data.atlas_data,
                draw_data,
                cam_data,
                opts,
            );
        },
    }

    if (toggled) {
        switch (dropdown.background_data) {
            .nine_slice => |nine_slice| new_idx = drawNineSlice(new_idx, base_x, base_y + title_h, nine_slice, draw_data, cam_data),
            .normal => |image_data| {
                const opts: base.QuadOptions = .{
                    .alpha_mult = image_data.alpha,
                    .scissor = dropdown.scissor,
                    .base_color = image_data.color,
                    .base_color_intensity = image_data.color_intensity,
                    .shadow_texel_mult = if (image_data.glow) 2.0 / @max(image_data.scale_x, image_data.scale_y) else 0.0,
                };
                new_idx = base.drawQuad(
                    new_idx,
                    base_x,
                    base_y + title_h,
                    image_data.width(),
                    image_data.height(),
                    image_data.atlas_data,
                    draw_data,
                    cam_data,
                    opts,
                );
            },
        }
    }

    return new_idx;
}

fn drawElement(
    idx: u16,
    elem: element.UiElement,
    draw_data: base.DrawData,
    cam_data: base.CameraData,
    x_offset: f32,
    y_offset: f32,
    time: i64,
) u16 {
    var new_idx = idx;

    switch (elem) {
        .scrollable_container => |scrollable_container| {
            if (scrollable_container.visible) {
                new_idx = drawElement(new_idx, .{ .container = scrollable_container.container }, draw_data, cam_data, x_offset, y_offset, time);
                new_idx = drawElement(new_idx, .{ .slider = scrollable_container.scroll_bar }, draw_data, cam_data, x_offset, y_offset, time);
                new_idx = drawElement(new_idx, .{ .image = scrollable_container.scroll_bar_decor }, draw_data, cam_data, x_offset, y_offset, time);
            }
        },
        .container => |container| {
            if (container.visible) {
                for (container.elements.items) |cont_elem| {
                    new_idx = drawElement(new_idx, cont_elem, draw_data, cam_data, x_offset + container.x, y_offset + container.y, time);
                }
            }
        },
        .image => |image| new_idx = drawImage(new_idx, image, draw_data, cam_data, x_offset, y_offset),
        .menu_bg => |menu_bg| {
            if (menu_bg.visible)
                new_idx = drawMenuBackground(new_idx, menu_bg.x + x_offset, menu_bg.y + y_offset, menu_bg.w, menu_bg.h, 0, draw_data, cam_data, menu_bg.scissor);
        },
        .item => |item| new_idx = drawItem(new_idx, item, draw_data, cam_data, x_offset, y_offset),
        .bar => |bar| new_idx = drawBar(new_idx, bar, draw_data, cam_data, x_offset, y_offset),
        .button => |button| new_idx = drawButton(new_idx, button, draw_data, cam_data, x_offset, y_offset),
        .char_box => |char_box| new_idx = drawCharacterBox(new_idx, char_box, draw_data, cam_data, x_offset, y_offset),
        .text => |text| {
            if (text.visible)
                new_idx = base.drawText(new_idx, text.x + x_offset, text.y + y_offset, &text.text_data, draw_data, cam_data, text.scissor, false);
        },
        .input_field => |input_field| new_idx = drawInputField(new_idx, input_field, draw_data, cam_data, x_offset, y_offset, time),
        .toggle => |toggle| new_idx = drawToggle(new_idx, toggle, draw_data, cam_data, x_offset, y_offset),
        .key_mapper => |key_mapper| new_idx = drawKeyMapper(new_idx, key_mapper, draw_data, cam_data, x_offset, y_offset),
        .slider => |slider| new_idx = drawSlider(new_idx, slider, draw_data, cam_data, x_offset, y_offset),
        .dropdown => |dropdown| {
            const toggled = dropdown.toggled and dropdown.container.visible;
            if (toggled) dropdown.lock.lock();
            defer if (toggled) dropdown.lock.unlock();

            new_idx = drawDropdown(new_idx, dropdown, draw_data, cam_data, x_offset, y_offset);
            if (toggled)
                new_idx = drawElement(new_idx, .{ .scrollable_container = dropdown.container }, draw_data, cam_data, x_offset, y_offset, time);
        },
        .dropdown_container => |dropdown_container| {
            switch (dropdown_container.background_data.current(dropdown_container.state)) {
                .nine_slice => |nine_slice| new_idx = drawNineSlice(
                    new_idx,
                    dropdown_container.x + x_offset,
                    dropdown_container.y + y_offset,
                    nine_slice,
                    draw_data,
                    cam_data,
                ),
                .normal => |image_data| {
                    const opts: base.QuadOptions = .{
                        .alpha_mult = image_data.alpha,
                        .scissor = dropdown_container.scissor,
                        .base_color = image_data.color,
                        .base_color_intensity = image_data.color_intensity,
                    };
                    new_idx = base.drawQuad(
                        new_idx,
                        dropdown_container.x + x_offset,
                        dropdown_container.y + y_offset,
                        image_data.texWRaw(),
                        image_data.texHRaw(),
                        image_data.atlas_data,
                        draw_data,
                        cam_data,
                        opts,
                    );
                },
            }

            new_idx = drawElement(
                new_idx,
                .{ .container = &dropdown_container.container },
                draw_data,
                cam_data,
                dropdown_container.x + x_offset,
                dropdown_container.y + y_offset,
                time,
            );
        },
    }

    return new_idx;
}

pub fn drawTempElements(idx: u16, draw_data: base.DrawData, cam_data: base.CameraData) u16 {
    ui_systems.temp_elem_lock.lock();
    defer ui_systems.temp_elem_lock.unlock();

    @prefetch(ui_systems.temp_elements.items, .{ .locality = 0 });
    var new_idx = idx;
    for (ui_systems.temp_elements.items) |*elem| {
        switch (elem.*) {
            .status => |*text| {
                if (text.visible) {
                    new_idx = base.drawText(new_idx, text.screen_x, text.screen_y, &text.text_data, draw_data, cam_data, .{}, false);
                }
            },
            .balloon => |*balloon| {
                if (balloon.visible) {
                    const image_data = balloon.image_data.normal; // assume no 9 slice
                    const w = image_data.texWRaw();
                    const h = image_data.texHRaw();

                    const opts: base.QuadOptions = .{
                        .alpha_mult = image_data.alpha,
                        .base_color = image_data.color,
                        .base_color_intensity = image_data.color_intensity,
                    };
                    new_idx = base.drawQuad(new_idx, balloon.screen_x, balloon.screen_y, w, h, image_data.atlas_data, draw_data, cam_data, opts);

                    const decor_offset = h / 10;
                    new_idx = base.drawText(
                        new_idx,
                        balloon.screen_x + (w - balloon.text_data.width) / 2,
                        balloon.screen_y + (h - balloon.text_data.height) / 2 - decor_offset,
                        &balloon.text_data,
                        draw_data,
                        cam_data,
                        .{},
                        false,
                    );
                }
            },
        }
    }

    return new_idx;
}

pub fn drawUiElements(idx: u16, draw_data: base.DrawData, cam_data: base.CameraData, time: i64) u16 {
    ui_systems.ui_lock.lock();
    defer ui_systems.ui_lock.unlock();

    @prefetch(ui_systems.elements.items, .{ .locality = 0 });
    var new_idx = idx;
    for (ui_systems.elements.items) |elem| {
        new_idx = drawElement(new_idx, elem, draw_data, cam_data, 0, 0, time);
    }
    return new_idx;
}
