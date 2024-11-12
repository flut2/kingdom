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

pub const Enemy = struct {
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
    size_mult: f32 = 1.0,
    max_hp: i32 = 0,
    hp: i32 = 0,
    defense: i16 = 0,
    condition: utils.Condition = .{},
    anim_data: assets.AnimEnemyData = undefined,
    atlas_data: assets.AtlasData = undefined,
    move_angle: f32 = std.math.nan(f32),
    move_step: f32 = 0.0,
    target_x: f32 = 0.0,
    target_y: f32 = 0.0,
    attack_start: i64 = 0,
    attack_angle: f32 = 0.0,
    data: *const game_data.EnemyData = undefined,
    colors: []u32 = &.{},
    render_x_offset: f32 = 0.0,
    anim_idx: u8 = 0,
    facing: f32 = std.math.nan(f32),
    next_anim: i64 = -1,
    disposed: bool = false,

    pub fn addToMap(self: *Enemy, allocator: std.mem.Allocator) void {
        base.addToMap(self, Enemy, allocator);
    }

    pub fn deinit(self: *Enemy, allocator: std.mem.Allocator) void {
        base.deinit(self, Enemy, allocator);
    }

    pub fn update(self: *Enemy, time: i64, dt: f32) void {
        const screen_pos = camera.rotateAroundCamera(self.x, self.y);
        const size = camera.size_mult * camera.scale * self.size_mult;

        const attack_period = std.time.us_per_s / 3;
        const move_period = std.time.us_per_s / 2;

        var float_period: f32 = 0.0;
        var action: assets.Action = .stand;
        if (time < self.attack_start + attack_period) {
            const time_dt: f32 = @floatFromInt(time - self.attack_start);
            float_period = @mod(time_dt, attack_period) / attack_period;
            self.facing = self.attack_angle;
            action = .attack;
        } else if (!std.math.isNan(self.move_angle)) {
            const float_time: f32 = @floatFromInt(time);
            float_period = @mod(float_time, move_period) / move_period;
            self.facing = self.move_angle;
            action = .walk;
        } else {
            float_period = 0;
            action = .stand;
        }

        const angle = if (std.math.isNan(self.facing))
            0.0
        else
            utils.halfBound(self.facing) / (std.math.pi / 4.0);

        const dir: assets.Direction = switch (@as(u8, @intFromFloat(@round(angle + 4))) % 8) {
            2...5 => .right,
            else => .left,
        };

        const anim_idx: u8 = @intFromFloat(@max(0, @min(0.99999, float_period)) * 2.0);
        const dir_idx: u8 = @intFromEnum(dir);
        const stand_data = self.anim_data.walk_anims[dir_idx * assets.AnimEnemyData.walk_actions];

        self.atlas_data = switch (action) {
            .walk => self.anim_data.walk_anims[dir_idx * assets.AnimEnemyData.walk_actions + 1 + anim_idx],
            .attack => self.anim_data.attack_anims[dir_idx * assets.AnimEnemyData.attack_actions + anim_idx],
            .stand => stand_data,
        };

        const w = self.atlas_data.width() * size;
        const stand_w = stand_data.width() * size;
        self.render_x_offset = (if (dir == .left) stand_w - w else w - stand_w) / 2.0;

        const h = self.atlas_data.height() * size;
        self.screen_y = screen_pos.y + self.z * -camera.px_per_tile - h - 10;
        self.screen_x = screen_pos.x;

        if (!std.math.isNan(self.move_angle) and self.move_step > 0.0) {
            const cos_angle = @cos(self.move_angle);
            const sin_angle = @sin(self.move_angle);
            const next_x = self.x + dt * self.move_step * cos_angle;
            const next_y = self.y + dt * self.move_step * sin_angle;
            self.x = if (cos_angle > 0.0) @min(self.target_x, next_x) else @max(self.target_x, next_x);
            self.y = if (sin_angle > 0.0) @min(self.target_y, next_y) else @max(self.target_y, next_y);
        }
    }
};
