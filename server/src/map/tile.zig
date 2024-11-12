const std = @import("std");
const game_data = @import("shared").game_data;

pub const Tile = struct {
    data_id: u16 = std.math.maxInt(u16),
    x: u16 = 0,
    y: u16 = 0,
    update_count: u16 = 0,
    occupied: bool = false,
    data: *const game_data.GroundData = undefined,
};
