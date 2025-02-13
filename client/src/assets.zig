const std = @import("std");
const builtin = @import("builtin");

const game_data = @import("shared").game_data;
const glfw = @import("zglfw");
const pack = @import("turbopack");
const zaudio = @import("zaudio");
const zstbi = @import("zstbi");

const main = @import("main.zig");
const Settings = @import("Settings.zig");

pub const padding = 2;

pub const atlas_width = 2048;
pub const atlas_height = 1024;
pub const base_texel_w = 1.0 / @as(f32, atlas_width);
pub const base_texel_h = 1.0 / @as(f32, atlas_height);

pub const ui_atlas_width = 2048;
pub const ui_atlas_height = 1024;
pub const ui_texel_w = 1.0 / @as(f32, ui_atlas_width);
pub const ui_texel_h = 1.0 / @as(f32, ui_atlas_height);

// for packing
const Position = struct { x: u16, y: u16 };

pub const Action = enum { stand, walk, attack };
pub const Direction = enum { right, left, down, up };

pub const CharacterData = struct {
    pub const size = 64.0;
    pub const padding = 8.0;
    pub const padding_mult = 1.0 + CharacterData.padding * 2 / size;
    pub const line_height = 1.149;
    pub const px_range = 18.0;

    atlas_w: f32,
    atlas_h: f32,
    x_advance: f32,
    tex_u: f32,
    tex_v: f32,
    tex_w: f32,
    tex_h: f32,
    x_offset: f32,
    y_offset: f32,
    width: f32,
    height: f32,

    pub fn parse(split: *std.mem.SplitIterator(u8, .sequence), atlas_w: f32, atlas_h: f32) !CharacterData {
        var data: CharacterData = .{
            .atlas_w = atlas_w,
            .atlas_h = atlas_h,
            .x_advance = try std.fmt.parseFloat(f32, split.next().?) * size,
            .x_offset = try std.fmt.parseFloat(f32, split.next().?) * size,
            .y_offset = try std.fmt.parseFloat(f32, split.next().?) * size,
            .width = try std.fmt.parseFloat(f32, split.next().?) * size + CharacterData.padding * 2,
            .height = try std.fmt.parseFloat(f32, split.next().?) * size + CharacterData.padding * 2,
            .tex_u = (try std.fmt.parseFloat(f32, split.next().?) - CharacterData.padding) / atlas_w,
            .tex_h = (atlas_h - try std.fmt.parseFloat(f32, split.next().?) + CharacterData.padding * 2) / atlas_h,
            .tex_w = (try std.fmt.parseFloat(f32, split.next().?) + CharacterData.padding * 2) / atlas_w,
            .tex_v = (atlas_h - try std.fmt.parseFloat(f32, split.next().?) - CharacterData.padding) / atlas_h,
        };
        data.width -= data.x_offset;
        data.height -= data.y_offset;
        data.tex_h -= data.tex_v;
        data.tex_w -= data.tex_u;
        return data;
    }
};

pub const AnimEnemyData = struct {
    pub const directions = 2;
    pub const walk_actions = 3;
    pub const attack_actions = 2;

    walk_anims: [directions * walk_actions]AtlasData,
    attack_anims: [directions * attack_actions]AtlasData,
};

pub const AnimPlayerData = struct {
    pub const directions = 4;
    pub const walk_actions = 3;
    pub const attack_actions = 2;

    walk_anims: [directions * walk_actions]AtlasData,
    attack_anims: [directions * attack_actions]AtlasData,
};

pub const AtlasType = enum(u8) {
    base,
    ui,

    pub fn width(self: AtlasType) f32 {
        return switch (self) {
            .base => atlas_width,
            .ui => ui_atlas_width,
        };
    }

    pub fn height(self: AtlasType) f32 {
        return switch (self) {
            .base => atlas_height,
            .ui => ui_atlas_height,
        };
    }
};

pub const AtlasData = extern struct {
    pub fn whole(atlas_type: AtlasType) AtlasData {
        return fromRawF32(1.0, 1.0, 1.0, 1.0, atlas_type);
    }

    tex_u: f32,
    tex_v: f32,
    tex_w: f32,
    tex_h: f32,
    atlas_type: AtlasType,

    pub fn removePadding(self: *AtlasData) void {
        const w = self.atlas_type.width();
        const h = self.atlas_type.height();
        const float_pad: f32 = padding;
        self.tex_u += float_pad / w;
        self.tex_v += float_pad / h;
        self.tex_w -= float_pad * 2 / w;
        self.tex_h -= float_pad * 2 / h;
    }

    pub fn fromRaw(u: c_int, v: c_int, w: c_int, h: c_int, ui: AtlasType) AtlasData {
        return fromRawF32(@floatFromInt(u), @floatFromInt(v), @floatFromInt(w), @floatFromInt(h), ui);
    }

    pub fn fromRawF32(u: f32, v: f32, w: f32, h: f32, atlas_type: AtlasType) AtlasData {
        const atlas_w = atlas_type.width();
        const atlas_h = atlas_type.height();
        return .{
            .tex_u = u / atlas_w,
            .tex_v = v / atlas_h,
            .tex_w = w / atlas_w,
            .tex_h = h / atlas_h,
            .atlas_type = atlas_type,
        };
    }

    pub fn texURaw(self: AtlasData) f32 {
        return self.tex_u * self.atlas_type.width() + padding;
    }

    pub fn texVRaw(self: AtlasData) f32 {
        return self.tex_v * self.atlas_type.height() + padding;
    }

    pub fn texWRaw(self: AtlasData) f32 {
        return self.tex_w * self.atlas_type.width();
    }

    pub fn texHRaw(self: AtlasData) f32 {
        return self.tex_h * self.atlas_type.height();
    }

    pub fn width(self: AtlasData) f32 {
        return self.texWRaw() - padding * 2.0;
    }

    pub fn height(self: AtlasData) f32 {
        return self.texHRaw() - padding * 2.0;
    }
};

const AudioState = struct {
    device: *zaudio.Device,
    engine: *zaudio.Engine,

    export fn audioCallback(device: *zaudio.Device, output: ?*anyopaque, _: ?*const anyopaque, num_frames: u32) void {
        const audio: *AudioState = @ptrCast(@alignCast(device.getUserData()));
        audio.engine.readPcmFrames(output.?, num_frames, null) catch {};
    }

    fn create(allocator: std.mem.Allocator) !*AudioState {
        const audio = try allocator.create(AudioState);

        var device_config = zaudio.Device.Config.init(.playback);
        device_config.data_callback = audioCallback;
        device_config.user_data = audio;
        device_config.sample_rate = 48000;
        device_config.period_size_in_frames = 480;
        device_config.period_size_in_milliseconds = 10;
        device_config.playback.format = .float32;
        device_config.playback.channels = 2;
        const device = try zaudio.Device.create(null, device_config);

        var engine_config = zaudio.Engine.Config.init();
        engine_config.device = device;
        engine_config.no_auto_start = .true32;
        const engine = try zaudio.Engine.create(engine_config);

        audio.* = .{ .device = device, .engine = engine };
        return audio;
    }

    fn destroy(audio: *AudioState, allocator: std.mem.Allocator) void {
        audio.engine.destroy();
        audio.device.destroy();
        allocator.destroy(audio);
    }
};

const RGBA = packed struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,
};

pub var sfx_path_buffer: [256]u8 = undefined;
pub var audio_state: *AudioState = undefined;
pub var main_music: *zaudio.Sound = undefined;

