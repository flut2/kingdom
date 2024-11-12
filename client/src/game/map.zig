const std = @import("std");
const network = @import("../network.zig");
const shared = @import("shared");
const game_data = shared.game_data;
const utils = shared.utils;
const network_data = shared.network_data;
const camera = @import("../camera.zig");
const input = @import("../input.zig");
const main = @import("../main.zig");
const element = @import("../ui/element.zig");
const zstbi = @import("zstbi");
const particles = @import("particles.zig");
const systems = @import("../ui/systems.zig");
const assets = @import("../assets.zig");

const Square = @import("square.zig").Square;
const Player = @import("player.zig").Player;
const Projectile = @import("projectile.zig").Projectile;
const Entity = @import("entity.zig").Entity;
const Enemy = @import("enemy.zig").Enemy;
const Container = @import("container.zig").Container;
const Portal = @import("portal.zig").Portal;

const day_cycle: i32 = 10 * std.time.us_per_min;
const day_cycle_half: f32 = @as(f32, day_cycle) / 2;

pub var square_lock: std.Thread.Mutex = .{};
pub var use_lock: struct {
    player: std.Thread.Mutex = .{},
    entity: std.Thread.Mutex = .{},
    enemy: std.Thread.Mutex = .{},
    container: std.Thread.Mutex = .{},
    portal: std.Thread.Mutex = .{},
    projectile: std.Thread.Mutex = .{},
    particle: std.Thread.Mutex = .{},
    particle_effect: std.Thread.Mutex = .{},
} = .{};
pub var add_lock: struct {
    player: std.Thread.Mutex = .{},
    entity: std.Thread.Mutex = .{},
    enemy: std.Thread.Mutex = .{},
    container: std.Thread.Mutex = .{},
    portal: std.Thread.Mutex = .{},
    projectile: std.Thread.Mutex = .{},
    particle: std.Thread.Mutex = .{},
    particle_effect: std.Thread.Mutex = .{},
} = .{};
pub var list: struct {
    player: std.ArrayListUnmanaged(Player) = .{},
    entity: std.ArrayListUnmanaged(Entity) = .{},
    enemy: std.ArrayListUnmanaged(Enemy) = .{},
    container: std.ArrayListUnmanaged(Container) = .{},
    portal: std.ArrayListUnmanaged(Portal) = .{},
    projectile: std.ArrayListUnmanaged(Projectile) = .{},
    particle: std.ArrayListUnmanaged(particles.Particle) = .{},
    particle_effect: std.ArrayListUnmanaged(particles.ParticleEffect) = .{},
} = .{};
pub var add_list: struct {
    player: std.ArrayListUnmanaged(Player) = .{},
    entity: std.ArrayListUnmanaged(Entity) = .{},
    enemy: std.ArrayListUnmanaged(Enemy) = .{},
    container: std.ArrayListUnmanaged(Container) = .{},
    portal: std.ArrayListUnmanaged(Portal) = .{},
    projectile: std.ArrayListUnmanaged(Projectile) = .{},
    particle: std.ArrayListUnmanaged(particles.Particle) = .{},
    particle_effect: std.ArrayListUnmanaged(particles.ParticleEffect) = .{},
} = .{};
pub var remove_list: struct {
    player: std.ArrayListUnmanaged(usize) = .{},
    entity: std.ArrayListUnmanaged(usize) = .{},
    enemy: std.ArrayListUnmanaged(usize) = .{},
    container: std.ArrayListUnmanaged(usize) = .{},
    portal: std.ArrayListUnmanaged(usize) = .{},
    projectile: std.ArrayListUnmanaged(usize) = .{},
    particle: std.ArrayListUnmanaged(usize) = .{},
    particle_effect: std.ArrayListUnmanaged(usize) = .{},
} = .{};

pub var interactive: struct {
    const InteractiveType = enum(u8) { unset, portal, container, purchasable };
    map_id: std.atomic.Value(u32) = std.atomic.Value(u32).init(std.math.maxInt(u32)),
    type: std.atomic.Value(InteractiveType) = std.atomic.Value(InteractiveType).init(.unset),
} = .{};
pub var squares: []Square = &.{};
pub var move_records: std.ArrayListUnmanaged(network_data.TimedPosition) = .{};
pub var info: network_data.MapInfo = .{};
pub var last_records_clear_time: i64 = 0;
pub var local_player_id: u32 = std.math.maxInt(u32);
pub var minimap: zstbi.Image = undefined;
pub var minimap_copy: []u8 = undefined;

