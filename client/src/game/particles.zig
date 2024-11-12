const std = @import("std");
const assets = @import("../assets.zig");
const shared = @import("shared");
const utils = shared.utils;
const network_data = shared.network_data;
const map = @import("map.zig");
const network = @import("../network.zig");

pub var allocator: std.mem.Allocator = undefined;

pub const ThrowParticle = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    color: u32 = 0,
    size: f32 = 1.0,
    alpha_mult: f32 = 1.0,

    initial_size: f32,
    lifetime: f32,
    time_left: f32,
    dx: f32,
    dy: f32,

    last_update: i64 = 0,

    pub fn addToMap(part: ThrowParticle) void {
        var lock = map.addLockForType(Particle);
        lock.lock();
        defer lock.unlock();
        map.addListForType(Particle).append(allocator, .{ .throw = part }) catch @panic("Adding ThrowParticle failed");
    }

    pub fn update(self: *ThrowParticle, time: i64, dt: f32) bool {
        self.time_left -= dt;
        if (self.time_left <= 0)
            return false;

        self.z = @sin(self.time_left / self.lifetime * std.math.pi) * 2;
        self.x += self.dx * dt / std.time.us_per_ms;
        self.y += self.dy * dt / std.time.us_per_ms;

        if (time - self.last_update >= 16 * std.time.us_per_ms) {
            const duration: f32 = 0.4 * std.time.us_per_s;
            var particle: SparkParticle = .{
                .size = @floor(self.z + 1),
                .initial_size = @floor(self.z + 1),
                .color = self.color,
                .lifetime = duration,
                .time_left = duration,
                .dx = utils.plusMinus(1),
                .dy = utils.plusMinus(1),
                .x = self.x,
                .y = self.y,
                .z = self.z,
            };
            particle.addToMap();

            self.last_update = time;
        }
        return true;
    }
};

pub const SparkerParticle = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    color: u32 = 0,
    size: f32 = 1.0,
    alpha_mult: f32 = 1.0,

    initial_size: f32,
    lifetime: f32,
    time_left: f32,
    dx: f32,
    dy: f32,

    last_update: i64 = 0,

    pub fn addToMap(part: SparkerParticle) void {
        var lock = map.addLockForType(Particle);
        lock.lock();
        defer lock.unlock();
        map.addListForType(Particle).append(allocator, .{ .sparker = part }) catch @panic("Adding SparkerParticle failed");
    }

    pub fn update(self: *SparkerParticle, time: i64, dt: f32) bool {
        self.time_left -= dt;
        if (self.time_left <= 0)
            return false;

        self.x += self.dx * dt;
        self.y += self.dy * dt;

        if (time - self.last_update >= 16 * std.time.us_per_ms) {
            const duration: f32 = 0.6 * std.time.us_per_s;
            var particle: SparkParticle = .{
                .size = 1.0,
                .initial_size = 1.0,
                .color = self.color,
                .lifetime = duration,
                .time_left = duration,
                .dx = utils.plusMinus(1),
                .dy = utils.plusMinus(1),
                .x = self.x,
                .y = self.y,
                .z = self.z,
            };
            particle.addToMap();

            self.last_update = time;
        }

        return true;
    }
};

pub const SparkParticle = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    color: u32 = 0,
    size: f32 = 1.0,
    alpha_mult: f32 = 1.0,

    initial_size: f32,
    lifetime: f32,
    time_left: f32,
    dx: f32,
    dy: f32,

    pub fn addToMap(part: SparkParticle) void {
        var lock = map.addLockForType(Particle);
        lock.lock();
        defer lock.unlock();
        map.addListForType(Particle).append(allocator, .{ .spark = part }) catch @panic("Adding SparkParticle failed");
    }

    pub fn update(self: *SparkParticle, _: i64, dt: f32) bool {
        self.time_left -= dt;
        if (self.time_left <= 0)
            return false;

        self.x += self.dx * (dt / std.time.us_per_s);
        self.y += self.dy * (dt / std.time.us_per_s);
        self.size = self.time_left / self.lifetime * self.initial_size;
        return true;
    }
};