pub var atlas: zstbi.Image = undefined;
pub var ui_atlas: zstbi.Image = undefined;
pub var menu_background: zstbi.Image = undefined;

pub var bold_atlas: zstbi.Image = undefined;
pub var bold_chars: [256]CharacterData = undefined;
pub var bold_italic_atlas: zstbi.Image = undefined;
pub var bold_italic_chars: [256]CharacterData = undefined;
pub var medium_atlas: zstbi.Image = undefined;
pub var medium_chars: [256]CharacterData = undefined;
pub var medium_italic_atlas: zstbi.Image = undefined;
pub var medium_italic_chars: [256]CharacterData = undefined;

// horrible, but no other option since cursor is opaque
pub var default_cursor_pressed: *glfw.Cursor = undefined;
pub var default_cursor: *glfw.Cursor = undefined;
pub var royal_cursor_pressed: *glfw.Cursor = undefined;
pub var royal_cursor: *glfw.Cursor = undefined;
pub var ranger_cursor_pressed: *glfw.Cursor = undefined;
pub var ranger_cursor: *glfw.Cursor = undefined;
pub var aztec_cursor_pressed: *glfw.Cursor = undefined;
pub var aztec_cursor: *glfw.Cursor = undefined;
pub var fiery_cursor_pressed: *glfw.Cursor = undefined;
pub var fiery_cursor: *glfw.Cursor = undefined;
pub var target_enemy_cursor_pressed: *glfw.Cursor = undefined;
pub var target_enemy_cursor: *glfw.Cursor = undefined;
pub var target_ally_cursor_pressed: *glfw.Cursor = undefined;
pub var target_ally_cursor: *glfw.Cursor = undefined;

pub var sfx_copy_map: std.AutoHashMapUnmanaged(*zaudio.Sound, std.ArrayListUnmanaged(*zaudio.Sound)) = .{};
pub var sfx_map: std.StringHashMapUnmanaged(*zaudio.Sound) = .{};
pub var dominant_color_data: std.StringHashMapUnmanaged([]RGBA) = .{};
pub var atlas_to_color_data: std.AutoHashMapUnmanaged(u160, []u32) = .{};
pub var atlas_data: std.StringHashMapUnmanaged([]AtlasData) = .{};
pub var ui_atlas_data: std.StringHashMapUnmanaged([]AtlasData) = .{};
pub var anim_enemies: std.StringHashMapUnmanaged([]AnimEnemyData) = .{};
pub var anim_players: std.StringHashMapUnmanaged([]AnimPlayerData) = .{};

pub var interact_key_tex: AtlasData = AtlasData.fromRawF32(0.0, 0.0, 0.0, 0.0, .ui);
pub var key_tex_map: std.AutoHashMapUnmanaged(Settings.Button, u16) = .{};

pub var left_top_mask_uv: [4]f32 = undefined;
pub var right_bottom_mask_uv: [4]f32 = undefined;
pub var minimap_icons: []AtlasData = undefined;
pub var particle: AtlasData = undefined;
pub var wall_backface_data: AtlasData = undefined;
pub var empty_bar_data: AtlasData = undefined;
pub var hp_bar_data: AtlasData = undefined;
pub var mp_bar_data: AtlasData = undefined;
pub var error_data: AtlasData = undefined;
pub var error_data_enemy: AnimEnemyData = undefined;
pub var error_data_player: AnimPlayerData = undefined;
pub var light_w: f32 = 1.0;
pub var light_h: f32 = 1.0;
pub var light_data: AtlasData = undefined;

fn packSort(_: void, lhs: pack.IdRect, rhs: pack.IdRect) bool {
    return lhs.rect.w < rhs.rect.w;
}

fn imageBounds(img: zstbi.Image, x: usize, y: usize, cut_w: u32, cut_h: u32) struct {
    w: u32,
    h: u32,
    x_offset: u16,
    y_offset: u16,
} {
    var min_x = x + cut_w;
    var min_y = y + cut_h;
    var max_x = x;
    var max_y = y;

    for (y..y + cut_h) |loop_y| {
        for (x..x + cut_w) |loop_x| {
            if (img.data[(loop_y * img.width + loop_x) * 4 + 3] != 0) {
                min_x = @min(min_x, loop_x);
                min_y = @min(min_y, loop_y);
                max_x = @max(max_x, loop_x);
                max_y = @max(max_y, loop_y);
            }
        }
    }

    const w = if (min_x > max_x) 0 else max_x - min_x + 1;
    const h = if (min_y > max_y) 0 else max_y - min_y + 1;
    return .{
        .w = @intCast(w),
        .h = @intCast(h),
        .x_offset = @intCast(if (w == 0 or x > min_x) 0 else min_x - x),
        .y_offset = @intCast(if (h == 0 or y > min_y) 0 else min_y - y),
    };
}

fn addCursors(comptime image_name: [:0]const u8, comptime cut_width: u32, comptime cut_height: u32, allocator: std.mem.Allocator) !void {
    var img = try zstbi.Image.loadFromFile("./assets/sheets/" ++ image_name, 4);
    defer img.deinit();

    const img_size = cut_width * cut_height;
    const len = std.math.divExact(u32, img.width * img.height, img_size) catch
        std.debug.panic("Cursor image " ++ image_name ++ " has an incorrect resolution: {}x{} (cut_w={}, cut_h={})", .{ img.width, img.height, cut_width, cut_height });

    for (0..len) |i| {
        const cur_src_x = (i * cut_width) % img.width;
        const cur_src_y = @divFloor(i * cut_width, img.width) * cut_height;

        var temp = try allocator.alloc(u8, img_size * 4);
        defer allocator.free(temp);

        for (0..img_size) |j| {
            const row_count = @divFloor(j, cut_width);
            const row_idx = j % cut_width;
            const target_idx = (row_count * cut_width + row_idx) * 4;
            const src_idx = ((cur_src_y + row_count) * img.width + cur_src_x + row_idx) * 4;
            @memcpy(temp[target_idx .. target_idx + 4], img.data[src_idx .. src_idx + 4]);
        }

        const cursor = try glfw.Cursor.create(
            cut_width,
            cut_height,
            temp,
            cut_width / 2,
            cut_height / 2,
        );

        switch (i) {
            0 => default_cursor_pressed = cursor,
            1 => default_cursor = cursor,
            2 => royal_cursor_pressed = cursor,
            3 => royal_cursor = cursor,
            4 => ranger_cursor_pressed = cursor,
            5 => ranger_cursor = cursor,
            6 => aztec_cursor_pressed = cursor,
            7 => aztec_cursor = cursor,
            8 => fiery_cursor_pressed = cursor,
            9 => fiery_cursor = cursor,
            10 => target_enemy_cursor_pressed = cursor,
            11 => target_enemy_cursor = cursor,
            12 => target_ally_cursor_pressed = cursor,
            13 => target_ally_cursor = cursor,
            else => {},
        }
    }
}

