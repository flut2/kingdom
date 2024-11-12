const std = @import("std");
const assets = @import("../assets.zig");
const game_data = @import("shared").game_data;
const main = @import("../main.zig");
const map = @import("map.zig");
const utils = @import("shared").utils;
const network = @import("../network.zig");
const particles = @import("particles.zig");

const Player = @import("player.zig").Player;
const Entity = @import("entity.zig").Entity;
const Enemy = @import("enemy.zig").Enemy;
const Square = @import("square.zig").Square;

pub const Projectile = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    screen_x: f32 = 0.0,
    screen_y: f32 = 0.0,
    size: f32 = 1.0,
    atlas_data: assets.AtlasData = assets.AtlasData.fromRaw(0, 0, 0, 0, .base),
    start_time: i64 = 0,
    angle: f32 = 0.0,
    visual_angle: f32 = 0.0,
    total_angle_change: f32 = 0.0,
    zero_vel_dist: f32 = -1.0,
    start_x: f32 = 0.0,
    start_y: f32 = 0.0,
    last_deflect: f32 = 0.0,
    index: u8 = 0,
    owner_map_id: u32 = std.math.maxInt(u32),
    damage_players: bool = false,
    damage: i32 = 0,
    data: game_data.ProjectileData,
    colors: []u32 = &.{},
    hit_list: std.AutoHashMapUnmanaged(u32, void) = .{},
    heat_seek_fired: bool = false,
    last_hit_check: i64 = 0,
    disposed: bool = false,

    pub fn addToMap(self: *Projectile, allocator: std.mem.Allocator) void {
        self.start_time = main.current_time;

        const tex_list = self.data.textures;
        const tex = tex_list[utils.rng.next() % tex_list.len];
        if (assets.atlas_data.get(tex.sheet)) |data| {
            self.atlas_data = data[tex.index];
        } else {
            std.log.err("Could not find sheet {s} for projectile. Using error texture", .{tex.sheet});
            self.atlas_data = assets.error_data;
        }

        self.colors = assets.atlas_to_color_data.get(@bitCast(self.atlas_data)) orelse blk: {
            std.log.err("Could not parse color data for projectile. Setting it to empty", .{});
            break :blk &.{};
        };

        var lock = map.addLockForType(Projectile);
        lock.lock();
        defer lock.unlock();
        map.addListForType(Projectile).append(allocator, self.*) catch @panic("Adding projectile failed");
    }

    pub fn deinit(self: *Projectile, allocator: std.mem.Allocator) void {
        if (self.disposed)
            return;

        self.disposed = true;
        self.hit_list.deinit(allocator);
    }

    fn findTargetPlayer(x: f32, y: f32, radius: f32) ?*Player {
        var min_dist = radius * radius;
        var target: ?*Player = null;

        var lock = map.useLockForType(Player);
        lock.lock();
        defer lock.unlock();
        for (map.listForType(Player).items) |*p| {
            const dist_sqr = utils.distSqr(p.x, p.y, x, y);
            if (dist_sqr < min_dist) {
                min_dist = dist_sqr;
                target = p;
            }
        }

        return target;
    }

    fn findTargetEnemy(x: f32, y: f32, radius: f32) ?*Enemy {
        var min_dist = radius * radius;
        var target: ?*Enemy = null;

        var lock = map.useLockForType(Enemy);
        lock.lock();
        defer lock.unlock();
        for (map.listForType(Enemy).items) |*e| {
            if (e.data.health <= 0) continue;

            const dist_sqr = utils.distSqr(e.x, e.y, x, y);
            if (dist_sqr < min_dist) {
                min_dist = dist_sqr;
                target = e;
            }
        }

        return target;
    }

    fn updatePosition(self: *Projectile, elapsed: f32, dt: f32) void {
        if (self.data.heat_seek_radius > 0 and elapsed >= self.data.heat_seek_delay and !self.heat_seek_fired) {
            var target_x: f32 = -1.0;
            var target_y: f32 = -1.0;

            if (self.damage_players) {
                if (findTargetPlayer(self.x, self.y, self.data.heat_seek_radius * self.data.heat_seek_radius)) |player| {
                    target_x = player.x;
                    target_y = player.y;
                }
            } else {
                if (findTargetEnemy(self.x, self.y, self.data.heat_seek_radius * self.data.heat_seek_radius)) |enemy| {
                    target_x = enemy.x;
                    target_y = enemy.y;
                }
            }

            if (target_x > 0 and target_y > 0) {
                self.angle = @mod(std.math.atan2(target_y - self.y, target_x - self.x), std.math.tau);
                self.heat_seek_fired = true;
            }
        }

        var angle_change: f32 = 0.0;
        if (self.data.angle_change != 0 and elapsed < self.data.angle_change_end and elapsed >= self.data.angle_change_delay) {
            angle_change += dt * std.math.degreesToRadians(self.data.angle_change);
        }

        if (self.data.angle_change_accel != 0 and elapsed >= self.data.angle_change_accel_delay) {
            const time_in_accel = elapsed - self.data.angle_change_accel_delay;
            angle_change += dt * std.math.degreesToRadians(self.data.angle_change_accel) * time_in_accel;
        }

        if (angle_change != 0.0) {
            if (self.data.angle_change_clamp != 0) {
                const clamp_dt = self.data.angle_change_clamp - self.total_angle_change;
                const clamped_change = @min(angle_change, clamp_dt);
                self.total_angle_change += clamped_change;
                self.angle += clamped_change;
            } else {
                self.angle += angle_change;
            }
        }

        var dist: f32 = 0.0;
        const uses_zero_vel = self.data.zero_velocity_delay > 0;
        if (!uses_zero_vel or self.data.zero_velocity_delay > elapsed) {
            if (self.data.accel == 0.0 or elapsed < self.data.accel_delay) {
                dist = dt * self.data.speed * 10.0;
            } else {
                const time_in_accel = elapsed - self.data.accel_delay;
                const accel_dist = dt * (self.data.speed * 10.0 + self.data.accel * 10.0 * time_in_accel);
                if (self.data.speed_clamp == 0.0) {
                    dist = accel_dist;
                } else {
                    const clamp_dist = dt * self.data.speed_clamp * 10.0;
                    dist = if (self.data.accel > 0) @min(accel_dist, clamp_dist) else @max(accel_dist, clamp_dist);
                }
            }
        } else {
            if (self.zero_vel_dist == -1.0) {
                self.zero_vel_dist = utils.dist(self.start_x, self.start_y, self.x, self.y);
            }

            self.x = self.start_x + self.zero_vel_dist * @cos(self.angle);
            self.y = self.start_y + self.zero_vel_dist * @sin(self.angle);
            return;
        }

        if (self.data.boomerang and elapsed > self.data.duration / 2.0)
            dist = -dist;

        self.x += dist * @cos(self.angle);
        self.y += dist * @sin(self.angle);
        if (self.data.amplitude != 0) {
            const phase: f32 = if (self.index % 2 == 0) 0.0 else std.math.pi;
            const time_ratio = elapsed / self.data.duration;
            const deflection_target = self.data.amplitude * @sin(phase + time_ratio * self.data.frequency * std.math.tau);
            self.x += (deflection_target - self.last_deflect) * @cos(self.angle + std.math.pi / 2.0);
            self.y += (deflection_target - self.last_deflect) * @sin(self.angle + std.math.pi / 2.0);
            self.last_deflect = deflection_target;
        }
    }

    pub fn update(self: *Projectile, time: i64, dt: f32, allocator: std.mem.Allocator) bool {
        const elapsed_sec = @as(f32, @floatFromInt(time - self.start_time)) / std.time.us_per_s;
        const dt_sec = dt / std.time.us_per_s;
        if (elapsed_sec >= self.data.duration)
            return false;

        const last_x = self.x;
        const last_y = self.y;

        self.updatePosition(elapsed_sec, dt_sec);
        if (self.x < 0 or self.y < 0 or self.x >= @as(f32, @floatFromInt(map.info.width)) or self.y >= @as(f32, @floatFromInt(map.info.height))) {
            return false;
        }

        if (last_x == 0 and last_y == 0) {
            self.visual_angle = self.angle;
        } else {
            const y_dt: f32 = self.y - last_y;
            const x_dt: f32 = self.x - last_x;
            self.visual_angle = std.math.atan2(y_dt, x_dt);
        }

        if (time - self.last_hit_check < 16 * std.time.us_per_ms)
            return true;

        self.last_hit_check = time;

        const square = map.getSquare(self.x, self.y, false).?;
        {
            var lock = map.useLockForType(Entity);
            lock.lock();
            defer lock.unlock();
            if (map.findObjectConst(Entity, square.entity_map_id)) |e| {
                if (e.data.occupy_square) {
                    particles.HitEffect.addToMap(.{
                        .x = self.x,
                        .y = self.y,
                        .colors = self.colors,
                        .angle = self.angle,
                        .speed = self.data.speed,
                        .size = 1.0,
                        .amount = 3,
                    });
                    return false;
                }
            } else if (square.data_id == Square.editor_tile or square.data_id == Square.empty_tile)
                return false;
        }

        if (self.damage_players) {
            if (findTargetPlayer(self.x, self.y, 0.57)) |player| {
                if (self.hit_list.contains(player.map_id))
                    return true;

                if (player.condition.invulnerable) {
                    assets.playSfx(player.data.hit_sound);
                    return false;
                }

                if (map.local_player_id == player.map_id) {
                    map.takeDamage(
                        player,
                        game_data.damage(self.damage, player.defense, self.data.ignore_def, player.condition),
                        utils.Condition.fromCondSlice(self.data.conditions),
                        self.colors,
                        self.data.ignore_def,
                        allocator,
                    );
                    main.server.sendPacket(.{ .player_hit = .{ .proj_index = self.index, .enemy_map_id = self.owner_map_id } });
                } else if (!self.data.piercing) {
                    particles.HitEffect.addToMap(.{
                        .x = self.x,
                        .y = self.y,
                        .colors = self.colors,
                        .angle = self.angle,
                        .speed = self.data.speed,
                        .size = 1.0,
                        .amount = 3,
                    });
                }

                if (self.data.piercing) {
                    self.hit_list.put(allocator, player.map_id, {}) catch |e| {
                        std.log.err("Failed to add player with data id {} to the hit list: {}", .{ player.data_id, e });
                    };
                } else {
                    return false;
                }
            }
        } else {
            if (findTargetEnemy(self.x, self.y, 0.57)) |enemy| {
                if (self.hit_list.contains(enemy.map_id))
                    return true;

                if (enemy.condition.invulnerable) {
                    assets.playSfx(enemy.data.hit_sound);
                    return false;
                }

                const damage = game_data.damage(self.damage, enemy.defense, self.data.ignore_def, enemy.condition);
                map.takeDamage(
                    enemy,
                    damage,
                    utils.Condition.fromCondSlice(self.data.conditions),
                    self.colors,
                    self.data.ignore_def,
                    allocator,
                );

                main.server.sendPacket(.{ .enemy_hit = .{
                    .time = time,
                    .proj_index = self.index,
                    .enemy_map_id = enemy.map_id,
                    .killed = enemy.hp <= damage,
                } });

                if (self.data.piercing) {
                    self.hit_list.put(allocator, enemy.map_id, {}) catch |e| {
                        std.log.err("Failed to add enemy with data id {} to the hit list: {}", .{ enemy.data_id, e });
                    };
                } else return false;
            }
        }

        return true;
    }
};
