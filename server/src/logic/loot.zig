const std = @import("std");
const shared = @import("shared");
const utils = shared.utils;
const game_data = shared.game_data;

const Portal = @import("../map/portal.zig").Portal;
const Enemy = @import("../map/enemy.zig").Enemy;

pub fn dropPortal(host: *Enemy, portal_name: []const u8, chance: f32) void {
    if (utils.rng.random().float(f32) <= chance) {
        const portal_data = game_data.portal.from_name.get(portal_name) orelse {
            std.log.err("Portal not found for name \"{s}\"", .{portal_name});
            return;
        };
        _ = host.world.add(Portal, .{ .x = host.x, .y = host.y, .data_id = portal_data.id }) catch return;
    }
}
