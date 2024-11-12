const std = @import("std");
const shared = @import("shared");
const utils = shared.utils;
const game_data = shared.game_data;
const network_data = shared.network_data;
const uv = shared.uv;
const main = @import("main.zig");
const map = @import("game/map.zig");
const element = @import("ui/element.zig");
const camera = @import("camera.zig");
const assets = @import("assets.zig");
const particles = @import("game/particles.zig");
const ui_systems = @import("ui/systems.zig");
const dialog = @import("ui/dialogs/dialog.zig");
const rpc = @import("rpc");
const build_options = @import("options");

const Square = @import("game/square.zig").Square;
const Player = @import("game/player.zig").Player;
const Enemy = @import("game/enemy.zig").Enemy;
const Entity = @import("game/entity.zig").Entity;
const Container = @import("game/container.zig").Container;
const Portal = @import("game/portal.zig").Portal;
const Projectile = @import("game/projectile.zig").Projectile;

const read_buffer_size = 65535;
const write_buffer_size = 65535;

pub fn typeToObjEnum(comptime T: type) network_data.ObjectType {
    return switch (T) {
        Player => .player,
        Enemy => .enemy,
        Entity => .entity,
        Container => .container,
        Portal => .portal,
        else => @compileError("Invalid type"),
    };
}

pub fn ObjEnumToType(comptime obj_type: network_data.ObjectType) type {
    return switch (obj_type) {
        .player => Player,
        .entity => Entity,
        .enemy => Enemy,
        .portal => Portal,
        .container => Container,
    };
}

const WriteRequest = extern struct {
    request: uv.uv_write_t = .{},
    buffer: uv.uv_buf_t = .{},
};

