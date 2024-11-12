const std = @import("std");
const element = @import("../element.zig");
const game_data = @import("shared").game_data;

const NoneTooltip = @import("none_tooltip.zig").NoneTooltip;
const ItemTooltip = @import("item_tooltip.zig").ItemTooltip;
const TextTooltip = @import("text_tooltip.zig").TextTooltip;

pub const TooltipType = enum {
    none,
    item,
    text,
};
pub const Tooltip = union(TooltipType) {
    none: NoneTooltip,
    item: ItemTooltip,
    text: TextTooltip,
};
pub const TooltipParams = union(TooltipType) {
    none: void,
    item: struct { x: f32, y: f32, item: u16 },
    text: struct { x: f32, y: f32, text_data: element.TextData },
};

pub var map: std.AutoHashMapUnmanaged(TooltipType, *Tooltip) = .{};
pub var current: *Tooltip = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    defer {
        const dummy_tooltip_ctx: std.hash_map.AutoContext(TooltipType) = undefined;
        if (map.capacity() > 0) map.rehash(dummy_tooltip_ctx);
    }

    inline for (@typeInfo(Tooltip).@"union".fields) |field| {
        var tooltip = try allocator.create(Tooltip);
        tooltip.* = @unionInit(Tooltip, field.name, .{});
        try @field(tooltip, field.name).init(allocator);
        try map.put(allocator, std.meta.stringToEnum(TooltipType, field.name) orelse
            std.debug.panic("No enum type with name {s} found on TooltipType", .{field.name}), tooltip);
    }

    current = map.get(.none).?;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    var iter = map.valueIterator();
    while (iter.next()) |value| {
        switch (value.*.*) {
            inline else => |*tooltip| {
                tooltip.deinit();
            },
        }

        allocator.destroy(value.*);
    }

    map.deinit(allocator);
}

fn fieldName(comptime T: type) []const u8 {
    if (!@inComptime())
        @compileError("This function is comptime only");

    var field_name: []const u8 = "";
    for (@typeInfo(Tooltip).@"union".fields) |field| {
        if (field.type == T)
            field_name = field.name;
    }

    if (field_name.len <= 0)
        @compileError("No params found");

    return field_name;
}

pub fn ParamsFor(comptime T: type) type {
    return std.meta.TagPayloadByName(TooltipParams, fieldName(T));
}

pub fn switchTooltip(comptime tooltip_type: TooltipType, params: std.meta.TagPayload(TooltipParams, tooltip_type)) void {
    if (std.meta.activeTag(current.*) == tooltip_type)
        return;

    switch (current.*) {
        inline else => |tooltip| {
            tooltip.root.visible = false;
        },
    }

    current = map.get(tooltip_type) orelse blk: {
        std.log.err("Tooltip for {} was not found, using .none", .{tooltip_type});
        break :blk map.get(.none) orelse std.debug.panic(".none was not a valid tooltip", .{});
    };

    const T = std.meta.TagPayload(Tooltip, tooltip_type);
    const field_name = comptime fieldName(T);
    @field(current, field_name).root.visible = true;
    @field(current, field_name).update(params);
}