fn addImage(
    comptime sheet_name: [:0]const u8,
    comptime image_name: [:0]const u8,
    comptime cut_width: u32,
    comptime cut_height: u32,
    comptime dont_trim: bool,
    ctx: *pack.Context,
    allocator: std.mem.Allocator,
) !void {
    var img = try zstbi.Image.loadFromFile("./assets/sheets/" ++ image_name, 4);
    defer img.deinit();

    const len = std.math.divExact(u32, img.width * img.height, cut_width * cut_height) catch
        std.debug.panic("Sheet " ++ sheet_name ++ " has an incorrect resolution: {}x{} (cut_w={}, cut_h={})", .{ img.width, img.height, cut_width, cut_height });

    var current_rects = try allocator.alloc(pack.IdRect, len);
    defer allocator.free(current_rects);

    var current_positions = try allocator.alloc(Position, len);
    defer allocator.free(current_positions);

    for (0..len) |i| {
        const cur_src_x = (i * cut_width) % img.width;
        const cur_src_y = @divFloor(i * cut_width, img.width) * cut_height;
        const bounds = imageBounds(img, cur_src_x, cur_src_y, cut_width, cut_height);
        if (dont_trim) {
            current_positions[i].x = @intCast(cur_src_x);
            current_positions[i].y = @intCast(cur_src_y);
            if (bounds.w == 0 or bounds.h == 0) {
                current_rects[i].rect.w = 0;
                current_rects[i].rect.h = 0;
            } else {
                current_rects[i].rect.w = cut_width + padding * 2;
                current_rects[i].rect.h = cut_height + padding * 2;
            }
            current_rects[i].id = @intCast(i);
        } else {
            current_positions[i].x = @intCast(cur_src_x + bounds.x_offset);
            current_positions[i].y = @intCast(cur_src_y + bounds.y_offset);
            current_rects[i].rect.w = @intCast(bounds.w + padding * 2);
            current_rects[i].rect.h = @intCast(bounds.h + padding * 2);
            current_rects[i].id = @intCast(i);
        }
    }

    try pack.pack(pack.IdRect, ctx, current_rects, .{ .assume_capacity = true, .sortLessThanFn = packSort });

    var data = try allocator.alloc(AtlasData, len);

    var dominant_colors = try allocator.alloc(RGBA, len);
    @memset(dominant_colors, RGBA{});

    var color_counts: std.AutoHashMapUnmanaged(RGBA, u32) = .{};
    defer color_counts.deinit(allocator);

    for (0..len) |i| {
        const id_rect = current_rects[i];
        const rect = id_rect.rect;
        const idx: usize = @intCast(id_rect.id);
        const pos = current_positions[idx];
        if (rect.w <= 0 or rect.h <= 0) {
            data[idx] = AtlasData.fromRaw(0, 0, rect.w, rect.h, .base);
            continue;
        }

        const cur_atlas_x: u32 = @intCast(rect.x + padding);
        const cur_atlas_y: u32 = @intCast(rect.y + padding);

        color_counts.clearRetainingCapacity();

        const w: u32 = @intCast(rect.w - padding * 2);
        const h: u32 = @intCast(rect.h - padding * 2);
        for (0..h) |j| {
            const atlas_idx = ((cur_atlas_y + j) * atlas_width + cur_atlas_x) * 4;
            const src_idx = ((pos.y + j) * img.width + pos.x) * 4;
            @memcpy(atlas.data[atlas_idx .. atlas_idx + w * 4], img.data[src_idx .. src_idx + w * 4]);

            for (0..w) |k| {
                const x_offset = k * 4;
                if (img.data[src_idx + 3 + x_offset] > 0) {
                    const rgba = RGBA{
                        .r = img.data[src_idx + x_offset],
                        .g = img.data[src_idx + 1 + x_offset],
                        .b = img.data[src_idx + 2 + x_offset],
                        .a = 255,
                    };
                    if (color_counts.get(rgba)) |count| {
                        try color_counts.put(allocator, rgba, count + 1);
                    } else {
                        try color_counts.put(allocator, rgba, 1);
                    }
                }
            }
        }

        var colors: std.ArrayListUnmanaged(u32) = .{};
        defer colors.deinit(allocator);

        var max: u32 = 0;
        var count_iter = color_counts.iterator();
        while (count_iter.next()) |entry| {
            try colors.append(allocator, @as(u32, @intCast(entry.key_ptr.r)) << 16 |
                @as(u32, @intCast(entry.key_ptr.g)) << 8 |
                @as(u32, @intCast(entry.key_ptr.b)));

            if (entry.value_ptr.* > max) {
                dominant_colors[idx] = entry.key_ptr.*;
                max = entry.value_ptr.*;
            }
        }

        data[idx] = AtlasData.fromRaw(rect.x, rect.y, rect.w, rect.h, .base);
        try atlas_to_color_data.put(allocator, @bitCast(data[idx]), try allocator.dupe(u32, colors.items));
    }

    try atlas_data.put(allocator, sheet_name, data);
    try dominant_color_data.put(allocator, sheet_name, dominant_colors);
}

fn addUiImage(
    comptime sheet_name: [:0]const u8,
    comptime image_name: [:0]const u8,
    comptime cut_width_base: u32,
    comptime cut_height_base: u32,
    ctx: *pack.Context,
    allocator: std.mem.Allocator,
) !void {
    var img = try zstbi.Image.loadFromFile("./assets/ui/" ++ image_name, 4);
    defer img.deinit();

    const imply_size = std.math.maxInt(u32);
    const cut_width = if (cut_width_base == imply_size) img.width else cut_width_base;
    const cut_height = if (cut_height_base == imply_size) img.height else cut_height_base;

    const len = std.math.divExact(u32, img.width * img.height, cut_width * cut_height) catch
        std.debug.panic("Sheet " ++ sheet_name ++ " has an incorrect resolution: {}x{} (cut_w={}, cut_h={})", .{ img.width, img.height, cut_width, cut_height });

    var current_rects = try allocator.alloc(pack.IdRect, len);
    defer allocator.free(current_rects);

    var current_positions = try allocator.alloc(Position, len);
    defer allocator.free(current_positions);

    var data = try allocator.alloc(AtlasData, len);

    for (0..len) |i| {
        const cur_src_x = (i * cut_width) % img.width;
        const cur_src_y = @divFloor(i * cut_width, img.width) * cut_height;
        const bounds = imageBounds(img, cur_src_x, cur_src_y, cut_width, cut_height);
        current_positions[i].x = @intCast(cur_src_x + bounds.x_offset);
        current_positions[i].y = @intCast(cur_src_y + bounds.y_offset);
        current_rects[i].rect.w = @intCast(bounds.w + padding * 2);
        current_rects[i].rect.h = @intCast(bounds.h + padding * 2);
        current_rects[i].id = @intCast(i);
    }

    try pack.pack(pack.IdRect, ctx, current_rects, .{ .assume_capacity = true, .sortLessThanFn = packSort });

    for (0..len) |i| {
        const id_rect = current_rects[i];
        const rect = id_rect.rect;
        const idx: usize = @intCast(id_rect.id);
        const pos = current_positions[idx];
        if (rect.w <= 0 or rect.h <= 0) {
            data[idx] = AtlasData.fromRaw(rect.x, rect.y, rect.w, rect.h, .ui);
            continue;
        }

        const cur_atlas_x: u32 = @intCast(rect.x + padding);
        const cur_atlas_y: u32 = @intCast(rect.y + padding);
        const w: u32 = @intCast(rect.w - padding * 2);
        const h: u32 = @intCast(rect.h - padding * 2);
        for (0..h) |j| {
            const atlas_idx = ((cur_atlas_y + j) * atlas_width + cur_atlas_x) * 4;
            const src_idx = ((pos.y + j) * img.width + pos.x) * 4;
            @memcpy(ui_atlas.data[atlas_idx .. atlas_idx + w * 4], img.data[src_idx .. src_idx + w * 4]);
        }

        data[idx] = AtlasData.fromRaw(rect.x, rect.y, rect.w, rect.h, .ui);
    }

    try ui_atlas_data.put(allocator, sheet_name, data);
}

