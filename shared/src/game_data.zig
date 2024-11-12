const std = @import("std");
const utils = @import("utils.zig");

pub var class: Maps(ClassData) = .{};
pub var container: Maps(ContainerData) = .{};
pub var enemy: Maps(EnemyData) = .{};
pub var entity: Maps(EntityData) = .{};
pub var ground: Maps(GroundData) = .{};
pub var item: Maps(ItemData) = .{};
pub var portal: Maps(PortalData) = .{};
pub var region: Maps(RegionData) = .{};

var arena: std.heap.ArenaAllocator = undefined;

pub fn Maps(comptime T: type) type {
    return struct {
        from_id: std.AutoHashMapUnmanaged(u16, T) = .{},
        from_name: std.HashMapUnmanaged([]const u8, T, StringContext, 80) = .{},
    };
}

fn parseClasses(allocator: std.mem.Allocator, path: []const u8) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_data = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(file_data);

    const json = try std.json.parseFromSlice([]InternalClassData, allocator, file_data, .{});
    defer json.deinit();

    for (json.value) |int_class| {
        const default_items: []u16 = try allocator.alloc(u16, int_class.default_items.len);
        for (default_items, 0..) |*default_item, i| {
            const item_name = int_class.default_items[i];
            if (item_name.len == 0) {
                default_item.* = std.math.maxInt(u16);
                continue;
            }
            default_item.* = (item.from_name.get(item_name) orelse @panic("Invalid item given to ClassData")).id;
        }

        const class_data: ClassData = .{
            .id = int_class.id,
            .name = try allocator.dupe(u8, int_class.name),
            .description = try allocator.dupe(u8, int_class.description),
            .texture = .{
                .sheet = try allocator.dupe(u8, int_class.texture.sheet),
                .index = int_class.texture.index,
            },
            .item_types = int_class.item_types,
            .default_items = default_items,
            .stats = int_class.stats,
            .hit_sound = try allocator.dupe(u8, int_class.hit_sound),
            .death_sound = try allocator.dupe(u8, int_class.death_sound),
            .rpc_name = try allocator.dupe(u8, int_class.rpc_name),
            .light = int_class.light,
        };
        try class.from_id.put(allocator, class_data.id, class_data);
        try class.from_name.put(allocator, class_data.name, class_data);
    }
}

fn parseGeneric(allocator: std.mem.Allocator, path: []const u8, comptime DataType: type, data_maps: *Maps(DataType)) !void {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const file_data = try file.readToEndAlloc(allocator, std.math.maxInt(u32));
    defer allocator.free(file_data);

    const data_slice = try std.json.parseFromSliceLeaky([]DataType, allocator, file_data, .{ .allocate = .alloc_always });
    for (data_slice) |data| {
        try data_maps.from_id.put(allocator, data.id, data);
        try data_maps.from_name.put(allocator, data.name, data);
    }
}

pub fn init(allocator: std.mem.Allocator) !void {
    defer {
        const dummy_id_ctx: std.hash_map.AutoContext(u16) = undefined;
        const dummy_name_ctx: StringContext = undefined;
        inline for (.{ &item, &container, &enemy, &entity, &ground, &portal, &region, &class }) |data_maps| {
            if (data_maps.from_id.capacity() > 0) data_maps.from_id.rehash(dummy_id_ctx);
            if (data_maps.from_name.capacity() > 0) data_maps.from_name.rehash(dummy_name_ctx);
        }
    }

    arena = std.heap.ArenaAllocator.init(allocator);
    const arena_allocator = arena.allocator();

    try parseGeneric(arena_allocator, "./assets/data/items.json", ItemData, &item);
    try parseGeneric(arena_allocator, "./assets/data/containers.json", ContainerData, &container);
    try parseGeneric(arena_allocator, "./assets/data/enemies.json", EnemyData, &enemy);
    try parseGeneric(arena_allocator, "./assets/data/entities.json", EntityData, &entity);
    try parseGeneric(arena_allocator, "./assets/data/ground.json", GroundData, &ground);
    try parseGeneric(arena_allocator, "./assets/data/portals.json", PortalData, &portal);
    try parseGeneric(arena_allocator, "./assets/data/regions.json", RegionData, &region);

    // Must be last to resolve item name->id
    try parseClasses(arena_allocator, "./assets/data/classes.json");
}