var last_update: i64 = 0;

pub fn useLockForType(comptime T: type) *std.Thread.Mutex {
    return switch (T) {
        Entity => &use_lock.entity,
        Enemy => &use_lock.enemy,
        Player => &use_lock.player,
        Portal => &use_lock.portal,
        Container => &use_lock.container,
        Projectile => &use_lock.projectile,
        particles.Particle => &use_lock.particle,
        particles.ParticleEffect => &use_lock.particle_effect,
        else => @compileError("Invalid type"),
    };
}

pub fn addLockForType(comptime T: type) *std.Thread.Mutex {
    return switch (T) {
        Entity => &add_lock.entity,
        Enemy => &add_lock.enemy,
        Player => &add_lock.player,
        Portal => &add_lock.portal,
        Container => &add_lock.container,
        Projectile => &add_lock.projectile,
        particles.Particle => &add_lock.particle,
        particles.ParticleEffect => &add_lock.particle_effect,
        else => @compileError("Invalid type"),
    };
}

pub fn listForType(comptime T: type) *std.ArrayListUnmanaged(T) {
    return switch (T) {
        Entity => &list.entity,
        Enemy => &list.enemy,
        Player => &list.player,
        Portal => &list.portal,
        Container => &list.container,
        Projectile => &list.projectile,
        particles.Particle => &list.particle,
        particles.ParticleEffect => &list.particle_effect,
        else => @compileError("Invalid type"),
    };
}

pub fn addListForType(comptime T: type) *std.ArrayListUnmanaged(T) {
    return switch (T) {
        Entity => &add_list.entity,
        Enemy => &add_list.enemy,
        Player => &add_list.player,
        Portal => &add_list.portal,
        Container => &add_list.container,
        Projectile => &add_list.projectile,
        particles.Particle => &add_list.particle,
        particles.ParticleEffect => &add_list.particle_effect,
        else => @compileError("Invalid type"),
    };
}

pub fn removeListForType(comptime T: type) *std.ArrayListUnmanaged(usize) {
    return switch (T) {
        Entity => &remove_list.entity,
        Enemy => &remove_list.enemy,
        Player => &remove_list.player,
        Portal => &remove_list.portal,
        Container => &remove_list.container,
        Projectile => &remove_list.projectile,
        particles.Particle => &remove_list.particle,
        particles.ParticleEffect => &remove_list.particle_effect,
        else => @compileError("Invalid type"),
    };
}

pub fn init(allocator: std.mem.Allocator) !void {
    particles.allocator = allocator;
    minimap = try zstbi.Image.createEmpty(1024, 1024, 4, .{});
    minimap_copy = try allocator.alloc(u8, 1024 * 1024 * 4);
}

pub fn deinit(allocator: std.mem.Allocator) void {
    inline for (@typeInfo(@TypeOf(list)).@"struct".fields) |field| {
        var lock = &@field(use_lock, field.name);
        lock.lock();
        defer lock.unlock();

        @field(remove_list, field.name).deinit(allocator);

        var child_list = &@field(list, field.name);
        defer child_list.deinit(allocator);
        if (comptime !std.mem.eql(u8, field.name, "particle") and !std.mem.eql(u8, field.name, "particle_effect"))
            for (child_list.items) |*obj| obj.deinit(allocator);
    }

    inline for (@typeInfo(@TypeOf(add_list)).@"struct".fields) |field| {
        var lock = &@field(add_lock, field.name);
        lock.lock();
        defer lock.unlock();
        var child_list = &@field(add_list, field.name);
        defer child_list.deinit(allocator);
        if (comptime !std.mem.eql(u8, field.name, "particle") and !std.mem.eql(u8, field.name, "particle_effect"))
            for (child_list.items) |*obj| obj.deinit(allocator);
    }

    move_records.deinit(allocator);
    allocator.free(info.name);
    {
        square_lock.lock();
        defer square_lock.unlock();
        allocator.free(squares);
    }

    main.minimap_lock.lock();
    defer main.minimap_lock.unlock();
    minimap.deinit();
    allocator.free(minimap_copy);
}

