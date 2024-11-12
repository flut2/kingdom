const std = @import("std");
const shared = @import("shared");
const game_data = shared.game_data;
const network_data = shared.network_data;
const utils = shared.utils;
const stat_util = @import("stat_util.zig");

const World = @import("../world.zig").World;

pub const Container = struct {
    const inv_default = [_]u16{std.math.maxInt(u16)} ** 8;

    map_id: u32 = std.math.maxInt(u32),
    data_id: u16 = std.math.maxInt(u16),
    x: f32 = 0.0,
    y: f32 = 0.0,
    name: ?[]const u8 = null,
    size_mult: f32 = 1.0,
    stats_writer: utils.PacketWriter = .{},
    inventory: [8]u16 = inv_default,
    disappear_time: i64 = 0,
    data: *const game_data.ContainerData = undefined,
    world: *World = undefined,
    spawned: bool = false,

    pub fn init(self: *Container, allocator: std.mem.Allocator) !void {
        self.stats_writer.list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, 32);
        self.data = game_data.container.from_id.getPtr(self.data_id) orelse {
            std.log.err("Could not find data for container with data id {}", .{self.data_id});
            return;
        };
        self.disappear_time = @import("../main.zig").current_time + 30 * std.time.us_per_s;
    }

    pub fn deinit(self: *Container) !void {
        self.stats_writer.list.deinit(self.world.allocator);
    }

    pub fn tick(self: *Container, time: i64, _: i64) !void {
        if (time >= self.disappear_time or std.mem.eql(u16, &self.inventory, &inv_default)) {
            try self.world.remove(Container, self);
            return;
        }
    }

    pub fn exportStats(self: *Container, cache: *[@typeInfo(network_data.ContainerStat).@"union".fields.len]?network_data.ContainerStat) ![]u8 {
        const writer = &self.stats_writer;
        writer.list.clearRetainingCapacity();

        const allocator = self.world.allocator;
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .x = self.x });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .y = self.y });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .size_mult = self.size_mult });
        if (self.name) |name| stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .name = name });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .inv_0 = self.inventory[0] });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .inv_1 = self.inventory[1] });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .inv_2 = self.inventory[2] });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .inv_3 = self.inventory[3] });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .inv_4 = self.inventory[4] });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .inv_5 = self.inventory[5] });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .inv_6 = self.inventory[6] });
        stat_util.write(network_data.ContainerStat, allocator, writer, cache, .{ .inv_7 = self.inventory[7] });

        return writer.list.items;
    }
};
