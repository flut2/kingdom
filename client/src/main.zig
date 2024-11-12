const std = @import("std");
const shared = @import("shared");
const network_data = shared.network_data;
const game_data = shared.game_data;
const requests = shared.requests;
const utils = shared.utils;
const uv = shared.uv;
const assets = @import("assets.zig");
const network = @import("network.zig");
const builtin = @import("builtin");
const glfw = @import("zglfw");
const zstbi = @import("zstbi");
const input = @import("input.zig");
const camera = @import("camera.zig");
const map = @import("game/map.zig");
const element = @import("ui/element.zig");
const render = @import("render/base.zig");
const tracy = if (build_options.enable_tracy) @import("tracy") else {};
const zaudio = @import("zaudio");
const ui_systems = @import("ui/systems.zig");
const rpc = @import("rpc");
const dialog = @import("ui/dialogs/dialog.zig");
const rpmalloc = @import("rpmalloc").RPMalloc(.{});
const build_options = @import("options");
const gpu = @import("zgpu");

const Settings = @import("Settings.zig");

const AccountData = struct {
    email: []const u8,
    token: u128,

    pub fn load() !AccountData {
        const file = try std.fs.cwd().openFile("login_data_do_not_share.json", .{});
        defer file.close();

        const file_data = try file.readToEndAlloc(account_arena_allocator, std.math.maxInt(u32));
        defer account_arena_allocator.free(file_data);

        return try std.json.parseFromSliceLeaky(
            AccountData,
            account_arena_allocator,
            file_data,
            .{ .ignore_unknown_fields = true, .allocate = .alloc_always },
        );
    }

    pub fn save(self: AccountData) !void {
        const file = try std.fs.cwd().createFile("login_data_do_not_share.json", .{});
        defer file.close();

        const json = try std.json.stringifyAlloc(account_arena_allocator, self, .{ .whitespace = .indent_4 });
        try file.writeAll(json);
    }
};

pub export var NvOptimusEnablement: c_int = 1;
pub export var AmdPowerXpressRequestHighPerformance: c_int = 1;

pub var gctx: *gpu.GraphicsContext = undefined;
pub var account_arena_allocator: std.mem.Allocator = undefined;
pub var current_account: ?AccountData = null;
pub var character_list: ?network_data.CharacterListData = null;
pub var current_time: i64 = 0;
pub var render_thread: std.Thread = undefined;
pub var network_thread: ?std.Thread = null;
pub var tick_render = true;
pub var tick_frame = false;
pub var editing_map = false;
pub var need_minimap_update = false;
pub var need_force_update = false;
pub var minimap_lock: std.Thread.Mutex = .{};
pub var need_swap_chain_update = false;
pub var minimap_update: struct {
    min_x: u32 = std.math.maxInt(u32),
    max_x: u32 = std.math.minInt(u32),
    min_y: u32 = std.math.maxInt(u32),
    max_y: u32 = std.math.minInt(u32),
} = .{};
pub var rpc_client: *rpc = undefined;
pub var rpc_start: u64 = 0;
pub var version_text: []const u8 = undefined;
pub var allocator: std.mem.Allocator = undefined;
pub var start_time: i64 = 0;
pub var server: network.Server = undefined;
pub var settings: Settings = undefined;
pub var class_quest_idx: usize = std.math.maxInt(usize);

fn onResize(_: *glfw.Window, w: i32, h: i32) callconv(.C) void {
    const float_w: f32 = @floatFromInt(w);
    const float_h: f32 = @floatFromInt(h);

    camera.screen_width = float_w;
    camera.screen_height = float_h;
    camera.clip_scale_x = 2.0 / float_w;
    camera.clip_scale_y = 2.0 / float_h;

    ui_systems.resize(float_w, float_h);

    need_swap_chain_update = true;
}

fn networkCallback(ip: []const u8, port: u16, hello_data: network_data.C2SPacket) void {
    defer network_thread = null;

    if (build_options.enable_tracy) tracy.SetThreadName("Network");

    rpmalloc.initThread() catch |e| {
        std.log.err("Network thread initialization failed: {}", .{e});
        return;
    };
    defer rpmalloc.deinitThread(true);

    server = .{ .hello_data = hello_data };
    defer server.deinit();

    server.connect(ip, port) catch |e| {
        std.log.err("Connection failed: {}", .{e});
        return;
    };
}

