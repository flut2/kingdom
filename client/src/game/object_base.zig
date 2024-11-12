const std = @import("std");
const shared = @import("shared");
const game_data = shared.game_data;
const network_data = shared.network_data;
const utils = shared.utils;
const assets = @import("../assets.zig");
const map = @import("map.zig");
const main = @import("../main.zig");
const camera = @import("../camera.zig");
const ui_systems = @import("../ui/systems.zig");

const Player = @import("player.zig").Player;
const Entity = @import("entity.zig").Entity;
const Enemy = @import("enemy.zig").Enemy;
const Portal = @import("portal.zig").Portal;
const Container = @import("container.zig").Container;

pub fn addToMap(self: anytype, comptime ObjType: type, allocator: std.mem.Allocator) void {
    const type_name = switch (ObjType) {
        Player => "player",
        Entity => "entity",
        Enemy => "enemy",
        Portal => "portal",
        Container => "container",
        else => @compileError("Invalid type"),
    };

    self.data = @field(game_data, type_name).from_id.getPtr(self.data_id) orelse {
        std.log.err("Could not find data for {s} with data id {}, returning", .{ type_name, self.data_id });
        return;
    };
    self.size_mult = self.data.size_mult;

    texParse: {
        const T = @TypeOf(self.*);
        if (T == Enemy) {
            const tex = self.data.texture;
            if (assets.anim_enemies.get(tex.sheet)) |anim_data| {
                self.anim_data = anim_data[tex.index];
            } else {
                std.log.err("Could not find anim sheet {s} for {s} with data id {}. Using error texture", .{ tex.sheet, type_name, self.data_id });
                self.anim_data = assets.error_data_enemy;
            }
            self.atlas_data = self.anim_data.walk_anims[0];
        } else {
            if (self.data.textures.len == 0) {
                std.log.err("{s} with data id {} has an empty texture list, parsing failed", .{ type_name, self.data_id });
                break :texParse;
            }

            const tex = self.data.textures[utils.rng.next() % self.data.textures.len];

            if (assets.atlas_data.get(tex.sheet)) |data| {
                self.atlas_data = data[tex.index];
            } else {
                std.log.err("Could not find sheet {s} for {s} with data id {}. Using error texture", .{ tex.sheet, type_name, self.data_id });
                self.atlas_data = assets.error_data;
            }
        }

        if (@hasField(T, "colors")) self.colors = assets.atlas_to_color_data.get(@bitCast(self.atlas_data)) orelse blk: {
            std.log.err("Could not parse color data for {s} with data id {}. Setting it to empty", .{ type_name, self.data_id });
            break :blk &.{};
        };

        if (self.data.draw_on_ground or @hasField(@TypeOf(self.data.*), "is_wall") and self.data.is_wall)
            self.atlas_data.removePadding();
    }

    if (self.name_text_data == null and self.data.show_name) {
        self.name_text_data = .{
            .text = undefined,
            .text_type = .bold,
            .size = 12,
        };
        self.name_text_data.?.setText(if (self.name) |obj_name| obj_name else self.data.name, allocator);
    }

    var lock = map.addLockForType(ObjType);
    lock.lock();
    defer lock.unlock();
    map.addListForType(ObjType).append(allocator, self.*) catch @panic("Adding " ++ type_name ++ " failed");
}

pub fn deinit(self: anytype, comptime ObjType: type, allocator: std.mem.Allocator) void {
    if (self.disposed)
        return;

    const type_name = switch (ObjType) {
        Player => "player",
        Entity => "entity",
        Enemy => "enemy",
        Portal => "portal",
        Container => "container",
        else => @compileError("Invalid type"),
    };

    self.disposed = true;
    ui_systems.removeAttachedUi(comptime std.meta.stringToEnum(network_data.ObjectType, type_name).?, self.map_id);

    if (self.name_text_data) |*data|
        data.deinit(allocator);

    if (self.name) |en_name|
        allocator.free(en_name);
}

pub fn update(self: anytype, comptime ObjType: type, time: i64) void {
    const type_name = switch (ObjType) {
        Player => "player",
        Entity => "entity",
        Enemy => "enemy",
        Portal => "portal",
        Container => "container",
        else => @compileError("Invalid type"),
    };

    const screen_pos = camera.rotateAroundCamera(self.x, self.y);
    const size = camera.size_mult * camera.scale * self.size_mult;

    if (self.data.animation) |animation| {
        updateAnim: {
            if (time >= self.next_anim) {
                const frame_len = animation.frames.len;
                if (frame_len < 2) {
                    std.log.err("The amount of frames ({}) was not enough for {s} with data id {}", .{ frame_len, type_name, self.data_id });
                    break :updateAnim;
                }

                const frame_data = animation.frames[self.anim_idx];
                const tex_data = frame_data.texture;
                if (assets.atlas_data.get(tex_data.sheet)) |tex| {
                    if (tex_data.index >= tex.len) {
                        std.log.err("Incorrect index ({}) given to anim with sheet {s}, {s} with data id: {}", .{ tex_data.index, tex_data.sheet, type_name, self.data_id });
                        break :updateAnim;
                    }
                    self.atlas_data = tex[tex_data.index];
                    if (self.data.draw_on_ground or @hasField(@TypeOf(self.data.*), "is_wall") and self.data.is_wall)
                        self.atlas_data.removePadding();
                    self.anim_idx = @intCast((self.anim_idx + 1) % frame_len);
                    self.next_anim = time + @as(i64, @intFromFloat(frame_data.time * std.time.us_per_s));
                } else {
                    std.log.err("Could not find sheet {s} for anim on {s} with data id {}", .{ tex_data.sheet, type_name, self.data_id });
                    break :updateAnim;
                }
            }
        }
    }

    const h = self.atlas_data.height() * size;
    self.screen_y = screen_pos.y + self.z * -camera.px_per_tile - h - 10;
    self.screen_x = screen_pos.x;
}
