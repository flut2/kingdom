const std = @import("std");
const builtin = @import("builtin");

const build_options = @import("options");
const rpmalloc = @import("rpmalloc");
const shared = @import("shared");
const game_data = shared.game_data;
const utils = shared.utils;
const uv = shared.uv;

const Client = @import("client.zig").Client;
const db = @import("db.zig");
const behavior = @import("logic/behavior.zig");
const behavior_logic = @import("logic/logic.zig");
const login = @import("login.zig");
const maps = @import("map/maps.zig");
const settings = @import("settings.zig");

const tracy = if (build_options.enable_tracy) @import("tracy") else {};
pub const c = @cImport({
    @cDefine("REDIS_OPT_NONBLOCK", {});
    @cDefine("REDIS_OPT_REUSEADDR", {});
    @cInclude("hiredis.h");
});

pub const tps_ms = 1000 / settings.tps;

pub const read_buffer_size = 65535;
pub const write_buffer_size = 65535;

pub var client_pool: std.heap.MemoryPool(Client) = undefined;
pub var socket_pool: std.heap.MemoryPool(uv.uv_tcp_t) = undefined;
pub var game_timer: uv.uv_timer_t = undefined;
pub var allocator: std.mem.Allocator = undefined;
pub var login_thread: std.Thread = undefined;
pub var game_thread: std.Thread = undefined;
pub var tick_id: u8 = 0;
pub var current_time: i64 = -1;

export fn timerCallback(_: [*c]uv.uv_timer_t) void {
    tick_id +%= 1;
    const time = std.time.microTimestamp();
    defer current_time = time;
    const dt = if (current_time == -1) 0 else time - current_time;
    var iter = maps.worlds.iterator();
    while (iter.next()) |entry| entry.value_ptr.tick(time, dt) catch unreachable;
}

pub fn gameTick() !void {
    if (build_options.enable_tracy) tracy.SetThreadName("Game");

    if (builtin.mode != .Debug) {
        rpmalloc.initThread();
        defer rpmalloc.deinitThread();
    }

    const timer_init_status = uv.uv_timer_init(uv.uv_default_loop(), @ptrCast(&game_timer));
    if (timer_init_status != 0)
        std.debug.panic("Timer init failed: {s}", .{uv.uv_strerror(timer_init_status)});
    const timer_start_status = uv.uv_timer_start(@ptrCast(&game_timer), timerCallback, 0, tps_ms);
    if (timer_start_status != 0)
        std.debug.panic("Timer start failed: {s}", .{uv.uv_strerror(timer_start_status)});

    var server: uv.uv_tcp_t = .{};
    const accept_socket_status = uv.uv_tcp_init(uv.uv_default_loop(), @ptrCast(&server));
    if (accept_socket_status != 0)
        std.debug.panic("Setting up accept socket failed: {s}", .{uv.uv_strerror(accept_socket_status)});

    const addr = try std.net.Address.parseIp4("0.0.0.0", settings.game_port);
    const socket_bind_status = uv.uv_tcp_bind(@ptrCast(&server), @ptrCast(&addr.in.sa), 0);
    if (socket_bind_status != 0)
        std.debug.panic("Setting up socket bind failed: {s}", .{uv.uv_strerror(socket_bind_status)});

    const listen_result = uv.uv_listen(@ptrCast(&server), switch (builtin.os.tag) {
        .windows => std.os.windows.ws2_32.SOMAXCONN,
        .macos, .ios, .tvos, .watchos, .linux => std.os.linux.SOMAXCONN,
        else => @panic("Host OS not supported"),
    }, onAccept);
    if (listen_result != 0)
        std.debug.panic("Listen error: {s}", .{uv.uv_strerror(listen_result)});

    const run_status = uv.uv_run(uv.uv_default_loop(), uv.UV_RUN_DEFAULT);
    if (run_status != 0 and run_status != 1)
        std.log.err("Run failed: {s}", .{uv.uv_strerror(socket_bind_status)});
}