pub fn deinit() void {
    arena.deinit();
}

fn isNumberFormattedLikeAnInteger(value: []const u8) bool {
    if (std.mem.eql(u8, value, "-0")) return false;
    return std.mem.indexOfAny(u8, value, ".eE") == null;
}

fn sliceToInt(comptime T: type, slice: []const u8) !T {
    if (isNumberFormattedLikeAnInteger(slice))
        return std.fmt.parseInt(T, slice, 0);
    // Try to coerce a float to an integer.
    const float = try std.fmt.parseFloat(f128, slice);
    if (@round(float) != float) return error.InvalidNumber;
    if (float > std.math.maxInt(T) or float < std.math.minInt(T)) return error.Overflow;
    return @as(T, @intCast(@as(i128, @intFromFloat(float))));
}

fn freeAllocated(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |slice| {
            allocator.free(slice);
        },
        else => {},
    }
}

pub fn jsonParseWithHex(comptime T: type, allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!T {
    const struct_info = @typeInfo(T).@"struct";

    if (.object_begin != try source.next()) return error.UnexpectedToken;

    var r: T = undefined;
    var fields_seen = [_]bool{false} ** struct_info.fields.len;

    while (true) {
        var name_token: ?std.json.Token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
        const field_name = switch (name_token.?) {
            inline .string, .allocated_string => |slice| slice,
            .object_end => { // No more fields.
                break;
            },
            else => {
                return error.UnexpectedToken;
            },
        };

        inline for (struct_info.fields, 0..) |field, i| {
            if (field.is_comptime) @compileError("comptime fields are not supported: " ++ @typeName(LightData) ++ "." ++ field.name);
            if (std.mem.eql(u8, field.name, field_name)) {
                // Free the name token now in case we're using an allocator that optimizes freeing the last allocated object.
                // (Recursing into innerParse() might trigger more allocations.)
                freeAllocated(allocator, name_token.?);
                name_token = null;
                if (fields_seen[i]) {
                    switch (options.duplicate_field_behavior) {
                        .use_first => {
                            // Parse and ignore the redundant value.
                            // We don't want to skip the value, because we want type checking.
                            _ = try std.json.innerParse(field.type, allocator, source, options);
                            break;
                        },
                        .@"error" => return error.DuplicateField,
                        .use_last => {},
                    }
                }
                @field(r, field.name) = switch (@typeInfo(field.type)) {
                    .int, .comptime_int => blk: {
                        const token = try source.nextAllocMax(allocator, .alloc_if_needed, options.max_value_len.?);
                        defer freeAllocated(allocator, token);
                        const slice = switch (token) {
                            inline .number, .allocated_number, .string, .allocated_string => |slice| slice,
                            else => return error.UnexpectedToken,
                        };
                        break :blk try sliceToInt(field.type, slice);
                    },
                    else => try std.json.innerParse(field.type, allocator, source, options),
                };
                fields_seen[i] = true;
                break;
            }
        } else {
            // Didn't match anything.
            freeAllocated(allocator, name_token.?);
            if (options.ignore_unknown_fields) {
                try source.skipValue();
            } else {
                return error.UnknownField;
            }
        }
    }
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (!fields_seen[i]) {
            if (field.default_value) |default_ptr| {
                const default = @as(*align(1) const field.type, @ptrCast(default_ptr)).*;
                @field(r, field.name) = default;
            } else {
                return error.MissingField;
            }
        }
    }
    return r;
}

pub fn damage(dmg: i32, defense: i32, ignore_def: bool, condition: utils.Condition) i32 {
    if (dmg == 0 or condition.invulnerable)
        return 0;

    const def = if (ignore_def or condition.armor_broken)
        0
    else if (condition.armored)
        defense * 2
    else
        defense;

    return @max(@divFloor(dmg, 5), dmg - def);
}

