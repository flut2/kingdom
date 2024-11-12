const std = @import("std");
const shared = @import("shared");
const utils = shared.utils;
const game_data = shared.game_data;

pub const StatValue = union(enum) {
    str: []const u8,
    b: bool,
    sbyte: i8,
    byte: u8,
    short: i16,
    ushort: u16,
    int: i32,
    uint: u32,
    float: f32,
    condition: utils.Condition,
};

pub fn write(
    comptime StatType: type,
    allocator: std.mem.Allocator,
    writer: *utils.PacketWriter,
    cache: *[@typeInfo(StatType).@"union".fields.len]?StatType,
    value: StatType,
) void {
    switch (value) {
        inline else => |inner_value, tag| {
            const T = @TypeOf(inner_value);
            const type_info = @typeInfo(T);
            const is_array = type_info == .array;
            const is_slice = type_info == .pointer and type_info.pointer.size == .Slice;
            const is_condition = T == utils.Condition;
            const cond_int = if (is_condition) type_info.@"struct".backing_integer.? else {};

            const tag_id = @intFromEnum(tag);
            if (cache[tag_id] != null and
                (is_array and std.mem.eql(type_info.array.child, @field(cache[tag_id].?, @tagName(tag)), inner_value) or
                is_slice and std.mem.eql(type_info.pointer.child, @field(cache[tag_id].?, @tagName(tag)), inner_value) or
                is_condition and @as(cond_int, @bitCast(@field(cache[tag_id].?, @tagName(tag)))) == @as(cond_int, @bitCast(inner_value)) or
                !is_condition and !is_array and !is_slice and @field(cache[tag_id].?, @tagName(tag)) == inner_value))
                return;

            writer.write(@intFromEnum(tag), allocator);
            writer.write(inner_value, allocator);

            if (cache[tag_id]) |*cache_field| {
                @field(cache_field.*, @tagName(tag)) = inner_value;
            } else cache[tag_id] = @unionInit(StatType, @tagName(tag), inner_value);
        },
    }
}
