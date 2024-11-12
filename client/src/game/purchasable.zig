const std = @import("std");
const element = @import("../ui/element.zig");
const shared = @import("shared");
const utils = shared.utils;
const game_data = shared.game_data;
const assets = @import("../assets.zig");
const particles = @import("particles.zig");
const map = @import("map.zig");
const main = @import("../main.zig");
const camera = @import("../camera.zig");
const base = @import("object_base.zig");

pub const Purchasable = struct {
    map_id: u32 = std.math.maxInt(u32),
    data_id: u16 = std.math.maxInt(u16),
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    screen_x: f32 = 0.0,
    screen_y: f32 = 0.0,
    alpha: f32 = 1.0,
    name: ?[]const u8 = null,
    name_text_data: ?element.TextData = null,
    size_mult: f32 = 0,
    atlas_data: assets.AtlasData = assets.AtlasData.fromRaw(0, 0, 0, 0, .base),
    data: *const game_data.PurchasableData = undefined,
    anim_idx: u8 = 0,
    next_anim: i64 = -1,
    disposed: bool = false,

    pub fn addToMap(self: *Purchasable, allocator: std.mem.Allocator) void {
        base.addToMap(self, Purchasable, allocator);
    }

    pub fn deinit(self: *Purchasable, allocator: std.mem.Allocator) void {
        base.deinit(self, Purchasable, allocator);
    }

    pub fn update(self: *Purchasable, time: i64) void {
        base.update(self, Purchasable, time);
    }
};