pub const TeleportParticle = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    color: u32 = 0,
    size: f32 = 1.0,
    alpha_mult: f32 = 1.0,

    time_left: f32,
    z_dir: f32,

    pub fn addToMap(part: TeleportParticle) void {
        var lock = map.addLockForType(Particle);
        lock.lock();
        defer lock.unlock();
        map.addListForType(Particle).append(allocator, .{ .teleport = part }) catch @panic("Adding TeleportParticle failed");
    }

    pub fn update(self: *TeleportParticle, _: i64, dt: f32) bool {
        self.time_left -= dt;
        if (self.time_left <= 0)
            return false;

        const displacement = 8.0 / @as(f32, std.time.us_per_s);
        self.z += self.z_dir * dt * displacement;
        return true;
    }
};

pub const ExplosionParticle = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    color: u32 = 0,
    size: f32 = 1.0,
    alpha_mult: f32 = 1.0,

    lifetime: f32,
    time_left: f32,
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,

    pub fn addToMap(part: ExplosionParticle) void {
        var lock = map.addLockForType(Particle);
        lock.lock();
        defer lock.unlock();
        map.addListForType(Particle).append(allocator, .{ .explosion = part }) catch @panic("Adding ExplosionParticle failed");
    }

    pub fn update(self: *ExplosionParticle, _: i64, dt: f32) bool {
        self.time_left -= dt;
        if (self.time_left <= 0)
            return false;

        const displacement = 8.0 / @as(f32, std.time.us_per_s);
        self.x += self.x_dir * dt * displacement;
        self.y += self.y_dir * dt * displacement;
        self.z += self.z_dir * dt * displacement;
        return true;
    }
};

pub const HitParticle = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    color: u32 = 0,
    size: f32 = 1.0,
    alpha_mult: f32 = 1.0,

    lifetime: f32,
    time_left: f32,
    x_dir: f32,
    y_dir: f32,
    z_dir: f32,

    pub fn addToMap(part: HitParticle) void {
        var lock = map.addLockForType(Particle);
        lock.lock();
        defer lock.unlock();
        map.addListForType(Particle).append(allocator, .{ .hit = part }) catch @panic("Adding HitParticle failed");
    }

    pub fn update(self: *HitParticle, _: i64, dt: f32) bool {
        self.time_left -= dt;
        if (self.time_left <= 0)
            return false;

        const displacement = 8.0 / @as(f32, std.time.us_per_s);
        self.x += self.x_dir * dt * displacement;
        self.y += self.y_dir * dt * displacement;
        self.z += self.z_dir * dt * displacement;
        return true;
    }
};

pub const HealParticle = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,
    color: u32 = 0,
    size: f32 = 1.0,
    alpha_mult: f32 = 1.0,

    target_obj_type: network_data.ObjectType,
    target_map_id: u32,
    angle: f32,
    dist: f32,
    time_left: f32,
    z_dir: f32,

    pub fn addToMap(part: HealParticle) void {
        var lock = map.addLockForType(Particle);
        lock.lock();
        defer lock.unlock();
        map.addListForType(Particle).append(allocator, .{ .heal = part }) catch @panic("Adding HealParticle failed");
    }

    pub fn update(self: *HealParticle, _: i64, dt: f32) bool {
        self.time_left -= dt;
        if (self.time_left <= 0)
            return false;

        switch (self.target_obj_type) {
            inline else => |obj_enum| {
                const T = network.ObjEnumToType(obj_enum);
                var lock = map.useLockForType(T);
                lock.lock();
                defer lock.unlock();
                if (map.findObjectConst(T, self.target_map_id)) |obj| {
                    self.x = obj.x + self.dist * @cos(self.angle);
                    self.y = obj.y + self.dist * @sin(self.angle);
                    const displacement = 8.0 / @as(f32, std.time.us_per_s);
                    self.z += self.z_dir * dt * displacement;
                    return true;
                }
            },
        }

        return false;
    }
};