pub fn expGoal(level: u8) u32 {
    return switch (level) {
        1 => 1000,
        2 => 1500,
        3 => 2500,
        4 => 4000,
        5 => 6000,
        6 => 8500,
        7 => 11500,
        8 => 15000,
        9 => 19000,
        10 => 23500,
        11 => 28500,
        12 => 34000,
        13 => 40000,
        14 => 46500,
        15 => 54500,
        16 => 62000,
        17 => 70000,
        18 => 80000,
        19 => 100000,
        else => 0,
    };
}

pub fn fameGoal(quests_complete: u8) u32 {
    return switch (quests_complete) {
        0 => 1000,
        1 => 5000,
        2 => 15000,
        3 => 45000,
        4 => 100000,
        else => 0,
    };
}

pub const StarType = enum {
    light_blue,
    blue,
    red,
    orange,
    yellow,
    white,

    pub fn fromCount(stars: u8) StarType {
        return @enumFromInt(@divFloor(stars, class.from_id.size));
    }

    pub fn toTextureData(self: StarType) TextureData {
        return switch (self) {
            .light_blue => .{ .sheet = "misc", .index = 21 },
            .blue => .{ .sheet = "misc", .index = 22 },
            .red => .{ .sheet = "misc", .index = 23 },
            .orange => .{ .sheet = "misc", .index = 24 },
            .yellow => .{ .sheet = "misc", .index = 25 },
            .white => .{ .sheet = "misc", .index = 26 },
        };
    }
};

pub const ItemType = enum {
    any,
    accessory,
    consumable,

    dagger,
    sword,
    bow,
    staff,
    wand,

    plate,
    leather,
    robe,

    spell,
    tome,
    cloak,
    quiver,
    helm,

    pub fn toString(self: ItemType) []const u8 {
        return switch (self) {
            .any => "Unknown",
            .accessory => "Accessory",
            .consumable => "Consumable",
            .dagger => "Dagger",
            .sword => "Sword",
            .bow => "Bow",
            .staff => "Staff",
            .wand => "Wand",
            .plate => "Plate",
            .leather => "Leather",
            .robe => "Robe",
            .spell => "Spell",
            .tome => "Tome",
            .cloak => "Cloak",
            .quiver => "Quiver",
            .helm => "Helm",
        };
    }

    pub fn typesMatch(self: ItemType, target: ItemType) bool {
        return self == target or self == .any or target == .any;
    }
};

pub const Currency = enum { gold, gems, crowns };

const AnimationData = struct {
    probability: f32 = 1.0,
    period: f32,
    period_jitter: f32 = 0.0,
    frames: []struct {
        time: f32,
        texture: TextureData,
    },
};

const TextureData = struct {
    sheet: []const u8,
    index: u16,
};

const LightData = struct {
    color: u32 = std.math.maxInt(u32),
    intensity: f32 = 0.0,
    radius: f32 = 1.0,
    pulse: f32 = 0.0,
    pulse_speed: f32 = 0.0,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!LightData {
        return jsonParseWithHex(LightData, allocator, source, options);
    }

    pub const jsonStringify = @compileError("Not supported");
};

const ClassStatDetails = struct {
    base: u16,
    max: u16,
    level_increase_min: i16,
    level_increase_max: i16,
};

const ClassStats = struct {
    health: ClassStatDetails,
    mana: ClassStatDetails,
    attack: ClassStatDetails,
    defense: ClassStatDetails,
    speed: ClassStatDetails,
    dexterity: ClassStatDetails,
    vitality: ClassStatDetails,
    wisdom: ClassStatDetails,
};

const InternalClassData = struct {
    id: u16,
    name: []const u8,
    description: []const u8,
    texture: TextureData,
    item_types: []const ItemType,
    default_items: []const []const u8,
    stats: ClassStats,
    hit_sound: []const u8 = "Unknown",
    death_sound: []const u8 = "Unknown",
    rpc_name: []const u8 = "Unknown",
    light: LightData = .{},
};