pub const Server = struct {
    loop: *uv.uv_loop_t = undefined,
    socket: *uv.uv_tcp_t = undefined,
    shutdown_signal: *uv.uv_async_t = undefined,
    write_lock: std.Thread.Mutex = .{},
    hello_data: network_data.C2SPacket = undefined,
    initialized: bool = false,

    fn PacketData(comptime tag: @typeInfo(network_data.S2CPacket).@"union".tag_type.?) type {
        return @typeInfo(network_data.S2CPacket).@"union".fields[@intFromEnum(tag)].type;
    }

    fn handlerFn(comptime tag: @typeInfo(network_data.S2CPacket).@"union".tag_type.?) fn (*Server, PacketData(tag)) void {
        return switch (tag) {
            .ally_projectile => handleAllyProjectile,
            .aoe => handleAoe,
            .self_map_id => handleSelfMapId,
            .damage => handleDamage,
            .death => handleDeath,
            .enemy_projectile => handleEnemyProjectile,
            .@"error" => handleError,
            .inv_result => handleInvResult,
            .map_info => handleMapInfo,
            .dropped_map_ids => handleDroppedMapIds,
            .notification => handleNotification,
            .ping => handlePing,
            .show_effect => handleShowEffect,
            .text => handleText,
            .new_data => handleNewData,
        };
    }

    fn ObjEnumToStatType(comptime obj_type: network_data.ObjectType) type {
        return switch (obj_type) {
            .player => network_data.PlayerStat,
            .entity => network_data.EntityStat,
            .enemy => network_data.EnemyStat,
            .portal => network_data.PortalStat,
            .container => network_data.ContainerStat,
        };
    }

    fn ObjEnumToStatHandler(comptime obj_type: network_data.ObjectType) fn (*ObjEnumToType(obj_type), ObjEnumToStatType(obj_type), std.mem.Allocator) void {
        return switch (obj_type) {
            .player => parsePlayerStat,
            .entity => parseEntityStat,
            .enemy => parseEnemyStat,
            .portal => parsePortalStat,
            .container => parseContainerStat,
        };
    }

    pub export fn allocBuffer(_: [*c]uv.uv_handle_t, suggested_size: usize, buf: [*c]uv.uv_buf_t) void {
        buf.*.base = @ptrCast(main.allocator.alloc(u8, suggested_size) catch unreachable);
        buf.*.len = @intCast(suggested_size);
    }

    export fn writeCallback(ud: [*c]uv.uv_write_t, status: c_int) void {
        const wr: *WriteRequest = @ptrCast(@alignCast(ud));
        const server: *Server = @ptrCast(@alignCast(wr.request.data));
        main.allocator.free(wr.buffer.base[0..wr.buffer.len]);
        main.allocator.destroy(wr);

        if (status != 0) {
            std.log.err("Write error: {s}", .{uv.uv_strerror(status)});
            server.sameThreadShutdown();
            dialog.showDialog(.text, .{
                .title = "Connection Error",
                .body = "Socket writing was interrupted",
            });
            return;
        }
    }

    pub export fn readCallback(ud: *anyopaque, bytes_read: isize, buf: [*c]const uv.uv_buf_t) void {
        const socket: *uv.uv_stream_t = @ptrCast(@alignCast(ud));
        const server: *Server = @ptrCast(@alignCast(socket.data));
        var child_arena = std.heap.ArenaAllocator.init(main.allocator);
        defer child_arena.deinit();
        const child_arena_allocator = child_arena.allocator();

        if (bytes_read > 0) {
            var reader: utils.PacketReader = .{ .buffer = buf.*.base[0..@intCast(bytes_read)] };

            while (reader.index <= bytes_read - 3) {
                defer _ = child_arena.reset(.retain_capacity);

                const len = reader.read(u16, child_arena_allocator);
                if (len > bytes_read - reader.index)
                    return;

                const next_packet_idx = reader.index + len;
                const EnumType = @typeInfo(network_data.S2CPacket).@"union".tag_type.?;
                const byte_id = reader.read(std.meta.Int(.unsigned, @bitSizeOf(EnumType)), child_arena_allocator);
                const packet_id = std.meta.intToEnum(EnumType, byte_id) catch |e| {
                    std.log.err("Error parsing S2CPacketId ({}): id={}, size={}, len={}", .{ e, byte_id, bytes_read, len });
                    return;
                };

                switch (packet_id) {
                    inline else => |id| handlerFn(id)(server, reader.read(PacketData(id), child_arena_allocator)),
                }

                if (reader.index < next_packet_idx) {
                    std.log.err("S2C packet {} has {} bytes left over", .{ packet_id, next_packet_idx - reader.index });
                    reader.index = next_packet_idx;
                }
            }
        } else if (bytes_read < 0) {
            std.log.err("Read error: {s}", .{uv.uv_err_name(@intCast(bytes_read))});
            server.sameThreadShutdown();
            dialog.showDialog(.text, .{
                .title = "Connection Error",
                .body = "Server closed the connection",
            });
        }

        if (buf.*.base != null) main.allocator.free(buf.*.base[0..@intCast(buf.*.len)]);
    }

    export fn connectCallback(conn: [*c]uv.uv_connect_t, status: c_int) void {
        const server: *Server = @ptrCast(@alignCast(conn.*.data));
        defer main.allocator.destroy(@as(*uv.uv_connect_t, @ptrCast(conn)));

        if (status != 0) {
            std.log.err("Connection callback error: {s}", .{uv.uv_strerror(status)});
            main.disconnect(false);
            server.sameThreadShutdown();
            dialog.showDialog(.text, .{
                .title = "Connection Error",
                .body = "Connection failed",
            });
            return;
        }

        const read_status = uv.uv_read_start(@ptrCast(server.socket), allocBuffer, readCallback);
        if (read_status != 0) {
            std.log.err("Read init error: {s}", .{uv.uv_strerror(read_status)});
            server.sameThreadShutdown();
            dialog.showDialog(.text, .{
                .title = "Connection Error",
                .body = "Server inaccessible",
            });
            return;
        }

        {
            ui_systems.ui_lock.lock();
            defer ui_systems.ui_lock.unlock();
            ui_systems.switchScreen(.game);
        }
        server.sendPacket(server.hello_data);
    }

    export fn shutdownCallback(handle: [*c]uv.uv_async_t) void {
        const server: *Server = @ptrCast(@alignCast(handle.*.data));
        server.sameThreadShutdown();
        dialog.showDialog(.none, {});
    }

    export fn asyncWriteCallback(async_handle: [*c]uv.uv_async_t) void {
        const wr: *WriteRequest = @ptrCast(@alignCast(async_handle.*.data));
        const server: *Server = @ptrCast(@alignCast(wr.request.data));

        const write_status = uv.uv_write(@ptrCast(wr), @ptrCast(server.socket), @ptrCast(&wr.buffer), 1, writeCallback);
        if (write_status != 0) {
            std.log.err("Write send error: {s}", .{uv.uv_strerror(write_status)});
            server.sameThreadShutdown();
            dialog.showDialog(.text, .{
                .title = "Connection Error",
                .body = "Socket writing failed",
            });
            return;
        }
    }

    pub fn deinit(self: *Server) void {
        main.disconnect(false);
        main.allocator.destroy(self.shutdown_signal);
        main.allocator.destroy(self.loop);
        main.allocator.destroy(self.socket);
        self.initialized = false;
    }

    pub fn sendPacket(self: *Server, packet: network_data.C2SPacket) void {
        self.write_lock.lock();
        defer self.write_lock.unlock();

        const is_tick = packet == .move or packet == .pong;
        if (build_options.log_packets == .all or
            build_options.log_packets == .c2s or
            (build_options.log_packets == .c2s_tick or build_options.log_packets == .all_tick) and is_tick or
            (build_options.log_packets == .c2s_non_tick or build_options.log_packets == .all_non_tick) and !is_tick)
        {
            std.log.info("Send: {}", .{packet}); // todo custom formatting
        }

        if (packet == .use_portal or packet == .escape) {
            var lock = map.useLockForType(Player); // not great assuming that this won't ever deadlock...
            lock.lock();
            defer lock.unlock();
            if (map.localPlayerRef()) |player| {
                player.x = -1.0;
                player.y = -1.0;
                map.clearMoveRecords(main.current_time);
            }
        }

        switch (packet) {
            inline else => |data| {
                var writer: utils.PacketWriter = .{};
                defer writer.list.deinit(main.allocator);
                writer.writeLength(main.allocator);
                writer.write(@intFromEnum(std.meta.activeTag(packet)), main.allocator);
                writer.write(data, main.allocator);
                writer.updateLength();

                const uv_buffer: uv.uv_buf_t = .{ .base = @ptrCast(writer.list.items.ptr), .len = @intCast(writer.list.items.len) };

                var write_status = uv.UV_EAGAIN;
                while (write_status == uv.UV_EAGAIN) write_status = uv.uv_try_write(@ptrCast(self.socket), @ptrCast(&uv_buffer), 1);
                if (write_status < 0) {
                    std.log.err("Write send error: {s}", .{uv.uv_strerror(write_status)});
                    self.signalShutdown();
                    dialog.showDialog(.text, .{
                        .title = "Connection Error",
                        .body = "Socket writing failed",
                    });
                    return;
                }
            },
        }
    }

    pub fn connect(self: *Server, ip: []const u8, port: u16) !void {
        const addr = try std.net.Address.parseIp4(ip, port);

        self.loop = try main.allocator.create(uv.uv_loop_t);
        const loop_status = uv.uv_loop_init(@ptrCast(self.loop));
        if (loop_status != 0) {
            std.log.err("Loop creation error: {s}", .{uv.uv_strerror(loop_status)});
            return error.NoLoop;
        }

        self.socket = try main.allocator.create(uv.uv_tcp_t);
        self.socket.data = self;
        const tcp_status = uv.uv_tcp_init(@ptrCast(self.loop), @ptrCast(self.socket));
        if (tcp_status != 0) {
            std.log.err("Socket creation error: {s}", .{uv.uv_strerror(tcp_status)});
            return error.NoSocket;
        }

        self.shutdown_signal = try main.allocator.create(uv.uv_async_t);
        self.shutdown_signal.data = self;
        const async_shutdown_status = uv.uv_async_init(@ptrCast(self.loop), @ptrCast(self.shutdown_signal), shutdownCallback);
        if (async_shutdown_status != 0) {
            std.log.err("Async shutdown initialization error: {s}", .{uv.uv_strerror(async_shutdown_status)});
            return error.AsyncShutdownInitFailed;
        }

        var connect_data = try main.allocator.create(uv.uv_connect_t);
        connect_data.data = self;
        const conn_status = uv.uv_tcp_connect(@ptrCast(connect_data), @ptrCast(self.socket), @ptrCast(&addr.in.sa), connectCallback);
        if (conn_status != 0) {
            std.log.err("Connection error: {s}", .{uv.uv_strerror(conn_status)});
            return error.ConnectionFailed;
        }

        self.initialized = true;

        const run_status = uv.uv_run(@ptrCast(self.loop), uv.UV_RUN_DEFAULT);
        if (run_status != 0 and run_status != 1) {
            std.log.err("Run error: {s}", .{uv.uv_strerror(run_status)});
            return error.RunFailed;
        }
    }

    pub fn signalShutdown(self: *Server) void {
        if (!self.initialized)
            return;

        const shutdown_status = uv.uv_async_send(@ptrCast(self.shutdown_signal));
        if (shutdown_status != 0)
            std.log.err("Shutdown error: {s}", .{uv.uv_strerror(shutdown_status)});
    }

    fn sameThreadShutdown(self: *Server) void {
        if (!self.initialized)
            return;

        if (uv.uv_is_closing(@ptrCast(self.shutdown_signal)) == 0) uv.uv_close(@ptrCast(self.shutdown_signal), closeCallback);
        if (uv.uv_is_closing(@ptrCast(self.socket)) == 0) uv.uv_close(@ptrCast(self.socket), closeCallback);
        uv.uv_stop(@ptrCast(self.loop));
    }

    export fn closeCallback(_: [*c]uv.uv_handle_t) void {}

    fn logRead(comptime tick: enum { non_tick, tick }) bool {
        return if (tick == .non_tick)
            build_options.log_packets == .all or
                build_options.log_packets == .s2c or
                build_options.log_packets == .s2c_non_tick or
                build_options.log_packets == .all_non_tick
        else
            build_options.log_packets == .all or
                build_options.log_packets == .s2c or
                build_options.log_packets == .s2c_tick or
                build_options.log_packets == .all_tick;
    }

    fn handleAllyProjectile(_: *Server, data: PacketData(.ally_projectile)) void {
        if (logRead(.non_tick)) std.log.debug("Recv - AllyProjectile: {}", .{data});

        var lock = map.useLockForType(Player);
        lock.lock();
        defer lock.unlock();

        if (map.findObjectRef(Player, data.player_map_id)) |player| {
            const item_data = game_data.item.from_id.getPtr(data.item_data_id);
            var proj: Projectile = .{
                .x = player.x,
                .y = player.y,
                .data = item_data.?.projectile.?,
                .angle = data.angle,
                .index = @intCast(data.proj_index),
                .owner_map_id = player.map_id,
            };
            proj.addToMap(main.allocator);

            const attack_period: i64 = @intFromFloat(1.0 / (Player.attack_frequency * item_data.?.fire_rate));
            player.attack_period = attack_period;
            player.attack_angle = data.angle - camera.angle;
            player.attack_start = main.current_time;
        }
    }

    fn handleAoe(_: *Server, data: PacketData(.aoe)) void {
        particles.AoeEffect.addToMap(.{
            .x = data.x,
            .y = data.y,
            .color = data.color,
            .radius = data.radius,
        });

        if (logRead(.non_tick)) std.log.debug("Recv - Aoe: {}", .{data});
    }

    fn handleSelfMapId(_: *Server, data: PacketData(.self_map_id)) void {
        map.local_player_id = data.player_map_id;
        if (logRead(.non_tick)) std.log.debug("Recv - SelfMapId: {}", .{data});
    }

    fn handleDamage(_: *Server, data: PacketData(.damage)) void {
        var lock = map.useLockForType(Player);
        lock.lock();
        defer lock.unlock();

        if (map.findObjectRef(Player, data.player_map_id)) |player| {
            map.takeDamage(
                player,
                data.amount,
                data.effects,
                player.colors,
                data.ignore_def,
                main.allocator,
            );
        }

        if (logRead(.non_tick)) std.log.debug("Recv - Damage: {}", .{data});
    }

    fn handleDeath(self: *Server, data: PacketData(.death)) void {
        self.sameThreadShutdown();
        dialog.showDialog(.none, {});

        if (logRead(.non_tick)) std.log.debug("Recv - Death: {}", .{data});
    }

    fn handleEnemyProjectile(_: *Server, data: PacketData(.enemy_projectile)) void {
        if (logRead(.non_tick)) std.log.debug("Recv - EnemyProjectile: {}", .{data});

        var lock = map.useLockForType(Enemy);
        lock.lock();
        defer lock.unlock();

        var owner = if (map.findObjectRef(Enemy, data.enemy_map_id)) |enemy| enemy else return;

        const owner_data = game_data.enemy.from_id.getPtr(owner.data_id);
        if (owner_data == null or owner_data.?.projectiles == null or data.proj_data_id >= owner_data.?.projectiles.?.len)
            return;

        const total_angle = data.angle_incr * @as(f32, @floatFromInt(data.num_projs - 1));
        var current_angle = data.angle - total_angle / 2.0;

        for (0..data.num_projs) |i| {
            var proj: Projectile = .{
                .x = data.x,
                .y = data.y,
                .damage = data.damage,
                .data = owner_data.?.projectiles.?[data.proj_data_id],
                .angle = current_angle,
                .index = data.proj_index +% @as(u8, @intCast(i)),
                .owner_map_id = data.enemy_map_id,
                .damage_players = true,
            };
            proj.addToMap(main.allocator);

            current_angle += data.angle_incr;
        }

        owner.attack_angle = data.angle;
        owner.attack_start = main.current_time;
    }

    fn handleError(self: *Server, data: PacketData(.@"error")) void {
        if (logRead(.non_tick)) std.log.debug("Recv - Error: {}", .{data});

        if (data.type == .message_with_disconnect or data.type == .force_close_game) {
            self.sameThreadShutdown();
            dialog.showDialog(.text, .{
                .title = "Connection Error",
                .body = main.allocator.dupe(u8, data.description) catch return,
                .dispose_body = true,
            });
        }
    }

    fn handleInvResult(_: *Server, data: PacketData(.inv_result)) void {
        if (logRead(.non_tick)) std.log.debug("Recv - InvResult: {}", .{data});
    }

    fn handleMapInfo(_: *Server, data: PacketData(.map_info)) void {
        if (logRead(.non_tick)) std.log.debug("Recv - MapInfo: {}", .{data});

        map.dispose(main.allocator);
        camera.quake = false;

        main.allocator.free(map.info.name);
        map.setMapInfo(data, main.allocator);
        map.info.name = main.allocator.dupe(u8, data.name) catch "";

        main.tick_frame = true;
    }

    fn handleDroppedMapIds(_: *Server, data: PacketData(.dropped_map_ids)) void {
        inline for (.{
            .{ data.players, Player },
            .{ data.enemies, Enemy },
            .{ data.entities, Entity },
            .{ data.portals, Portal },
            .{ data.containers, Container },
        }) |typed_list| @"continue": {
            const list = typed_list[0];
            const T = typed_list[1];

            if (list.len == 0) break :@"continue";

            var lock = map.useLockForType(T);
            lock.lock();
            defer lock.unlock();
            for (list) |map_id| _ = map.removeEntity(T, main.allocator, map_id);
        }
    }

    fn handleNotification(_: *Server, data: PacketData(.notification)) void {
        switch (data.obj_type) {
            inline else => |inner| {
                const T = ObjEnumToType(inner);
                var lock = map.useLockForType(T);
                lock.lock();
                defer lock.unlock();
                if (map.findObjectConst(T, data.map_id) == null) return;
            },
        }

        element.StatusText.add(.{
            .obj_type = data.obj_type,
            .map_id = data.map_id,
            .lifetime = 2000,
            .text_data = .{
                .text = main.allocator.dupe(u8, data.message) catch return,
                .text_type = .bold,
                .size = 16,
                .color = data.color,
            },
            .initial_size = 16,
        }) catch unreachable;
    }

    fn handlePing(self: *Server, data: PacketData(.ping)) void {
        self.sendPacket(.{ .pong = .{ .ping_time = data.time, .time = main.current_time } });

        if (logRead(.tick)) std.log.debug("Recv - Ping: {}", .{data});
    }

    fn handleShowEffect(_: *Server, data: PacketData(.show_effect)) void {
        switch (data.eff_type) {
            .area_blast => {
                particles.AoeEffect.addToMap(.{
                    .x = data.x1,
                    .y = data.y1,
                    .radius = data.x2,
                    .color = data.color,
                });
            },
            .throw => {
                var start_x = data.x2;
                var start_y = data.y2;

                switch (data.obj_type) {
                    inline else => |inner| {
                        const T = ObjEnumToType(inner);
                        var lock = map.useLockForType(T);
                        lock.lock();
                        defer lock.unlock();
                        if (map.findObjectConst(T, data.map_id)) |obj| {
                            start_x = obj.x;
                            start_y = obj.y;
                        }
                    },
                }
                particles.ThrowEffect.addToMap(.{
                    .start_x = start_x,
                    .start_y = start_y,
                    .end_x = data.x1,
                    .end_y = data.y1,
                    .color = data.color,
                    .duration = 1500,
                });
            },
            .teleport => {
                particles.TeleportEffect.addToMap(.{
                    .x = data.x1,
                    .y = data.y1,
                });
            },
            .trail => {
                var start_x = data.x2;
                var start_y = data.y2;

                switch (data.obj_type) {
                    inline else => |inner| {
                        const T = ObjEnumToType(inner);
                        var lock = map.useLockForType(T);
                        lock.lock();
                        defer lock.unlock();
                        if (map.findObjectConst(T, data.map_id)) |obj| {
                            start_x = obj.x;
                            start_y = obj.y;
                        }
                    },
                }

                particles.LineEffect.addToMap(.{
                    .start_x = start_x,
                    .start_y = start_y,
                    .end_x = data.x1,
                    .end_y = data.y1,
                    .color = data.color,
                });
            },
            .potion => {
                // the effect itself handles checks for invalid entity
                particles.HealEffect.addToMap(.{
                    .target_obj_type = data.obj_type,
                    .target_map_id = data.map_id,
                    .color = data.color,
                });
            },
            .earthquake => {
                camera.quake = true;
                camera.quake_amount = 0.0;
            },
            else => {},
        }

        if (logRead(.non_tick)) std.log.debug("Recv - ShowEffect: {}", .{data});
    }

    fn handleText(_: *Server, data: PacketData(.text)) void {
        if (ui_systems.screen == .game)
            ui_systems.screen.game.addChatLine(data.name, data.text, data.name_color, data.text_color) catch |e| {
                std.log.err("Adding message with name {s} and text {s} failed: {}", .{ data.name, data.text, e });
            };

        if (data.map_id != std.math.maxInt(u32)) {
            {
                switch (data.obj_type) {
                    inline else => |inner| {
                        const T = ObjEnumToType(inner);
                        var lock = map.useLockForType(T);
                        lock.lock();
                        defer lock.unlock();
                        if (map.findObjectConst(T, data.map_id) == null) return;
                    },
                }
            }

            var atlas_data = assets.error_data;
            if (assets.ui_atlas_data.get("speech_balloons")) |balloon_data| {
                switch (data.name_color) {
                    0xD4AF37 => atlas_data = balloon_data[5], // admin balloon
                    // todo
                    0x000000 => atlas_data = balloon_data[2], // guild balloon
                    0x000001 => atlas_data = balloon_data[4], // party balloon
                    else => {
                        if (!std.mem.eql(u8, data.recipient, "")) {
                            atlas_data = balloon_data[1]; // tell balloon
                        } else {
                            atlas_data = if (data.obj_type == .enemy)
                                balloon_data[3] // enemy balloon
                            else
                                balloon_data[0]; // normal balloon
                        }
                    },
                }
            } else std.debug.panic("Could not find speech_balloons in the UI atlas", .{});

            element.SpeechBalloon.add(.{
                .image_data = .{ .normal = .{
                    .scale_x = 3.0,
                    .scale_y = 3.0,
                    .atlas_data = atlas_data,
                } },
                .text_data = .{
                    .text = main.allocator.dupe(u8, data.text) catch unreachable,
                    .size = 16,
                    .max_width = 160,
                    .outline_width = 1.5,
                    .disable_subpixel = true,
                    .color = data.text_color,
                },
                .target_obj_type = data.obj_type,
                .target_map_id = data.map_id,
            }) catch unreachable;
        }
    }

    fn handleNewData(self: *Server, data: PacketData(.new_data)) void {
        const tick_time = @as(f32, std.time.us_per_s) / 30.0;

        defer {
            if (main.tick_frame) {
                const time = main.current_time;
                var lock = map.useLockForType(Player);
                lock.lock();
                defer lock.unlock();
                if (map.localPlayerRef()) |local_player| {
                    self.sendPacket(.{ .move = .{
                        .tick_id = data.tick_id,
                        .time = time,
                        .x = local_player.x,
                        .y = local_player.y,
                        .records = map.move_records.items,
                    } });

                    local_player.onMove();
                } else {
                    self.sendPacket(.{ .move = .{
                        .tick_id = data.tick_id,
                        .time = time,
                        .x = -1.0,
                        .y = -1.0,
                        .records = &.{},
                    } });
                }

                map.clearMoveRecords(time);
            }
        }

        for (data.tiles) |tile| {
            var square: Square = .{
                .data_id = tile.data_id,
                .x = @as(f32, @floatFromInt(tile.x)) + 0.5,
                .y = @as(f32, @floatFromInt(tile.y)) + 0.5,
            };

            square.addToMap();
        }

        {
            main.minimap_lock.lock();
            defer main.minimap_lock.unlock();
            main.need_minimap_update = data.tiles.len > 0;
        }

        inline for (.{
            .{ data.players, Player },
            .{ data.enemies, Enemy },
            .{ data.entities, Entity },
            .{ data.portals, Portal },
            .{ data.containers, Container },
        }) |typed_list| {
            const T = typed_list[1];
            var lock = map.useLockForType(T);
            lock.lock();
            defer lock.unlock();
            for (typed_list[0]) |obj| {
                var stat_reader: utils.PacketReader = .{ .buffer = obj.stats };
                var add_lock = map.addLockForType(T);
                var need_add_unlock = false;
                defer if (need_add_unlock) add_lock.unlock();
                const current_obj = map.findObjectRef(T, obj.map_id) orelse findAddObj: {
                    add_lock.lock();
                    for (map.addListForType(T).items) |*add_obj| {
                        if (add_obj.map_id == obj.map_id) {
                            need_add_unlock = true;
                            break :findAddObj add_obj;
                        }
                    }

                    add_lock.unlock();
                    break :findAddObj null;
                };
                if (current_obj) |object| {
                    const pre_x = switch (T) {
                        Player, Enemy => object.x,
                        else => 0.0,
                    };
                    const pre_y = switch (T) {
                        Player, Enemy => object.y,
                        else => 0.0,
                    };

                    parseObjectStat(typeToObjEnum(T), &stat_reader, main.allocator, object);

                    switch (T) {
                        Player => {
                            if (object.map_id != map.local_player_id)
                                updateMove(object, pre_x, pre_y, tick_time);

                            if (object.map_id == map.local_player_id and ui_systems.screen == .game)
                                ui_systems.screen.game.updateStats();
                        },
                        Enemy => updateMove(object, pre_x, pre_y, tick_time),
                        else => {},
                    }
                } else {
                    var new_obj: T = .{ .map_id = obj.map_id, .data_id = obj.data_id };
                    parseObjectStat(typeToObjEnum(T), &stat_reader, main.allocator, &new_obj);
                    new_obj.addToMap(main.allocator);
                }
            }
        }
    }

    fn updateMove(obj: anytype, pre_x: f32, pre_y: f32, tick_time: f32) void {
        const y_dt = obj.y - pre_y;
        const x_dt = obj.x - pre_x;

        if (!std.math.isNan(obj.move_angle)) {
            const dist_sqr = y_dt * y_dt + x_dt * x_dt;
            obj.move_step = @sqrt(dist_sqr) / tick_time;
            obj.target_x = obj.x;
            obj.target_y = obj.y;
            obj.x = pre_x;
            obj.y = pre_y;
        }

        obj.move_angle = if (y_dt == 0 and x_dt == 0) std.math.nan(f32) else std.math.atan2(y_dt, x_dt);
    }

    fn parseObjectStat(
        comptime obj_type: network_data.ObjectType,
        stat_reader: *utils.PacketReader,
        allocator: std.mem.Allocator,
        object: *ObjEnumToType(obj_type),
    ) void {
        while (stat_reader.index < stat_reader.buffer.len) {
            const StatType = ObjEnumToStatType(obj_type);
            const type_info = @typeInfo(StatType).@"union";
            const TagType = type_info.tag_type.?;
            const stat_id: usize = @intFromEnum(stat_reader.read(TagType, allocator));
            inline for (type_info.fields, 0..) |field, i| @"continue": {
                if (i != stat_id) break :@"continue";

                const stat = @unionInit(StatType, field.name, stat_reader.read(field.type, allocator));
                ObjEnumToStatHandler(obj_type)(object, stat, allocator);
            }
        }
    }

    fn parseNameStat(object: anytype, allocator: std.mem.Allocator, name: []const u8) void {
        if (name.len <= 0)
            return;

        if (object.name) |obj_name| allocator.free(obj_name);

        object.name = name;

        if (object.name_text_data) |*data| {
            data.setText(object.name.?, allocator);
        } else {
            object.name_text_data = .{
                .text = object.name.?,
                .text_type = .bold,
                .size = 12,
            };
            if (@TypeOf(object) == Player) {
                object.name_text_data.color = 0xFCDF00;
                object.name_text_data.max_width = 200;
            }

            object.name_text_data.?.lock.lock();
            defer object.name_text_data.?.lock.unlock();

            object.name_text_data.?.recalculateAttributes(allocator);
        }
    }

    fn parsePlayerStat(player: *Player, stat: network_data.PlayerStat, allocator: std.mem.Allocator) void {
        const is_self = player.map_id == map.local_player_id;
        switch (stat) {
            .x => |val| player.x = val,
            .y => |val| player.y = val,
            .size_mult => |val| player.size_mult = val,
            .max_hp => |val| player.max_hp = val,
            .hp => |val| {
                player.hp = val;
                if (val > 0) player.dead = false;
            },
            .max_mp => |val| player.max_mp = val,
            .mp => |val| player.mp = val,
            .attack => |val| player.attack = val,
            .defense => |val| player.defense = val,
            .speed => |val| player.speed = val,
            .dexterity => |val| player.dexterity = val,
            .vitality => |val| player.vitality = val,
            .wisdom => |val| player.wisdom = val,
            .max_hp_bonus => |val| player.max_hp_bonus = val,
            .max_mp_bonus => |val| player.max_mp_bonus = val,
            .attack_bonus => |val| player.attack_bonus = val,
            .defense_bonus => |val| player.defense_bonus = val,
            .speed_bonus => |val| player.speed_bonus = val,
            .dexterity_bonus => |val| player.dexterity_bonus = val,
            .vitality_bonus => |val| player.vitality_bonus = val,
            .wisdom_bonus => |val| player.wisdom_bonus = val,
            .condition => |val| player.condition = val,
            .gold => |val| player.gold = val,
            .fame => |val| player.fame = val,
            .muted_until => |val| player.muted_until = val,
            .stars => |val| {
                player.stars = val;
                const tex = game_data.StarType.fromCount(val).toTextureData();
                player.star_icon = assets.atlas_data.get(tex.sheet).?[tex.index];
            },
            .inv_0,
            .inv_1,
            .inv_2,
            .inv_3,
            .inv_4,
            .inv_5,
            .inv_6,
            .inv_7,
            .inv_8,
            .inv_9,
            .inv_10,
            .inv_11,
            .inv_12,
            .inv_13,
            .inv_14,
            .inv_15,
            .inv_16,
            .inv_17,
            .inv_18,
            .inv_19,
            => |val| {
                const inv_idx = @intFromEnum(stat) - @intFromEnum(network_data.PlayerStat.inv_0);
                player.inventory[inv_idx] = val;
                if (is_self and ui_systems.screen == .game)
                    ui_systems.screen.game.setInvItem(val, inv_idx);
            },
            .level => |val| {
                if (player.level != 0 and player.level != val)
                    element.StatusText.add(.{
                        .obj_type = .player,
                        .map_id = player.map_id,
                        .text_data = .{
                            .text = std.fmt.allocPrint(allocator, "Level Up!", .{}) catch unreachable,
                            .text_type = .bold,
                            .size = 16,
                            .color = 0x7200BF,
                        },
                        .initial_size = 16,
                    }) catch unreachable;

                player.level = val;
            },
            .exp => |val| {
                if (is_self and player.exp > 0) {
                    if (player.level < 20) {
                        if (val > player.exp)
                            element.StatusText.add(.{
                                .obj_type = .player,
                                .map_id = player.map_id,
                                .text_data = .{
                                    .text = std.fmt.allocPrint(allocator, "+{} EXP", .{val - player.exp}) catch unreachable,
                                    .text_type = .bold,
                                    .size = 16,
                                    .color = 0x7200BF,
                                },
                                .initial_size = 16,
                            }) catch unreachable;
                    } else {
                        const prev_fame = @divFloor(player.exp, 1000);
                        const post_fame = @divFloor(player.exp + val, 1000);
                        if (prev_fame != post_fame) {
                            element.StatusText.add(.{
                                .obj_type = .player,
                                .map_id = player.map_id,
                                .text_data = .{
                                    .text = std.fmt.allocPrint(allocator, "+{} Fame", .{post_fame - prev_fame}) catch unreachable,
                                    .text_type = .bold,
                                    .size = 16,
                                    .color = 0xE64F2A,
                                },
                                .initial_size = 16,
                            }) catch unreachable;
                        }
                    }
                }

                player.exp = val;
            },
            .name => |val| parseNameStat(player, allocator, val),
        }
    }

    fn parseEnemyStat(enemy: *Enemy, stat: network_data.EnemyStat, allocator: std.mem.Allocator) void {
        switch (stat) {
            .x => |val| enemy.x = val,
            .y => |val| enemy.y = val,
            .max_hp => |val| enemy.max_hp = val,
            .hp => |val| {
                enemy.hp = val;
                if (val > 0) enemy.dead = false;
            },
            .size_mult => |val| enemy.size_mult = val,
            .condition => |val| enemy.condition = val,
            .name => |val| parseNameStat(enemy, allocator, val),
        }
    }

    fn parseEntityStat(entity: *Entity, stat: network_data.EntityStat, allocator: std.mem.Allocator) void {
        switch (stat) {
            .x => |val| entity.x = val,
            .y => |val| entity.y = val,
            .hp => |val| {
                entity.hp = val;
                if (val > 0) entity.dead = false;
            },
            .size_mult => |val| entity.size_mult = val,
            .name => |val| parseNameStat(entity, allocator, val),
        }
    }

    fn parseContainerStat(container: *Container, stat: network_data.ContainerStat, allocator: std.mem.Allocator) void {
        switch (stat) {
            .x => |val| container.x = val,
            .y => |val| container.y = val,
            .size_mult => |val| container.size_mult = val,
            .inv_0, .inv_1, .inv_2, .inv_3, .inv_4, .inv_5, .inv_6, .inv_7 => |val| {
                const inv_idx = @intFromEnum(stat) - @intFromEnum(network_data.ContainerStat.inv_0);
                container.inventory[inv_idx] = val;

                const int_id = map.interactive.map_id.load(.acquire);
                if (container.map_id == int_id and ui_systems.screen == .game)
                    ui_systems.screen.game.setContainerItem(val, inv_idx);
            },
            .name => |val| {
                const int_id = map.interactive.map_id.load(.acquire);
                if (container.map_id == int_id and ui_systems.screen == .game)
                    ui_systems.screen.game.container_name.text_data.setText(val, ui_systems.screen.game.allocator);
                parseNameStat(container, allocator, val);
            },
        }
    }

    fn parsePortalStat(portal: *Portal, stat: network_data.PortalStat, allocator: std.mem.Allocator) void {
        switch (stat) {
            .x => |val| portal.x = val,
            .y => |val| portal.y = val,
            .size_mult => |val| portal.size_mult = val,
            .name => |val| parseNameStat(portal, allocator, val),
        }
    }
};
