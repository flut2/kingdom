const std = @import("std");
const shared = @import("shared");
const game_data = shared.game_data;
const network_data = shared.network_data;

const Player = @import("player.zig").Player;
const World = @import("../world.zig").World;

pub const Projectile = struct {
    map_id: u32 = std.math.maxInt(u32),
    index: u8 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    angle: f32 = 0.0,
    damage: i32 = 0.0,
    owner_obj_type: network_data.ObjectType,
    owner_map_id: u32 = std.math.maxInt(u32),
    start_time: i64 = 0,
    hit_list: std.AutoHashMapUnmanaged(u32, void) = .{},
    data: *const game_data.ProjectileData,
    world: *World = undefined,

    pub fn deinit(self: *Projectile) !void {
        self.hit_list.deinit(self.world.allocator);
    }

    pub fn delete(self: *Projectile) !void {
        if (self.world.findRef(Player, self.owner_map_id)) |player| {
            player.projectiles[self.index] = null;
        }

        try self.world.remove(Projectile, self);
    }

    pub fn tick(self: *Projectile, time: i64, _: i64) !void {
        if (time - self.start_time >= @as(i64, @intFromFloat(self.data.duration + 0.25 * std.time.us_per_s))) {
            try self.delete();
            return;
        }
    }
};