pub const ClassData = struct {
    id: u16,
    name: []const u8,
    description: []const u8,
    texture: TextureData,
    item_types: []const ItemType,
    default_items: []const u16,
    stats: ClassStats,
    hit_sound: []const u8,
    death_sound: []const u8,
    rpc_name: []const u8,
    light: LightData,
};

pub const ContainerData = struct {
    id: u16,
    name: []const u8,
    textures: []const TextureData,
    size_mult: f32 = 1.0,
    item_types: []const ItemType = &[_]ItemType{.any} ** 8,
    light: LightData = .{},
    show_name: bool = false,
    draw_on_ground: bool = false,
    animation: ?AnimationData = null,
};

pub const ProjectileData = struct {
    textures: []const TextureData,
    speed: f32,
    duration: f32,
    damage: i32,
    angle_correction: i8 = 0,
    size_mult: f32 = 1.0,
    rotation: f32 = 0.0,
    piercing: bool = false,
    boomerang: bool = false,
    amplitude: f32 = 0.0,
    frequency: f32 = 0.0,
    magnitude: f32 = 0.0,
    accel: f32 = 0.0,
    accel_delay: f32 = 0.0,
    speed_clamp: f32 = 0.0,
    angle_change: f32 = 0.0,
    angle_change_delay: f32 = 0,
    angle_change_end: f32 = 0,
    angle_change_accel: f32 = 0.0,
    angle_change_accel_delay: f32 = 0,
    angle_change_clamp: f32 = 0.0,
    zero_velocity_delay: f32 = 0,
    heat_seek_speed: f32 = 0.0,
    heat_seek_radius: f32 = 0.0,
    heat_seek_delay: f32 = 0,
    light: LightData = .{},
    conditions: ?[]const TimedCondition = null,
    ignore_def: bool = false,

    pub fn range(self: ProjectileData) f32 {
        return self.speed * self.duration * 10.0;
    }
};

pub const EnemyData = struct {
    id: u16,
    name: []const u8,
    texture: TextureData,
    health: u32 = 0, // Having no health means it can't be hit/die
    defense: i32 = 0,
    projectiles: ?[]const ProjectileData = null,
    size_mult: f32 = 1.0,
    light: LightData = .{},
    hit_sound: []const u8 = "Unknown",
    death_sound: []const u8 = "Unknown",
    show_name: bool = false,
    draw_on_ground: bool = false,
    exp_reward: u32 = 0,
};

pub const EntityData = struct {
    id: u16,
    name: []const u8,
    textures: []const TextureData,
    top_textures: ?[]const TextureData = null,
    health: i32 = 0, // Having no health means it can't be hit/die
    defense: i32 = 0,
    size_mult: f32 = 1.0,
    light: LightData = .{},
    draw_on_ground: bool = false,
    occupy_square: bool = false,
    full_occupy: bool = false,
    static: bool = true,
    is_wall: bool = false,
    show_name: bool = false,
    block_ground_damage: bool = false,
    block_sink: bool = false,
    hit_sound: []const u8 = "Unknown",
    death_sound: []const u8 = "Unknown",
    animation: ?AnimationData = null,
    exp_reward: u32 = 0,
};

pub const GroundData = struct {
    id: u16,
    name: []const u8,
    textures: []const TextureData,
    light: LightData = .{},
    animation: struct {
        type: enum { unset, flow, wave } = .unset,
        delta_x: f32 = 0.0,
        delta_y: f32 = 0.0,
    } = .{},
    sink: bool = false,
    push: bool = false,
    no_walk: bool = false,
    slide_amount: f32 = 0.0,
    speed_mult: f32 = 1.0,
    damage: i16 = 0,
    blend_prio: i16 = 0,
};

