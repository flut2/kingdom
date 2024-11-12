const std = @import("std");
const map = @import("../game/map.zig");
const assets = @import("../assets.zig");
const camera = @import("../camera.zig");
const gpu = @import("zgpu");
const utils = @import("shared").utils;
const zstbi = @import("zstbi");
const element = @import("../ui/element.zig");
const main = @import("../main.zig");
const systems = @import("../ui/systems.zig");
const glfw = @import("zglfw");

const game_render = @import("game.zig");
const ground_render = @import("ground.zig");
const ui_render = @import("ui.zig");

const VertexField = extern struct {
    x: f32,
    y: f32,
    z: f32,
    w: f32,

    pub fn zero() VertexField {
        return .{ .x = 0.0, .y = 0.0, .z = 0.0, .w = 0.0 };
    }
};

pub const CameraData = struct {
    minimap_zoom: f32,
    angle: f32,
    scale: f32,
    x: f32,
    y: f32,
    z: f32,
    cos: f32,
    sin: f32,
    clip_x: f32,
    clip_y: f32,
    min_x: u32,
    max_x: u32,
    min_y: u32,
    max_y: u32,
    max_dist_sq: f32,
    screen_width: f32,
    screen_height: f32,
    clip_scale_x: f32,
    clip_scale_y: f32,
    square_render_data: camera.SquareRenderData,

    pub fn rotateAroundCameraClip(self: CameraData, x_in: f32, y_in: f32) struct { x: f32, y: f32 } {
        return .{
            .x = x_in * self.cos + y_in * self.sin + self.clip_x,
            .y = x_in * -self.sin + y_in * self.cos + self.clip_y,
        };
    }

    pub fn rotateAroundCamera(self: CameraData, x_in: f32, y_in: f32) struct { x: f32, y: f32 } {
        return .{
            .x = x_in * self.cos + y_in * self.sin + self.clip_x + self.screen_width / 2.0,
            .y = x_in * -self.sin + y_in * self.cos + self.clip_y + self.screen_height / 2.0,
        };
    }

    pub fn visibleInCamera(self: CameraData, x_in: f32, y_in: f32) bool {
        if (std.math.isNan(x_in) or
            std.math.isNan(y_in) or
            x_in < 0 or
            y_in < 0 or
            x_in > std.math.maxInt(u32) or
            y_in > std.math.maxInt(u32))
            return false;

        const floor_x: u32 = @intFromFloat(@floor(x_in));
        const floor_y: u32 = @intFromFloat(@floor(y_in));
        return !(floor_x < self.min_x or floor_x > self.max_x or floor_y < self.min_y or floor_y > self.max_y);
    }
};

pub const LightData = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    color: u32,
    intensity: f32,
};

pub const DrawData = struct {
    encoder: gpu.wgpu.CommandEncoder,
    buffer: gpu.wgpu.Buffer,
    pipeline: gpu.wgpu.RenderPipeline,
    bind_group: gpu.wgpu.BindGroup,
};

pub const QuadOptions = struct {
    rotation: f32 = 0.0,
    base_color: u32 = std.math.maxInt(u32),
    base_color_intensity: f32 = 0.0,
    alpha_mult: f32 = 1.0,
    shadow_texel_mult: f32 = 0.0,
    shadow_color: u32 = std.math.maxInt(u32),
    scissor: element.ScissorRect = .{},
    force_glow_off: bool = false,
};

pub const BaseVertexData = extern struct {
    pos_uv: VertexField,
    base_color_and_intensity: VertexField = VertexField.zero(),
    alpha_and_shadow_color: VertexField = VertexField.zero(),
    texel_and_text_data: VertexField = VertexField.zero(),
    outline_color_and_w: VertexField = VertexField.zero(),
    render_type: f32,
};

pub const GroundVertexData = extern struct {
    pos_uv: VertexField,
    left_top_blend_uv: VertexField,
    right_bottom_blend_uv: VertexField,
    base_and_offset_uv: VertexField,
};

pub const GroundUniformData = extern struct {
    left_top_mask_uv: [4]f32,
    right_bottom_mask_uv: [4]f32,
};

const TextureWithView = struct {
    texture: gpu.wgpu.Texture,
    view: gpu.wgpu.TextureView,

    pub fn release(self: TextureWithView) void {
        self.texture.release();
        self.view.release();
    }
};

pub const quad_render_type = 0.0;
pub const ui_quad_render_type = 1.0;
pub const quad_glow_off_render_type = 2.0;
pub const ui_quad_glow_off_render_type = 3.0;
pub const minimap_render_type = 4.0;
pub const menu_bg_render_type = 5.0;
pub const text_normal_render_type = 6.0;
pub const text_drop_shadow_render_type = 7.0;
pub const text_normal_no_subpixel_render_type = 8.0;
pub const text_drop_shadow_no_subpixel_render_type = 9.0;

pub const base_batch_vert_size = 10000 * 4;
pub const ground_batch_vert_size = 10000 * 4;
pub const max_lights = 1000;

pub var base_pipeline: gpu.wgpu.RenderPipeline = undefined;
pub var base_bind_group: gpu.wgpu.BindGroup = undefined;
pub var ground_pipeline: gpu.wgpu.RenderPipeline = undefined;
pub var ground_bind_group: gpu.wgpu.BindGroup = undefined;

pub var base_vb: gpu.wgpu.Buffer = undefined;
pub var ground_vb: gpu.wgpu.Buffer = undefined;
pub var ground_uniforms: gpu.wgpu.Buffer = undefined;
pub var index_buffer: gpu.wgpu.Buffer = undefined;

pub var base_vert_data: [base_batch_vert_size]BaseVertexData = undefined;
pub var ground_vert_data: [ground_batch_vert_size]GroundVertexData = undefined;

pub var bold_text: TextureWithView = undefined;
pub var bold_italic_text: TextureWithView = undefined;
pub var medium_text: TextureWithView = undefined;
pub var medium_italic_text: TextureWithView = undefined;
pub var base: TextureWithView = undefined;
pub var ui: TextureWithView = undefined;
pub var minimap: TextureWithView = undefined;
pub var menu_bg: TextureWithView = undefined;

pub var clear_render_pass_info: gpu.wgpu.RenderPassDescriptor = undefined;
pub var load_render_pass_info: gpu.wgpu.RenderPassDescriptor = undefined;
pub var first_draw = false;

pub var nearest_sampler: gpu.wgpu.Sampler = undefined;
pub var linear_sampler: gpu.wgpu.Sampler = undefined;

pub var condition_rects: [@bitSizeOf(utils.Condition)][]const assets.AtlasData = undefined;
pub var enter_text_data: element.TextData = undefined;
pub var lights: std.ArrayListUnmanaged(LightData) = .{};

fn createTexture(ctx: *gpu.GraphicsContext, tex: *TextureWithView, img: zstbi.Image) void {
    tex.texture = ctx.device.createTexture(.{
        .usage = .{ .texture_binding = true, .copy_dst = true },
        .size = .{ .width = img.width, .height = img.height, .depth_or_array_layers = 1 },
        .format = .rgba8_unorm,
        .mip_level_count = 1,
    });
    tex.view = tex.texture.createView(.{});

    ctx.queue.writeTexture(
        .{ .texture = tex.texture },
        .{ .bytes_per_row = img.bytes_per_row, .rows_per_image = img.height },
        .{ .width = img.width, .height = img.height },
        u8,
        img.data,
    );
}

fn groundBindGroupLayout(ctx: *gpu.GraphicsContext) gpu.wgpu.BindGroupLayout {
    return ctx.device.createBindGroupLayout(.{
        .entry_count = 3,
        .entries = &.{
            gpu.bufferEntry(0, .{ .vertex = true, .fragment = true }, .uniform, false, 0),
            gpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            gpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
        },
    });
}

