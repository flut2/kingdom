const std = @import("std");

pub const EmptyScreen = struct {
    allocator: std.mem.Allocator,
    inited: bool = false,

    pub fn init(allocator: std.mem.Allocator) !*EmptyScreen {
        const screen = try allocator.create(EmptyScreen);
        screen.* = .{ .allocator = allocator, .inited = true };
        return screen;
    }

    pub fn deinit(self: *EmptyScreen) void {
        self.inited = false;

        self.allocator.destroy(self);
    }

    pub fn resize(_: *EmptyScreen, _: f32, _: f32) void {}
    pub fn update(_: *EmptyScreen, _: i64, _: f32) !void {}
};
