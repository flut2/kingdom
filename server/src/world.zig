const std = @import("std");
const shared = @import("shared");
const utils = shared.utils;
const game_data = shared.game_data;
const maps = @import("map/maps.zig");

const LightData = maps.LightData;
const Tile = @import("map/tile.zig").Tile;
const Entity = @import("map/entity.zig").Entity;
const Enemy = @import("map/enemy.zig").Enemy;
const Player = @import("map/player.zig").Player;
const Portal = @import("map/portal.zig").Portal;
const Container = @import("map/container.zig").Container;
const Projectile = @import("map/projectile.zig").Projectile;

pub const WorldPoint = struct { x: u16, y: u16 };

pub const World = struct {
    id: i32 = std.math.minInt(i32),
    owner_portal_id: u32 = std.math.maxInt(u32),
    next_map_ids: struct {
        entity: u32 = 0,
        enemy: u32 = 0,
        player: u32 = 0,
        portal: u32 = 0,
        container: u32 = 0,
        projectile: u32 = 0,
    } = .{},
    w: u16 = 0,
    h: u16 = 0,
    time_added: i64 = 0,
    name: []const u8 = undefined,
    light_data: LightData = .{},
    map_type: maps.MapType = .default,
    tiles: []Tile = &.{},
    regions: std.AutoHashMapUnmanaged(u16, []WorldPoint) = .{},
    drops: struct {
        entity: std.ArrayListUnmanaged(u32) = .{},
        enemy: std.ArrayListUnmanaged(u32) = .{},
        player: std.ArrayListUnmanaged(u32) = .{},
        portal: std.ArrayListUnmanaged(u32) = .{},
        container: std.ArrayListUnmanaged(u32) = .{},
    } = .{},
    lists: struct {
        entity: std.ArrayListUnmanaged(Entity) = .{},
        enemy: std.ArrayListUnmanaged(Enemy) = .{},
        player: std.ArrayListUnmanaged(Player) = .{},
        portal: std.ArrayListUnmanaged(Portal) = .{},
        container: std.ArrayListUnmanaged(Container) = .{},
        projectile: std.ArrayListUnmanaged(Projectile) = .{},
    } = .{},
    allocator: std.mem.Allocator = undefined,

    pub fn listForType(self: *World, comptime T: type) *std.ArrayListUnmanaged(T) {
        return switch (T) {
            Entity => &self.lists.entity,
            Enemy => &self.lists.enemy,
            Player => &self.lists.player,
            Portal => &self.lists.portal,
            Container => &self.lists.container,
            Projectile => &self.lists.projectile,
            else => @compileError("Given type has no list"),
        };
    }

    pub fn dropsForType(self: *World, comptime T: type) *std.ArrayListUnmanaged(u32) {
        return switch (T) {
            Entity => &self.drops.entity,
            Enemy => &self.drops.enemy,
            Player => &self.drops.player,
            Portal => &self.drops.portal,
            Container => &self.drops.container,
            else => @compileError("Given type has no drops list"),
        };
    }

    pub fn nextMapIdForType(self: *World, comptime T: type) *u32 {
        return switch (T) {
            Entity => &self.next_map_ids.entity,
            Enemy => &self.next_map_ids.enemy,
            Player => &self.next_map_ids.player,
            Portal => &self.next_map_ids.portal,
            Container => &self.next_map_ids.container,
            Projectile => &self.next_map_ids.projectile,
            else => @compileError("Invalid type"),
        };
    }

    pub fn appendMap(self: *World, map: maps.MapData) !void {
        @memcpy(self.tiles, map.tiles);
        self.regions = map.regions;

        self.name = map.details.name;
        self.light_data = map.details.light;
        self.map_type = map.details.map_type;

        for (map.entities) |e| _ = try self.add(Entity, .{ .x = e.x, .y = e.y, .data_id = e.data_id });
        for (map.enemies) |e| _ = try self.add(Enemy, .{ .x = e.x, .y = e.y, .data_id = e.data_id });
        for (map.portals) |p| _ = try self.add(Portal, .{ .x = p.x, .y = p.y, .data_id = p.data_id });
        for (map.containers) |c| _ = try self.add(Container, .{ .x = c.x, .y = c.y, .data_id = c.data_id });
    }

    pub fn create(allocator: std.mem.Allocator, w: u16, h: u16, id: i32) !World {
        return .{
            .id = id,
            .w = w,
            .h = h,
            .tiles = try allocator.alloc(Tile, @as(u32, w) * @as(u32, h)),
            .allocator = allocator,
            .time_added = @import("main.zig").current_time,
        };
    }

    pub fn deinit(self: *World) void {
        std.log.err("World \"{s}\" (id {}) removed", .{ self.name, self.id });

        inline for (.{ &self.lists, &self.drops }) |list| {
            inline for (@typeInfo(@TypeOf(list.*)).@"struct".fields) |field| @field(list, field.name).deinit(self.allocator);
        }
        self.allocator.free(self.tiles);
        _ = maps.worlds.swapRemove(self.id);
    }

    pub fn addExisting(self: *World, comptime T: type, obj: *T) !u32 {
        const next_map_id = self.nextMapIdForType(T);
        obj.map_id = next_map_id.*;
        next_map_id.* += 1;

        obj.world = self;

        if (std.meta.hasFn(T, "init"))
            try obj.init(self.allocator);

        try self.listForType(T).append(self.allocator, obj.*);

        return obj.map_id;
    }

    pub fn add(self: *World, comptime T: type, data: struct { x: f32, y: f32, data_id: u16 = std.math.maxInt(u16) }) !u32 {
        var obj: T = .{ .x = data.x, .y = data.y };
        if (@hasField(T, "data_id"))
            obj.data_id = data.data_id;

        const next_map_id = self.nextMapIdForType(T);
        obj.map_id = next_map_id.*;
        next_map_id.* += 1;

        obj.world = self;

        if (std.meta.hasFn(T, "init"))
            try obj.init(self.allocator);

        try self.listForType(T).append(self.allocator, obj);

        return obj.map_id;
    }

    pub fn remove(self: *World, comptime T: type, value: *T) !void {
        if (std.meta.hasFn(T, "deinit"))
            try value.deinit();

        if (T != Projectile) try self.dropsForType(T).append(self.allocator, value.map_id);

        var list = self.listForType(T);
        for (list.items, 0..) |item, i| {
            if (item.map_id == value.map_id) {
                _ = list.swapRemove(i);
                return;
            }
        }
    }

    pub fn find(self: *World, comptime T: type, map_id: u32) ?T {
        for (self.listForType(T).items) |item| {
            if (item.map_id == map_id)
                return item;
        }

        return null;
    }

    pub fn findRef(self: *World, comptime T: type, map_id: u32) ?*T {
        for (self.listForType(T).items) |*item| {
            if (item.map_id == map_id)
                return item;
        }

        return null;
    }

    pub fn tick(self: *World, time: i64, dt: i64) !void {
        if (self.id >= 0 and self.map_type != .realm and
            time > self.time_added + 30 * std.time.us_per_s and self.listForType(Player).items.len == 0)
        {
            self.deinit();
            return;
        }

        inline for (.{ Entity, Enemy, Portal, Container, Projectile, Player }) |ObjType| {
            for (self.listForType(ObjType).items) |*obj| {
                try obj.tick(time, dt);
            }
        }
    }

    pub fn getNearestPlayerWithin(self: *World, x: f32, y: f32, radius_sqr: f32) ?*Player {
        var min_dist_sqr = radius_sqr;
        var target: ?*Player = null;
        for (self.listForType(Player).items) |*p| {
            const dx = p.x - x;
            const dy = p.y - y;
            const dist_sqr = dx * dx + dy * dy;
            if (dist_sqr <= min_dist_sqr and !p.condition.invisible) {
                min_dist_sqr = dist_sqr;
                target = p;
            }
        }

        return target;
    }

    // If there is a target within radius_min_sqr, returns nothing
    // so that the caller can do nothing. Only one line differs.
    pub fn getNearestPlayerWithinRing(self: *World, x: f32, y: f32, radius_sqr: f32, radius_min_sqr: f32) ?*Player {
        var min_dist_sqr = radius_sqr;
        var target: ?*Player = null;
        for (self.listForType(Player).items) |*p| {
            const dx = p.x - x;
            const dy = p.y - y;
            const dist_sqr = dx * dx + dy * dy;
            if (dist_sqr <= radius_min_sqr)
                return null;

            if (dist_sqr <= min_dist_sqr and !p.condition.invisible) {
                min_dist_sqr = dist_sqr;
                target = p;
            }
        }

        return target;
    }

    pub fn getNearestEnemyWithin(self: *World, x: f32, y: f32, radius_sqr: f32, en_type: u16) ?*Enemy {
        var min_dist_sqr = radius_sqr;
        var target: ?*Enemy = null;
        for (self.listForType(Enemy).items) |*e| {
            const dx = e.x - x;
            const dy = e.y - y;
            const dist_sqr = dx * dx + dy * dy;
            if (e.en_type == en_type and dist_sqr <= min_dist_sqr) {
                min_dist_sqr = dist_sqr;
                target = e;
            }
        }

        return target;
    }

    pub fn aoePlayer(self: *World, x: f32, y: f32, owner_name: []const u8, radius: f32, opts: struct {
        damage: i32 = 0,
        effect: ?utils.ConditionEnum = null,
        effect_duration: i64 = 1 * std.time.us_per_s,
        aoe_color: u32 = 0xFFFFFF,
        ignore_def: bool = false,
    }) void {
        const radius_sqr = radius * radius;
        for (self.listForType(Player).items) |*p| {
            const dx = p.x - x;
            const dy = p.y - y;
            const dist_sqr = dx * dx + dy * dy;
            if (dist_sqr > 16 * 16)
                continue;

            p.client.queuePacket(.{ .show_effect = .{
                .eff_type = .area_blast,
                .obj_type = .entity,
                .map_id = std.math.maxInt(u32),
                .x1 = x,
                .y1 = y,
                .x2 = radius,
                .y2 = 0,
                .color = opts.aoe_color,
            } });

            if (dist_sqr > radius_sqr)
                continue;

            p.damage(owner_name, opts.damage, opts.ignore_def);
            if (opts.effect) |eff| p.applyCondition(eff, opts.effect_duration) catch continue;
        }
    }
};