fn baseBindGroupLayout(ctx: *gpu.GraphicsContext) gpu.wgpu.BindGroupLayout {
    return ctx.device.createBindGroupLayout(.{
        .entry_count = 10,
        .entries = &.{
            gpu.samplerEntry(0, .{ .fragment = true }, .filtering),
            gpu.samplerEntry(1, .{ .fragment = true }, .filtering),
            gpu.textureEntry(2, .{ .fragment = true }, .float, .tvdim_2d, false),
            gpu.textureEntry(3, .{ .fragment = true }, .float, .tvdim_2d, false),
            gpu.textureEntry(4, .{ .fragment = true }, .float, .tvdim_2d, false),
            gpu.textureEntry(5, .{ .fragment = true }, .float, .tvdim_2d, false),
            gpu.textureEntry(6, .{ .fragment = true }, .float, .tvdim_2d, false),
            gpu.textureEntry(7, .{ .fragment = true }, .float, .tvdim_2d, false),
            gpu.textureEntry(8, .{ .fragment = true }, .float, .tvdim_2d, false),
            gpu.textureEntry(9, .{ .fragment = true }, .float, .tvdim_2d, false),
        },
    });
}

fn createPipelines(ctx: *gpu.GraphicsContext) void {
    const ground_bind_group_layout = groundBindGroupLayout(ctx);
    defer ground_bind_group_layout.release();

    const base_bind_group_layout = baseBindGroupLayout(ctx);
    defer base_bind_group_layout.release();

    const base_pipeline_layout = ctx.device.createPipelineLayout(.{
        .bind_group_layout_count = 1,
        .bind_group_layouts = &.{base_bind_group_layout},
    });
    defer base_pipeline_layout.release();

    const ground_pipeline_layout = ctx.device.createPipelineLayout(.{
        .bind_group_layout_count = 1,
        .bind_group_layouts = &.{ground_bind_group_layout},
    });
    defer ground_pipeline_layout.release();

    const ground_shader = gpu.createWgslShaderModule(ctx.device, @embedFile("shaders/ground.wgsl"), "Ground Shader");
    defer ground_shader.release();

    const base_shader = gpu.createWgslShaderModule(ctx.device, @embedFile("shaders/base.wgsl"), "Base Shader");
    defer base_shader.release();

    const base_color_targets: []const gpu.wgpu.ColorTargetState = &.{.{
        .format = gpu.GraphicsContext.swapchain_format,
        .blend = &.{
            .color = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
            .alpha = .{ .src_factor = .src_alpha, .dst_factor = .one_minus_src_alpha },
        },
    }};

    const base_vertex_attributes: []const gpu.wgpu.VertexAttribute = &.{
        .{ .format = .float32x4, .offset = @offsetOf(BaseVertexData, "pos_uv"), .shader_location = 0 },
        .{ .format = .float32x4, .offset = @offsetOf(BaseVertexData, "base_color_and_intensity"), .shader_location = 1 },
        .{ .format = .float32x4, .offset = @offsetOf(BaseVertexData, "alpha_and_shadow_color"), .shader_location = 2 },
        .{ .format = .float32x4, .offset = @offsetOf(BaseVertexData, "texel_and_text_data"), .shader_location = 3 },
        .{ .format = .float32x4, .offset = @offsetOf(BaseVertexData, "outline_color_and_w"), .shader_location = 4 },
        .{ .format = .float32, .offset = @offsetOf(BaseVertexData, "render_type"), .shader_location = 5 },
    };
    const base_vertex_buffers: []const gpu.wgpu.VertexBufferLayout = &.{.{
        .array_stride = @sizeOf(BaseVertexData),
        .attribute_count = base_vertex_attributes.len,
        .attributes = base_vertex_attributes.ptr,
    }};

    const base_pipeline_descriptor: gpu.wgpu.RenderPipelineDescriptor = .{
        .layout = base_pipeline_layout,
        .vertex = .{
            .module = base_shader,
            .entry_point = "vs_main",
            .buffer_count = base_vertex_buffers.len,
            .buffers = base_vertex_buffers.ptr,
        },
        .primitive = .{
            .front_face = .cw,
            .cull_mode = .none,
            .topology = .triangle_list,
        },
        .fragment = &.{
            .module = base_shader,
            .entry_point = "fs_main",
            .target_count = base_color_targets.len,
            .targets = base_color_targets.ptr,
        },
    };
    base_pipeline = ctx.device.createRenderPipeline(base_pipeline_descriptor);

    const ground_color_targets: []const gpu.wgpu.ColorTargetState = &.{.{ .format = gpu.GraphicsContext.swapchain_format }};

    const ground_vertex_attributes: []const gpu.wgpu.VertexAttribute = &.{
        .{ .format = .float32x4, .offset = @offsetOf(GroundVertexData, "pos_uv"), .shader_location = 0 },
        .{ .format = .float32x4, .offset = @offsetOf(GroundVertexData, "left_top_blend_uv"), .shader_location = 1 },
        .{ .format = .float32x4, .offset = @offsetOf(GroundVertexData, "right_bottom_blend_uv"), .shader_location = 2 },
        .{ .format = .float32x4, .offset = @offsetOf(GroundVertexData, "base_and_offset_uv"), .shader_location = 3 },
    };
    const ground_vertex_buffers: []const gpu.wgpu.VertexBufferLayout = &.{.{
        .array_stride = @sizeOf(GroundVertexData),
        .attribute_count = ground_vertex_attributes.len,
        .attributes = ground_vertex_attributes.ptr,
    }};

    const ground_pipeline_descriptor = gpu.wgpu.RenderPipelineDescriptor{
        .layout = ground_pipeline_layout,
        .vertex = .{
            .module = ground_shader,
            .entry_point = "vs_main",
            .buffer_count = ground_vertex_buffers.len,
            .buffers = ground_vertex_buffers.ptr,
        },
        .primitive = .{
            .front_face = .cw,
            .cull_mode = .none,
            .topology = .triangle_list,
        },
        .fragment = &.{
            .module = ground_shader,
            .entry_point = "fs_main",
            .target_count = ground_color_targets.len,
            .targets = ground_color_targets.ptr,
        },
    };
    ground_pipeline = ctx.device.createRenderPipeline(ground_pipeline_descriptor);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    for (condition_rects) |rects| {
        allocator.free(rects);
    }

    enter_text_data.deinit(allocator);
    lights.deinit(allocator);

    base_pipeline.release();
    base_bind_group.release();
    ground_pipeline.release();
    ground_bind_group.release();

    base_vb.release();
    ground_vb.release();
    ground_uniforms.release();
    index_buffer.release();

    bold_text.release();
    bold_italic_text.release();
    medium_text.release();
    medium_italic_text.release();
    base.release();
    ui.release();
    minimap.release();
    menu_bg.release();

    nearest_sampler.release();
    linear_sampler.release();
}