pub const Particle = union(enum) {
    throw: ThrowParticle,
    spark: SparkParticle,
    sparker: SparkerParticle,
    teleport: TeleportParticle,
    explosion: ExplosionParticle,
    hit: HitParticle,
    heal: HealParticle,

    pub fn update(self: *Particle, time: i64, dt: f32) bool {
        return switch (self.*) {
            inline else => |*p| p.update(time, dt),
        };
    }
};

pub const ThrowEffect = struct {
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
    color: u32,
    duration: i64,

    pub fn addToMap(effect: ThrowEffect) void {
        var lock = map.addLockForType(ParticleEffect);
        lock.lock();
        defer lock.unlock();
        map.addListForType(ParticleEffect).append(allocator, .{ .throw = effect }) catch @panic("Adding ThrowEffect failed");
    }

    pub fn update(self: *ThrowEffect, _: i64, _: f32) bool {
        const duration: f32 = @floatFromInt((if (self.duration == 0) 1500 else self.duration) * std.time.us_per_ms);
        var particle: ThrowParticle = .{
            .size = 2.0,
            .initial_size = 2.0,
            .color = self.color,
            .lifetime = duration,
            .time_left = duration,
            .dx = (self.end_x - self.start_x) / duration,
            .dy = (self.end_y - self.start_y) / duration,
            .x = self.start_x,
            .y = self.start_y,
        };
        particle.addToMap();

        return false;
    }
};

pub const AoeEffect = struct {
    x: f32,
    y: f32,
    radius: f32,
    color: u32,

    pub fn addToMap(effect: AoeEffect) void {
        var lock = map.addLockForType(ParticleEffect);
        lock.lock();
        defer lock.unlock();
        map.addListForType(ParticleEffect).append(allocator, .{ .aoe = effect }) catch @panic("Adding AoeEffect failed");
    }

    pub fn update(self: *AoeEffect, _: i64, _: f32) bool {
        const part_num = 4 + self.radius * 2;
        for (0..@intFromFloat(part_num)) |i| {
            const float_i: f32 = @floatFromInt(i);
            const angle = (float_i * 2.0 * std.math.pi) / part_num;
            const end_x = self.x + self.radius * @cos(angle);
            const end_y = self.y + self.radius * @sin(angle);
            const duration = 0.2 * std.time.us_per_s;
            var particle: SparkerParticle = .{
                .size = 0.4,
                .initial_size = 0.4,
                .color = self.color,
                .lifetime = duration,
                .time_left = duration,
                .dx = (end_x - self.x) / duration,
                .dy = (end_y - self.y) / duration,
                .x = self.x,
                .y = self.y,
            };
            particle.addToMap();
        }

        return false;
    }
};

pub const TeleportEffect = struct {
    x: f32,
    y: f32,

    pub fn addToMap(effect: TeleportEffect) void {
        var lock = map.addLockForType(ParticleEffect);
        lock.lock();
        defer lock.unlock();
        map.addListForType(ParticleEffect).append(allocator, .{ .teleport = effect }) catch @panic("Adding TeleportEffect failed");
    }

    pub fn update(self: *TeleportEffect, _: i64, _: f32) bool {
        for (0..20) |_| {
            const rand = utils.rng.random().float(f32);
            const angle = 2.0 * std.math.pi * rand;
            const radius = 0.7 * rand;

            var particle: TeleportParticle = .{
                .size = 0.8,
                .color = 0x0000FF,
                .time_left = (0.5 + 1.0 * rand) * std.time.us_per_s,
                .z_dir = 0.1,
                .x = self.x + radius * @cos(angle),
                .y = self.y + radius * @sin(angle),
            };
            particle.addToMap();
        }

        return false;
    }
};