// lock ui_systems.ui_lock before calling (UI already does this implicitly)
pub fn enterGame(selected_server: network_data.ServerData, char_id: u32, class_data_id: u16) void {
    if (network_thread != null or current_account == null)
        return;

    network_thread = std.Thread.spawn(.{ .allocator = allocator }, networkCallback, .{ selected_server.ip, selected_server.port, network_data.C2SPacket{ .hello = .{
        .build_ver = build_options.version,
        .email = current_account.?.email,
        .token = current_account.?.token,
        .char_id = @intCast(char_id),
        .class_id = class_data_id,
    } } }) catch |e| {
        std.log.err("Connection failed: {}", .{e});
        return;
    };
}

pub fn enterTest(selected_server: network_data.ServerData, char_id: u32, test_map: []u8) void {
    if (network_thread != null or current_account == null)
        return;

    network_thread = std.Thread.spawn(.{ .allocator = allocator }, networkCallback, .{ selected_server.ip, selected_server.port, network_data.C2SPacket{ .map_hello = .{
        .build_ver = build_options.version,
        .email = current_account.?.email,
        .token = current_account.?.token,
        .char_id = char_id,
        .map = test_map,
    } } }) catch |e| {
        std.log.err("Connection failed: {}", .{e});
        return;
    };
}

fn renderTick() !void {
    if (build_options.enable_tracy) tracy.SetThreadName("Render");

    rpmalloc.initThread() catch |e| {
        std.log.err("Render thread initialization failed: {}", .{e});
        return;
    };
    defer rpmalloc.deinitThread(true);

    var last_vsync = settings.enable_vsync;
    var fps_time_start: i64 = 0;
    var frames: usize = 0;
    while (tick_render) {
        if (need_swap_chain_update or last_vsync != settings.enable_vsync) {
            gctx.swapchain.release();
            const framebuffer_size = gctx.window_provider.fn_getFramebufferSize(gctx.window_provider.window);
            gctx.swapchain_descriptor.width = framebuffer_size[0];
            gctx.swapchain_descriptor.height = framebuffer_size[1];
            gctx.swapchain_descriptor.present_mode = if (settings.enable_vsync) .fifo else .immediate;
            gctx.swapchain = gctx.device.createSwapChain(gctx.surface, gctx.swapchain_descriptor);
            last_vsync = settings.enable_vsync;
            need_swap_chain_update = false;
        }

        if (!tick_render)
            return;

        defer frames += 1;
        const back_buffer = gctx.swapchain.getCurrentTextureView();
        const encoder = gctx.device.createCommandEncoder(null);

        render.draw(current_time, back_buffer, encoder, allocator);

        const commands = encoder.finish(null);
        gctx.submit(&.{commands}, @as(f32, @floatFromInt(current_time)) / std.time.us_per_s);
        gctx.swapchain.present();

        back_buffer.release();
        encoder.release();
        commands.release();

        if (current_time - fps_time_start > 1 * std.time.us_per_s) {
            try if (settings.stats_enabled) switch (ui_systems.screen) {
                inline .game, .editor => |screen| if (screen.inited) screen.updateFpsText(frames, try utils.currentMemoryUse(current_time)),
                else => {},
            };
            frames = 0;
            fps_time_start = current_time;
        }

        minimapUpdate: {
            if (!tick_frame or ui_systems.screen == .editor)
                break :minimapUpdate;

            minimap_lock.lock();
            defer minimap_lock.unlock();

            if (need_minimap_update) {
                const min_x = @min(map.minimap.width, minimap_update.min_x);
                const max_x = @max(map.minimap.width, minimap_update.max_x + 1);
                const min_y = @min(map.minimap.height, minimap_update.min_y);
                const max_y = @max(map.minimap.height, minimap_update.max_y + 1);

                const w = max_x - min_x;
                const h = max_y - min_y;
                if (w <= 0 or h <= 0)
                    break :minimapUpdate;

                const comp_len = map.minimap.num_components * map.minimap.bytes_per_component;

                for (min_y..max_y, 0..) |y, i| {
                    const base_map_idx = y * map.minimap.width * comp_len + min_x * comp_len;
                    @memcpy(
                        map.minimap_copy[i * w * comp_len .. (i + 1) * w * comp_len],
                        map.minimap.data[base_map_idx .. base_map_idx + w * comp_len],
                    );
                }

                gctx.queue.writeTexture(
                    .{ .texture = render.minimap.texture, .origin = .{ .x = min_x, .y = min_y } },
                    .{ .bytes_per_row = comp_len * w, .rows_per_image = h },
                    .{ .width = w, .height = h },
                    u8,
                    map.minimap_copy[0 .. w * h * comp_len],
                );

                need_minimap_update = false;
                minimap_update = .{};
            } else if (need_force_update) {
                gctx.queue.writeTexture(
                    .{ .texture = render.minimap.texture },
                    .{ .bytes_per_row = map.minimap.bytes_per_row, .rows_per_image = map.minimap.height },
                    .{ .width = map.minimap.width, .height = map.minimap.height },
                    u8,
                    map.minimap.data,
                );
                need_force_update = false;
            }
        }
    }
}

