const std = @import("std");

const Metadata = @import("../behavior.zig").BehaviorMetadata;
const Player = @import("../../map/player.zig").Player;
const Entity = @import("../../map/entity.zig").Entity;

pub const HealthShrine = struct {
    pub const data: Metadata = .{
        .type = .entity,
        .name = "Health Shrine",
    };

    pub fn exit(host: *Entity) !void {
        const last_healed: *i64 = @ptrCast(@alignCast(host.behavior_data.?));
        host.world.allocator.destroy(last_healed);
    }

    pub fn tick(host: *Entity, time: i64, _: i64) !void {
        if (host.behavior_data == null)
            host.behavior_data = try host.world.allocator.create(i64);

        const last_healed: *i64 = @ptrCast(@alignCast(host.behavior_data.?));
        if (time - last_healed.* >= 1.5 * std.time.us_per_s) {
            defer last_healed.* = time;

            const player = host.world.getNearestPlayerWithin(host.x, host.y, 4.0 * 4.0) orelse return;
            const pre_hp = player.hp;
            player.hp = @min(player.stats[Player.health_stat] + player.stat_boosts[Player.health_stat], player.hp + 75);
            const hp_delta = player.hp - pre_hp;
            if (hp_delta <= 0)
                return;

            var buf: [64]u8 = undefined;
            player.client.queuePacket(.{ .notification = .{
                .obj_type = .player,
                .map_id = player.map_id,
                .message = std.fmt.bufPrint(&buf, "+{}", .{hp_delta}) catch return,
                .color = 0x00FF00,
            } });

            player.client.queuePacket(.{ .show_effect = .{
                .eff_type = .trail,
                .obj_type = .entity,
                .map_id = host.map_id,
                .x1 = player.x,
                .y1 = player.y,
                .x2 = 0,
                .y2 = 0,
                .color = 0x00FF00,
            } });
        }
    }
};

pub const MagicShrine = struct {
    pub const data: Metadata = .{
        .type = .entity,
        .name = "Magic Shrine",
    };

    pub fn exit(host: *Entity) !void {
        const last_healed: *i64 = @ptrCast(@alignCast(host.behavior_data.?));
        host.world.allocator.destroy(last_healed);
    }

    pub fn tick(host: *Entity, time: i64, _: i64) !void {
        if (host.behavior_data == null)
            host.behavior_data = try host.world.allocator.create(i64);

        const last_healed: *i64 = @ptrCast(@alignCast(host.behavior_data.?));
        if (time - last_healed.* >= 1.5 * std.time.us_per_s) {
            defer last_healed.* = time;

            const player = host.world.getNearestPlayerWithin(host.x, host.y, 4.0 * 4.0) orelse return;
            const pre_mp = player.mp;
            player.mp = @min(player.stats[Player.mana_stat] + player.stat_boosts[Player.mana_stat], player.mp + 40);
            const mp_delta = player.mp - pre_mp;
            if (mp_delta <= 0)
                return;

            var buf: [64]u8 = undefined;
            player.client.queuePacket(.{ .notification = .{
                .obj_type = .player,
                .map_id = player.map_id,
                .message = std.fmt.bufPrint(&buf, "+{}", .{mp_delta}) catch return,
                .color = 0x0000FF,
            } });

            player.client.queuePacket(.{ .show_effect = .{
                .eff_type = .trail,
                .obj_type = .entity,
                .map_id = host.map_id,
                .x1 = player.x,
                .y1 = player.y,
                .x2 = 0,
                .y2 = 0,
                .color = 0x0000FF,
            } });
        }
    }
};
