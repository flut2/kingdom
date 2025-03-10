const std = @import("std");
const c = @cImport({
    @cInclude("sys/ioctl.h");
});

pub extern "c" fn getpid() std.posix.pid_t;

pub const Stream = std.net.Stream;

pub fn peek(stream: Stream) !bool {
    var bytes_available: i32 = undefined;
    //TODO: clean once https://github.com/ziglang/zig/issues/16197 is closed
    const ret: std.posix.E = @enumFromInt(std.c.ioctl(stream.handle, c.FIONREAD, @as(usize, @intFromPtr(&bytes_available))));
    switch (ret) {
        .BADF => return error.BadFileDescriptor,
        .FAULT => unreachable,
        .INVAL => return error.InvalidRequest,
        .NOTTY => unreachable,
        .SUCCESS => {},
        else => unreachable,
    }

    return bytes_available != 0;
}