fn addAnimEnemy(
    comptime sheet_name: [:0]const u8,
    comptime image_name: [:0]const u8,
    comptime cut_width: u32,
    comptime cut_height: u32,
    ctx: *pack.Context,
    allocator: std.mem.Allocator,
) !void {
    var img = try zstbi.Image.loadFromFile("./assets/sheets/" ++ image_name, 4);
    defer img.deinit();

    const len = @divExact(std.math.divExact(u32, img.width * img.height, cut_width * cut_height) catch
        std.debug.panic(
        "Sheet " ++ sheet_name ++ " has an incorrect resolution: {}x{} (cut_w={}, cut_h={})",
        .{ img.width, img.height, cut_width, cut_height },
    ), 6) * 5 * AnimEnemyData.directions;

    var current_rects = try allocator.alloc(pack.IdRect, len);
    defer allocator.free(current_rects);

    var current_positions = try allocator.alloc(Position, len);
    defer allocator.free(current_positions);

    var left_sub: u32 = 0;
    for (0..len) |i| {
        const frame_idx = i % 5;
        const set_idx = @divFloor(i, 5);
        const cur_src_x = frame_idx * cut_width;
        if (set_idx % 2 == 1 and frame_idx == 0) {
            left_sub += 1;
        }

        const cur_src_y = (set_idx - left_sub) * cut_height;
        const attack_scale = @as(u32, @intFromBool(frame_idx == 4)) + 1;
        const bounds = imageBounds(img, cur_src_x, cur_src_y, cut_width * attack_scale, cut_height);
        current_positions[i].x = @intCast(cur_src_x + bounds.x_offset);
        current_positions[i].y = @intCast(cur_src_y + bounds.y_offset);
        current_rects[i].rect.w = @intCast(bounds.w + padding * 2);
        current_rects[i].rect.h = @intCast(bounds.h + padding * 2);
        current_rects[i].id = @intCast(i);
    }

    try pack.pack(pack.IdRect, ctx, current_rects, .{ .assume_capacity = true, .sortLessThanFn = packSort });

    const enemy_data = try allocator.alloc(AnimEnemyData, @divFloor(len, 5));

    var dominant_colors = try allocator.alloc(RGBA, len);
    @memset(dominant_colors, RGBA{});

    var color_counts: std.AutoHashMapUnmanaged(RGBA, u32) = .{};
    defer color_counts.deinit(allocator);

    for (0..len) |i| {
        const id_rect = current_rects[i];
        const rect = id_rect.rect;
        const idx: usize = @intCast(id_rect.id);
        const pos = current_positions[idx];

        color_counts.clearRetainingCapacity();

        const data = AtlasData.fromRaw(rect.x, rect.y, rect.w, rect.h, .base);
        const frame_idx = idx % 5;
        const set_idx = @divFloor(idx, 5);
        const data_idx = @divFloor(set_idx, 2);
        const dir_idx = set_idx % 2;
        if (frame_idx >= 3) {
            enemy_data[data_idx].attack_anims[dir_idx * AnimEnemyData.attack_actions + frame_idx - AnimEnemyData.walk_actions] = data;
        } else {
            enemy_data[data_idx].walk_anims[dir_idx * AnimEnemyData.walk_actions + frame_idx] = data;
        }

        if (rect.w <= 0 or rect.h <= 0)
            continue;

        const cur_atlas_x: u32 = @intCast(rect.x + padding);
        const cur_atlas_y: u32 = @intCast(rect.y + padding);
        const w: u32 = @intCast(rect.w - padding * 2);
        const h: u32 = @intCast(rect.h - padding * 2);

        for (0..w * h) |k| {
            const row_count = @divFloor(k, w);
            const row_idx = k % w;
            const atlas_idx = ((cur_atlas_y + row_count) * atlas_width + cur_atlas_x + row_idx) * 4;

            const src_idx = if (dir_idx == @intFromEnum(Direction.left))
                ((pos.y + row_count) * img.width + pos.x + w - row_idx - 1) * 4
            else
                ((pos.y + row_count) * img.width + pos.x + row_idx) * 4;

            @memcpy(atlas.data[atlas_idx .. atlas_idx + 4], img.data[src_idx .. src_idx + 4]);

            if (img.data[src_idx + 3] > 0) {
                const rgba = RGBA{
                    .r = img.data[src_idx],
                    .g = img.data[src_idx + 1],
                    .b = img.data[src_idx + 2],
                    .a = 255,
                };
                if (color_counts.get(rgba)) |count| {
                    try color_counts.put(allocator, rgba, count + 1);
                } else {
                    try color_counts.put(allocator, rgba, 1);
                }
            }
        }

        var colors: std.ArrayListUnmanaged(u32) = .{};
        defer colors.deinit(allocator);

        var max: u32 = 0;
        var count_iter = color_counts.iterator();
        while (count_iter.next()) |entry| {
            try colors.append(allocator, @as(u32, @intCast(entry.key_ptr.r)) << 16 |
                @as(u32, @intCast(entry.key_ptr.g)) << 8 |
                @as(u32, @intCast(entry.key_ptr.b)));

            if (entry.value_ptr.* > max) {
                dominant_colors[set_idx] = entry.key_ptr.*;
                max = entry.value_ptr.*;
            }
        }

        try atlas_to_color_data.put(allocator, @bitCast(data), try allocator.dupe(u32, colors.items));
    }

    try anim_enemies.put(allocator, sheet_name, enemy_data);
    try dominant_color_data.put(allocator, sheet_name, dominant_colors);
}