pub fn init(ctx: *gpu.GraphicsContext, allocator: std.mem.Allocator) !void {
    for (0..@bitSizeOf(utils.Condition)) |i| {
        const sheet_name = "conditions";
        const sheet_indices: []const u16 = switch (std.meta.intToEnum(utils.ConditionEnum, i) catch continue) {
            .weak => &[_]u16{5},
            .slowed => &[_]u16{7},
            .sick => &[_]u16{10},
            .speedy => &[_]u16{6},
            .bleeding => &[_]u16{2},
            .healing => &[_]u16{1},
            .damaging => &[_]u16{4},
            .invulnerable => &[_]u16{11},
            .armored => &[_]u16{3},
            .armor_broken => &[_]u16{9},
            .targeted => &[_]u16{8},
            .max_hp_boost => &[_]u16{12},
            .max_mp_boost => &[_]u16{13},
            .attack_boost => &[_]u16{14},
            .defense_boost => &[_]u16{15},
            .speed_boost => &[_]u16{16},
            .dexterity_boost => &[_]u16{17},
            .vitality_boost => &[_]u16{18},
            .wisdom_boost => &[_]u16{19},
            .hidden, .invisible => &.{},
        };

        const indices_len = sheet_indices.len;
        if (indices_len == 0) {
            condition_rects[i] = &.{};
            continue;
        }

        var rects = allocator.alloc(assets.AtlasData, indices_len) catch continue;
        for (0..indices_len) |j| {
            rects[j] = (assets.atlas_data.get(sheet_name) orelse std.debug.panic("Could not find sheet {s} for cond parsing", .{sheet_name}))[sheet_indices[j]];
        }

        condition_rects[i] = rects;
    }

    enter_text_data = .{
        .text = "Enter",
        .text_type = .bold,
        .size = 12,
    };

    {
        enter_text_data.lock.lock();
        defer enter_text_data.lock.unlock();

        enter_text_data.recalculateAttributes(main.allocator);
    }

    base_vb = ctx.device.createBuffer(.{
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = base_vert_data.len * @sizeOf(BaseVertexData),
    });
    ctx.queue.writeBuffer(base_vb, 0, BaseVertexData, base_vert_data[0..]);

    ground_vb = ctx.device.createBuffer(.{
        .usage = .{ .copy_dst = true, .vertex = true },
        .size = ground_vert_data.len * @sizeOf(GroundVertexData),
    });
    ctx.queue.writeBuffer(ground_vb, 0, GroundVertexData, ground_vert_data[0..]);

    ground_uniforms = ctx.device.createBuffer(.{
        .usage = .{ .copy_dst = true, .uniform = true },
        .size = @sizeOf(GroundUniformData),
    });
    ctx.queue.writeBuffer(ground_uniforms, 0, GroundUniformData, &.{.{
        .left_top_mask_uv = assets.left_top_mask_uv,
        .right_bottom_mask_uv = assets.right_bottom_mask_uv,
    }});

    var index_data: [60000]u16 = undefined;
    for (0..10000) |i| {
        const actual_i: u16 = @intCast(i * 6);
        const i_4: u16 = @intCast(i * 4);
        index_data[actual_i] = 0 + i_4;
        index_data[actual_i + 1] = 1 + i_4;
        index_data[actual_i + 2] = 3 + i_4;
        index_data[actual_i + 3] = 1 + i_4;
        index_data[actual_i + 4] = 2 + i_4;
        index_data[actual_i + 5] = 3 + i_4;
    }
    index_buffer = ctx.device.createBuffer(.{
        .usage = .{ .copy_dst = true, .index = true },
        .size = index_data.len * @sizeOf(u16),
    });
    ctx.queue.writeBuffer(index_buffer, 0, u16, index_data[0..]);

    createTexture(ctx, &minimap, map.minimap);
    createTexture(ctx, &medium_text, assets.medium_atlas);
    createTexture(ctx, &medium_italic_text, assets.medium_italic_atlas);
    createTexture(ctx, &bold_text, assets.bold_atlas);
    createTexture(ctx, &bold_italic_text, assets.bold_italic_atlas);
    createTexture(ctx, &base, assets.atlas);
    createTexture(ctx, &ui, assets.ui_atlas);
    createTexture(ctx, &menu_bg, assets.menu_background);

    assets.medium_atlas.deinit();
    assets.medium_italic_atlas.deinit();
    assets.bold_atlas.deinit();
    assets.bold_italic_atlas.deinit();
    assets.atlas.deinit();
    assets.ui_atlas.deinit();
    assets.menu_background.deinit();

    nearest_sampler = ctx.device.createSampler(.{});
    linear_sampler = ctx.device.createSampler(.{ .min_filter = .linear, .mag_filter = .linear });

    const ground_bind_group_layout = groundBindGroupLayout(ctx);
    defer ground_bind_group_layout.release();

    ground_bind_group = ctx.device.createBindGroup(.{
        .layout = ground_bind_group_layout,
        .entry_count = 3,
        .entries = &.{
            .{ .binding = 0, .buffer = ground_uniforms, .size = @sizeOf(GroundUniformData) },
            .{ .binding = 1, .sampler = nearest_sampler, .size = 0 },
            .{ .binding = 2, .texture_view = base.view, .size = 0 },
        },
    });

    const base_bind_group_layout = baseBindGroupLayout(ctx);
    defer base_bind_group_layout.release();

    base_bind_group = ctx.device.createBindGroup(.{
        .layout = base_bind_group_layout,
        .entry_count = 10,
        .entries = &.{
            .{ .binding = 0, .sampler = nearest_sampler, .size = 0 },
            .{ .binding = 1, .sampler = linear_sampler, .size = 0 },
            .{ .binding = 2, .texture_view = base.view, .size = 0 },
            .{ .binding = 3, .texture_view = ui.view, .size = 0 },
            .{ .binding = 4, .texture_view = medium_text.view, .size = 0 },
            .{ .binding = 5, .texture_view = medium_italic_text.view, .size = 0 },
            .{ .binding = 6, .texture_view = bold_text.view, .size = 0 },
            .{ .binding = 7, .texture_view = bold_italic_text.view, .size = 0 },
            .{ .binding = 8, .texture_view = minimap.view, .size = 0 },
            .{ .binding = 9, .texture_view = menu_bg.view, .size = 0 },
        },
    });

    createPipelines(ctx);
}