pub fn dispose(allocator: std.mem.Allocator) void {
    interactive.map_id.store(std.math.maxInt(u32), .release);
    interactive.type.store(.unset, .release);

    local_player_id = std.math.maxInt(u32);
    info = .{};

    inline for (@typeInfo(@TypeOf(list)).@"struct".fields) |field| {
        var lock = &@field(use_lock, field.name);
        lock.lock();
        defer lock.unlock();

        @field(remove_list, field.name).clearRetainingCapacity();

        var child_list = &@field(list, field.name);
        defer child_list.clearRetainingCapacity();
        if (comptime !std.mem.eql(u8, field.name, "particle") and !std.mem.eql(u8, field.name, "particle_effect"))
            for (child_list.items) |*obj| obj.deinit(allocator);
    }

    inline for (@typeInfo(@TypeOf(add_list)).@"struct".fields) |field| {
        var lock = &@field(add_lock, field.name);
        lock.lock();
        defer lock.unlock();
        var child_list = &@field(add_list, field.name);
        defer child_list.clearRetainingCapacity();
        if (comptime !std.mem.eql(u8, field.name, "particle") and !std.mem.eql(u8, field.name, "particle_effect"))
            for (child_list.items) |*obj| obj.deinit(allocator);
    }

    {
        square_lock.lock();
        defer square_lock.unlock();
        @memset(squares, Square{});
    }

    main.minimap_lock.lock();
    defer main.minimap_lock.unlock();
    @memset(minimap.data, 0);
    main.need_force_update = true;

    // main.minimap_update = .{};
    // minimap.deinit();
    // minimap = try zstbi.Image.createEmpty(1, 1, 4, .{});
    // main.need_force_update = true;
}

pub fn getLightIntensity(time: i64) f32 {
    if (info.day_intensity == 0 and info.night_intensity == 0) return info.bg_intensity;

    const server_time_clamped: f32 = @floatFromInt(@mod(time + info.server_time, day_cycle));
    const intensity_delta = info.day_intensity - info.night_intensity;
    if (server_time_clamped <= day_cycle_half)
        return info.night_intensity + intensity_delta * (server_time_clamped / day_cycle_half)
    else
        return info.day_intensity - intensity_delta * ((server_time_clamped - day_cycle_half) / day_cycle_half);
}

pub fn setMapInfo(data: network_data.MapInfo, allocator: std.mem.Allocator) void {
    info = data;

    {
        square_lock.lock();
        defer square_lock.unlock();
        squares = if (squares.len == 0)
            allocator.alloc(Square, @as(u32, data.width) * @as(u32, data.height)) catch return
        else
            allocator.realloc(squares, @as(u32, data.width) * @as(u32, data.height)) catch return;

        @memset(squares, Square{});
    }

    const size = @max(data.width, data.height);
    const max_zoom: f32 = @floatFromInt(@divFloor(size, 32));
    camera.minimap_zoom = @max(1, @min(max_zoom, camera.minimap_zoom));

    main.minimap_lock.lock();
    defer main.minimap_lock.unlock();
    @memset(minimap.data, 0);
    main.need_force_update = true;

    // main.minimap_lock.lock();
    // defer main.minimap_lock.unlock();
    // main.minimap_update = .{};
    // minimap.deinit();
    // minimap = zstbi.Image.createEmpty(data.width, data.height, 4, .{}) catch |e| {
    //     std.debug.panic("Minimap allocation failed: {}", .{e});
    //     return;
    // };
    // main.need_force_update = true;
}

pub fn localPlayerConst() ?Player {
    std.debug.assert(!useLockForType(Player).tryLock());
    if (local_player_id == -1) return null;
    if (findObjectConst(Player, local_player_id)) |player| return player;
    return null;
}

pub fn localPlayerRef() ?*Player {
    std.debug.assert(!useLockForType(Player).tryLock());
    if (local_player_id == -1) return null;
    if (findObjectRef(Player, local_player_id)) |player| return player;
    return null;
}

