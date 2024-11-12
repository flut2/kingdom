const std = @import("std");
const shared = @import("shared");
const game_data = shared.game_data;
const network_data = shared.network_data;
const utils = shared.utils;
const db = @import("db.zig");
const main = @import("main.zig");

const Entity = @import("map/entity.zig").Entity;
const Enemy = @import("map/enemy.zig").Enemy;
const Portal = @import("map/portal.zig").Portal;
const Container = @import("map/container.zig").Container;
const Player = @import("map/player.zig").Player;
const Client = @import("client.zig").Client;

fn h(str: []const u8) u64 {
    return std.hash.Wyhash.hash(0, str);
}

fn checkRank(player: *Player, comptime rank: network_data.Rank) bool {
    if (@intFromEnum(player.rank) >= @intFromEnum(rank))
        return true;

    player.client.sendMessage("You don't meet the rank requirements");
    return false;
}

pub fn handle(iter: *std.mem.SplitIterator(u8, .scalar), player: *Player) void {
    const command_name = iter.next() orelse return;
    switch (h(command_name)) {
        h("/spawn") => if (checkRank(player, .admin)) handleSpawn(iter, player),
        h("/clearspawn") => if (checkRank(player, .admin)) handleClearSpawn(player),
        h("/give") => if (checkRank(player, .admin)) handleGive(iter, player),
        h("/ban") => if (checkRank(player, .mod)) handleBan(iter, player),
        h("/unban") => if (checkRank(player, .mod)) handleUnban(iter, player),
        h("/mute") => if (checkRank(player, .mod)) handleMute(iter, player),
        h("/unmute") => if (checkRank(player, .mod)) handleUnmute(iter, player),
        h("/cond"), h("/condition") => if (checkRank(player, .staff)) handleCond(iter, player),
        // h("/max") => if (checkRank(player, .staff)) handleMax(iter, player),
        else => player.client.sendMessage("Unknown command"),
    }
}

fn handleSpawn(iter: *std.mem.SplitIterator(u8, .scalar), player: *Player) void {
    var buf: [256]u8 = undefined;
    var name_stream = std.io.fixedBufferStream(&buf);
    const first_str = iter.next() orelse return;
    const count = blk: {
        const int = std.fmt.parseInt(u16, first_str, 0) catch {
            _ = name_stream.write(first_str) catch unreachable;
            break :blk 1;
        };

        break :blk int;
    };
    if (iter.index) |i| {
        if (name_stream.pos != 0)
            _ = name_stream.write(" ") catch unreachable;
        _ = name_stream.write(iter.buffer[i..]) catch unreachable;
    }

    var response_buf: [256]u8 = undefined;

    const written_name = name_stream.getWritten();
    var name: ?[]const u8 = null;
    inline for (.{ Entity, Enemy, Portal, Container }) |ObjType| {
        if (switch (ObjType) {
            Entity => game_data.entity,
            Enemy => game_data.enemy,
            Portal => game_data.portal,
            Container => game_data.container,
            else => unreachable,
        }.from_name.get(written_name)) |data| {
            name = data.name;
            for (0..count) |_| {
                var obj: ObjType = .{
                    .x = player.x,
                    .y = player.y,
                    .data_id = data.id,
                    .spawned = true,
                };
                _ = player.world.addExisting(ObjType, &obj) catch return;
            }
        }
    }

    if (name) |name_inner| {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Spawned {}x \"{s}\"", .{ count, name_inner }) catch return);
    } else {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "\"{s}\" not found in game data", .{written_name}) catch return);
        return;
    }
}

fn handleGive(iter: *std.mem.SplitIterator(u8, .scalar), player: *Player) void {
    var response_buf: [256]u8 = undefined;

    const item_name = iter.buffer[iter.index orelse 0 ..];
    const item_data = game_data.item.from_name.get(item_name) orelse {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "\"{s}\" not found in game data", .{item_name}) catch return);
        return;
    };
    const class_data = game_data.class.from_id.get(player.data_id) orelse return;
    for (&player.inventory, 0..) |*equip, i| {
        if (equip.* == std.math.maxInt(u16) and (i >= 4 or class_data.item_types[i].typesMatch(item_data.item_type))) {
            equip.* = item_data.id;
            player.client.sendMessage(std.fmt.bufPrint(&response_buf, "You've been given a \"{s}\"", .{item_data.name}) catch return);
            return;
        }
    }

    player.client.sendMessage("You don't have enough space");
}

fn handleClearSpawn(player: *Player) void {
    var count: usize = 0;
    inline for (.{ Entity, Enemy, Portal, Container }) |ObjType| {
        for (player.world.listForType(ObjType).items) |*obj| {
            if (obj.spawned) {
                player.world.remove(ObjType, obj) catch continue;
                count += 1;
            }
        }
    }

    if (count == 0) {
        player.client.sendMessage("No entities found");
    } else {
        var buf: [256]u8 = undefined;
        player.client.sendMessage(std.fmt.bufPrint(&buf, "Cleared {} entities", .{count}) catch return);
    }
}