pub fn drawQuad(
    idx: u16,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    atlas_data: assets.AtlasData,
    draw_data: DrawData,
    cam_data: CameraData,
    opts: QuadOptions,
) u16 {
    var idx_new = idx;

    if (idx_new == base_batch_vert_size) {
        @branchHint(.unlikely);
        draw_data.encoder.writeBuffer(
            draw_data.buffer,
            0,
            BaseVertexData,
            base_vert_data[0..base_batch_vert_size],
        );
        endDraw(
            draw_data,
            base_batch_vert_size * @sizeOf(BaseVertexData),
            @divExact(base_batch_vert_size, 4) * 6,
        );
        idx_new = 0;
    }

    var base_rgb = element.RGBF32.fromValues(0.0, 0.0, 0.0);
    if (opts.base_color != std.math.maxInt(u32))
        base_rgb = element.RGBF32.fromInt(opts.base_color);

    var shadow_rgb = element.RGBF32.fromValues(0.0, 0.0, 0.0);
    if (opts.shadow_color != std.math.maxInt(u32))
        shadow_rgb = element.RGBF32.fromInt(opts.shadow_color);

    const texel_w = 1.0 / atlas_data.atlas_type.width() * opts.shadow_texel_mult;
    const texel_h = 1.0 / atlas_data.atlas_type.height() * opts.shadow_texel_mult;

    const scaled_w = w * cam_data.clip_scale_x;
    const scaled_h = h * cam_data.clip_scale_y;
    const scaled_x = (x - cam_data.screen_width / 2.0 + w / 2.0) * cam_data.clip_scale_x;
    const scaled_y = -(y - cam_data.screen_height / 2.0 + h / 2.0) * cam_data.clip_scale_y;

    const cos_angle = @cos(opts.rotation);
    const sin_angle = @sin(opts.rotation);
    const x_cos = cos_angle * scaled_w * 0.5;
    const x_sin = sin_angle * scaled_w * 0.5;
    const y_cos = cos_angle * scaled_h * 0.5;
    const y_sin = sin_angle * scaled_h * 0.5;

    const should_glow = main.settings.enable_glow and !opts.force_glow_off and opts.shadow_texel_mult > 0.0;
    const render_type: f32 = switch (atlas_data.atlas_type) {
        .ui => if (should_glow) ui_quad_render_type else ui_quad_glow_off_render_type,
        .base => if (should_glow) quad_render_type else quad_glow_off_render_type,
    };

    const dont_scissor = element.ScissorRect.dont_scissor;
    const scaled_min_x = if (opts.scissor.min_x != dont_scissor)
        (opts.scissor.min_x + x - cam_data.screen_width / 2.0) * cam_data.clip_scale_x
    else if (opts.rotation == 0) @as(f32, -1.0) else @as(f32, -2.0);
    const scaled_max_x = if (opts.scissor.max_x != dont_scissor)
        (opts.scissor.max_x + x - cam_data.screen_width / 2.0) * cam_data.clip_scale_x
    else if (opts.rotation == 0) @as(f32, 1.0) else @as(f32, 2.0);

    // have to flip these, y is inverted... should be fixed later
    const scaled_min_y = if (opts.scissor.max_y != dont_scissor)
        -(opts.scissor.max_y + y - cam_data.screen_height / 2.0) * cam_data.clip_scale_y
    else if (opts.rotation == 0) @as(f32, -1.0) else @as(f32, -2.0);
    const scaled_max_y = if (opts.scissor.min_y != dont_scissor)
        -(opts.scissor.min_y + y - cam_data.screen_height / 2.0) * cam_data.clip_scale_y
    else if (opts.rotation == 0) @as(f32, 1.0) else @as(f32, 2.0);

    var x1 = -x_cos + x_sin + scaled_x;
    var tex_u1 = atlas_data.tex_u;
    if (x1 < scaled_min_x) {
        const scale = (scaled_min_x - x1) / scaled_w;
        x1 = scaled_min_x;
        tex_u1 += scale * atlas_data.tex_w;
    } else if (x1 > scaled_max_x) {
        const scale = (x1 - scaled_max_x) / scaled_w;
        x1 = scaled_max_x;
        tex_u1 -= scale * atlas_data.tex_w;
    }

    var y1 = -y_sin - y_cos + scaled_y;
    var tex_v1 = atlas_data.tex_v + atlas_data.tex_h;
    if (y1 < scaled_min_y) {
        const scale = (scaled_min_y - y1) / scaled_h;
        y1 = scaled_min_y;
        tex_v1 -= scale * atlas_data.tex_h;
    } else if (y1 > scaled_max_y) {
        const scale = (y1 - scaled_max_y) / scaled_h;
        y1 = scaled_max_y;
        tex_v1 += scale * atlas_data.tex_h;
    }

    base_vert_data[idx_new] = .{
        .pos_uv = .{
            .x = x1,
            .y = y1,
            .z = tex_u1,
            .w = tex_v1,
        },
        .base_color_and_intensity = .{
            .x = base_rgb.r,
            .y = base_rgb.g,
            .z = base_rgb.b,
            .w = opts.base_color_intensity,
        },
        .alpha_and_shadow_color = .{
            .x = opts.alpha_mult,
            .y = shadow_rgb.r,
            .z = shadow_rgb.g,
            .w = shadow_rgb.b,
        },
        .texel_and_text_data = .{
            .x = texel_w,
            .y = texel_h,
            .z = 0.0,
            .w = 0.0,
        },
        .outline_color_and_w = .{
            .x = shadow_rgb.r,
            .y = shadow_rgb.g,
            .z = shadow_rgb.b,
            .w = 0.5,
        },
        .render_type = render_type,
    };

    var x2 = x_cos + x_sin + scaled_x;
    var tex_u2 = atlas_data.tex_u + atlas_data.tex_w;
    if (x2 < scaled_min_x) {
        const scale = (scaled_min_x - x2) / scaled_w;
        x2 = scaled_min_x;
        tex_u2 += scale * atlas_data.tex_w;
    } else if (x2 > scaled_max_x) {
        const scale = (x2 - scaled_max_x) / scaled_w;
        x2 = scaled_max_x;
        tex_u2 -= scale * atlas_data.tex_w;
    }

    var y2 = y_sin - y_cos + scaled_y;
    var tex_v2 = atlas_data.tex_v + atlas_data.tex_h;
    if (y2 < scaled_min_y) {
        const scale = (scaled_min_y - y2) / scaled_h;
        y2 = scaled_min_y;
        tex_v2 -= scale * atlas_data.tex_h;
    } else if (y2 > scaled_max_y) {
        const scale = (y2 - scaled_max_y) / scaled_h;
        y2 = scaled_max_y;
        tex_v2 += scale * atlas_data.tex_h;
    }

    base_vert_data[idx_new + 1] = .{
        .pos_uv = .{
            .x = x2,
            .y = y2,
            .z = tex_u2,
            .w = tex_v2,
        },
        .base_color_and_intensity = .{
            .x = base_rgb.r,
            .y = base_rgb.g,
            .z = base_rgb.b,
            .w = opts.base_color_intensity,
        },
        .alpha_and_shadow_color = .{
            .x = opts.alpha_mult,
            .y = shadow_rgb.r,
            .z = shadow_rgb.g,
            .w = shadow_rgb.b,
        },
        .texel_and_text_data = .{
            .x = texel_w,
            .y = texel_h,
            .z = 0.0,
            .w = 0.0,
        },
        .outline_color_and_w = .{
            .x = shadow_rgb.r,
            .y = shadow_rgb.g,
            .z = shadow_rgb.b,
            .w = 0.5,
        },
        .render_type = render_type,
    };

    var x3 = x_cos - x_sin + scaled_x;
    var tex_u3 = atlas_data.tex_u + atlas_data.tex_w;
    if (x3 < scaled_min_x) {
        const scale = (scaled_min_x - x3) / scaled_w;
        x3 = scaled_min_x;
        tex_u3 += scale * atlas_data.tex_w;
    } else if (x3 > scaled_max_x) {
        const scale = (x3 - scaled_max_x) / scaled_w;
        x3 = scaled_max_x;
        tex_u3 -= scale * atlas_data.tex_w;
    }

    var y3 = y_sin + y_cos + scaled_y;
    var tex_v3 = atlas_data.tex_v;
    if (y3 < scaled_min_y) {
        const scale = (scaled_min_y - y3) / scaled_h;
        y3 = scaled_min_y;
        tex_v3 -= scale * atlas_data.tex_h;
    } else if (y3 > scaled_max_y) {
        const scale = (y3 - scaled_max_y) / scaled_h;
        y3 = scaled_max_y;
        tex_v3 += scale * atlas_data.tex_h;
    }

    base_vert_data[idx_new + 2] = .{
        .pos_uv = .{
            .x = x3,
            .y = y3,
            .z = tex_u3,
            .w = tex_v3,
        },
        .base_color_and_intensity = .{
            .x = base_rgb.r,
            .y = base_rgb.g,
            .z = base_rgb.b,
            .w = opts.base_color_intensity,
        },
        .alpha_and_shadow_color = .{
            .x = opts.alpha_mult,
            .y = shadow_rgb.r,
            .z = shadow_rgb.g,
            .w = shadow_rgb.b,
        },
        .texel_and_text_data = .{
            .x = texel_w,
            .y = texel_h,
            .z = 0.0,
            .w = 0.0,
        },
        .outline_color_and_w = .{
            .x = shadow_rgb.r,
            .y = shadow_rgb.g,
            .z = shadow_rgb.b,
            .w = 0.5,
        },
        .render_type = render_type,
    };

    var x4 = -x_cos - x_sin + scaled_x;
    var tex_u4 = atlas_data.tex_u;
    if (x4 < scaled_min_x) {
        const scale = (scaled_min_x - x4) / scaled_w;
        x4 = scaled_min_x;
        tex_u4 += scale * atlas_data.tex_w;
    } else if (x4 > scaled_max_x) {
        const scale = (x4 - scaled_max_x) / scaled_w;
        x4 = scaled_max_x;
        tex_u4 -= scale * atlas_data.tex_w;
    }

    var y4 = -y_sin + y_cos + scaled_y;
    var tex_v4 = atlas_data.tex_v;
    if (y4 < scaled_min_y) {
        const scale = (scaled_min_y - y4) / scaled_h;
        y4 = scaled_min_y;
        tex_v4 -= scale * atlas_data.tex_h;
    } else if (y4 > scaled_max_y) {
        const scale = (y4 - scaled_max_y) / scaled_h;
        y4 = scaled_max_y;
        tex_v4 += scale * atlas_data.tex_h;
    }

    base_vert_data[idx_new + 3] = .{
        .pos_uv = .{
            .x = x4,
            .y = y4,
            .z = tex_u4,
            .w = tex_v4,
        },
        .base_color_and_intensity = .{
            .x = base_rgb.r,
            .y = base_rgb.g,
            .z = base_rgb.b,
            .w = opts.base_color_intensity,
        },
        .alpha_and_shadow_color = .{
            .x = opts.alpha_mult,
            .y = shadow_rgb.r,
            .z = shadow_rgb.g,
            .w = shadow_rgb.b,
        },
        .texel_and_text_data = .{
            .x = texel_w,
            .y = texel_h,
            .z = 0.0,
            .w = 0.0,
        },
        .outline_color_and_w = .{
            .x = shadow_rgb.r,
            .y = shadow_rgb.g,
            .z = shadow_rgb.b,
            .w = 0.5,
        },
        .render_type = render_type,
    };

    return idx_new + 4;
}