pub const StatIncreaseData = union(enum) {
    max_hp: u16,
    max_mp: u16,
    attack: u16,
    defense: u16,
    speed: u16,
    dexterity: u16,
    vitality: u16,
    wisdom: u16,

    pub fn toString(self: StatIncreaseData) []const u8 {
        return switch (self) {
            .max_hp => "Max HP",
            .max_mp => "Max MP",
            .attack => "Attack",
            .defense => "Defense",
            .speed => "Speed",
            .dexterity => "Dexterity",
            .vitality => "Vitality",
            .wisdom => "Wisdom",
        };
    }

    pub fn toControlCode(self: StatIncreaseData) []const u8 {
        return switch (self) {
            .max_hp => "&img=\"misc_big,2\"",
            .max_mp => "&img=\"misc_big,3\"",
            .attack => "&img=\"misc_big,4\"",
            .defense => "&img=\"misc_big,5\"",
            .speed => "&img=\"misc_big,6\"",
            .dexterity => "&img=\"misc_big,7\"",
            .vitality => "&img=\"misc_big,8\"",
            .wisdom => "&img=\"misc_big,9\"",
        };
    }

    pub fn amount(self: StatIncreaseData) u16 {
        return switch (self) {
            inline else => |inner| inner,
        };
    }
};

pub const TimedCondition = struct {
    type: utils.ConditionEnum,
    duration: f32,
};

pub const ActivationData = union(enum) {
    increment_stat: StatIncreaseData,
    heal: i32,
    magic: i32,
    create_entity: []const u8,
    create_enemy: []const u8,
    create_portal: []const u8,
    heal_nova: struct { amount: i32, radius: f32 },
    magic_nova: struct { amount: i32, radius: f32 },
    stat_boost_self: struct { stat_incr: StatIncreaseData, amount: i16, duration: f32 },
    stat_boost_aura: struct { stat_incr: StatIncreaseData, amount: i16, duration: f32, radius: f32 },
    condition_effect_self: TimedCondition,
    condition_effect_aura: struct { cond: TimedCondition, radius: f32 },
    teleport: void,
    spell: struct { projectile_count: u8, arc_gap: f32, projectile: ProjectileData },
};

pub const ItemData = struct {
    id: u16,
    name: []const u8,
    description: []const u8 = "",
    item_type: ItemType,
    rarity: []const u8 = "Common",
    texture: TextureData,
    fire_rate: f32 = 1.0,
    projectile_count: u8 = 1,
    projectile: ?ProjectileData = null,
    stat_increases: ?[]const StatIncreaseData = null,
    activations: ?[]const ActivationData = null,
    arc_gap: f32 = 5.0,
    mana_cost: i32 = 0,
    health_cost: i32 = 0,
    cooldown: f32 = 0.0,
    consumable: bool = false,
    untradeable: bool = false,
    bag_type: enum { brown, purple, blue, white } = .brown,
    sound: []const u8 = "Unknown",
};

pub const PortalData = struct {
    id: u16,
    name: []const u8,
    textures: []const TextureData,
    draw_on_ground: bool = false,
    light: LightData = .{},
    size_mult: f32 = 1.0,
    show_name: bool = true,
    animation: ?AnimationData = null,
};

pub const RegionData = struct {
    id: u16,
    name: []const u8,
    color: u32,

    pub fn jsonParse(allocator: std.mem.Allocator, source: anytype, options: std.json.ParseOptions) std.json.ParseError(@TypeOf(source.*))!RegionData {
        return jsonParseWithHex(RegionData, allocator, source, options);
    }

    pub const jsonStringify = @compileError("Not supported");
};

pub const StringContext = struct {
    pub fn hash(_: @This(), s: []const u8) u64 {
        var buf: [1024]u8 = undefined; // bad
        return std.hash.Wyhash.hash(0, std.ascii.lowerString(&buf, s));
    }

    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        if (a.len != b.len) return false;
        if (a.len == 0 or a.ptr == b.ptr) return true;

        for (a, b) |a_elem, b_elem| {
            if (a_elem != b_elem and a_elem != std.ascii.toLower(b_elem)) return false;
        }
        return true;
    }
};