fn handleBan(iter: *std.mem.SplitIterator(u8, .scalar), player: *Player) void {
    var response_buf: [256]u8 = undefined;

    const allocator = player.world.allocator;
    var names = db.Names.init(allocator);
    defer names.deinit();

    const player_name = iter.next() orelse {
        player.client.sendMessage("Invalid command usage. Arguments: /ban [name] [optional expiry, in seconds]");
        return;
    };
    const acc_id = names.get(player_name) catch {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Player \"{s}\" not found in database", .{player_name}) catch unreachable);
        return;
    };

    var acc_data = db.AccountData.init(allocator, acc_id);
    defer acc_data.deinit();

    const expiry_str = iter.next();
    const expiry = if (expiry_str) |str| std.fmt.parseInt(u32, str, 10) catch std.math.maxInt(u32) else std.math.maxInt(u32);

    banHwid: {
        const hwid = acc_data.get(.hwid) catch break :banHwid;
        var banned_hwids = db.BannedHwids.init(allocator);
        defer banned_hwids.deinit();
        banned_hwids.add(hwid, expiry) catch break :banHwid;
    }

    acc_data.set(.{ .ban_expiry = main.current_time + expiry * std.time.us_per_s }) catch {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Accessing database records for player \"{s}\" failed", .{player_name}) catch unreachable);
        return;
    };

    player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Player \"{s}\" successfully banned", .{player_name}) catch unreachable);
}

fn handleUnban(iter: *std.mem.SplitIterator(u8, .scalar), player: *Player) void {
    var response_buf: [256]u8 = undefined;

    const allocator = player.world.allocator;
    var names = db.Names.init(allocator);
    defer names.deinit();

    const player_name = iter.next() orelse {
        player.client.sendMessage("Invalid command usage. Arguments: /unban [name]");
        return;
    };
    const acc_id = names.get(player_name) catch {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Player \"{s}\" not found in database", .{player_name}) catch unreachable);
        return;
    };

    var acc_data = db.AccountData.init(allocator, acc_id);
    defer acc_data.deinit();

    unbanHwid: {
        const hwid = acc_data.get(.hwid) catch break :unbanHwid;
        var banned_hwids = db.BannedHwids.init(allocator);
        defer banned_hwids.deinit();
        banned_hwids.remove(hwid) catch break :unbanHwid;
    }

    acc_data.set(.{ .ban_expiry = 0 }) catch {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Accessing database records for player \"{s}\" failed", .{player_name}) catch unreachable);
        return;
    };

    player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Player \"{s}\" successfully unbanned", .{player_name}) catch unreachable);
}

fn handleMute(iter: *std.mem.SplitIterator(u8, .scalar), player: *Player) void {
    var response_buf: [256]u8 = undefined;

    const allocator = player.world.allocator;
    var names = db.Names.init(allocator);
    defer names.deinit();

    const player_name = iter.next() orelse {
        player.client.sendMessage("Invalid command usage. Arguments: /mute [name] [optional expiry, in seconds]");
        return;
    };
    const acc_id = names.get(player_name) catch {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Player \"{s}\" not found in database", .{player_name}) catch unreachable);
        return;
    };

    var acc_data = db.AccountData.init(allocator, acc_id);
    defer acc_data.deinit();

    const expiry_str = iter.next();
    const expiry = if (expiry_str) |str| std.fmt.parseInt(u32, str, 10) catch std.math.maxInt(u32) else std.math.maxInt(u32);

    muteHwid: {
        const hwid = acc_data.get(.hwid) catch break :muteHwid;
        var muted_hwids = db.MutedHwids.init(allocator);
        defer muted_hwids.deinit();
        muted_hwids.add(hwid, expiry) catch break :muteHwid;
    }

    acc_data.set(.{ .mute_expiry = main.current_time + expiry * std.time.us_per_s }) catch {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Accessing database records for player \"{s}\" failed", .{player_name}) catch unreachable);
        return;
    };

    player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Player \"{s}\" successfully muted", .{player_name}) catch unreachable);
}

fn handleUnmute(iter: *std.mem.SplitIterator(u8, .scalar), player: *Player) void {
    var response_buf: [256]u8 = undefined;

    const allocator = player.world.allocator;
    var names = db.Names.init(allocator);
    defer names.deinit();

    const player_name = iter.next() orelse {
        player.client.sendMessage("Invalid command usage. Arguments: /unmute [name]");
        return;
    };
    const acc_id = names.get(player_name) catch {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Player \"{s}\" not found in database", .{player_name}) catch unreachable);
        return;
    };

    var acc_data = db.AccountData.init(allocator, acc_id);
    defer acc_data.deinit();

    unmuteHwid: {
        const hwid = acc_data.get(.hwid) catch break :unmuteHwid;
        var muted_hwids = db.MutedHwids.init(allocator);
        defer muted_hwids.deinit();
        muted_hwids.remove(hwid) catch break :unmuteHwid;
    }

    acc_data.set(.{ .mute_expiry = 0 }) catch {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Accessing database records for player \"{s}\" failed", .{player_name}) catch unreachable);
        return;
    };

    player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Player \"{s}\" successfully unmuted", .{player_name}) catch unreachable);
}

fn handleCond(iter: *std.mem.SplitIterator(u8, .scalar), player: *Player) void {
    var response_buf: [256]u8 = undefined;

    const cond_name = iter.buffer[iter.index orelse 0 ..];
    const cond = std.meta.stringToEnum(utils.ConditionEnum, cond_name) orelse {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Condition \"{s}\" not found in game data", .{cond_name}) catch return);
        return;
    };
    player.condition.toggle(cond);
    if (player.condition.get(cond)) {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Condition applied: \"{s}\"", .{@tagName(cond)}) catch return);
        return;
    } else {
        player.client.sendMessage(std.fmt.bufPrint(&response_buf, "Condition removed: \"{s}\"", .{@tagName(cond)}) catch return);
        return;
    }
}