pub fn drawQuadVerts(
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
    draw_data: DrawData,
    opts: QuadOptions,
) u16 {
    var idx_new = idx;

    if (idx_new == base_batch_vert_size) {
        @branchHint(.unlikely);
        draw_data.encoder.writeBuffer(
            draw_data.buffer,
            0,
            BaseVertexData,
            base_vert_data[0..base_batch_vert_size],
        );
        endDraw(
            draw_data,
            base_batch_vert_size * @sizeOf(BaseVertexData),
            @divExact(base_batch_vert_size, 4) * 6,
        );
        idx_new = 0;
    }

    var base_rgb = element.RGBF32.fromValues(-1.0, -1.0, -1.0);
    if (opts.base_color != std.math.maxInt(u32))
        base_rgb = element.RGBF32.fromInt(opts.base_color);

    var shadow_rgb = element.RGBF32.fromValues(0.0, 0.0, 0.0);
    if (opts.shadow_color != std.math.maxInt(u32))
        shadow_rgb = element.RGBF32.fromInt(opts.shadow_color);

    const texel_w = assets.base_texel_w * opts.shadow_texel_mult;
    const texel_h = assets.base_texel_h * opts.shadow_texel_mult;

    const render_type = quad_render_type;

    base_vert_data[idx_new] = .{
        .pos_uv = .{
            .x = x1,
            .y = y1,
            .z = atlas_data.tex_u,
            .w = atlas_data.tex_v,
        },
        .base_color_and_intensity = .{
            .x = base_rgb.r,
            .y = base_rgb.g,
            .z = base_rgb.b,
            .w = opts.base_color_intensity,
        },
        .alpha_and_shadow_color = .{
            .x = opts.alpha_mult,
            .y = shadow_rgb.r,
            .z = shadow_rgb.g,
            .w = shadow_rgb.b,
        },
        .texel_and_text_data = .{
            .x = texel_w,
            .y = texel_h,
            .z = 0.0,
            .w = 0.0,
        },
        .outline_color_and_w = .{
            .x = shadow_rgb.r,
            .y = shadow_rgb.g,
            .z = shadow_rgb.b,
            .w = 0.5,
        },
        .render_type = render_type,
    };

    base_vert_data[idx_new + 1] = .{
        .pos_uv = .{
            .x = x2,
            .y = y2,
            .z = atlas_data.tex_u + atlas_data.tex_w,
            .w = atlas_data.tex_v,
        },
        .base_color_and_intensity = .{
            .x = base_rgb.r,
            .y = base_rgb.g,
            .z = base_rgb.b,
            .w = opts.base_color_intensity,
        },
        .alpha_and_shadow_color = .{
            .x = opts.alpha_mult,
            .y = shadow_rgb.r,
            .z = shadow_rgb.g,
            .w = shadow_rgb.b,
        },
        .texel_and_text_data = .{
            .x = texel_w,
            .y = texel_h,
            .z = 0.0,
            .w = 0.0,
        },
        .outline_color_and_w = .{
            .x = shadow_rgb.r,
            .y = shadow_rgb.g,
            .z = shadow_rgb.b,
            .w = 0.5,
        },
        .render_type = render_type,
    };

    base_vert_data[idx_new + 2] = .{
        .pos_uv = .{
            .x = x3,
            .y = y3,
            .z = atlas_data.tex_u + atlas_data.tex_w,
            .w = atlas_data.tex_v + atlas_data.tex_h,
        },
        .base_color_and_intensity = .{
            .x = base_rgb.r,
            .y = base_rgb.g,
            .z = base_rgb.b,
            .w = opts.base_color_intensity,
        },
        .alpha_and_shadow_color = .{
            .x = opts.alpha_mult,
            .y = shadow_rgb.r,
            .z = shadow_rgb.g,
            .w = shadow_rgb.b,
        },
        .texel_and_text_data = .{
            .x = texel_w,
            .y = texel_h,
            .z = 0.0,
            .w = 0.0,
        },
        .outline_color_and_w = .{
            .x = shadow_rgb.r,
            .y = shadow_rgb.g,
            .z = shadow_rgb.b,
            .w = 0.5,
        },
        .render_type = render_type,
    };

    base_vert_data[idx_new + 3] = .{
        .pos_uv = .{
            .x = x4,
            .y = y4,
            .z = atlas_data.tex_u,
            .w = atlas_data.tex_v + atlas_data.tex_h,
        },
        .base_color_and_intensity = .{
            .x = base_rgb.r,
            .y = base_rgb.g,
            .z = base_rgb.b,
            .w = opts.base_color_intensity,
        },
        .alpha_and_shadow_color = .{
            .x = opts.alpha_mult,
            .y = shadow_rgb.r,
            .z = shadow_rgb.g,
            .w = shadow_rgb.b,
        },
        .texel_and_text_data = .{
            .x = texel_w,
            .y = texel_h,
            .z = 0.0,
            .w = 0.0,
        },
        .outline_color_and_w = .{
            .x = shadow_rgb.r,
            .y = shadow_rgb.g,
            .z = shadow_rgb.b,
            .w = 0.5,
        },
        .render_type = render_type,
    };

    return idx_new + 4;
}