pub const LineEffect = struct {
    start_x: f32,
    start_y: f32,
    end_x: f32,
    end_y: f32,
    color: u32,

    pub fn addToMap(effect: LineEffect) void {
        var lock = map.addLockForType(ParticleEffect);
        lock.lock();
        defer lock.unlock();
        map.addListForType(ParticleEffect).append(allocator, .{ .line = effect }) catch @panic("Adding LineEffect failed");
    }

    pub fn update(self: *LineEffect, _: i64, _: f32) bool {
        const duration = 0.7 * std.time.us_per_s;
        for (0..30) |i| {
            const f = @as(f32, @floatFromInt(i)) / 30;
            var particle: SparkParticle = .{
                .size = 1.0,
                .initial_size = 1.0,
                .color = self.color,
                .lifetime = duration,
                .time_left = duration,
                .dx = (self.end_x - self.start_x) / duration,
                .dy = (self.end_y - self.start_y) / duration,
                .x = self.end_x + f * (self.start_x - self.end_x),
                .y = self.end_y + f * (self.start_y - self.end_y),
                .z = 0.5,
            };
            particle.addToMap();
        }

        return false;
    }
};

pub const ExplosionEffect = struct {
    x: f32,
    y: f32,
    colors: []const u32,
    size: f32,
    amount: u32,

    pub fn addToMap(effect: ExplosionEffect) void {
        var lock = map.addLockForType(ParticleEffect);
        lock.lock();
        defer lock.unlock();
        map.addListForType(ParticleEffect).append(allocator, .{ .explosion = effect }) catch @panic("Adding ExplosionEffect failed");
    }

    pub fn update(self: *ExplosionEffect, _: i64, _: f32) bool {
        if (self.colors.len == 0)
            return false;

        for (0..self.amount) |_| {
            const duration = (0.2 + utils.rng.random().float(f32) * 0.1) * std.time.us_per_s;
            var particle: ExplosionParticle = .{
                .size = self.size,
                .color = self.colors[utils.rng.next() % self.colors.len],
                .lifetime = duration,
                .time_left = duration,
                .x_dir = utils.rng.random().float(f32) - 0.5,
                .y_dir = utils.rng.random().float(f32) - 0.5,
                .z_dir = 0,
                .x = self.x,
                .y = self.y,
                .z = 0.5,
            };
            particle.addToMap();
        }

        return false;
    }
};

pub const HitEffect = struct {
    x: f32,
    y: f32,
    colors: []const u32,
    size: f32,
    angle: f32,
    speed: f32,
    amount: u32,

    pub fn addToMap(effect: HitEffect) void {
        var lock = map.addLockForType(ParticleEffect);
        lock.lock();
        defer lock.unlock();
        map.addListForType(ParticleEffect).append(allocator, .{ .hit = effect }) catch @panic("Adding HitEffect failed");
    }

    pub fn update(self: *HitEffect, _: i64, _: f32) bool {
        if (self.colors.len == 0)
            return false;

        const cos = self.speed / 600.0 * -@cos(self.angle);
        const sin = self.speed / 600.0 * -@sin(self.angle);

        for (0..self.amount) |_| {
            const duration = (0.2 + utils.rng.random().float(f32) * 0.1) * std.time.us_per_s;
            var particle: HitParticle = .{
                .size = self.size,
                .color = self.colors[utils.rng.next() % self.colors.len],
                .lifetime = duration,
                .time_left = duration,
                .x_dir = cos + (utils.rng.random().float(f32) - 0.5) * 0.4,
                .y_dir = sin + (utils.rng.random().float(f32) - 0.5) * 0.4,
                .z_dir = 0,
                .x = self.x,
                .y = self.y,
                .z = 0.5,
            };
            particle.addToMap();
        }

        return false;
    }
};

