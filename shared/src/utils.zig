const std = @import("std");
const builtin = @import("builtin");
const game_data = @import("game_data.zig");

// Big endian isn't supported on this
pub const PacketWriter = struct {
    list: std.ArrayListUnmanaged(u8) = .{},

    pub fn writeLength(self: *PacketWriter, allocator: std.mem.Allocator) void {
        self.list.appendSlice(allocator, &.{ 0, 0 }) catch unreachable;
    }

    pub fn updateLength(self: *PacketWriter) void {
        const buf = self.list.items[0..2];
        const len: u16 = @intCast(self.list.items.len - 2);
        @memcpy(buf, std.mem.asBytes(&len));
    }

    pub fn write(self: *PacketWriter, value: anytype, allocator: std.mem.Allocator) void {
        const T = @TypeOf(value);
        const type_info = @typeInfo(T);

        if (type_info == .pointer and (type_info.pointer.size == .Slice or type_info.pointer.size == .Many)) {
            self.write(@as(u16, @intCast(value.len)), allocator);
            for (value) |val|
                self.write(val, allocator);
            return;
        }

        if (type_info == .array) {
            self.write(@as(u16, @intCast(value.len)), allocator);
            for (value) |val|
                self.write(val, allocator);
            return;
        }

        const value_bytes = std.mem.asBytes(&value);

        if (type_info == .@"struct") {
            switch (type_info.@"struct".layout) {
                .auto, .@"extern" => {
                    inline for (type_info.@"struct".fields) |field| {
                        self.write(@field(value, field.name), allocator);
                    }
                    return;
                },
                .@"packed" => {}, // will be handled below, packed structs are just ints
            }
        }

        self.list.appendSlice(allocator, value_bytes) catch unreachable;
    }
};

// Big endian isn't supported on this
pub const PacketReader = struct {
    index: u16 = 0,
    buffer: []const u8 = undefined,

    // Arrays and slices are allocated. Using an arena allocator is recommended
    pub fn read(self: *PacketReader, comptime T: type, allocator: std.mem.Allocator) T {
        const type_info = @typeInfo(T);
        if (type_info == .pointer or type_info == .array) {
            const ChildType = if (type_info == .array) type_info.array.child else type_info.pointer.child;
            const len = self.read(u16, allocator);
            var ret = allocator.alloc(ChildType, len) catch unreachable;
            for (0..len) |i| {
                ret[i] = self.read(ChildType, allocator);
            }

            return ret;
        }

        if (type_info == .@"struct") {
            switch (type_info.@"struct".layout) {
                .auto, .@"extern" => {
                    var value: T = undefined;
                    inline for (type_info.@"struct".fields) |field| {
                        @field(value, field.name) = self.read(field.type, allocator);
                    }
                    return value;
                },
                .@"packed" => {}, // will be handled below, packed structs are just ints
            }
        }

        const byte_size = @sizeOf(T);
        const next_idx = self.index + byte_size;
        if (next_idx > self.buffer.len)
            std.debug.panic("Buffer attempted to read out of bounds", .{});
        var buf = self.buffer[self.index..next_idx];
        self.index += byte_size;
        return std.mem.bytesToValue(T, buf[0..byte_size]);
    }
};

pub const ConditionEnum = enum {
    weak,
    slowed,
    sick,
    speedy,
    bleeding,
    healing,
    damaging,
    invulnerable,
    armored,
    armor_broken,
    hidden,
    targeted,
    invisible,
    max_hp_boost,
    max_mp_boost,
    attack_boost,
    defense_boost,
    speed_boost,
    dexterity_boost,
    vitality_boost,
    wisdom_boost,

    pub fn toString(self: ConditionEnum) []const u8 {
        return switch (self) {
            .weak => "Weak",
            .slowed => "Slowed",
            .sick => "Sick",
            .speedy => "Speedy",
            .bleeding => "Bleeding",
            .healing => "Healing",
            .damaging => "Damaging",
            .invulnerable => "Invulnerable",
            .armored => "Armored",
            .armor_broken => "Armor Broken",
            .hidden => "Hidden",
            .targeted => "Targeted",
            .invisible => "Invisible",
            .max_hp_boost => "HP Boost",
            .max_mp_boost => "MP Boost",
            .attack_boost => "Attack Boost",
            .defense_boost => "Defense Boost",
            .speed_boost => "Speed Boost",
            .dexterity_boost => "Dexterity Boost",
            .vitality_boost => "Vitality Boost",
            .wisdom_boost => "Wisdom Boost",
        };
    }
};