pub fn drawText(
    idx: u16,
    x: f32,
    y: f32,
    text_data: *element.TextData,
    draw_data: DrawData,
    cam_data: CameraData,
    scissor_override: element.ScissorRect,
    comptime needs_scale: bool,
) u16 {
    text_data.lock.lock();
    defer text_data.lock.unlock();

    // text data not initiated
    if (text_data.line_widths == null or text_data.break_indices == null)
        return idx;

    var idx_new = idx;

    const rgb = element.RGBF32.fromInt(text_data.color);
    const shadow_rgb = element.RGBF32.fromInt(text_data.shadow_color);
    const outline_rgb = element.RGBF32.fromInt(text_data.outline_color);

    const camera_scale = if (needs_scale) cam_data.scale else 1.0;
    const size_scale = text_data.size / assets.CharacterData.size * camera_scale * assets.CharacterData.padding_mult;
    const start_line_height = assets.CharacterData.line_height * assets.CharacterData.size * size_scale;
    var line_height = start_line_height;

    const max_width_off = text_data.max_width == std.math.floatMax(f32);
    const max_height_off = text_data.max_height == std.math.floatMax(f32);

    var render_type: f32 = text_normal_render_type;
    if (text_data.shadow_texel_offset_mult != 0) {
        render_type = if (text_data.disable_subpixel) text_drop_shadow_no_subpixel_render_type else text_drop_shadow_render_type;
    } else {
        render_type = if (text_data.disable_subpixel) text_normal_no_subpixel_render_type else text_normal_render_type;
    }

    const start_x = @round(x - cam_data.screen_width / 2.0) - (assets.CharacterData.padding * (text_data.size / assets.CharacterData.size));
    const start_y = @round(y - cam_data.screen_height / 2.0 + line_height); // line_height already accounts for pad
    const y_base = switch (text_data.vert_align) {
        .top => start_y,
        .middle => if (max_height_off) start_y else start_y + @round((text_data.max_height - text_data.height) / 2),
        .bottom => if (max_height_off) start_y else start_y + @round(text_data.max_height - text_data.height),
    };
    var line_idx: u16 = 1;
    var x_base = switch (text_data.hori_align) {
        .left => start_x,
        .middle => if (max_width_off) start_x else start_x + @round((text_data.max_width - text_data.line_widths.?.items[0]) / 2),
        .right => if (max_width_off) start_x else start_x + @round(text_data.max_width - text_data.line_widths.?.items[0]),
    };
    var x_pointer = x_base;
    var y_pointer = y_base;
    var current_color = rgb;
    var current_size = size_scale;
    var current_type = text_data.text_type;
    var index_offset: u16 = 0;
    for (0..text_data.text.len) |i| {
        if (idx_new == base_batch_vert_size) {
            @branchHint(.unlikely);
            draw_data.encoder.writeBuffer(
                draw_data.buffer,
                0,
                BaseVertexData,
                base_vert_data[0..base_batch_vert_size],
            );
            endDraw(
                draw_data,
                base_batch_vert_size * @sizeOf(BaseVertexData),
                @divExact(base_batch_vert_size, 4) * 6,
            );
            idx_new = 0;
        }

        const offset_i = i + index_offset;
        if (offset_i >= text_data.text.len)
            return idx_new;

        var char = text_data.text[offset_i];
        specialChar: {
            if (!text_data.handle_special_chars)
                break :specialChar;

            if (char == '&') {
                const name_start = text_data.text[offset_i + 1 ..];
                const reset = "reset";
                if (text_data.text.len >= offset_i + 1 + reset.len and std.mem.eql(u8, name_start[0..reset.len], reset)) {
                    current_type = text_data.text_type;
                    current_color = rgb;
                    current_size = size_scale;
                    line_height = assets.CharacterData.line_height * assets.CharacterData.size * current_size;
                    y_pointer += (line_height - start_line_height) / 2.0;
                    index_offset += @intCast(reset.len);
                    continue;
                }

                const space = "space";
                if (text_data.text.len >= offset_i + 1 + space.len and std.mem.eql(u8, name_start[0..space.len], space)) {
                    char = ' ';
                    index_offset += @intCast(space.len);
                    break :specialChar;
                }

                if (std.mem.indexOfScalar(u8, name_start, '=')) |eql_idx| {
                    const value_start_idx = offset_i + 1 + eql_idx + 1;
                    if (text_data.text.len <= value_start_idx or text_data.text[value_start_idx] != '"')
                        break :specialChar;

                    const value_start = text_data.text[value_start_idx + 1 ..];
                    if (std.mem.indexOfScalar(u8, value_start, '"')) |value_end_idx| {
                        const name = name_start[0..eql_idx];
                        const value = value_start[0..value_end_idx];
                        if (std.mem.eql(u8, name, "col")) {
                            const int_color = std.fmt.parseInt(u32, value, 16) catch {
                                std.log.err("Invalid color given to control code: {s}", .{value});
                                break :specialChar;
                            };
                            current_color = element.RGBF32.fromInt(int_color);
                        } else if (std.mem.eql(u8, name, "size")) {
                            const size = std.fmt.parseFloat(f32, value) catch {
                                std.log.err("Invalid size given to control code: {s}", .{value});
                                break :specialChar;
                            };
                            current_size = size / assets.CharacterData.size * camera_scale * assets.CharacterData.padding_mult;
                            line_height = assets.CharacterData.line_height * assets.CharacterData.size * current_size;
                            y_pointer += (line_height - start_line_height) / 2.0;
                        } else if (std.mem.eql(u8, name, "type")) {
                            if (std.mem.eql(u8, value, "med")) {
                                current_type = .medium;
                            } else if (std.mem.eql(u8, value, "med_it")) {
                                current_type = .medium_italic;
                            } else if (std.mem.eql(u8, value, "bold")) {
                                current_type = .bold;
                            } else if (std.mem.eql(u8, value, "bold_it")) {
                                current_type = .bold_italic;
                            }
                        } else if (std.mem.eql(u8, name, "img")) {
                            var values = std.mem.splitScalar(u8, value, ',');
                            const sheet = values.next();
                            if (sheet == null or std.mem.eql(u8, sheet.?, value)) {
                                std.log.err("Invalid sheet given to control code: {?s}", .{sheet});
                                break :specialChar;
                            }

                            const index_str = values.next() orelse {
                                std.log.err("Index was not found for control code with sheet {s}", .{sheet.?});
                                break :specialChar;
                            };
                            const index = std.fmt.parseInt(u32, index_str, 0) catch {
                                std.log.err("Invalid index given to control code with sheet {s}: {s}", .{ sheet.?, index_str });
                                break :specialChar;
                            };
                            const data = assets.atlas_data.get(sheet.?) orelse {
                                std.log.err("Sheet {s} given to control code was not found in atlas", .{sheet.?});
                                break :specialChar;
                            };
                            if (index >= data.len) {
                                std.log.err("The index {} given for sheet {s} in control code was out of bounds", .{ index, sheet.? });
                                break :specialChar;
                            }

                            if (std.mem.indexOfScalar(usize, text_data.break_indices.?.items, i) != null) {
                                y_pointer += line_height;
                                if (y_pointer - y_base > text_data.max_height)
                                    return idx_new;

                                x_base = switch (text_data.hori_align) {
                                    .left => start_x,
                                    .middle => if (max_width_off) start_x else start_x + @round((text_data.max_width - text_data.line_widths.?.items[line_idx]) / 2),
                                    .right => if (max_width_off) start_x else start_x + @round(text_data.max_width - text_data.line_widths.?.items[line_idx]),
                                };
                                x_pointer = x_base;
                                line_idx += 1;
                            }

                            const w_larger = data[index].tex_w > data[index].tex_h;
                            const quad_size = current_size * assets.CharacterData.size;
                            idx_new = drawQuad(
                                idx_new,
                                x_pointer + cam_data.screen_width / 2.0,
                                y_pointer - quad_size + cam_data.screen_height / 2.0,
                                if (w_larger) quad_size else data[index].width() * (quad_size / data[index].height()),
                                if (w_larger) data[index].height() * (quad_size / data[index].width()) else quad_size,
                                data[index],
                                draw_data,
                                cam_data,
                                .{ .alpha_mult = text_data.alpha },
                            );

                            x_pointer += quad_size;
                        } else break :specialChar;

                        index_offset += @intCast(1 + eql_idx + 1 + value_end_idx + 1);
                        continue;
                    } else break :specialChar;
                } else break :specialChar;
            }
        }

        const mod_char = if (text_data.password) '*' else char;

        const char_data = switch (current_type) {
            .medium => assets.medium_chars[mod_char],
            .medium_italic => assets.medium_italic_chars[mod_char],
            .bold => assets.bold_chars[mod_char],
            .bold_italic => assets.bold_italic_chars[mod_char],
        };

        const shadow_texel_w = text_data.shadow_texel_offset_mult / char_data.atlas_w;
        const shadow_texel_h = text_data.shadow_texel_offset_mult / char_data.atlas_h;

        var next_x_pointer = x_pointer + char_data.x_advance * current_size;
        if (std.mem.indexOfScalar(usize, text_data.break_indices.?.items, i) != null) {
            y_pointer += line_height;
            if (y_pointer - y_base > text_data.max_height)
                return idx_new;

            x_base = switch (text_data.hori_align) {
                .left => start_x,
                .middle => if (max_width_off) start_x else start_x + @round((text_data.max_width - text_data.line_widths.?.items[line_idx]) / 2),
                .right => if (max_width_off) start_x else start_x + @round(text_data.max_width - text_data.line_widths.?.items[line_idx]),
            };
            x_pointer = x_base;
            next_x_pointer = x_base + char_data.x_advance * current_size;
            line_idx += 1;
        }

        if (char_data.tex_w <= 0) {
            x_pointer += char_data.x_advance * current_size;
            continue;
        }

        const w = char_data.width * current_size;
        const h = char_data.height * current_size;
        const scaled_x = (x_pointer + char_data.x_offset * current_size + w / 2) * cam_data.clip_scale_x;
        const scaled_y = -(y_pointer - char_data.y_offset * current_size - h / 2) * cam_data.clip_scale_y;
        const scaled_w = w * cam_data.clip_scale_x;
        const scaled_h = h * cam_data.clip_scale_y;
        const px_range = assets.CharacterData.px_range / camera_scale;

        // text type could be incorporated into render type, would save us another vertex block and reduce branches
        // would be hell to maintain and extend though...
        const text_type: f32 = @floatFromInt(@intFromEnum(current_type));

        const dont_scissor = element.ScissorRect.dont_scissor;
        const scissor = if (scissor_override.isDefault()) text_data.scissor else scissor_override;
        const scaled_min_x = if (scissor.min_x != dont_scissor)
            (scissor.min_x + start_x) * cam_data.clip_scale_x
        else
            -1.0;
        const scaled_max_x = if (scissor.max_x != dont_scissor)
            (scissor.max_x + start_x) * cam_data.clip_scale_x
        else
            1.0;

        // have to flip these, y is inverted... should be fixed later
        const scaled_min_y = if (scissor.max_y != dont_scissor)
            -(scissor.max_y + start_y - line_height) * cam_data.clip_scale_y
        else
            -1.0;
        const scaled_max_y = if (scissor.min_y != dont_scissor)
            -(scissor.min_y + start_y - line_height) * cam_data.clip_scale_y
        else
            1.0;

        x_pointer = next_x_pointer;

        var x1 = scaled_w * -0.5 + scaled_x;
        var tex_u1 = char_data.tex_u;
        if (x1 < scaled_min_x) {
            const scale = (scaled_min_x - x1) / scaled_w;
            x1 = scaled_min_x;
            tex_u1 += scale * char_data.tex_w;
        } else if (x1 > scaled_max_x) {
            const scale = (x1 - scaled_max_x) / scaled_w;
            x1 = scaled_max_x;
            tex_u1 -= scale * char_data.tex_w;
        }

        var y1 = scaled_h * 0.5 + scaled_y;
        var tex_v1 = char_data.tex_v;
        if (y1 < scaled_min_y) {
            const scale = (scaled_min_y - y1) / scaled_h;
            y1 = scaled_min_y;
            tex_v1 -= scale * char_data.tex_h;
        } else if (y1 > scaled_max_y) {
            const scale = (y1 - scaled_max_y) / scaled_h;
            y1 = scaled_max_y;
            tex_v1 += scale * char_data.tex_h;
        }

        base_vert_data[idx_new] = .{
            .pos_uv = .{
                .x = x1,
                .y = y1,
                .z = tex_u1,
                .w = tex_v1,
            },
            .base_color_and_intensity = .{
                .x = current_color.r,
                .y = current_color.g,
                .z = current_color.b,
                .w = 1.0,
            },
            .alpha_and_shadow_color = .{
                .x = text_data.alpha,
                .y = shadow_rgb.r,
                .z = shadow_rgb.g,
                .w = shadow_rgb.b,
            },
            .texel_and_text_data = .{
                .x = shadow_texel_w,
                .y = shadow_texel_h,
                .z = current_size * px_range,
                .w = text_type,
            },
            .outline_color_and_w = .{
                .x = outline_rgb.r,
                .y = outline_rgb.g,
                .z = outline_rgb.b,
                .w = text_data.outline_width,
            },
            .render_type = render_type,
        };

        var x2 = scaled_w * 0.5 + scaled_x;
        var tex_u2 = char_data.tex_u + char_data.tex_w;
        if (x2 < scaled_min_x) {
            const scale = (scaled_min_x - x2) / scaled_w;
            x2 = scaled_min_x;
            tex_u2 += scale * char_data.tex_w;
        } else if (x2 > scaled_max_x) {
            const scale = (x2 - scaled_max_x) / scaled_w;
            x2 = scaled_max_x;
            tex_u2 -= scale * char_data.tex_w;
        }

        var y2 = scaled_h * 0.5 + scaled_y;
        var tex_v2 = char_data.tex_v;
        if (y2 < scaled_min_y) {
            const scale = (scaled_min_y - y2) / scaled_h;
            y2 = scaled_min_y;
            tex_v2 -= scale * char_data.tex_h;
        } else if (y2 > scaled_max_y) {
            const scale = (y2 - scaled_max_y) / scaled_h;
            y2 = scaled_max_y;
            tex_v2 += scale * char_data.tex_h;
        }

        base_vert_data[idx_new + 1] = .{
            .pos_uv = .{
                .x = x2,
                .y = y2,
                .z = tex_u2,
                .w = tex_v2,
            },
            .base_color_and_intensity = .{
                .x = current_color.r,
                .y = current_color.g,
                .z = current_color.b,
                .w = 1.0,
            },
            .alpha_and_shadow_color = .{
                .x = text_data.alpha,
                .y = shadow_rgb.r,
                .z = shadow_rgb.g,
                .w = shadow_rgb.b,
            },
            .texel_and_text_data = .{
                .x = shadow_texel_w,
                .y = shadow_texel_h,
                .z = current_size * px_range,
                .w = text_type,
            },
            .outline_color_and_w = .{
                .x = outline_rgb.r,
                .y = outline_rgb.g,
                .z = outline_rgb.b,
                .w = text_data.outline_width,
            },
            .render_type = render_type,
        };

        var x3 = scaled_w * 0.5 + scaled_x;
        var tex_u3 = char_data.tex_u + char_data.tex_w;
        if (x3 < scaled_min_x) {
            const scale = (scaled_min_x - x3) / scaled_w;
            x3 = scaled_min_x;
            tex_u3 += scale * char_data.tex_w;
        } else if (x3 > scaled_max_x) {
            const scale = (x3 - scaled_max_x) / scaled_w;
            x3 = scaled_max_x;
            tex_u3 -= scale * char_data.tex_w;
        }

        var y3 = scaled_h * -0.5 + scaled_y;
        var tex_v3 = char_data.tex_v + char_data.tex_h;
        if (y3 < scaled_min_y) {
            const scale = (scaled_min_y - y3) / scaled_h;
            y3 = scaled_min_y;
            tex_v3 -= scale * char_data.tex_h;
        } else if (y3 > scaled_max_y) {
            const scale = (y3 - scaled_max_y) / scaled_h;
            y3 = scaled_max_y;
            tex_v3 += scale * char_data.tex_h;
        }

        base_vert_data[idx_new + 2] = .{
            .pos_uv = .{
                .x = x3,
                .y = y3,
                .z = tex_u3,
                .w = tex_v3,
            },
            .base_color_and_intensity = .{
                .x = current_color.r,
                .y = current_color.g,
                .z = current_color.b,
                .w = 1.0,
            },
            .alpha_and_shadow_color = .{
                .x = text_data.alpha,
                .y = shadow_rgb.r,
                .z = shadow_rgb.g,
                .w = shadow_rgb.b,
            },
            .texel_and_text_data = .{
                .x = shadow_texel_w,
                .y = shadow_texel_h,
                .z = current_size * px_range,
                .w = text_type,
            },
            .outline_color_and_w = .{
                .x = outline_rgb.r,
                .y = outline_rgb.g,
                .z = outline_rgb.b,
                .w = text_data.outline_width,
            },
            .render_type = render_type,
        };

        var x4 = scaled_w * -0.5 + scaled_x;
        var tex_u4 = char_data.tex_u;
        if (x4 < scaled_min_x) {
            const scale = (scaled_min_x - x4) / scaled_w;
            x4 = scaled_min_x;
            tex_u4 += scale * char_data.tex_w;
        } else if (x4 > scaled_max_x) {
            const scale = (x4 - scaled_max_x) / scaled_w;
            x4 = scaled_max_x;
            tex_u4 -= scale * char_data.tex_w;
        }

        var y4 = scaled_h * -0.5 + scaled_y;
        var tex_v4 = char_data.tex_v + char_data.tex_h;
        if (y4 < scaled_min_y) {
            const scale = (scaled_min_y - y4) / scaled_h;
            y4 = scaled_min_y;
            tex_v4 -= scale * char_data.tex_h;
        } else if (y4 > scaled_max_y) {
            const scale = (y4 - scaled_max_y) / scaled_h;
            y4 = scaled_max_y;
            tex_v4 += scale * char_data.tex_h;
        }

        base_vert_data[idx_new + 3] = .{
            .pos_uv = .{
                .x = x4,
                .y = y4,
                .z = tex_u4,
                .w = tex_v4,
            },
            .base_color_and_intensity = .{
                .x = current_color.r,
                .y = current_color.g,
                .z = current_color.b,
                .w = 1.0,
            },
            .alpha_and_shadow_color = .{
                .x = text_data.alpha,
                .y = shadow_rgb.r,
                .z = shadow_rgb.g,
                .w = shadow_rgb.b,
            },
            .texel_and_text_data = .{
                .x = shadow_texel_w,
                .y = shadow_texel_h,
                .z = current_size * px_range,
                .w = text_type,
            },
            .outline_color_and_w = .{
                .x = outline_rgb.r,
                .y = outline_rgb.g,
                .z = outline_rgb.b,
                .w = text_data.outline_width,
            },
            .render_type = render_type,
        };

        idx_new += 4;
    }

    return idx_new;
}

