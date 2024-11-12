const std = @import("std");
const shared = @import("shared");
const network_data = shared.network_data;
const game_data = shared.game_data;
const utils = shared.utils;
const stat_util = @import("stat_util.zig");
const behavior_logic = @import("../logic/logic.zig");
const behavior = @import("../logic/behavior.zig");
const main = @import("../main.zig");

const World = @import("../world.zig").World;
const Player = @import("player.zig").Player;

pub const Enemy = struct {
    map_id: u32 = std.math.maxInt(u32),
    data_id: u16 = std.math.maxInt(u16),
    x: f32 = 0.0,
    y: f32 = 0.0,
    max_hp: i32 = 100,
    hp: i32 = 100,
    size_mult: f32 = 1.0,
    name: ?[]const u8 = null,
    next_proj_index: u8 = 0,
    projectiles: [256]?u32 = [_]?u32{null} ** 256,
    stats_writer: utils.PacketWriter = .{},
    condition: utils.Condition = .{},
    damages_dealt: std.AutoArrayHashMapUnmanaged(u32, i32) = .{},
    data: *const game_data.EnemyData = undefined,
    behavior: ?behavior.EnemyBehavior = null,
    world: *World = undefined,
    spawned: bool = false,
    storages: behavior_logic.EnemyStorages = .{},

    pub fn init(self: *Enemy, allocator: std.mem.Allocator) !void {
        self.behavior = behavior.enemy_behavior_map.get(self.data_id);
        if (self.behavior) |behav| {
            if (behav.spawn) |spawn| try spawn(self);
            if (behav.entry) |entry| try entry(self);
        }

        self.stats_writer.list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 32);

        self.data = game_data.enemy.from_id.getPtr(self.data_id) orelse {
            std.log.err("Could not find data for enemy with data id {}", .{self.data_id});
            return;
        };
        self.hp = @intCast(self.data.health);
        self.max_hp = @intCast(self.data.health);
    }

    pub fn deinit(self: *Enemy) !void {
        const allocator = self.world.allocator;

        var iter = self.damages_dealt.iterator();
        while (iter.next()) |entry| {
            if (self.world.findRef(Player, entry.key_ptr.*)) |player| {
                player.addExp(self.data.exp_reward);
            }
        }

        if (self.behavior) |behav| {
            if (behav.death) |death| try death(self);
            if (behav.exit) |exit| try exit(self);
        }

        self.storages.deinit();
        self.damages_dealt.deinit(allocator);
        self.stats_writer.list.deinit(allocator);
    }

    pub fn move(self: *Enemy, x: f32, y: f32) void {
        if (x < 0.0 or y < 0.0)
            return;

        const ux: u32 = @intFromFloat(x);
        const uy: u32 = @intFromFloat(y);
        if (ux >= self.world.w or uy >= self.world.h)
            return;

        const tile = self.world.tiles[uy * self.world.w + ux];
        if (tile.data_id != std.math.maxInt(u16) and !tile.data.no_walk and !tile.occupied) {
            self.x = x;
            self.y = y;
        }
    }

    pub fn delete(self: *Enemy) !void {
        try self.world.remove(Enemy, self);
    }

    pub fn tick(self: *Enemy, time: i64, dt: i64) !void {
        if (self.data.health > 0 and self.hp <= 0) try self.delete();
        if (self.behavior) |behav| if (behav.tick) |behav_tick| try behav_tick(self, time, dt);
    }

    pub fn damage(self: *Enemy, owner_id: u32, amount: i32, ignore_def: bool) void {
        if (self.data.health == 0)
            return;

        const dmg = game_data.damage(amount, self.data.defense, ignore_def, self.condition);
        self.hp -= dmg;
        if (self.hp <= 0) {
            self.delete() catch return;
            return;
        }

        const res = self.damages_dealt.getOrPut(self.world.allocator, owner_id) catch return;
        if (res.found_existing) res.value_ptr.* += dmg else res.value_ptr.* = dmg;
    }

    pub fn exportStats(self: *Enemy, cache: *[@typeInfo(network_data.EnemyStat).@"union".fields.len]?network_data.EnemyStat) ![]u8 {
        const writer = &self.stats_writer;
        writer.list.clearRetainingCapacity();

        const allocator = self.world.allocator;
        stat_util.write(network_data.EnemyStat, allocator, writer, cache, .{ .x = self.x });
        stat_util.write(network_data.EnemyStat, allocator, writer, cache, .{ .y = self.y });
        stat_util.write(network_data.EnemyStat, allocator, writer, cache, .{ .size_mult = self.size_mult });
        if (self.name) |name| stat_util.write(network_data.EnemyStat, allocator, writer, cache, .{ .name = name });
        stat_util.write(network_data.EnemyStat, allocator, writer, cache, .{ .hp = self.hp });
        stat_util.write(network_data.EnemyStat, allocator, writer, cache, .{ .max_hp = self.max_hp });
        stat_util.write(network_data.EnemyStat, allocator, writer, cache, .{ .condition = self.condition });

        return writer.list.items;
    }

    // Move toward or onto, but not through. Don't move if too close
    // Does not prevent moving closer than range if crossing it
    pub fn moveToward(host: *Enemy, x: f32, y: f32, range_sqr: f32, speed: f32, dt: i64) void {
        const dx = x - host.x;
        const dy = y - host.y;
        const mag_sqr = dx * dx + dy * dy;
        if (mag_sqr <= range_sqr) return; // Close enough

        const fdt: f32 = @floatFromInt(dt);
        const dist = speed * (fdt / std.time.us_per_s); // Distance to move this tick

        if (mag_sqr > dist * dist) {
            // Set length of dx,dy to dist
            const c = dist / @sqrt(mag_sqr);
            host.move(host.x + dx * c, host.y + dy * c);
        } else {
            // Don't overshoot
            host.move(x, y);
        }
    }
};
