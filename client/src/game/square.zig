const std = @import("std");
const assets = @import("../assets.zig");
const shared = @import("shared");
const game_data = shared.game_data;
const utils = shared.utils;
const ui_systems = @import("../ui/systems.zig");
const map = @import("map.zig");
const main = @import("../main.zig");

pub const Square = struct {
    pub const left_blend_idx = 0;
    pub const top_blend_idx = 1;
    pub const right_blend_idx = 2;
    pub const bottom_blend_idx = 3;

    pub const empty_tile = std.math.maxInt(u16);
    pub const editor_tile = std.math.maxInt(u16) - 1;

    pub const Blend = struct { u: f32, v: f32 };

    data_id: u16 = empty_tile,
    x: f32 = 0.0,
    y: f32 = 0.0,
    atlas_data: assets.AtlasData = assets.AtlasData.fromRaw(0, 0, 0, 0, .base),
    blends: [4]Blend = [_]Blend{.{ .u = -1.0, .v = -1.0 }} ** 4,
    data: *const game_data.GroundData = undefined,
    entity_map_id: u32 = std.math.maxInt(u32),
    sinking: bool = false,
    u_offset: f32 = 0,
    v_offset: f32 = 0,

    pub fn addToMap(self: *Square) void {
        const floor_y: u32 = @intFromFloat(@floor(self.y));
        const floor_x: u32 = @intFromFloat(@floor(self.x));

        self.data = game_data.ground.from_id.getPtr(self.data_id) orelse {
            std.log.err("Could not find data for square with data id {}, returning", .{self.data_id});
            return;
        };

        texParse: {
            if (game_data.ground.from_id.get(self.data_id)) |ground_data| {
                const tex_list = ground_data.textures;
                if (tex_list.len == 0) {
                    std.log.err("Square with data id {} has an empty texture list, parsing failed", .{self.data_id});
                    break :texParse;
                }

                const tex = if (tex_list.len == 1) tex_list[0] else tex_list[utils.rng.next() % tex_list.len];
                if (assets.atlas_data.get(tex.sheet)) |data| {
                    var atlas_data = data[tex.index];
                    atlas_data.removePadding();
                    self.atlas_data = atlas_data;
                } else {
                    std.log.err("Could not find sheet {s} for square with data id {}. Using error texture", .{ tex.sheet, self.data_id });
                    self.atlas_data = assets.error_data;
                }

                if (ui_systems.screen != .editor) {
                    if (assets.dominant_color_data.get(tex.sheet)) |color_data| {
                        main.minimap_lock.lock();
                        defer main.minimap_lock.unlock();

                        const color = color_data[tex.index];
                        const base_data_idx: usize = @intCast(floor_y * map.minimap.num_components * map.minimap.width + floor_x * map.minimap.num_components);
                        @memcpy(map.minimap.data[base_data_idx .. base_data_idx + 4], &@as([4]u8, @bitCast(color)));

                        main.minimap_update.min_x = @min(main.minimap_update.min_x, floor_x);
                        main.minimap_update.max_x = @max(main.minimap_update.max_x, floor_x);
                        main.minimap_update.min_y = @min(main.minimap_update.min_y, floor_y);
                        main.minimap_update.max_y = @max(main.minimap_update.max_y, floor_y);
                    }
                }
            }
        }

        self.updateBlends();
        map.squares[floor_y * map.info.width + floor_x] = self.*;
    }

    fn parseDir(x: f32, y: f32, square: *Square, current_prio: i32, comptime blend_idx: comptime_int) void {
        if (map.getSquarePtr(x, y, true)) |other_sq| {
            const opposite_idx = (blend_idx + 2) % 4;

            if (other_sq.data_id != editor_tile and other_sq.data_id != empty_tile) {
                const other_blend_prio = other_sq.data.blend_prio;
                if (other_blend_prio > current_prio) {
                    square.blends[blend_idx] = .{
                        .u = other_sq.atlas_data.tex_u,
                        .v = other_sq.atlas_data.tex_v,
                    };
                    other_sq.blends[opposite_idx] = .{ .u = -1.0, .v = -1.0 };
                } else if (other_blend_prio < current_prio) {
                    other_sq.blends[opposite_idx] = .{
                        .u = square.atlas_data.tex_u,
                        .v = square.atlas_data.tex_v,
                    };
                    square.blends[blend_idx] = .{ .u = -1.0, .v = -1.0 };
                } else {
                    square.blends[blend_idx] = .{ .u = -1.0, .v = -1.0 };
                    other_sq.blends[opposite_idx] = .{ .u = -1.0, .v = -1.0 };
                }

                return;
            }

            other_sq.blends[opposite_idx] = .{ .u = -1.0, .v = -1.0 };
        }

        square.blends[blend_idx] = .{ .u = -1.0, .v = -1.0 };
    }

    pub fn updateBlends(square: *Square) void {
        if (square.data_id == editor_tile or square.data_id == empty_tile)
            return;

        const current_prio = square.data.blend_prio;
        parseDir(square.x - 1, square.y, square, current_prio, left_blend_idx);
        parseDir(square.x, square.y - 1, square, current_prio, top_blend_idx);
        if (square.x < std.math.maxInt(u32)) parseDir(square.x + 1, square.y, square, current_prio, right_blend_idx);
        if (square.y < std.math.maxInt(u32)) parseDir(square.x, square.y + 1, square, current_prio, bottom_blend_idx);
    }
};