pub fn endDraw(draw_data: DrawData, verts: u64, indices: u32) void {
    const pass = draw_data.encoder.beginRenderPass(if (first_draw) clear_render_pass_info else load_render_pass_info);
    pass.setVertexBuffer(0, draw_data.buffer, 0, verts);
    pass.setIndexBuffer(index_buffer, .uint16, 0, indices * @sizeOf(u16));
    pass.setPipeline(draw_data.pipeline);
    pass.setBindGroup(0, draw_data.bind_group, null);
    pass.drawIndexed(indices, 1, 0, 0, 0);
    pass.end();
    pass.release();
    first_draw = false;
}

pub fn draw(time: i64, back_buffer: gpu.wgpu.TextureView, encoder: gpu.wgpu.CommandEncoder, allocator: std.mem.Allocator) void {
    const clear_color_attachments: []const gpu.wgpu.RenderPassColorAttachment = &.{.{
        .view = back_buffer,
        .load_op = .clear,
        .store_op = .store,
        .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
    }};
    clear_render_pass_info = .{
        .color_attachment_count = clear_color_attachments.len,
        .color_attachments = clear_color_attachments.ptr,
    };

    const load_color_attachments: []const gpu.wgpu.RenderPassColorAttachment = &.{.{
        .view = back_buffer,
        .load_op = .load,
        .store_op = .store,
        .clear_value = .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 1.0 },
    }};
    load_render_pass_info = .{
        .color_attachment_count = load_color_attachments.len,
        .color_attachments = load_color_attachments.ptr,
    };

    first_draw = true;
    var idx: u16 = 0;
    var square_idx: u16 = 0;

    const base_draw_data: DrawData = .{
        .encoder = encoder,
        .buffer = base_vb,
        .pipeline = base_pipeline,
        .bind_group = base_bind_group,
    };
    const ground_draw_data: DrawData = .{
        .encoder = encoder,
        .buffer = ground_vb,
        .pipeline = ground_pipeline,
        .bind_group = ground_bind_group,
    };

    camera.lock.lock();
    const cam_data: CameraData = .{
        .minimap_zoom = camera.minimap_zoom,
        .angle = camera.angle,
        .scale = camera.scale,
        .x = camera.x,
        .y = camera.y,
        .z = camera.z,
        .cos = camera.cos,
        .sin = camera.sin,
        .clip_x = camera.clip_x,
        .clip_y = camera.clip_y,
        .min_x = camera.min_x,
        .max_x = camera.max_x,
        .min_y = camera.min_y,
        .max_y = camera.max_y,
        .max_dist_sq = camera.max_dist_sq,
        .screen_width = camera.screen_width,
        .screen_height = camera.screen_height,
        .clip_scale_x = camera.clip_scale_x,
        .clip_scale_y = camera.clip_scale_y,
        .square_render_data = camera.square_render_data,
    };
    camera.lock.unlock();
    if ((main.tick_frame or main.editing_map) and
        cam_data.x >= 0 and cam_data.y >= 0 and
        map.validPos(@intFromFloat(cam_data.x), @intFromFloat(cam_data.y)))
    {
        const float_time_ms = @as(f32, @floatFromInt(time)) / std.time.us_per_ms;
        lights.clearRetainingCapacity();

        square_idx = ground_render.drawSquares(square_idx, ground_draw_data, float_time_ms, cam_data, allocator);

        if (square_idx > 0) {
            encoder.writeBuffer(
                ground_vb,
                0,
                GroundVertexData,
                ground_vert_data[0..square_idx],
            );
            endDraw(
                ground_draw_data,
                @as(u64, square_idx) * @sizeOf(GroundVertexData),
                @divFloor(square_idx, 4) * 6,
            );
        }

        idx = game_render.drawEntities(idx, base_draw_data, cam_data, float_time_ms, allocator);

        if (main.settings.enable_lights) {
            const opts: QuadOptions = .{ .base_color = map.info.bg_color, .base_color_intensity = 1.0, .alpha_mult = map.getLightIntensity(time) };
            idx = drawQuad(idx, 0, 0, cam_data.screen_width, cam_data.screen_height, assets.wall_backface_data, base_draw_data, cam_data, opts);

            for (lights.items) |data| {
                idx = drawQuad(
                    idx,
                    data.x,
                    data.y,
                    data.w,
                    data.h,
                    assets.light_data,
                    base_draw_data,
                    cam_data,
                    .{ .base_color = data.color, .base_color_intensity = 1.0, .alpha_mult = data.intensity },
                );
            }
        }
    }

    idx = ui_render.drawTempElements(idx, base_draw_data, cam_data);
    idx = ui_render.drawUiElements(idx, base_draw_data, cam_data, time);

    if (idx > 0) {
        encoder.writeBuffer(
            base_vb,
            0,
            BaseVertexData,
            base_vert_data[0..idx],
        );
        endDraw(
            base_draw_data,
            @as(u64, idx) * @sizeOf(BaseVertexData),
            @divFloor(idx, 4) * 6,
        );
    }
}
