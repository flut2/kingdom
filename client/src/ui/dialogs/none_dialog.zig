const std = @import("std");
const element = @import("../element.zig");
const dialog = @import("dialog.zig");

pub const NoneDialog = struct {
    root: *element.Container = undefined,

    pub fn init(self: *NoneDialog, allocator: std.mem.Allocator) !void {
        self.root = try element.create(allocator, element.Container{
            .visible = false,
            .layer = .dialog,
            .x = 0,
            .y = 0,
        });
    }

    pub fn deinit(self: *NoneDialog) void {
        element.destroy(self.root);
    }

    pub fn setValues(_: *NoneDialog, _: dialog.ParamsFor(NoneDialog)) void {}
};