export fn onAccept(server: [*c]uv.uv_stream_t, status: i32) void {
    if (status < 0) {
        std.log.err("New connection error: {s}", .{uv.uv_strerror(status)});
        return;
    }

    const socket = socket_pool.create() catch unreachable;
    const init_recv_status = uv.uv_tcp_init(uv.uv_default_loop(), @ptrCast(socket));
    if (init_recv_status != 0) {
        std.log.err("Failed to initialize received socket: {s}", .{uv.uv_strerror(init_recv_status)});
        uv.uv_close(@ptrCast(socket), onSocketClose);
        return;
    }

    const accept_status = uv.uv_accept(server, @ptrCast(socket));
    if (accept_status != 0) {
        std.log.err("Failed to accept socket: {s}", .{uv.uv_strerror(accept_status)});
        uv.uv_close(@ptrCast(socket), onSocketClose);
        return;
    }

    const cli = client_pool.create() catch unreachable;
    socket.*.data = cli;
    cli.* = .{ .arena = std.heap.ArenaAllocator.init(allocator), .socket = socket };

    const read_init_status = uv.uv_read_start(@ptrCast(socket), Client.allocBuffer, Client.readCallback);
    if (read_init_status != 0) {
        std.log.err("Failed to initialize reading on socket: {s}", .{uv.uv_strerror(read_init_status)});
        cli.sameThreadShutdown();
        return;
    }
}

export fn onSocketClose(handle: [*c]uv.uv_handle_t) void {
    socket_pool.destroy(@ptrCast(@alignCast(handle)));
}

pub fn main() !void {
    if (build_options.enable_tracy) tracy.SetThreadName("Main");

    utils.rng.seed(@intCast(std.time.microTimestamp()));

    const is_debug = builtin.mode == .Debug;
    var gpa = if (is_debug) std.heap.GeneralPurposeAllocator(.{}){} else {};
    defer _ = if (is_debug) gpa.deinit();

    if (!is_debug) {
        rpmalloc.init(.{}, .{});
        defer rpmalloc.deinit();
    }

    const child_allocator = if (is_debug) gpa.allocator() else rpmalloc.allocator();
    allocator = if (build_options.enable_tracy) blk: {
        var tracy_alloc = tracy.TracyAllocator.init(child_allocator);
        break :blk tracy_alloc.allocator();
    } else child_allocator;

    behavior_logic.allocator = allocator;

    try game_data.init(allocator);
    defer game_data.deinit();

    try behavior.init(allocator);
    defer behavior.deinit(allocator);

    try maps.init(allocator);
    defer maps.deinit();

    try db.init(allocator);
    defer db.deinit();

    try login.init(allocator);
    defer login.deinit();

    client_pool = std.heap.MemoryPool(Client).init(allocator);
    defer client_pool.deinit();

    socket_pool = std.heap.MemoryPool(uv.uv_tcp_t).init(allocator);
    defer socket_pool.deinit();

    login_thread = try std.Thread.spawn(.{}, login.tick, .{});
    defer login_thread.join();

    game_thread = try std.Thread.spawn(.{}, gameTick, .{});
    defer game_thread.join();

    const stdin = std.io.getStdIn().reader();
    if (try stdin.readUntilDelimiterOrEofAlloc(allocator, '\n', 1024)) |dummy| {
        allocator.free(dummy);
    }
}

pub fn getIp(addr: std.net.Address) ![]const u8 {
    var ip_buf: [64]u8 = undefined;
    var stream = std.io.fixedBufferStream(&ip_buf);
    switch (addr.any.family) {
        std.posix.AF.INET => {
            const bytes = @as(*const [4]u8, @ptrCast(&addr.in.sa.addr));
            try std.fmt.format(stream.writer(), "{}.{}.{}.{}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
        },
        std.posix.AF.INET6 => {
            if (std.mem.eql(u8, addr.in6.sa.addr[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) {
                try std.fmt.format(stream.writer(), "[::ffff:{}.{}.{}.{}]", .{
                    addr.in6.sa.addr[12],
                    addr.in6.sa.addr[13],
                    addr.in6.sa.addr[14],
                    addr.in6.sa.addr[15],
                });
                return stream.getWritten();
            }
            const big_endian_parts = @as(*align(1) const [8]u16, @ptrCast(&addr.in6.sa.addr));
            const native_endian_parts = switch (builtin.target.cpu.arch.endian()) {
                .big => big_endian_parts.*,
                .little => blk: {
                    var buf: [8]u16 = undefined;
                    for (big_endian_parts, 0..) |part, i| buf[i] = std.mem.bigToNative(u16, part);
                    break :blk buf;
                },
            };
            try stream.writer().writeAll("[");
            var i: usize = 0;
            var abbrv = false;
            while (i < native_endian_parts.len) : (i += 1) {
                if (native_endian_parts[i] == 0) {
                    if (!abbrv) {
                        try stream.writer().writeAll(if (i == 0) "::" else ":");
                        abbrv = true;
                    }
                    continue;
                }
                try std.fmt.format(stream.writer(), "{x}", .{native_endian_parts[i]});
                if (i != native_endian_parts.len - 1) try stream.writer().writeAll(":");
            }
            try std.fmt.format(stream.writer(), "]", .{});
        },
        else => unreachable,
    }
    return stream.getWritten();
}