pub fn findObjectConst(comptime T: type, map_id: u32) ?T {
    std.debug.assert(!useLockForType(T).tryLock());
    for (listForType(T).items) |obj| {
        if (obj.map_id == map_id)
            return obj;
    }

    return null;
}

pub fn findObjectRef(comptime T: type, map_id: u32) ?*T {
    std.debug.assert(!useLockForType(T).tryLock());
    for (listForType(T).items) |*obj| {
        if (obj.map_id == map_id)
            return obj;
    }

    return null;
}

pub fn removeEntity(comptime T: type, allocator: std.mem.Allocator, map_id: u32) bool {
    std.debug.assert(!useLockForType(T).tryLock());
    var obj_list = listForType(T);
    for (obj_list.items, 0..) |*obj, i| {
        if (obj.map_id == map_id) {
            obj.deinit(allocator);
            _ = obj_list.orderedRemove(i);
            return true;
        }
    }

    return false;
}

pub fn update(allocator: std.mem.Allocator, time: i64, dt: f32) void {
    if (local_player_id == std.math.maxInt(u32)) return;

    {}

    var should_unset_interactive = true;
    defer if (should_unset_interactive) {
        interactive.map_id.store(std.math.maxInt(u32), .release);
        interactive.type.store(.unset, .release);
    };

    var should_unset_container = true;
    defer if (should_unset_container) {
        systems.ui_lock.lock();
        defer systems.ui_lock.unlock();
        if (systems.screen == .game) {
            const screen = systems.screen.game;
            if (screen.container_id != -1) {
                inline for (0..8) |idx| screen.setContainerItem(std.math.maxInt(u16), idx);
                screen.container_name.text_data.setText("", screen.allocator);
            }

            screen.container_id = std.math.maxInt(u32);
            screen.setContainerVisible(false);
        }
    };

    camera.lock.lock();
    const cam_x = camera.x;
    const cam_y = camera.y;
    const cam_min_x: f32 = @floatFromInt(camera.min_x);
    const cam_max_x: f32 = @floatFromInt(camera.max_x);
    const cam_min_y: f32 = @floatFromInt(camera.min_y);
    const cam_max_y: f32 = @floatFromInt(camera.max_y);
    camera.lock.unlock();

    inline for (.{ Entity, Enemy, Player, Portal, Projectile, Container, particles.Particle, particles.ParticleEffect }) |ObjType| {
        var obj_lock = useLockForType(ObjType);
        obj_lock.lock();
        defer obj_lock.unlock();
        var obj_list = listForType(ObjType);
        {
            var lock = addLockForType(ObjType);
            lock.lock();
            defer lock.unlock();
            var obj_add_list = addListForType(ObjType);
            defer obj_add_list.clearRetainingCapacity();
            obj_list.appendSlice(allocator, obj_add_list.items) catch @panic("Failed to add objects");
        }

        var obj_remove_list = removeListForType(ObjType);
        obj_remove_list.clearRetainingCapacity();

        for (obj_list.items, 0..) |*obj, i| {
            if (ObjType != particles.ParticleEffect and (ObjType != Player or obj.map_id != local_player_id)) {
                const obj_x = switch (ObjType) {
                    particles.Particle => switch (obj.*) {
                        inline else => |pt| pt.x,
                    },
                    else => obj.x,
                };
                const obj_y = switch (ObjType) {
                    particles.Particle => switch (obj.*) {
                        inline else => |pt| pt.y,
                    },
                    else => obj.y,
                };
                if (obj_x < cam_min_x or obj_x > cam_max_x or obj_y < cam_min_y or obj_y > cam_max_y) continue;
            }

            switch (ObjType) {
                Container => {
                    {
                        systems.ui_lock.lock();
                        defer systems.ui_lock.unlock();
                        if (systems.screen == .game) {
                            const screen = systems.screen.game;
                            const dt_x = cam_x - obj.x;
                            const dt_y = cam_y - obj.y;
                            if (dt_x * dt_x + dt_y * dt_y < 1) {
                                interactive.map_id.store(obj.map_id, .release);
                                interactive.type.store(.container, .release);

                                if (screen.container_id != obj.map_id) {
                                    inline for (0..8) |idx| screen.setContainerItem(obj.inventory[idx], idx);
                                    if (obj.name) |name| screen.container_name.text_data.setText(name, screen.allocator);
                                }

                                screen.container_id = obj.map_id;
                                screen.setContainerVisible(true);
                                should_unset_interactive = false;
                                should_unset_container = false;
                            }
                        }
                    }

                    obj.update(time);
                },
                Player => {
                    const is_self = obj.map_id == local_player_id;
                    if (is_self) useLockForType(Entity).lock();
                    defer if (is_self) useLockForType(Entity).unlock();
                    obj.walk_speed_multiplier = input.walking_speed_multiplier;
                    obj.move_angle = input.move_angle;
                    obj.update(time, dt, allocator);
                    if (is_self) {
                        camera.update(obj.x, obj.y, dt, input.rotate);
                        addMoveRecord(allocator, time, obj.x, obj.y);
                        if (input.attacking) {
                            const shoot_angle = std.math.atan2(
                                input.mouse_y - camera.screen_height / 2.0,
                                input.mouse_x - camera.screen_width / 2.0,
                            ) + camera.angle;
                            obj.weaponShoot(allocator, shoot_angle, time);
                        }
                    }
                },
                Portal => {
                    const is_game = blk: {
                        systems.ui_lock.lock();
                        defer systems.ui_lock.unlock();
                        break :blk systems.screen == .game;
                    };
                    if (is_game) {
                        const dt_x = cam_x - obj.x;
                        const dt_y = cam_y - obj.y;
                        if (dt_x * dt_x + dt_y * dt_y < 1) {
                            interactive.map_id.store(obj.map_id, .release);
                            interactive.type.store(.portal, .release);
                            should_unset_interactive = false;
                        }
                    }
                    obj.update(time);
                },
                Projectile => if (!obj.update(time, dt, allocator))
                    obj_remove_list.append(allocator, i) catch @panic("Removing projectile failed"),
                particles.Particle => if (!obj.update(time, dt))
                    obj_remove_list.append(allocator, i) catch @panic("Removing particle failed"),
                particles.ParticleEffect => if (!obj.update(time, dt))
                    obj_remove_list.append(allocator, i) catch @panic("Removing particle effect failed"),
                Entity => obj.update(time),
                Enemy => obj.update(time, dt),
                else => @compileError("Invalid type"),
            }
        }

        var iter = std.mem.reverseIterator(obj_remove_list.items);
        while (iter.next()) |i| {
            if (@hasField(@TypeOf(obj_list.items[i]), "deinit")) obj_list.items[i].deinit(allocator);
            _ = obj_list.orderedRemove(i);
        }
    }
}