fn addAnimPlayer(
    comptime sheet_name: [:0]const u8,
    comptime image_name: [:0]const u8,
    comptime cut_width: u32,
    comptime cut_height: u32,
    ctx: *pack.Context,
    allocator: std.mem.Allocator,
) !void {
    var img = try zstbi.Image.loadFromFile("./assets/sheets/" ++ image_name, 4);
    defer img.deinit();

    var len = @divExact(std.math.divExact(u32, img.width * img.height, cut_width * cut_height) catch
        std.debug.panic(
        "Sheet " ++ sheet_name ++ " has an incorrect resolution: {}x{} (cut_w={}, cut_h={})",
        .{ img.width, img.height, cut_width, cut_height },
    ), 6) * 5;
    len += @divFloor(len, 3); // for the "missing" left side

    var current_rects = try allocator.alloc(pack.IdRect, len);
    defer allocator.free(current_rects);

    var current_positions = try allocator.alloc(Position, len);
    defer allocator.free(current_positions);

    var left_sub: u32 = 0;
    for (0..len) |i| {
        const frame_idx = i % 5;
        const set_idx = @divFloor(i, 5);
        const cur_src_x = frame_idx * cut_width;
        if (set_idx % 4 == 1 and frame_idx == 0) {
            left_sub += 1;
        }

        const cur_src_y = (set_idx - left_sub) * cut_height;
        const attack_scale = @as(u32, @intFromBool(frame_idx == 4)) + 1;
        const bounds = imageBounds(img, cur_src_x, cur_src_y, cut_width * attack_scale, cut_height);
        current_positions[i].x = @intCast(cur_src_x + bounds.x_offset);
        current_positions[i].y = @intCast(cur_src_y + bounds.y_offset);
        current_rects[i].rect.w = @intCast(bounds.w + padding * 2);
        current_rects[i].rect.h = @intCast(bounds.h + padding * 2);
        current_rects[i].id = @intCast(i);
    }

    try pack.pack(pack.IdRect, ctx, current_rects, .{ .assume_capacity = true, .sortLessThanFn = packSort });

    left_sub = 0;

    const player_data = try allocator.alloc(AnimPlayerData, @divFloor(len, 5 * 4));

    var dominant_colors = try allocator.alloc(RGBA, len);
    @memset(dominant_colors, RGBA{});

    var color_counts: std.AutoHashMapUnmanaged(RGBA, u32) = .{};
    defer color_counts.deinit(allocator);

    for (0..len) |j| {
        const id_rect = current_rects[j];
        const rect = id_rect.rect;
        const idx: usize = @intCast(id_rect.id);
        const pos = current_positions[idx];

        color_counts.clearRetainingCapacity();

        const data = AtlasData.fromRaw(rect.x, rect.y, rect.w, rect.h, .base);
        const frame_idx = idx % 5;
        const set_idx = @divFloor(idx, 5);
        if (set_idx % 4 == 1 and frame_idx == 0) {
            left_sub += 1;
        }

        const data_idx = @divFloor(set_idx, 4);
        const dir_idx = set_idx % 4;
        if (frame_idx >= 3) {
            player_data[data_idx].attack_anims[dir_idx * AnimPlayerData.attack_actions + frame_idx - AnimEnemyData.walk_actions] = data;
        } else {
            player_data[data_idx].walk_anims[dir_idx * AnimPlayerData.walk_actions + frame_idx] = data;
        }

        if (rect.w <= 0 or rect.h <= 0)
            continue;

        const cur_atlas_x: u32 = @intCast(rect.x + padding);
        const cur_atlas_y: u32 = @intCast(rect.y + padding);
        const w: u32 = @intCast(rect.w - padding * 2);
        const h: u32 = @intCast(rect.h - padding * 2);

        for (0..w * h) |k| {
            const row_count = @divFloor(k, w);
            const row_idx = k % w;
            const atlas_idx = ((cur_atlas_y + row_count) * atlas_width + cur_atlas_x + row_idx) * 4;

            const src_idx = if (set_idx % 4 == @intFromEnum(Direction.left))
                ((pos.y + row_count) * img.width + pos.x + w - row_idx - 1) * 4
            else
                ((pos.y + row_count) * img.width + pos.x + row_idx) * 4;

            @memcpy(atlas.data[atlas_idx .. atlas_idx + 4], img.data[src_idx .. src_idx + 4]);

            if (img.data[src_idx + 3] > 0) {
                const rgba = RGBA{
                    .r = img.data[src_idx],
                    .g = img.data[src_idx + 1],
                    .b = img.data[src_idx + 2],
                    .a = 255,
                };
                if (color_counts.get(rgba)) |count| {
                    try color_counts.put(allocator, rgba, count + 1);
                } else {
                    try color_counts.put(allocator, rgba, 1);
                }
            }
        }

        var colors: std.ArrayListUnmanaged(u32) = .{};
        defer colors.deinit(allocator);

        var max: u32 = 0;
        var count_iter = color_counts.iterator();
        while (count_iter.next()) |entry| {
            try colors.append(allocator, @as(u32, entry.key_ptr.r) << 16 |
                @as(u32, entry.key_ptr.g) << 8 |
                @as(u32, entry.key_ptr.b));

            if (entry.value_ptr.* > max) {
                dominant_colors[set_idx] = entry.key_ptr.*;
                max = entry.value_ptr.*;
            }
        }

        try atlas_to_color_data.put(allocator, @bitCast(data), try allocator.dupe(u32, colors.items));
    }

    try anim_players.put(allocator, sheet_name, player_data);
    try dominant_color_data.put(allocator, sheet_name, dominant_colors);
}

fn parseFontData(allocator: std.mem.Allocator, comptime atlas_w: f32, comptime atlas_h: f32, comptime path: []const u8, chars: *[256]CharacterData) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const data = try file.readToEndAlloc(allocator, std.math.maxInt(u16));
    defer allocator.free(data);

    var iter = std.mem.splitSequence(u8, data, if (std.mem.indexOf(u8, data, "\r\n") != null) "\r\n" else "\n");
    while (iter.next()) |line| {
        if (line.len == 0)
            continue;

        var split = std.mem.splitSequence(u8, line, ",");
        const idx = try std.fmt.parseInt(usize, split.next().?, 0);
        chars[idx] = try CharacterData.parse(&split, atlas_w, atlas_h);
    }
}

pub fn playSfx(name: []const u8) void {
    if (main.settings.sfx_volume <= 0.0)
        return;

    const allocator = main.allocator;
    if (sfx_map.get(name)) |audio| {
        if (!audio.isPlaying()) {
            audio.setVolume(main.settings.sfx_volume);
            audio.start() catch return;
            return;
        }

        var audio_copies = sfx_copy_map.get(audio);
        if (audio_copies == null)
            audio_copies = .{};

        for (audio_copies.?.items) |copy_audio| {
            if (!copy_audio.isPlaying()) {
                copy_audio.setVolume(main.settings.sfx_volume);
                copy_audio.start() catch return;
                return;
            }
        }

        var new_copy_audio = audio_state.engine.createSoundCopy(audio, .{}, null) catch return;
        new_copy_audio.setVolume(main.settings.sfx_volume);
        new_copy_audio.start() catch return;
        audio_copies.?.append(allocator, new_copy_audio) catch return;
        sfx_copy_map.put(allocator, audio, audio_copies.?) catch return;
        return;
    }

    const path = std.fmt.bufPrintZ(&sfx_path_buffer, "./assets/sfx/{s}", .{name}) catch return;

    if (std.fs.cwd().access(path, .{})) |_| {
        var audio = audio_state.engine.createSoundFromFile(path, .{}) catch return;
        audio.setVolume(main.settings.sfx_volume);
        audio.start() catch return;

        sfx_map.put(allocator, name, audio) catch return;
    } else |_| {
        if (!std.mem.eql(u8, name, "Unknown"))
            std.log.err("Could not find sound effect for \"{s}\"", .{name});
    }
}

pub fn deinit(allocator: std.mem.Allocator) void {
    main_music.destroy();

    var copy_audio_iter = sfx_copy_map.valueIterator();
    while (copy_audio_iter.next()) |copy_audio_list| {
        for (copy_audio_list.items) |copy_audio| {
            copy_audio.*.destroy();
        }
        copy_audio_list.deinit(allocator);
    }
    sfx_copy_map.deinit(allocator);

    var audio_iter = sfx_map.valueIterator();
    while (audio_iter.next()) |audio| {
        audio.*.destroy();
    }
    sfx_map.deinit(allocator);
    audio_state.destroy(allocator);

    default_cursor_pressed.destroy();
    default_cursor.destroy();
    royal_cursor_pressed.destroy();
    royal_cursor.destroy();
    ranger_cursor_pressed.destroy();
    ranger_cursor.destroy();
    aztec_cursor_pressed.destroy();
    aztec_cursor.destroy();
    fiery_cursor_pressed.destroy();
    fiery_cursor.destroy();
    target_enemy_cursor_pressed.destroy();
    target_enemy_cursor.destroy();
    target_ally_cursor_pressed.destroy();
    target_ally_cursor.destroy();

    var colors_iter = atlas_to_color_data.valueIterator();
    while (colors_iter.next()) |colors| {
        allocator.free(colors.*);
    }

    var dominant_colors_iter = dominant_color_data.valueIterator();
    while (dominant_colors_iter.next()) |color_data| {
        allocator.free(color_data.*);
    }

    var rects_iter = atlas_data.valueIterator();
    while (rects_iter.next()) |sheet_rects| {
        allocator.free(sheet_rects.*);
    }

    var ui_rects_iter = ui_atlas_data.valueIterator();
    while (ui_rects_iter.next()) |sheet_rects| {
        allocator.free(sheet_rects.*);
    }

    var anim_enemy_iter = anim_enemies.valueIterator();
    while (anim_enemy_iter.next()) |enemy_data| {
        allocator.free(enemy_data.*);
    }

    var anim_player_iter = anim_players.valueIterator();
    while (anim_player_iter.next()) |player_data| {
        allocator.free(player_data.*);
    }

    dominant_color_data.deinit(allocator);
    atlas_to_color_data.deinit(allocator);
    atlas_data.deinit(allocator);
    ui_atlas_data.deinit(allocator);
    anim_enemies.deinit(allocator);
    anim_players.deinit(allocator);
    key_tex_map.deinit(allocator);
}