pub const HealEffect = struct {
    target_obj_type: network_data.ObjectType,
    target_map_id: u32,
    color: u32,

    pub fn addToMap(effect: HealEffect) void {
        var lock = map.addLockForType(ParticleEffect);
        lock.lock();
        defer lock.unlock();
        map.addListForType(ParticleEffect).append(allocator, .{ .heal = effect }) catch @panic("Adding HealEffect failed");
    }

    pub fn update(self: *HealEffect, _: i64, _: f32) bool {
        switch (self.target_obj_type) {
            inline else => |obj_enum| {
                const T = network.ObjEnumToType(obj_enum);
                var lock = map.useLockForType(T);
                lock.lock();
                defer lock.unlock();
                if (map.findObjectConst(T, self.target_map_id)) |obj| {
                    for (0..10) |i| {
                        const float_i: f32 = @floatFromInt(i);
                        const angle = std.math.tau * (float_i / 10.0);
                        const radius = 0.3 + 0.4 * utils.rng.random().float(f32);
                        var particle: HealParticle = .{
                            .size = 0.5 + utils.rng.random().float(f32),
                            .color = self.color,
                            .time_left = 1.0 * std.time.us_per_s,
                            .angle = angle,
                            .dist = radius,
                            .target_obj_type = self.target_obj_type,
                            .target_map_id = self.target_map_id,
                            .z_dir = 0.1 + utils.rng.random().float(f32) * 0.1,
                            .x = obj.x + radius * @cos(angle),
                            .y = obj.y + radius * @sin(angle),
                            .z = utils.rng.random().float(f32) * 0.3,
                        };
                        particle.addToMap();
                    }

                    return false;
                }
            },
        }

        std.log.err("Target with map id {d} not found for HealEffect", .{self.target_map_id});
        return false;
    }
};

pub const RingEffect = struct {
    start_x: f32,
    start_y: f32,
    radius: f32,
    color: u32,
    cooldown: i64,
    last_activate: i64 = -1,

    pub fn addToMap(effect: RingEffect) void {
        var lock = map.addLockForType(ParticleEffect);
        lock.lock();
        defer lock.unlock();
        map.addListForType(ParticleEffect).append(allocator, .{ .ring = effect }) catch @panic("Adding RingEffect failed");
    }

    pub fn update(self: *RingEffect, time: i64, _: f32) bool {
        if (self.cooldown > 0 and time < self.last_activate + self.cooldown)
            return true;

        const duration = 0.2 * std.time.us_per_s;
        for (0..12) |i| {
            const float_i: f32 = @floatFromInt(i);
            const angle = (float_i * 2.0 * std.math.pi) / 12.0;
            const cos_angle = @cos(angle);
            const sin_angle = @sin(angle);

            const start_x = self.start_x + self.radius * cos_angle;
            const start_y = self.start_y + self.radius * sin_angle;
            const end_x = self.start_x + self.radius * 0.9 * cos_angle;
            const end_y = self.start_y + self.radius * 0.9 * sin_angle;

            var particle: SparkerParticle = .{
                .size = 1.0,
                .initial_size = 1.0,
                .color = self.color,
                .lifetime = duration,
                .time_left = duration,
                .dx = (end_x - start_x) / duration,
                .dy = (end_y - start_y) / duration,
                .x = start_x,
                .y = start_y,
                .z = 0.5,
            };
            particle.addToMap();
        }

        self.last_activate = time;
        return self.cooldown > 0;
    }
};

pub const ParticleEffect = union(enum) {
    throw: ThrowEffect,
    aoe: AoeEffect,
    teleport: TeleportEffect,
    line: LineEffect,
    explosion: ExplosionEffect,
    hit: HitEffect,
    heal: HealEffect,
    ring: RingEffect,

    pub fn update(self: *ParticleEffect, time: i64, dt: f32) bool {
        return switch (self.*) {
            inline else => |*p| p.update(time, dt),
        };
    }
};