// x/y < 0 has to be handled before this, since it's a u32
pub fn validPos(x: u32, y: u32) bool {
    return !(x >= info.width or y >= info.height);
}

// check_validity should always be on, unless you profiled that it causes clear slowdowns in your code.
// even then, you should be very sure that the input can't ever go wrong or that it going wrong is inconsequential
pub fn getSquare(x: f32, y: f32, comptime check_validity: bool) ?Square {
    if (check_validity and (x < 0 or y < 0)) {
        @branchHint(.unlikely);
        return null;
    }

    const floor_x: u32 = @intFromFloat(@floor(x));
    const floor_y: u32 = @intFromFloat(@floor(y));
    if (check_validity and !validPos(floor_x, floor_y)) {
        @branchHint(.unlikely);
        return null;
    }

    const square = squares[floor_y * info.width + floor_x];
    if (check_validity and (square.data_id == Square.empty_tile or square.data_id == Square.editor_tile))
        return null;

    return square;
}

pub fn getSquarePtr(x: f32, y: f32, comptime check_validity: bool) ?*Square {
    if (check_validity and (x < 0 or y < 0)) {
        @branchHint(.unlikely);
        return null;
    }

    const floor_x: u32 = @intFromFloat(@floor(x));
    const floor_y: u32 = @intFromFloat(@floor(y));
    if (check_validity and !validPos(floor_x, floor_y)) {
        @branchHint(.unlikely);
        return null;
    }

    const square = &squares[floor_y * info.width + floor_x];
    if (check_validity and (square.data_id == Square.empty_tile or square.data_id == Square.editor_tile))
        return null;

    return square;
}