pub fn init(allocator: std.mem.Allocator) !void {
    defer {
        const dummy_string_ctx: std.hash_map.StringContext = undefined;
        if (sfx_map.capacity() > 0) sfx_map.rehash(dummy_string_ctx);
        if (dominant_color_data.capacity() > 0) dominant_color_data.rehash(dummy_string_ctx);
        if (atlas_data.capacity() > 0) atlas_data.rehash(dummy_string_ctx);
        if (ui_atlas_data.capacity() > 0) ui_atlas_data.rehash(dummy_string_ctx);
        if (anim_enemies.capacity() > 0) anim_enemies.rehash(dummy_string_ctx);
        if (anim_players.capacity() > 0) anim_players.rehash(dummy_string_ctx);

        const dummy_sfx_ctx: std.hash_map.AutoContext(*zaudio.Sound) = undefined;
        if (sfx_copy_map.capacity() > 0) sfx_copy_map.rehash(dummy_sfx_ctx);

        const dummy_atlas_ctx: std.hash_map.AutoContext(u160) = undefined;
        if (atlas_to_color_data.capacity() > 0) atlas_to_color_data.rehash(dummy_atlas_ctx);

        const dummy_button_ctx: std.hash_map.AutoContext(Settings.Button) = undefined;
        if (key_tex_map.capacity() > 0) key_tex_map.rehash(dummy_button_ctx);
    }

    menu_background = try zstbi.Image.loadFromFile("./assets/ui/menu_background.png", 4);

    bold_atlas = try zstbi.Image.loadFromFile("./assets/fonts/ubuntu_bold.png", 4);
    bold_italic_atlas = try zstbi.Image.loadFromFile("./assets/fonts/ubuntu_bold_italic.png", 4);
    medium_atlas = try zstbi.Image.loadFromFile("./assets/fonts/ubuntu_medium.png", 4);
    medium_italic_atlas = try zstbi.Image.loadFromFile("./assets/fonts/ubuntu_medium_italic.png", 4);

    try parseFontData(allocator, 1024, 1024, "./assets/fonts/ubuntu_bold.csv", &bold_chars);
    try parseFontData(allocator, 1024, 1024, "./assets/fonts/ubuntu_bold_italic.csv", &bold_italic_chars);
    try parseFontData(allocator, 1024, 512, "./assets/fonts/ubuntu_medium.csv", &medium_chars);
    try parseFontData(allocator, 1024, 1024, "./assets/fonts/ubuntu_medium_italic.csv", &medium_italic_chars);

    audio_state = try AudioState.create(allocator);
    try audio_state.engine.start();

    main_music = try audio_state.engine.createSoundFromFile("./assets/music/main_menu.mp3", .{});
    main_music.setLooping(true);
    main_music.setVolume(main.settings.music_volume);
    try main_music.start();

    try addCursors("cursors.png", 32, 32, allocator);

    atlas = try zstbi.Image.createEmpty(atlas_width, atlas_height, 4, .{});
    var ctx = try pack.Context.create(allocator, atlas_width, atlas_height, .{ .spaces_to_prealloc = 4096 });
    defer ctx.deinit();

    try addImage("light", "light.png", 128, 128, false, &ctx, allocator);
    try addImage("bars", "bars.png", 24, 8, false, &ctx, allocator);
    try addImage("conditions", "conditions.png", 16, 16, false, &ctx, allocator);
    try addImage("error_texture", "error_texture.png", 8, 8, false, &ctx, allocator);
    try addImage("invisible", "invisible.png", 8, 8, true, &ctx, allocator);
    try addImage("ground", "ground.png", 8, 8, true, &ctx, allocator);
    try addImage("ground_masks", "ground_masks.png", 8, 8, true, &ctx, allocator);
    try addImage("misc", "misc.png", 8, 8, false, &ctx, allocator);
    try addImage("misc_big", "misc_big.png", 16, 16, false, &ctx, allocator);
    try addImage("portals", "portals.png", 8, 8, false, &ctx, allocator);
    try addImage("portals_big", "portals_big.png", 16, 16, false, &ctx, allocator);
    try addImage("props", "props.png", 8, 8, false, &ctx, allocator);
    try addImage("props_big", "props_big.png", 16, 16, false, &ctx, allocator);
    try addImage("basic_items", "basic_items.png", 8, 8, false, &ctx, allocator);
    try addImage("basic_projectiles", "basic_projectiles.png", 8, 8, true, &ctx, allocator);
    try addImage("projectiles", "projectiles.png", 8, 8, true, &ctx, allocator);
    try addImage("wall_backface", "wall_backface.png", 8, 8, true, &ctx, allocator);
    try addImage("particles", "particles.png", 8, 8, false, &ctx, allocator);
    try addImage("walls", "walls.png", 8, 8, false, &ctx, allocator);

    try addAnimEnemy("mobs", "mobs.png", 8, 8, &ctx, allocator);
    try addAnimPlayer("players", "players.png", 8, 8, &ctx, allocator);

    // try zstbi.Image.writeToFile(atlas, "atlas.png", .png);

    ui_atlas = try zstbi.Image.createEmpty(ui_atlas_width, ui_atlas_height, 4, .{});
    var ui_ctx = try pack.Context.create(allocator, ui_atlas_width, ui_atlas_height, .{ .spaces_to_prealloc = 4096 });
    defer ui_ctx.deinit();

    const imply_size = std.math.maxInt(u32);
    try addUiImage("menu_decor_frame", "menu_decor_frame.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("retrieve_button", "retrieve_button.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("options_button", "options_button.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("rare_slot", "rare_slot.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("epic_slot", "epic_slot.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("legendary_slot", "legendary_slot.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("mythic_slot", "mythic_slot.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("rare_slot_equip", "rare_slot_equip.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("epic_slot_equip", "epic_slot_equip.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("legendary_slot_equip", "legendary_slot_equip.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("mythic_slot_equip", "mythic_slot_equip.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("in_combat_icon", "in_combat_icon.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("out_of_combat_icon", "out_of_combat_icon.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("out_of_mana_slot", "out_of_mana_slot.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("out_of_health_slot", "out_of_health_slot.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dialog_base_background", "screens/dialog_base_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dialog_title_background", "screens/dialog_title_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("button_base", "screens/button_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("button_hover", "screens/button_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("button_press", "screens/button_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_collapsed_icon_base", "screens/dropdown_collapsed_icon_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_collapsed_icon_hover", "screens/dropdown_collapsed_icon_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_collapsed_icon_press", "screens/dropdown_collapsed_icon_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_extended_icon_base", "screens/dropdown_extended_icon_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_extended_icon_hover", "screens/dropdown_extended_icon_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_extended_icon_press", "screens/dropdown_extended_icon_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_main_color_base", "screens/dropdown_main_color_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_main_color_hover", "screens/dropdown_main_color_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_main_color_press", "screens/dropdown_main_color_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_alt_color_base", "screens/dropdown_alt_color_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_alt_color_hover", "screens/dropdown_alt_color_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_alt_color_press", "screens/dropdown_alt_color_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_title_background", "screens/dropdown_title_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("dropdown_background", "screens/dropdown_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("checked_box_base", "screens/checked_box_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("checked_box_hover", "screens/checked_box_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("checked_box_press", "screens/checked_box_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("slider_background", "screens/slider_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("slider_knob_base", "screens/slider_knob_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("slider_knob_hover", "screens/slider_knob_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("slider_knob_press", "screens/slider_knob_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("text_input_base", "screens/text_input_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("text_input_hover", "screens/text_input_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("text_input_press", "screens/text_input_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("toggle_slider_base_off", "screens/toggle_slider_base_off.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("toggle_slider_hover_off", "screens/toggle_slider_hover_off.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("toggle_slider_press_off", "screens/toggle_slider_press_off.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("toggle_slider_base_on", "screens/toggle_slider_base_on.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("toggle_slider_hover_on", "screens/toggle_slider_hover_on.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("toggle_slider_press_on", "screens/toggle_slider_press_on.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_background", "screens/tooltip_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_background_rare", "screens/tooltip_background_rare.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_background_epic", "screens/tooltip_background_epic.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_background_legendary", "screens/tooltip_background_legendary.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_background_mythic", "screens/tooltip_background_mythic.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_bottom", "screens/tooltip_line_spacer_bottom.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_bottom_rare", "screens/tooltip_line_spacer_bottom_rare.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_bottom_epic", "screens/tooltip_line_spacer_bottom_epic.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_bottom_legendary", "screens/tooltip_line_spacer_bottom_legendary.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_bottom_mythic", "screens/tooltip_line_spacer_bottom_mythic.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_top", "screens/tooltip_line_spacer_top.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_top_rare", "screens/tooltip_line_spacer_top_rare.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_top_epic", "screens/tooltip_line_spacer_top_epic.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_top_legendary", "screens/tooltip_line_spacer_top_legendary.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("tooltip_line_spacer_top_mythic", "screens/tooltip_line_spacer_top_mythic.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("unchecked_box_base", "screens/unchecked_box_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("unchecked_box_hover", "screens/unchecked_box_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("unchecked_box_press", "screens/unchecked_box_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_menu_background", "screens/player_menu_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_menu_cell_base", "screens/player_menu_cell_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_menu_cell_hover", "screens/player_menu_cell_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_menu_cell_press", "screens/player_menu_cell_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("container_view", "container_view.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("minimap", "minimap.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("minimap_slots", "minimap_slots.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_inventory", "player_inventory.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_health_bar", "player_health_bar.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_mana_bar", "player_mana_bar.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_abilities_bars", "player_abilities_bars.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_xp_bar", "player_xp_bar.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_xp_decor", "player_xp_decor.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("options_background", "options_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_stats", "player_stats.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("chatbox_background", "chatbox_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("chatbox_input", "chatbox_input.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("chatbox_cursor", "chatbox_cursor.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("scroll_background", "scroll_background.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("scroll_wheel_base", "scroll_wheel_base.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("scroll_wheel_hover", "scroll_wheel_hover.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("scroll_wheel_press", "scroll_wheel_press.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("scrollbar_decor", "scrollbar_decor.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("stats_button", "stats_button.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("player_fame_bar", "player_fame_bar.png", imply_size, imply_size, &ui_ctx, allocator);
    try addUiImage("minimap_icons", "minimap_icons.png", 8, 8, &ui_ctx, allocator);
    try addUiImage("key_indicators", "key_indicators.png", 100, 100, &ui_ctx, allocator);
    try addUiImage("speech_balloons", "speech_balloons.png", 65, 45, &ui_ctx, allocator);

    // try zstbi.Image.writeToFile(ui_atlas, "ui_atlas.png", .png);

    if (ui_atlas_data.get("minimap_icons")) |icons| minimap_icons = icons else @panic("minimap_icons not found in UI atlas");

    if (atlas_data.get("light")) |light| {
        light_data = light[0];
    } else std.debug.panic("Could not find light in the atlas", .{});

    if (atlas_data.get("ground_masks")) |ground_masks| {
        var left_mask_data = ground_masks[0];
        left_mask_data.removePadding();

        var top_mask_data = ground_masks[1];
        top_mask_data.removePadding();

        left_top_mask_uv = [4]f32{ left_mask_data.tex_u, left_mask_data.tex_v, top_mask_data.tex_u, top_mask_data.tex_v };

        var right_mask_rect = ground_masks[2];
        right_mask_rect.removePadding();

        var bottom_mask_rect = ground_masks[3];
        bottom_mask_rect.removePadding();

        right_bottom_mask_uv = [4]f32{ right_mask_rect.tex_u, right_mask_rect.tex_v, bottom_mask_rect.tex_u, bottom_mask_rect.tex_v };
    } else std.debug.panic("Could not find ground_masks in the atlas", .{});

    if (atlas_data.get("wall_backface")) |backfaces| {
        wall_backface_data = backfaces[0];
        wall_backface_data.removePadding();
    } else std.debug.panic("Could not find wall_backface in the atlas", .{});

    if (atlas_data.get("particles")) |particles| {
        particle = particles[0];
    } else std.debug.panic("Could not find particle in the atlas", .{});

    if (atlas_data.get("bars")) |bars| {
        hp_bar_data = bars[0];
        mp_bar_data = bars[1];
        empty_bar_data = bars[2];
    } else std.debug.panic("Could not find bars in the atlas", .{});

    if (atlas_data.get("error_texture")) |error_tex| {
        error_data = error_tex[0];

        const enemy_walk_frames = AnimEnemyData.directions * AnimEnemyData.walk_actions;
        const enemy_attack_frames = AnimEnemyData.directions * AnimEnemyData.attack_actions;
        error_data_enemy = AnimEnemyData{
            .walk_anims = [_]AtlasData{error_data} ** enemy_walk_frames,
            .attack_anims = [_]AtlasData{error_data} ** enemy_attack_frames,
        };

        const player_walk_frames = AnimPlayerData.directions * AnimPlayerData.walk_actions;
        const player_attack_frames = AnimPlayerData.directions * AnimPlayerData.attack_actions;
        error_data_player = AnimPlayerData{
            .walk_anims = [_]AtlasData{error_data} ** player_walk_frames,
            .attack_anims = [_]AtlasData{error_data} ** player_attack_frames,
        };
    } else std.debug.panic("Could not find error_texture in the atlas", .{});

    try populateKeyMap(allocator);
    interact_key_tex = getKeyTexture(main.settings.interact);
}

fn populateKeyMap(allocator: std.mem.Allocator) !void {
    try key_tex_map.put(allocator, .{ .mouse = .left }, 46);
    try key_tex_map.put(allocator, .{ .mouse = .right }, 59);
    try key_tex_map.put(allocator, .{ .mouse = .middle }, 58);
    try key_tex_map.put(allocator, .{ .mouse = .four }, 108);
    try key_tex_map.put(allocator, .{ .mouse = .five }, 109);
    try key_tex_map.put(allocator, .{ .key = .zero }, 0);
    try key_tex_map.put(allocator, .{ .key = .one }, 4);
    try key_tex_map.put(allocator, .{ .key = .two }, 5);
    try key_tex_map.put(allocator, .{ .key = .three }, 6);
    try key_tex_map.put(allocator, .{ .key = .four }, 7);
    try key_tex_map.put(allocator, .{ .key = .five }, 8);
    try key_tex_map.put(allocator, .{ .key = .six }, 16);
    try key_tex_map.put(allocator, .{ .key = .seven }, 17);
    try key_tex_map.put(allocator, .{ .key = .eight }, 18);
    try key_tex_map.put(allocator, .{ .key = .nine }, 19);
    try key_tex_map.put(allocator, .{ .key = .kp_0 }, 91);
    try key_tex_map.put(allocator, .{ .key = .kp_1 }, 92);
    try key_tex_map.put(allocator, .{ .key = .kp_2 }, 93);
    try key_tex_map.put(allocator, .{ .key = .kp_3 }, 94);
    try key_tex_map.put(allocator, .{ .key = .kp_4 }, 95);
    try key_tex_map.put(allocator, .{ .key = .kp_5 }, 96);
    try key_tex_map.put(allocator, .{ .key = .kp_6 }, 97);
    try key_tex_map.put(allocator, .{ .key = .kp_7 }, 98);
    try key_tex_map.put(allocator, .{ .key = .kp_8 }, 99);
    try key_tex_map.put(allocator, .{ .key = .kp_9 }, 100);
    try key_tex_map.put(allocator, .{ .key = .F1 }, 68);
    try key_tex_map.put(allocator, .{ .key = .F2 }, 69);
    try key_tex_map.put(allocator, .{ .key = .F3 }, 70);
    try key_tex_map.put(allocator, .{ .key = .F4 }, 71);
    try key_tex_map.put(allocator, .{ .key = .F5 }, 72);
    try key_tex_map.put(allocator, .{ .key = .F6 }, 73);
    try key_tex_map.put(allocator, .{ .key = .F7 }, 74);
    try key_tex_map.put(allocator, .{ .key = .F8 }, 75);
    try key_tex_map.put(allocator, .{ .key = .F9 }, 76);
    try key_tex_map.put(allocator, .{ .key = .F10 }, 1);
    try key_tex_map.put(allocator, .{ .key = .F11 }, 2);
    try key_tex_map.put(allocator, .{ .key = .F12 }, 3);
    try key_tex_map.put(allocator, .{ .key = .a }, 20);
    try key_tex_map.put(allocator, .{ .key = .b }, 34);
    try key_tex_map.put(allocator, .{ .key = .c }, 39);
    try key_tex_map.put(allocator, .{ .key = .d }, 50);
    try key_tex_map.put(allocator, .{ .key = .e }, 52);
    try key_tex_map.put(allocator, .{ .key = .f }, 84);
    try key_tex_map.put(allocator, .{ .key = .g }, 85);
    try key_tex_map.put(allocator, .{ .key = .h }, 86);
    try key_tex_map.put(allocator, .{ .key = .i }, 88);
    try key_tex_map.put(allocator, .{ .key = .j }, 63);
    try key_tex_map.put(allocator, .{ .key = .k }, 74);
    try key_tex_map.put(allocator, .{ .key = .l }, 75);
    try key_tex_map.put(allocator, .{ .key = .m }, 76);
    try key_tex_map.put(allocator, .{ .key = .n }, 61);
    try key_tex_map.put(allocator, .{ .key = .o }, 65);
    try key_tex_map.put(allocator, .{ .key = .p }, 66);
    try key_tex_map.put(allocator, .{ .key = .q }, 25);
    try key_tex_map.put(allocator, .{ .key = .r }, 28);
    try key_tex_map.put(allocator, .{ .key = .s }, 29);
    try key_tex_map.put(allocator, .{ .key = .t }, 73);
    try key_tex_map.put(allocator, .{ .key = .u }, 67);
    try key_tex_map.put(allocator, .{ .key = .v }, 31);
    try key_tex_map.put(allocator, .{ .key = .w }, 10);
    try key_tex_map.put(allocator, .{ .key = .x }, 12);
    try key_tex_map.put(allocator, .{ .key = .y }, 13);
    try key_tex_map.put(allocator, .{ .key = .z }, 14);
    try key_tex_map.put(allocator, .{ .key = .up }, 32);
    try key_tex_map.put(allocator, .{ .key = .down }, 22);
    try key_tex_map.put(allocator, .{ .key = .left }, 23);
    try key_tex_map.put(allocator, .{ .key = .right }, 24);
    try key_tex_map.put(allocator, .{ .key = .left_shift }, 15);
    try key_tex_map.put(allocator, .{ .key = .right_shift }, 9);
    try key_tex_map.put(allocator, .{ .key = .left_bracket }, 37);
    try key_tex_map.put(allocator, .{ .key = .right_bracket }, 38);
    try key_tex_map.put(allocator, .{ .key = .left_control }, 49);
    try key_tex_map.put(allocator, .{ .key = .right_control }, 49);
    try key_tex_map.put(allocator, .{ .key = .left_alt }, 21);
    try key_tex_map.put(allocator, .{ .key = .right_alt }, 21);
    try key_tex_map.put(allocator, .{ .key = .comma }, 101);
    try key_tex_map.put(allocator, .{ .key = .period }, 102);
    try key_tex_map.put(allocator, .{ .key = .slash }, 103);
    try key_tex_map.put(allocator, .{ .key = .backslash }, 41);
    try key_tex_map.put(allocator, .{ .key = .semicolon }, 30);
    try key_tex_map.put(allocator, .{ .key = .minus }, 45);
    try key_tex_map.put(allocator, .{ .key = .equal }, 42);
    try key_tex_map.put(allocator, .{ .key = .tab }, 79);
    try key_tex_map.put(allocator, .{ .key = .space }, 57);
    try key_tex_map.put(allocator, .{ .key = .backspace }, 35);
    try key_tex_map.put(allocator, .{ .key = .enter }, 54);
    try key_tex_map.put(allocator, .{ .key = .delete }, 51);
    try key_tex_map.put(allocator, .{ .key = .end }, 53);
    try key_tex_map.put(allocator, .{ .key = .print_screen }, 44);
    try key_tex_map.put(allocator, .{ .key = .insert }, 62);
    try key_tex_map.put(allocator, .{ .key = .escape }, 64);
    try key_tex_map.put(allocator, .{ .key = .home }, 87);
    try key_tex_map.put(allocator, .{ .key = .page_up }, 89);
    try key_tex_map.put(allocator, .{ .key = .page_down }, 90);
    try key_tex_map.put(allocator, .{ .key = .caps_lock }, 40);
    try key_tex_map.put(allocator, .{ .key = .kp_add }, 43);
    try key_tex_map.put(allocator, .{ .key = .kp_subtract }, 107);
    try key_tex_map.put(allocator, .{ .key = .kp_multiply }, 33);
    try key_tex_map.put(allocator, .{ .key = .kp_divide }, 106);
    try key_tex_map.put(allocator, .{ .key = .kp_decimal }, 105);
    try key_tex_map.put(allocator, .{ .key = .kp_enter }, 56);
    try key_tex_map.put(allocator, .{ .key = .left_super }, if (builtin.os.tag == .windows) 11 else 48);
    try key_tex_map.put(allocator, .{ .key = .right_super }, if (builtin.os.tag == .windows) 11 else 48);
}

pub fn getKeyTexture(button: Settings.Button) AtlasData {
    const tex_list = ui_atlas_data.get("key_indicators") orelse @panic("Key texture parsing failed, the key_indicators sheet is missing");
    return tex_list[key_tex_map.get(button) orelse 104];
}

pub fn getUiData(comptime name: []const u8, idx: usize) AtlasData {
    return (ui_atlas_data.get(name) orelse @panic("Could not find " ++ name ++ " in the UI atlas"))[idx];
}
