const std = @import("std");
const element = @import("../element.zig");
const tooltip = @import("tooltip.zig");

pub const NoneTooltip = struct {
    root: *element.Container = undefined,

    pub fn init(self: *NoneTooltip, allocator: std.mem.Allocator) !void {
        self.root = try element.create(allocator, element.Container{
            .visible = false,
            .layer = .tooltip,
            .x = 0,
            .y = 0,
        });
    }

    pub fn deinit(self: *NoneTooltip) void {
        element.destroy(self.root);
    }

    pub fn update(_: *NoneTooltip, _: tooltip.ParamsFor(NoneTooltip)) void {}
};
