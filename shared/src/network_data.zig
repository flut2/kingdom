const utils = @import("utils.zig");

pub const ClassQuests = extern struct {
    class_id: u16,
    quests_complete: u8,
};

// Be mindful of the values of these. Reusing values will require you to either wipe or migrate the database, else you'll end up with a disaster
pub const Rank = enum(u8) {
    default = 0,
    staff = 50,
    mod = 75,
    admin = 100,
};

pub const CharacterListData = struct {
    name: []const u8,
    token: u128,
    rank: Rank,
    next_char_id: u32,
    max_chars: u32,
    characters: []const CharacterData,
    servers: []const ServerData,
    class_quests: []const ClassQuests,
};

pub const CharacterData = struct {
    char_id: u32,
    class_id: u16,
    health: i32,
    mana: i32,
    attack: i32,
    defense: i32,
    speed: i32,
    dexterity: i32,
    vitality: i32,
    wisdom: i32,
    items: []const u16,
};

pub const ServerData = struct {
    name: []const u8,
    ip: []const u8,
    port: u16,
    max_players: u16,
    admin_only: bool,
};

pub const PlayerStat = union(enum) {
    x: f32,
    y: f32,
    size_mult: f32,
    stars: u8,
    name: []const u8,
    gold: i32,
    fame: i32,
    level: u8,
    exp: u32,
    hp: i32,
    mp: i32,
    max_hp: i32,
    max_mp: i32,
    attack: i16,
    defense: i16,
    speed: i16,
    dexterity: i16,
    vitality: i16,
    wisdom: i16,
    max_hp_bonus: i32,
    max_mp_bonus: i32,
    attack_bonus: i16,
    defense_bonus: i16,
    speed_bonus: i16,
    dexterity_bonus: i16,
    vitality_bonus: i16,
    wisdom_bonus: i16,
    condition: utils.Condition,
    muted_until: i64,
    inv_0: u16,
    inv_1: u16,
    inv_2: u16,
    inv_3: u16,
    inv_4: u16,
    inv_5: u16,
    inv_6: u16,
    inv_7: u16,
    inv_8: u16,
    inv_9: u16,
    inv_10: u16,
    inv_11: u16,
    inv_12: u16,
    inv_13: u16,
    inv_14: u16,
    inv_15: u16,
    inv_16: u16,
    inv_17: u16,
    inv_18: u16,
    inv_19: u16,
};

pub const EntityStat = union(enum) {
    x: f32,
    y: f32,
    size_mult: f32,
    name: []const u8,
    hp: i32,
};

pub const EnemyStat = union(enum) {
    x: f32,
    y: f32,
    size_mult: f32,
    name: []const u8,
    hp: i32,
    max_hp: i32,
    condition: utils.Condition,
};

pub const PortalStat = union(enum) {
    x: f32,
    y: f32,
    size_mult: f32,
    name: []const u8,
};

pub const ContainerStat = union(enum) {
    x: f32,
    y: f32,
    size_mult: f32,
    name: []const u8,
    inv_0: u16,
    inv_1: u16,
    inv_2: u16,
    inv_3: u16,
    inv_4: u16,
    inv_5: u16,
    inv_6: u16,
    inv_7: u16,
};

pub const TileData = packed struct {
    x: u16,
    y: u16,
    data_id: u16,
};

pub const TimedPosition = packed struct {
    time: i64,
    x: f32,
    y: f32,
};

pub const ObjectType = enum(u8) {
    player,
    entity,
    enemy,
    container,
    portal,
};

pub const ObjectData = struct {
    data_id: u16,
    map_id: u32,
    stats: []const u8,
};

pub const MapInfo = struct {
    width: u16 = 0,
    height: u16 = 0,
    name: []const u8 = "",
    bg_color: u32 = 0,
    bg_intensity: f32 = 0.0,
    day_intensity: f32 = 0.0,
    night_intensity: f32 = 0.0,
    server_time: i64 = 0,
};

