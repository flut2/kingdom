const std = @import("std");
const element = @import("../ui/element.zig");
const ui_systems = @import("../ui/systems.zig");
const shared = @import("shared");
const utils = shared.utils;
const game_data = shared.game_data;
const assets = @import("../assets.zig");
const particles = @import("particles.zig");
const map = @import("map.zig");
const main = @import("../main.zig");
const camera = @import("../camera.zig");
const base = @import("object_base.zig");

pub const Entity = struct {
    map_id: u32 = std.math.maxInt(u32),
    data_id: u16 = std.math.maxInt(u16),
    dead: bool = false,
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    screen_x: f32 = 0.0,
    screen_y: f32 = 0.0,
    alpha: f32 = 1.0,
    name: ?[]const u8 = null,
    name_text_data: ?element.TextData = null,
    size_mult: f32 = 0,
    max_hp: i32 = 0,
    hp: i32 = 0,
    defense: i16 = 0,
    condition: utils.Condition = .{},
    atlas_data: assets.AtlasData = assets.AtlasData.fromRaw(0, 0, 0, 0, .base),
    top_atlas_data: assets.AtlasData = assets.AtlasData.fromRaw(0, 0, 0, 0, .base),
    data: *const game_data.EntityData = undefined,
    colors: []u32 = &.{},
    anim_idx: u8 = 0,
    next_anim: i64 = -1,
    disposed: bool = false,

    pub fn addToMap(self: *Entity, allocator: std.mem.Allocator) void {
        self.data = game_data.entity.from_id.getPtr(self.data_id) orelse {
            std.log.err("Could not find data for entity with data id {}, returning", .{self.data_id});
            return;
        };
        
        texParse: {
            if (self.data.textures.len == 0) {
                std.log.err("Entity with data id {} has an empty texture list, parsing failed", .{self.data_id});
                break :texParse;
            }

            const tex = self.data.textures[utils.rng.next() % self.data.textures.len];
            if (ui_systems.screen != .editor and self.data.static and self.data.occupy_square) {
                if (assets.dominant_color_data.get(tex.sheet)) |color_data| {
                    main.minimap_lock.lock();
                    defer main.minimap_lock.unlock();

                    const floor_y: u32 = @intFromFloat(@floor(self.y));
                    const floor_x: u32 = @intFromFloat(@floor(self.x));

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

        topTexParse: {
            if (!self.data.is_wall)
                break :topTexParse;

            if (self.data.top_textures) |top_tex_list| {
                if (top_tex_list.len == 0) {
                    std.log.err("Entity with data id {} has an empty top texture list, parsing failed", .{self.data_id});
                    break :topTexParse;
                }

                const top_tex = top_tex_list[@as(usize, @intCast(self.map_id)) % top_tex_list.len];
                if (assets.atlas_data.get(top_tex.sheet)) |data| {
                    var top_data = data[top_tex.index];
                    top_data.removePadding();
                    self.top_atlas_data = top_data;
                } else {
                    std.log.err("Could not find top sheet {s} for entity with data id {}. Using error texture", .{ top_tex.sheet, self.data_id });
                    self.top_atlas_data = assets.error_data;
                }
            }
        }

        collision: {
            if (self.x >= 0 and self.y >= 0) {
                const square = map.getSquarePtr(self.x, self.y, true) orelse break :collision;
                if (self.data.is_wall) {
                    self.x = @floor(self.x) + 0.5;
                    self.y = @floor(self.y) + 0.5;

                    square.entity_map_id = self.map_id;
                    square.updateBlends();
                } else if (self.data.occupy_square or self.data.full_occupy) square.entity_map_id = self.map_id;
            }
        }

        base.addToMap(self, Entity, allocator);
    }

    pub fn deinit(self: *Entity, allocator: std.mem.Allocator) void {
        base.deinit(self, Entity, allocator);

        if (self.data.is_wall or self.data.occupy_square or self.data.full_occupy) {
            if (map.getSquarePtr(self.x, self.y, true)) |square| {
                if (square.entity_map_id == self.map_id) square.entity_map_id = std.math.maxInt(u32);
            }
        }
    }

    pub fn update(self: *Entity, time: i64) void {
        base.update(self, Entity, time);
    }
};
