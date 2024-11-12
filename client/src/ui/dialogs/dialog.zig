const std = @import("std");
const element = @import("../element.zig");
const game_data = @import("shared").game_data;
const camera = @import("../../camera.zig");
const assets = @import("../../assets.zig");

const NineSlice = element.NineSliceImageData;

const NoneDialog = @import("none_dialog.zig").NoneDialog;
const TextDialog = @import("text_dialog.zig").TextDialog;

pub const DialogType = enum {
    none,
    text,
};
pub const Dialog = union(DialogType) {
    none: NoneDialog,
    text: TextDialog,
};
pub const DialogParams = union(DialogType) {
    none: void,
    text: struct { title: ?[]const u8 = null, body: []const u8, dispose_title: bool = false, dispose_body: bool = false },
};

pub var map: std.AutoHashMapUnmanaged(DialogType, *Dialog) = .{};
pub var dialog_bg: *element.Image = undefined;
pub var current: *Dialog = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    defer {
        const dummy_dialog_ctx: std.hash_map.AutoContext(DialogType) = undefined;
        if (map.capacity() > 0) map.rehash(dummy_dialog_ctx);
    }

    const background_data = assets.getUiData("options_background", 0);
    dialog_bg = try element.create(allocator, element.Image{
        .x = 0,
        .y = 0,
        .image_data = .{
            .nine_slice = NineSlice.fromAtlasData(background_data, camera.screen_width, camera.screen_height, 0, 0, 8, 8, 1.0),
        },
        .visible = false,
        .layer = .dialog,
    });

    inline for (@typeInfo(Dialog).@"union".fields) |field| {
        var dialog = try allocator.create(Dialog);
        dialog.* = @unionInit(Dialog, field.name, .{});
        try @field(dialog, field.name).init(allocator);
        try map.put(allocator, std.meta.stringToEnum(DialogType, field.name) orelse
            std.debug.panic("No enum type with name {s} found on DialogType", .{field.name}), dialog);
    }

    current = map.get(.none).?;
}

pub fn deinit(allocator: std.mem.Allocator) void {
    var iter = map.valueIterator();
    while (iter.next()) |value| {
        switch (value.*.*) {
            inline else => |*dialog| {
                dialog.deinit();
            },
        }

        allocator.destroy(value.*);
    }

    map.deinit(allocator);

    element.destroy(dialog_bg);
}

pub fn resize(w: f32, h: f32) void {
    dialog_bg.image_data.nine_slice.w = w;
    dialog_bg.image_data.nine_slice.h = h;

    switch (current.*) {
        inline else => |dialog| {
            dialog.root.x = (w - dialog.root.width()) / 2.0;
            dialog.root.y = (h - dialog.root.height()) / 2.0;
        },
    }
}

fn fieldName(comptime T: type) []const u8 {
    if (!@inComptime())
        @compileError("This function is comptime only");

    var field_name: []const u8 = "";
    for (@typeInfo(Dialog).@"union".fields) |field| {
        if (field.type == T)
            field_name = field.name;
    }

    if (field_name.len <= 0)
        @compileError("No params found");

    return field_name;
}

pub fn ParamsFor(comptime T: type) type {
    return std.meta.TagPayloadByName(DialogParams, fieldName(T));
}

pub fn showDialog(comptime dialog_type: DialogType, params: std.meta.TagPayload(DialogParams, dialog_type)) void {
    switch (current.*) {
        inline else => |dialog| dialog.root.visible = false,
    }

    dialog_bg.visible = dialog_type != .none;
    if (current.* != dialog_type) {
        current = map.get(dialog_type) orelse blk: {
            std.log.err("Dialog for {} was not found, using .none", .{dialog_type});
            break :blk map.get(.none) orelse std.debug.panic(".none was not a valid dialog", .{});
        };
    }

    const field_name = comptime fieldName(std.meta.TagPayload(Dialog, dialog_type));
    @field(current, field_name).root.visible = true;
    @field(current, field_name).setValues(params);
    @field(current, field_name).root.x = (camera.screen_width - @field(current, field_name).root.width()) / 2.0;
    @field(current, field_name).root.y = (camera.screen_height - @field(current, field_name).root.height()) / 2.0;
}
