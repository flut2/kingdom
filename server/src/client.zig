const std = @import("std");
const shared = @import("shared");
const utils = shared.utils;
const game_data = shared.game_data;
const network_data = shared.network_data;
const uv = shared.uv;
const settings = @import("settings.zig");
const main = @import("main.zig");
const builtin = @import("builtin");
const db = @import("db.zig");
const maps = @import("map/maps.zig");
const command = @import("command.zig");

const World = @import("world.zig").World;
const Entity = @import("map/entity.zig").Entity;
const Enemy = @import("map/enemy.zig").Enemy;
const Projectile = @import("map/projectile.zig").Projectile;
const Player = @import("map/player.zig").Player;
const Portal = @import("map/portal.zig").Portal;
const Container = @import("map/container.zig").Container;

const WriteRequest = extern struct {
    request: uv.uv_write_t = .{},
    buffer: uv.uv_buf_t = .{},
};

pub const Client = struct {
    socket: *uv.uv_tcp_t = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    needs_shutdown: bool = false,
    world: *World = undefined,
    ip: []const u8 = "",
    acc_id: u32 = std.math.maxInt(u32),
    char_id: u32 = std.math.maxInt(u32),
    player_map_id: u32 = std.math.maxInt(u32),

    fn PacketData(comptime tag: @typeInfo(network_data.C2SPacket).@"union".tag_type.?) type {
        return @typeInfo(network_data.C2SPacket).@"union".fields[@intFromEnum(tag)].type;
    }

    fn handlerFn(comptime tag: @typeInfo(network_data.C2SPacket).@"union".tag_type.?) fn (*Client, PacketData(tag)) void {
        return switch (tag) {
            .player_projectile => handlePlayerProjectile,
            .move => handleMove,
            .player_text => handlePlayerText,
            .inv_swap => handleInvSwap,
            .use_item => handleUseItem,
            .hello => handleHello,
            .inv_drop => handleInvDrop,
            .pong => handlePong,
            .teleport => handleTeleport,
            .use_portal => handleUsePortal,
            .buy => handleBuy,
            .ground_damage => handleGroundDamage,
            .player_hit => handlePlayerHit,
            .enemy_hit => handleEnemyHit,
            .escape => handleEscape,
            .map_hello => handleMapHello,
        };
    }

    pub export fn allocBuffer(socket: [*c]uv.uv_handle_t, suggested_size: usize, buf: [*c]uv.uv_buf_t) void {
        const client: *Client = @ptrCast(@alignCast(socket.*.data));
        buf.*.base = @ptrCast(client.arena.allocator().alloc(u8, suggested_size) catch {
            client.sameThreadShutdown(); // no failure, if we can't alloc it wouldn't go through anyway
            return;
        });
        buf.*.len = @intCast(suggested_size);
    }

    export fn closeCallback(socket: [*c]uv.uv_handle_t) void {
        const client: *Client = @ptrCast(@alignCast(socket.*.data));

        removePlayer: {
            if (client.player_map_id == std.math.maxInt(u32)) break :removePlayer;
            client.world.remove(Player, client.world.findRef(Player, client.player_map_id) orelse break :removePlayer) catch break :removePlayer;
        }

        main.socket_pool.destroy(client.socket);
        client.arena.deinit();
        main.client_pool.destroy(client);
    }

    export fn writeCallback(ud: [*c]uv.uv_write_t, status: c_int) void {
        const wr: *WriteRequest = @ptrCast(ud);
        const client: *Client = @ptrCast(@alignCast(wr.request.data));

        if (status != 0) {
            client.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Socket write error" } });
            return;
        }

        const arena_allocator = client.arena.allocator();
        arena_allocator.free(wr.buffer.base[0..wr.buffer.len]);
        arena_allocator.destroy(wr);
    }

    pub export fn readCallback(ud: *anyopaque, bytes_read: isize, buf: [*c]const uv.uv_buf_t) void {
        const socket: *uv.uv_stream_t = @ptrCast(@alignCast(ud));
        const client: *Client = @ptrCast(@alignCast(socket.data));
        // if (client.ip.len == 0) {
        //     const sockname_status = uv.uv_tcp_getsockname(@ptrCast(socket), @ptrCast(&address.any), @sizeOf(std.posix.socklen_t));
        //     if (sockname_status != 0) {
        //         std.log.err("Failed to get sockname: {s}", .{uv.uv_strerror(sockname_status)});
        //         uv.uv_close(@ptrCast(socket), closeCallback);
        //         return;
        //     }

        //     client.ip = main.getIp(address) catch |e| {
        //         std.log.err("Failed to parse IP from socket: {}", .{e});
        //         uv.uv_close(@ptrCast(socket), closeCallback);
        //         return;
        //     };
        // }
        const arena_allocator = client.arena.allocator();
        var child_arena = std.heap.ArenaAllocator.init(arena_allocator);
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
                const EnumType = @typeInfo(network_data.C2SPacket).@"union".tag_type.?;
                const byte_id = reader.read(std.meta.Int(.unsigned, @bitSizeOf(EnumType)), child_arena_allocator);
                const packet_id = std.meta.intToEnum(EnumType, byte_id) catch |e| {
                    std.log.err("Error parsing C2SPacketId ({}): id={}, size={}, len={}", .{ e, byte_id, bytes_read, len });
                    client.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Socket read error" } });
                    return;
                };

                switch (packet_id) {
                    inline else => |id| handlerFn(id)(client, reader.read(PacketData(id), child_arena_allocator)),
                }

                if (reader.index < next_packet_idx) {
                    std.log.err("C2S packet {} has {} bytes left over", .{ packet_id, next_packet_idx - reader.index });
                    reader.index = next_packet_idx;
                }
            }
        } else if (bytes_read < 0) {
            if (bytes_read != uv.UV_EOF) {
                client.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Socket read error" } });
            } else client.sameThreadShutdown();
            return;
        }

        arena_allocator.free(buf.*.base[0..@intCast(buf.*.len)]);
    }

    export fn asyncCloseCallback(_: [*c]uv.uv_handle_t) void {}

    pub export fn shutdownCallback(handle: [*c]uv.uv_async_t) void {
        const client: *Client = @ptrCast(@alignCast(handle.*.data));
        client.sameThreadShutdown();
    }

    pub fn sameThreadShutdown(self: *Client) void {
        if (uv.uv_is_closing(@ptrCast(self.socket)) == 0) uv.uv_close(@ptrCast(self.socket), closeCallback);
    }

    pub fn queuePacket(self: *Client, packet: network_data.S2CPacket) void {
        switch (packet) {
            inline else => |data| {
                const arena_allocator = self.arena.allocator();

                var writer: utils.PacketWriter = .{};
                writer.writeLength(arena_allocator);
                writer.write(@intFromEnum(std.meta.activeTag(packet)), arena_allocator);
                writer.write(data, arena_allocator);
                writer.updateLength();

                const wr: *WriteRequest = arena_allocator.create(WriteRequest) catch unreachable;
                wr.buffer.base = @ptrCast(writer.list.items);
                wr.buffer.len = @intCast(writer.list.items.len);
                wr.request.data = @ptrCast(self);
                const write_status = uv.uv_write(@ptrCast(wr), @ptrCast(self.socket), @ptrCast(&wr.buffer), 1, writeCallback);
                if (write_status != 0) {
                    self.sameThreadShutdown();
                    return;
                }
            },
        }

        if (packet == .@"error") self.sameThreadShutdown();
    }

    pub fn sendMessage(self: *Client, msg: []const u8) void {
        self.queuePacket(.{ .text = .{
            .name = "Server",
            .obj_type = .entity,
            .map_id = std.math.maxInt(u32),
            .bubble_time = 0,
            .recipient = "",
            .text = msg,
            .name_color = 0xCC00CC,
            .text_color = 0xFF99FF,
        } });
    }

    fn handlePlayerProjectile(self: *Client, data: PacketData(.player_projectile)) void {
        const player = self.world.findRef(Player, self.player_map_id) orelse return;
        const item_data = game_data.item.from_id.getPtr(player.inventory[0]) orelse return;
        const proj_data = item_data.projectile orelse return;

        var proj: Projectile = .{
            .x = data.x,
            .y = data.y,
            .owner_obj_type = .player,
            .owner_map_id = self.player_map_id,
            .angle = data.angle,
            .start_time = main.current_time,
            .damage = proj_data.damage,
            .index = data.proj_index,
            .data = &item_data.projectile.?,
        };

        _ = self.world.addExisting(Projectile, &proj) catch return;

        player.projectiles[data.proj_index] = proj.map_id;
    }

    fn handleMove(self: *Client, data: PacketData(.move)) void {
        if (data.x < 0.0 or data.y < 0.0)
            return;

        const player = self.world.findRef(Player, self.player_map_id) orelse {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Player not found" } });
            return;
        };

        const idx = @as(u32, @intFromFloat(data.y)) * @as(u32, self.world.w) + @as(u32, @intFromFloat(data.x));
        if (idx > self.world.tiles.len) {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Invalid position" } });
            return;
        }

        const tile = self.world.tiles[idx];
        if (tile.data.no_walk or tile.occupied) {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Tile occupied" } });
            return;
        }

        player.x = data.x;
        player.y = data.y;
    }

    fn handlePlayerText(self: *Client, data: PacketData(.player_text)) void {
        if (data.text.len == 0 or data.text.len > 256)
            return;

        const player = self.world.findRef(Player, self.player_map_id) orelse return;
        if (data.text[0] == '/') {
            var split = std.mem.splitScalar(u8, data.text, ' ');
            command.handle(&split, player);
            return;
        }

        if (player.muted_until >= main.current_time) return;

        for (self.world.listForType(Player).items) |*other_player| {
            other_player.client.queuePacket(.{ .text = .{
                .name = player.name,
                .obj_type = .player,
                .map_id = self.player_map_id,
                .bubble_time = 0,
                .recipient = "",
                .text = data.text,
                .name_color = if (@intFromEnum(player.rank) >= @intFromEnum(network_data.Rank.staff)) 0xF2CA46 else 0xEBEBEB,
                .text_color = if (@intFromEnum(player.rank) >= @intFromEnum(network_data.Rank.staff)) 0xD4AF37 else 0xB0B0B0,
            } });
        }
    }

    fn verifySwap(item_id: u16, target_type: game_data.ItemType) bool {
        const item_type = blk: {
            if (item_id == std.math.maxInt(u16)) break :blk .any;
            break :blk (game_data.item.from_id.get(item_id) orelse return false).item_type;
        };
        return game_data.ItemType.typesMatch(item_type, target_type);
    }

    fn handleInvSwap(self: *Client, data: PacketData(.inv_swap)) void {
        switch (data.from_obj_type) {
            .player => if (self.world.findRef(Player, data.from_map_id)) |player| {
                const start = player.inventory[data.from_slot_id];
                switch (data.to_obj_type) {
                    .player => {
                        if (!verifySwap(start, if (data.to_slot_id < 4) player.data.item_types[data.to_slot_id] else .any) or
                            !verifySwap(player.inventory[data.to_slot_id], if (data.from_slot_id < 4) player.data.item_types[data.from_slot_id] else .any))
                            return;
                        player.inventory[data.from_slot_id] = player.inventory[data.to_slot_id];
                        player.inventory[data.to_slot_id] = start;
                    },
                    .container => if (self.world.findRef(Container, data.to_map_id)) |cont| {
                        if (!verifySwap(cont.inventory[data.to_slot_id], if (data.from_slot_id < 4) player.data.item_types[data.from_slot_id] else .any))
                            return;
                        player.inventory[data.from_slot_id] = cont.inventory[data.to_slot_id];
                        cont.inventory[data.to_slot_id] = start;
                    } else return,
                    else => return,
                }

                player.recalculateItems();
            } else return,
            .container => if (self.world.findRef(Container, data.from_map_id)) |cont| {
                const start = cont.inventory[data.from_slot_id];
                switch (data.to_obj_type) {
                    .player => if (self.world.findRef(Player, data.to_map_id)) |player| {
                        if (!verifySwap(start, if (data.to_slot_id < 4) player.data.item_types[data.to_slot_id] else .any))
                            return;
                        cont.inventory[data.from_slot_id] = player.inventory[data.to_slot_id];
                        player.inventory[data.to_slot_id] = start;
                        player.recalculateItems();
                    } else return,
                    .container => if (self.world.findRef(Container, data.to_map_id)) |other_cont| {
                        cont.inventory[data.from_slot_id] = other_cont.inventory[data.to_slot_id];
                        other_cont.inventory[data.to_slot_id] = start;
                    } else return,
                    else => return,
                }
            } else return,
            else => return,
        }
    }

    fn handleUseItem(_: *Client, _: PacketData(.use_item)) void {}

    fn createChar(player: *Player, class_id: u16, timestamp: u64) !void {
        if (game_data.class.from_id.get(class_id)) |class_data| {
            const max_slots = try player.acc_data.get(.max_char_slots);
            const alive_ids: []const u32 = player.acc_data.get(.alive_char_ids) catch &.{};
            if (alive_ids.len >= max_slots)
                return error.SlotsFull;

            const next_char_id = try player.acc_data.get(.next_char_id);
            player.char_data.char_id = next_char_id;
            try player.acc_data.set(.{ .next_char_id = next_char_id + 1 });

            const new_alive_ids = try std.mem.concat(player.client.arena.allocator(), u32, &.{ alive_ids, &[_]u32{next_char_id} });
            try player.acc_data.set(.{ .alive_char_ids = new_alive_ids });

            try player.char_data.set(.{ .level = 0 });
            try player.char_data.set(.{ .experience = 0 });
            try player.char_data.set(.{ .class_id = class_id });
            try player.char_data.set(.{ .create_timestamp = timestamp });
            try player.char_data.set(.{ .level = 1 });
            try player.char_data.set(.{ .experience = 0 });

            var stats: [8]i32 = undefined;
            stats[Player.health_stat] = class_data.stats.health.base;
            stats[Player.mana_stat] = class_data.stats.mana.base;
            stats[Player.attack_stat] = class_data.stats.attack.base;
            stats[Player.defense_stat] = class_data.stats.defense.base;
            stats[Player.speed_stat] = class_data.stats.speed.base;
            stats[Player.dexterity_stat] = class_data.stats.dexterity.base;
            stats[Player.vitality_stat] = class_data.stats.vitality.base;
            stats[Player.wisdom_stat] = class_data.stats.wisdom.base;
            try player.char_data.set(.{ .hp = class_data.stats.health.base });
            try player.char_data.set(.{ .mp = class_data.stats.mana.base });
            try player.char_data.set(.{ .stats = stats });
            var starting_items: [20]u16 = [_]u16{std.math.maxInt(u16)} ** 20;
            for (class_data.default_items, 0..) |item, i| starting_items[i] = item;
            try player.char_data.set(.{ .items = starting_items });
        } else return error.InvalidCharId;
    }

    fn handleHello(self: *Client, data: PacketData(.hello)) void {
        if (self.player_map_id != std.math.maxInt(u32)) {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Already connected" } });
            return;
        }

        if (!std.mem.eql(u8, data.build_ver, settings.build_version)) {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Incorrect version" } });
            return;
        }

        const acc_id = db.login(data.email, data.token) catch |e| {
            switch (e) {
                error.NoData => self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Invalid email" } }),
                error.InvalidToken => self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Invalid credentials" } }),
                else => self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Unknown error" } }),
            }
            return;
        };
        self.acc_id = acc_id;

        const arena_allocator = self.arena.allocator();
        var player: Player = .{
            .acc_data = db.AccountData.init(arena_allocator, acc_id),
            .char_data = db.CharacterData.init(arena_allocator, acc_id, data.char_id),
            .client = self,
        };

        const is_banned = db.accountBanned(&player.acc_data) catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Database is missing data" } });
            return;
        };
        if (is_banned) {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Account banned" } });
            return;
        }

        const timestamp: u64 = @intCast(std.time.milliTimestamp());
        if (data.class_id != std.math.maxInt(u16)) {
            createChar(&player, data.class_id, timestamp) catch {
                self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Character creation failed" } });
                return;
            };
        }

        self.char_id = player.char_data.char_id;
        player.char_data.set(.{ .create_timestamp = timestamp }) catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Could not interact with database" } });
            return;
        };

        self.world = maps.worlds.getPtr(maps.retrieve_id) orelse {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Retrieve does not exist" } });
            return;
        };

        self.player_map_id = self.world.addExisting(Player, &player) catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Adding player to map failed" } });
            return;
        };

        self.queuePacket(.{ .map_info = .{
            .width = self.world.w,
            .height = self.world.h,
            .name = self.world.name,
            .bg_color = self.world.light_data.color,
            .bg_intensity = self.world.light_data.intensity,
            .day_intensity = self.world.light_data.day_intensity,
            .night_intensity = self.world.light_data.night_intensity,
            .server_time = main.current_time,
        } });

        self.queuePacket(.{ .self_map_id = .{ .player_map_id = self.player_map_id } });
    }

    fn handleInvDrop(self: *Client, data: PacketData(.inv_drop)) void {
        const player = self.world.findRef(Player, data.player_map_id) orelse return;
        var cont: Container = .{
            .x = player.x,
            .y = player.y,
            .data_id = game_data.container.from_name.get("Brown Bag").?.id,
            .name = self.world.allocator.dupe(u8, player.name) catch {
                self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Bag name creation failed" } });
                return;
            },
        };
        cont.inventory[0] = player.inventory[data.slot_id];
        _ = self.world.addExisting(Container, &cont) catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Bag spawning failed" } });
            return;
        };

        player.inventory[data.slot_id] = std.math.maxInt(u16);
        player.recalculateItems();
    }

    fn handlePong(_: *Client, _: PacketData(.pong)) void {}

    fn handleTeleport(_: *Client, _: PacketData(.teleport)) void {}

    fn handleUsePortal(self: *Client, data: PacketData(.use_portal)) void {
        const en_type = if (self.world.find(Portal, data.portal_map_id)) |e| e.data_id else {
            self.sendMessage("Portal not found");
            return;
        };

        const new_world = maps.portalWorld(en_type, data.portal_map_id) catch {
            self.sendMessage("Map load failed");
            return;
        } orelse {
            self.sendMessage("Map does not exist");
            return;
        };

        const player = self.world.findRef(Player, self.player_map_id) orelse {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Player does not exist" } });
            return;
        };
        player.save() catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Player save failed" } });
            return;
        };

        self.world.remove(Player, player) catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Removing player from map failed" } });
            return;
        };

        self.world = new_world;

        const arena_allocator = self.arena.allocator();
        var new_player: Player = .{
            .acc_data = db.AccountData.init(arena_allocator, self.acc_id),
            .char_data = db.CharacterData.init(arena_allocator, self.acc_id, self.char_id),
            .client = self,
        };
        self.player_map_id = self.world.addExisting(Player, &new_player) catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Adding player to map failed" } });
            return;
        };

        self.queuePacket(.{ .map_info = .{
            .width = @intCast(self.world.w),
            .height = @intCast(self.world.h),
            .name = self.world.name,
            .bg_color = self.world.light_data.color,
            .bg_intensity = self.world.light_data.intensity,
            .day_intensity = self.world.light_data.day_intensity,
            .night_intensity = self.world.light_data.night_intensity,
            .server_time = main.current_time,
        } });

        self.queuePacket(.{ .self_map_id = .{ .player_map_id = self.player_map_id } });
    }

    fn handleBuy(_: *Client, _: PacketData(.buy)) void {}

    fn handleGroundDamage(self: *Client, data: PacketData(.ground_damage)) void {
        const ux: u16 = @intFromFloat(data.x);
        const uy: u16 = @intFromFloat(data.y);
        const tile = self.world.tiles[uy * self.world.w + ux];
        if (tile.data_id == std.math.maxInt(u16)) return;

        const player = self.world.findRef(Player, self.player_map_id) orelse return;
        for (self.world.listForType(Player).items) |world_player| {
            if (world_player.map_id == self.player_map_id) continue;

            if (utils.distSqr(world_player.x, world_player.y, player.x, player.y) <= 16 * 16) {
                self.queuePacket(.{ .damage = .{
                    .player_map_id = self.player_map_id,
                    .effects = .{},
                    .amount = @intCast(tile.data.damage),
                    .ignore_def = true,
                } });
            }
        }

        player.damage(tile.data.name, tile.data.damage, true);
    }

    fn handlePlayerHit(self: *Client, data: PacketData(.player_hit)) void {
        const enemy = self.world.find(Enemy, data.enemy_map_id) orelse return;
        const proj = self.world.findRef(Projectile, enemy.projectiles[data.proj_index] orelse return) orelse return;
        if (proj.hit_list.contains(self.player_map_id)) return;
        const player = self.world.findRef(Player, self.player_map_id) orelse return;
        player.damage(enemy.data.name, proj.damage, proj.data.ignore_def);
        proj.hit_list.put(self.world.allocator, self.player_map_id, {}) catch return;
    }

    fn handleEnemyHit(self: *Client, data: PacketData(.enemy_hit)) void {
        const player = self.world.find(Player, self.player_map_id) orelse return;
        const enemy = self.world.findRef(Enemy, data.enemy_map_id) orelse return;
        const proj = self.world.findRef(Projectile, player.projectiles[data.proj_index] orelse return) orelse return;

        enemy.damage(self.player_map_id, proj.damage, proj.data.ignore_def);
        if (!proj.data.piercing)
            proj.delete() catch return;
    }

    fn handleEscape(self: *Client, _: PacketData(.escape)) void {
        const player = self.world.findRef(Player, self.player_map_id) orelse {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Player does not exist" } });
            return;
        };
        player.save() catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Player save failed" } });
            return;
        };

        self.world.remove(Player, player) catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Removing player from map failed" } });
            return;
        };

        self.world = maps.worlds.getPtr(maps.retrieve_id) orelse {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Retrieve does not exist" } });
            return;
        };

        const arena_allocator = self.arena.allocator();
        var new_player: Player = .{
            .acc_data = db.AccountData.init(arena_allocator, self.acc_id),
            .char_data = db.CharacterData.init(arena_allocator, self.acc_id, self.char_id),
            .client = self,
        };

        self.player_map_id = self.world.addExisting(Player, &new_player) catch {
            self.queuePacket(.{ .@"error" = .{ .type = .message_with_disconnect, .description = "Adding player to map failed" } });
            return;
        };

        self.queuePacket(.{ .map_info = .{
            .width = self.world.w,
            .height = self.world.h,
            .name = self.world.name,
            .bg_color = self.world.light_data.color,
            .bg_intensity = self.world.light_data.intensity,
            .day_intensity = self.world.light_data.day_intensity,
            .night_intensity = self.world.light_data.night_intensity,
            .server_time = main.current_time,
        } });

        self.queuePacket(.{ .self_map_id = .{ .player_map_id = self.player_map_id } });
    }

    fn handleMapHello(_: *Client, _: PacketData(.map_hello)) void {}
};