pub fn disconnect(has_lock: bool) void {
    map.dispose(allocator);
    input.reset();
    {
        if (!has_lock) ui_systems.ui_lock.lock();
        defer if (!has_lock) ui_systems.ui_lock.unlock();

        if (ui_systems.editor_backup) |editor| {
            ui_systems.switchScreen(.editor);
            _ = editor;
            ui_systems.editor_backup = null;
        } else {
            if (character_list.?.characters.len > 0)
                ui_systems.switchScreen(.char_select)
            else
                ui_systems.switchScreen(.char_create);
        }
    }
}

pub fn main() !void {
    if (build_options.enable_tracy) tracy.SetThreadName("Main");

    const win_freq = if (builtin.os.tag == .windows) std.os.windows.QueryPerformanceFrequency() else {};
    const start_instant = std.time.Instant.now() catch unreachable;
    start_time = switch (builtin.os.tag) {
        .windows => @intCast(@divFloor(start_instant.timestamp * std.time.us_per_s, win_freq)),
        else => @divFloor(start_instant.timestamp.nsec, std.time.ns_per_us) + start_instant.timestamp.sec * std.time.us_per_s,
    };
    utils.rng.seed(@intCast(start_time));

    const is_debug = builtin.mode == .Debug;
    var gpa = if (is_debug) std.heap.GeneralPurposeAllocator(.{ .stack_trace_frames = 10 }){} else {};
    defer _ = if (is_debug) gpa.deinit();

    try rpmalloc.init(null, .{});
    defer rpmalloc.deinit();

    const child_allocator = if (is_debug)
        gpa.allocator()
    else
        rpmalloc.allocator();
    allocator = if (build_options.enable_tracy) blk: {
        var tracy_alloc = tracy.TracyAllocator.init(child_allocator);
        break :blk tracy_alloc.allocator();
    } else child_allocator;

    var account_arena = std.heap.ArenaAllocator.init(allocator);
    account_arena_allocator = account_arena.allocator();
    defer account_arena.deinit();

    loadAccount: {
        current_account = AccountData.load() catch break :loadAccount;
    }
    defer if (settings.remember_login) if (current_account) |acc| acc.save() catch {};

    rpc_client = try rpc.init(allocator, &ready);
    defer rpc_client.deinit();

    try glfw.init();
    defer glfw.terminate();

    zstbi.init(allocator);
    defer zstbi.deinit();

    zaudio.init(allocator);
    defer zaudio.deinit();

    settings = try Settings.init(allocator);
    defer settings.deinit();

    try assets.init(allocator);
    defer assets.deinit(allocator);

    try game_data.init(allocator);
    defer game_data.deinit();

    requests.init(allocator);
    defer requests.deinit();

    try map.init(allocator);
    defer map.deinit(allocator);

    try ui_systems.init(allocator);
    defer ui_systems.deinit();

    input.init(allocator);
    defer input.deinit();

    if (current_account) |acc| {
        const token_str = try std.fmt.allocPrint(account_arena_allocator, "{}", .{acc.token});
        defer account_arena_allocator.free(token_str);

        var data: std.StringHashMapUnmanaged([]const u8) = .{};
        try data.put(account_arena_allocator, "email", acc.email);
        try data.put(account_arena_allocator, "token", token_str);
        defer data.deinit(account_arena_allocator);

        var needs_free = true;
        const response = requests.sendRequest(build_options.login_server_uri ++ "char/list", data) catch |e| blk: {
            switch (e) {
                error.ConnectionRefused => {
                    needs_free = false;
                    break :blk "Connection Refused";
                },
                else => return e,
            }
        };
        defer if (needs_free) requests.freeResponse(response);

        enterGame: {
            character_list = std.json.parseFromSliceLeaky(network_data.CharacterListData, account_arena_allocator, response, .{ .allocate = .alloc_always }) catch {
                ui_systems.ui_lock.lock();
                defer ui_systems.ui_lock.unlock();
                ui_systems.switchScreen(.main_menu);
                break :enterGame;
            };
            if (character_list.?.characters.len == 0) {
                ui_systems.ui_lock.lock();
                defer ui_systems.ui_lock.unlock();
                ui_systems.switchScreen(.main_menu);
                break :enterGame;
            }
            enterGame(character_list.?.servers[0], character_list.?.characters[0].char_id, std.math.maxInt(u16));
        }
    } else {
        ui_systems.ui_lock.lock();
        defer ui_systems.ui_lock.unlock();
        ui_systems.switchScreen(.main_menu);
    }

    glfw.windowHintTyped(.client_api, .no_api);
    const window = try glfw.Window.create(1280, 720, "Kingdom", null);
    defer window.destroy();
    window.setSizeLimits(1280, 720, -1, -1);
    window.setCursor(switch (settings.cursor_type) {
        .basic => assets.default_cursor,
        .royal => assets.royal_cursor,
        .ranger => assets.ranger_cursor,
        .aztec => assets.aztec_cursor,
        .fiery => assets.fiery_cursor,
        .target_enemy => assets.target_enemy_cursor,
        .target_ally => assets.target_ally_cursor,
    });

    gctx = gpu.GraphicsContext.create(
        allocator,
        .{
            .window = window,
            .fn_getTime = @ptrCast(&glfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&glfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&glfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&glfw.getX11Display),
            .fn_getX11Window = @ptrCast(&glfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&glfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&glfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&glfw.getCocoaWindow),
        },
        .{ .present_mode = if (settings.enable_vsync) .fifo else .immediate },
    ) catch |e| {
        std.log.err("Failed to create graphics context: {any}", .{e});
        return;
    };
    defer gctx.destroy(allocator);

    _ = window.setKeyCallback(input.keyEvent);
    _ = window.setCharCallback(input.charEvent);
    _ = window.setCursorPosCallback(input.mouseMoveEvent);
    _ = window.setMouseButtonCallback(input.mouseEvent);
    _ = window.setScrollCallback(input.scrollEvent);
    _ = window.setFramebufferSizeCallback(onResize);

    try render.init(gctx, allocator);
    defer render.deinit(allocator);

    var rpc_thread = try std.Thread.spawn(.{ .allocator = allocator }, runRpc, .{rpc_client});
    defer {
        rpc_client.stop();
        rpc_thread.join();
    }

    render_thread = try std.Thread.spawn(.{ .allocator = allocator }, renderTick, .{});
    defer {
        tick_render = false;
        render_thread.join();
    }

    defer server.signalShutdown();

    while (!window.shouldClose()) {
        glfw.pollEvents();

        const instant = std.time.Instant.now() catch unreachable;
        const time = switch (builtin.os.tag) {
            .windows => @as(i64, @intCast(@divFloor(instant.timestamp * std.time.us_per_s, win_freq))),
            else => @divFloor(instant.timestamp.nsec, std.time.ns_per_us) + instant.timestamp.sec * std.time.us_per_s,
        } - start_time;
        const dt: f32 = @floatFromInt(if (current_time > 0) time - current_time else 0);
        current_time = time;

        if (tick_frame or editing_map) {
            @branchHint(.likely);
            map.update(allocator, time, dt);
        }

        try ui_systems.update(time, dt);
    }
}

fn ready(cli: *rpc) !void {
    rpc_start = @intCast(std.time.timestamp());
    try cli.setPresence(.{
        .assets = .{
            .large_image = rpc.Packet.ArrayString(256).create("logo"),
            .large_text = rpc.Packet.ArrayString(128).create(version_text),
        },
        .timestamps = .{ .start = rpc_start },
    });
}

fn runRpc(cli: *rpc) void {
    if (build_options.enable_tracy) tracy.SetThreadName("RPC");

    rpmalloc.initThread() catch |e| {
        std.log.err("RPC thread initialization failed: {}", .{e});
        return;
    };
    defer rpmalloc.deinitThread(true);

    cli.run(.{ .client_id = "1223822665748320317" }) catch |e| {
        std.log.err("Setting up RPC failed: {}", .{e});
    };
}
