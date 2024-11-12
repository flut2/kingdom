const std = @import("std");
const gen_behaviors = @import("../_gen_behavior_file_dont_use.zig");
const behavs_len = @import("options").behavs_len;
const shared = @import("shared");
const utils = shared.utils;
const game_data = shared.game_data;

const Entity = @import("../map/entity.zig").Entity;
const Enemy = @import("../map/enemy.zig").Enemy;

const BehaviorType = enum { entity, enemy };
pub const BehaviorMetadata = struct {
    type: BehaviorType,
    name: []const u8,
};

fn getMetadata(comptime T: type) BehaviorMetadata {
    comptime {
        var ret: BehaviorMetadata = undefined;
        var found_metadata = false;
        for (@typeInfo(T).@"struct".decls) |decl| {
            const metadata = @field(T, decl.name);
            const is_metadata = @TypeOf(metadata) == BehaviorMetadata;
            if (!is_metadata)
                continue;

            if (found_metadata)
                @compileError("Duplicate behavior metadata");

            ret = metadata;
            found_metadata = true;
        }

        if (!found_metadata)
            @compileError("No behavior metadata found");

        return ret;
    }
}

fn BehaviorVtable(comptime ChildType: type) type {
    return struct {
        spawn: ?*const fn (self: *ChildType) anyerror!void = null,
        death: ?*const fn (self: *ChildType) anyerror!void = null,
        entry: ?*const fn (self: *ChildType) anyerror!void = null,
        exit: ?*const fn (self: *ChildType) anyerror!void = null,
        tick: ?*const fn (self: *ChildType, time: i64, dt: i64) anyerror!void = null,
    };
}

pub const EntityBehavior = BehaviorVtable(Entity);
pub const EnemyBehavior = BehaviorVtable(Enemy);

pub var entity_behavior_map: std.AutoHashMapUnmanaged(u16, EntityBehavior) = .{};
pub var enemy_behavior_map: std.AutoHashMapUnmanaged(u16, EnemyBehavior) = .{};

pub fn init(allocator: std.mem.Allocator) !void {
    inline for (0..behavs_len) |i| {
        const import = @field(gen_behaviors, std.fmt.comptimePrint("b{}", .{i}));
        inline for (@typeInfo(import).@"struct".decls) |d| @"continue": {
            const behav = @field(import, d.name);
            const metadata = comptime getMetadata(behav);
            const id = (switch (metadata.type) {
                .entity => game_data.entity.from_name.get(metadata.name),
                .enemy => game_data.enemy.from_name.get(metadata.name),
            } orelse {
                std.log.err("Adding behavior for \"{s}\" failed: object not found", .{metadata.name});
                break :@"continue";
            }).id;

            const res = try switch (metadata.type) {
                .entity => entity_behavior_map.getOrPut(allocator, id),
                .enemy => enemy_behavior_map.getOrPut(allocator, id),
            };
            if (res.found_existing)
                std.log.err("The struct \"{s}\" overwrote the behavior for the object \"{s}\"", .{ @typeName(behav), metadata.name });

            res.value_ptr.* = .{
                .spawn = if (std.meta.hasFn(behav, "spawn")) behav.spawn else null,
                .death = if (std.meta.hasFn(behav, "death")) behav.death else null,
                .entry = if (std.meta.hasFn(behav, "entry")) behav.entry else null,
                .exit = if (std.meta.hasFn(behav, "exit")) behav.exit else null,
                .tick = if (std.meta.hasFn(behav, "tick")) behav.tick else null,
            };
        }
    }
}

pub fn deinit(allocator: std.mem.Allocator) void {
    entity_behavior_map.deinit(allocator);
    enemy_behavior_map.deinit(allocator);
}