pub fn addMoveRecord(allocator: std.mem.Allocator, time: i64, x: f32, y: f32) void {
    if (last_records_clear_time < 0)
        return;

    const id = getId(time);
    if (id < 1 or id > 10)
        return;

    if (move_records.items.len == 0) {
        move_records.append(allocator, .{ .time = time, .x = x, .y = y }) catch |e| std.log.err("Adding move record failed: {}", .{e});
        return;
    }

    const record_idx = move_records.items.len - 1;
    const curr_record = move_records.items[record_idx];
    const curr_id = getId(curr_record.time);
    if (id != curr_id) {
        move_records.append(allocator, .{ .time = time, .x = x, .y = y }) catch |e| std.log.err("Adding move record failed: {}", .{e});
        return;
    }

    const score = getScore(id, time);
    const curr_score = getScore(id, curr_record.time);
    if (score < curr_score) {
        move_records.items[record_idx].time = time;
        move_records.items[record_idx].x = x;
        move_records.items[record_idx].y = y;
    }
}

pub fn clearMoveRecords(time: i64) void {
    move_records.clearRetainingCapacity();
    last_records_clear_time = time;
}

fn getId(time: i64) i64 {
    return @divFloor(time - last_records_clear_time + 50, 100);
}

fn getScore(id: i64, time: i64) i64 {
    return @intCast(@abs(time - last_records_clear_time - id * 100));
}

pub fn takeDamage(
    self: anytype,
    damage: i32,
    conditions: utils.Condition,
    proj_colors: []const u32,
    ignore_def: bool,
    allocator: std.mem.Allocator,
) void {
    if (self.dead)
        return;

    if (damage >= self.hp) {
        self.dead = true;

        assets.playSfx(self.data.death_sound);
        particles.ExplosionEffect.addToMap(.{
            .x = self.x,
            .y = self.y,
            .colors = self.colors,
            .size = self.size_mult,
            .amount = 30,
        });
    } else {
        assets.playSfx(self.data.hit_sound);
        particles.HitEffect.addToMap(.{
            .x = self.x,
            .y = self.y,
            .colors = proj_colors,
            .angle = 0.0,
            .speed = 0.01,
            .size = 1.0,
            .amount = 3,
        });

        const cond_int: @typeInfo(utils.Condition).@"struct".backing_integer.? = @bitCast(conditions);
        for (0..@bitSizeOf(utils.Condition)) |i| {
            if (cond_int & (@as(usize, 1) << @intCast(i)) != 0) {
                const eff: utils.ConditionEnum = @enumFromInt(i + 1);
                const cond_str = eff.toString();
                if (cond_str.len == 0)
                    continue;

                self.condition.set(eff, true);

                element.StatusText.add(.{
                    .obj_type = switch (@TypeOf(self.*)) {
                        Entity => .entity,
                        Enemy => .enemy,
                        Player => .player,
                        else => @compileError("Invalid type"),
                    },
                    .map_id = self.map_id,
                    .text_data = .{
                        .text = std.fmt.allocPrint(allocator, "{s}", .{cond_str}) catch unreachable,
                        .text_type = .bold,
                        .size = 16,
                        .color = 0xB02020,
                    },
                    .initial_size = 16,
                }) catch |e| {
                    std.log.err("Allocation for condition text \"{s}\" failed: {}", .{ cond_str, e });
                };
            }
        }
    }

    if (damage > 0) {
        element.StatusText.add(.{
            .obj_type = switch (@TypeOf(self.*)) {
                Entity => .entity,
                Enemy => .enemy,
                Player => .player,
                else => @compileError("Invalid type"),
            },
            .map_id = self.map_id,
            .text_data = .{
                .text = std.fmt.allocPrint(allocator, "-{}", .{damage}) catch unreachable,
                .text_type = .bold,
                .size = 16,
                .color = if (ignore_def) 0x890AFF else 0xB02020,
            },
            .initial_size = 16,
        }) catch |e| {
            std.log.err("Allocation for damage text \"-{}\" failed: {}", .{ damage, e });
        };
    }
}