// All packets without variable length fields (like slices) should be packed.
// This allows us to directly copy the struct into/from the buffer
pub const C2SPacket = union(enum) {
    player_projectile: packed struct { time: i64, proj_index: u8, x: f32, y: f32, angle: f32 },
    move: struct { tick_id: u8, time: i64, x: f32, y: f32, records: []const TimedPosition },
    player_text: struct { text: []const u8 },
    inv_swap: packed struct {
        time: i64,
        x: f32,
        y: f32,
        from_obj_type: ObjectType,
        from_map_id: u32,
        from_slot_id: u8,
        to_obj_type: ObjectType,
        to_map_id: u32,
        to_slot_id: u8,
    },
    use_item: packed struct { time: i64, obj_type: ObjectType, map_id: u32, slot_id: u8, x: f32, y: f32 },
    hello: struct {
        build_ver: []const u8,
        email: []const u8,
        token: u128,
        char_id: u32,
        class_id: u16,
    },
    inv_drop: packed struct { player_map_id: u32, slot_id: u8 },
    pong: packed struct { ping_time: i64, time: i64 },
    teleport: packed struct { player_map_id: u32 },
    use_portal: packed struct { portal_map_id: u32 },
    buy: packed struct { purchasable_map_id: u32 },
    ground_damage: packed struct { time: i64, x: f32, y: f32 },
    player_hit: packed struct { proj_index: u8, enemy_map_id: u32 },
    enemy_hit: packed struct { time: i64, proj_index: u8, enemy_map_id: u32, killed: bool },
    escape: packed struct {},
    map_hello: struct {
        build_ver: []const u8,
        email: []const u8,
        token: u128,
        char_id: u32,
        map: []const u8,
    },
};

pub const S2CPacket = union(enum) {
    self_map_id: packed struct { player_map_id: u32 },
    text: struct {
        name: []const u8,
        obj_type: ObjectType,
        map_id: u32,
        bubble_time: u8,
        recipient: []const u8,
        text: []const u8,
        name_color: u32,
        text_color: u32,
    },
    damage: packed struct {
        player_map_id: u32,
        effects: utils.Condition,
        amount: u16,
        ignore_def: bool,
    },
    new_data: struct {
        tick_id: u8,
        tiles: []const TileData,
        players: []const ObjectData,
        enemies: []const ObjectData,
        entities: []const ObjectData,
        portals: []const ObjectData,
        containers: []const ObjectData,
    },
    dropped_map_ids: struct {
        players: []const u32,
        enemies: []const u32,
        entities: []const u32,
        portals: []const u32,
        containers: []const u32,
    },
    notification: struct { obj_type: ObjectType, map_id: u32, message: []const u8, color: u32 },
    show_effect: packed struct {
        eff_type: enum(u8) {
            potion,
            teleport,
            stream,
            throw,
            area_blast,
            dead,
            trail,
            diffuse,
            flow,
            trap,
            lightning,
            concentrate,
            blast_wave,
            earthquake,
            flashing,
        },
        obj_type: ObjectType,
        map_id: u32,
        x1: f32,
        y1: f32,
        x2: f32,
        y2: f32,
        color: u32,
    },
    inv_result: packed struct { result: u8 },
    ping: packed struct { time: i64 },
    map_info: MapInfo,
    death: struct { killer_name: []const u8 },
    aoe: struct {
        x: f32,
        y: f32,
        radius: f32,
        damage: u16,
        eff: utils.Condition,
        duration: f32,
        orig_type: u8,
        color: u32,
    },
    ally_projectile: packed struct { proj_index: u8, player_map_id: u32, item_data_id: u16, angle: f32 },
    enemy_projectile: packed struct {
        enemy_map_id: u32,
        proj_index: u8,
        proj_data_id: u8,
        x: f32,
        y: f32,
        damage: i32,
        num_projs: u8,
        angle: f32,
        angle_incr: f32,
    },
    @"error": struct {
        type: enum {
            message_no_disconnect,
            message_with_disconnect,
            client_update_needed,
            force_close_game,
            invalid_teleport_target,
        },
        description: []const u8,
    },
};