pub const Condition = packed struct {
    comptime {
        const struct_fields = @typeInfo(Condition).@"struct".fields;
        const enum_fields = @typeInfo(ConditionEnum).@"enum".fields;
        if (struct_fields.len != enum_fields.len)
            @compileError("utils.Condition and utils.ConditionEnum's field lengths don't match");

        for (struct_fields, enum_fields) |struct_field, enum_field| {
            if (!std.mem.eql(u8, struct_field.name, enum_field.name))
                @compileError("utils.Condition and utils.ConditionEnum have differing field names: utils.Condition=" ++
                    struct_field.name ++ ", utils.ConditionEnum=" ++ enum_field.name);
        }
    }

    weak: bool = false,
    slowed: bool = false,
    sick: bool = false,
    speedy: bool = false,
    bleeding: bool = false,
    healing: bool = false,
    damaging: bool = false,
    invulnerable: bool = false,
    armored: bool = false,
    armor_broken: bool = false,
    hidden: bool = false,
    targeted: bool = false,
    invisible: bool = false,
    max_hp_boost: bool = false,
    max_mp_boost: bool = false,
    attack_boost: bool = false,
    defense_boost: bool = false,
    speed_boost: bool = false,
    dexterity_boost: bool = false,
    vitality_boost: bool = false,
    wisdom_boost: bool = false,

    pub fn fromCondSlice(slice: ?[]const game_data.TimedCondition) Condition {
        if (slice == null)
            return .{};

        var ret: Condition = .{};
        for (slice.?) |cond| {
            ret.set(cond.type, true);
        }
        return ret;
    }

    pub fn set(self: *Condition, cond: ConditionEnum, value: bool) void {
        switch (cond) {
            inline else => |tag| @field(self, @tagName(tag)) = value,
        }
    }

    pub fn get(self: *Condition, cond: ConditionEnum) bool {
        return switch (cond) {
            inline else => |tag| @field(self, @tagName(tag)),
        };
    }

    pub fn toggle(self: *Condition, cond: ConditionEnum) void {
        switch (cond) {
            inline else => |tag| @field(self, @tagName(tag)) = !@field(self, @tagName(tag)),
        }
    }
};

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32, w_pad: f32, h_pad: f32 };

pub var rng = std.Random.DefaultPrng.init(0);

var last_memory_access: i64 = -1;
var last_memory_value: f32 = -1.0;

pub fn typeId(comptime T: type) u32 {
    return @intFromError(@field(anyerror, @typeName(T)));
}

pub fn currentMemoryUse(time: i64) !f32 {
    if (time - last_memory_access < 5 * std.time.us_per_s)
        return last_memory_value;

    var memory_value: f32 = -1.0;
    switch (builtin.os.tag) {
        .windows => {
            const mem_info = try std.os.windows.GetProcessMemoryInfo(std.os.windows.self_process_handle);
            memory_value = @as(f32, @floatFromInt(mem_info.WorkingSetSize)) / 1024.0 / 1024.0;
        },
        .linux => {
            const file = try std.fs.cwd().openFile("/proc/self/statm", .{});
            defer file.close();

            var buf: [1024]u8 = undefined;
            const size = try file.readAll(&buf);

            var split_iter = std.mem.splitScalar(u8, buf[0..size], ' ');
            _ = split_iter.next(); // total size
            const rss: f32 = @floatFromInt(try std.fmt.parseInt(u32, split_iter.next().?, 0));
            memory_value = rss / 1024.0;
        },
        else => memory_value = 0,
    }

    last_memory_access = time;
    last_memory_value = memory_value;
    return memory_value;
}

pub fn toRoman(int: u12) []const u8 {
    if (int > 3999)
        return "Invalid";

    const value = [_]u12{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
    const roman = [_][]const u8{ "M", "CM", "D", "CD", "C", "XC", "L", "XL", "X", "IX", "V", "IV", "I" };

    var buf: [32]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    var num = int;
    for (0..value.len) |i| {
        while (num >= value[i]) {
            num -= value[i];
            stream.writer().writeAll(roman[i]) catch continue;
        }
    }

    return buf[0..stream.pos];
}

pub fn nextPowerOfTwo(value: u16) u16 {
    var mod_value = value - 1;
    mod_value |= mod_value >> 1;
    mod_value |= mod_value >> 2;
    mod_value |= mod_value >> 4;
    mod_value |= mod_value >> 8;
    return mod_value + 1;
}

pub fn plusMinus(range: f32) f32 {
    return rng.random().float(f32) * range * 2 - range;
}

pub fn isInBounds(x: f32, y: f32, bound_x: f32, bound_y: f32, bound_w: f32, bound_h: f32) bool {
    return x >= bound_x and x <= bound_x + bound_w and y >= bound_y and y <= bound_y + bound_h;
}

pub fn halfBound(angle: f32) f32 {
    const mod_angle = @mod(angle, std.math.tau);
    const new_angle = @mod(mod_angle + std.math.tau, std.math.tau);
    return if (new_angle > std.math.pi) new_angle - std.math.tau else new_angle;
}

pub fn distSqr(x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    const x_dt = x2 - x1;
    const y_dt = y2 - y1;
    return x_dt * x_dt + y_dt * y_dt;
}

pub fn dist(x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    return @sqrt(distSqr(x1, y1, x2, y2));
}
