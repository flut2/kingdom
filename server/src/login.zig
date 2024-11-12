const std = @import("std");
const build_options = @import("options");
const settings = @import("settings.zig");
const db = @import("db.zig");
const httpz = @import("httpz");
const rpmalloc = @import("rpmalloc").RPMalloc(.{});
const shared = @import("shared");
const builtin = @import("builtin");
const main = @import("main.zig");
const game_data = shared.game_data;
const network_data = shared.network_data;
const tracy = if (build_options.enable_tracy) @import("tracy") else {};

const Handlers = struct {
    fn notFound(_: Handlers, _: *httpz.Request, res: *httpz.Response) !void {
        res.status = 404;
        res.body = "Not Found";
    }

    fn uncaughtError(_: Handlers, req: *httpz.Request, res: *httpz.Response, err: anyerror) void {
        res.status = 500;
        res.body = "Internal Server Error";
        std.log.warn("Unhandled exception for request '{s}': {}", .{ req.url.raw, err });
    }
};

var handlers: Handlers = .{};
var server: httpz.Server(Handlers) = undefined;

pub fn init(allocator: std.mem.Allocator) !void {
    server = try httpz.Server(Handlers).init(allocator, .{ .port = settings.login_port }, handlers);

    var router = server.router();
    router.post("/account/verify", handleAccountVerify, .{});
    router.post("/account/register", handleAccountRegister, .{});
    router.post("/char/list", handleCharList, .{});
}

pub fn deinit() void {
    server.deinit();
}

pub fn tick() !void {
    if (build_options.enable_tracy) tracy.SetThreadName("Login");

    rpmalloc.initThread() catch |e| {
        std.log.err("Login thread initialization failed: {}", .{e});
        return;
    };
    defer rpmalloc.deinitThread(true);

    try server.listen();
}

fn handleAccountRegister(_: Handlers, req: *httpz.Request, res: *httpz.Response) !void {
    rpmalloc.initThread() catch {
        res.body = "Thread initialization failed";
        return;
    };
    defer rpmalloc.deinitThread(true);

    const query = try req.query();
    const name = query.get("name") orelse {
        res.body = "Invalid name";
        return;
    };
    const hwid = query.get("hwid") orelse {
        res.body = "Invalid HWID";
        return;
    };
    const email = query.get("email") orelse {
        res.body = "Invalid email";
        return;
    };
    const password = query.get("password") orelse {
        res.body = "Invalid password";
        return;
    };

    if (try db.isBanned(hwid)) {
        res.body = "Account banned";
        return;
    }

    var login_data = db.LoginData.init(res.arena, email);
    defer login_data.deinit();

    email_exists: {
        _ = login_data.get(.account_id) catch |e| if (e == error.NoData) break :email_exists;
        res.body = "Email already exists";
        return;
    }

    var names = db.Names.init(res.arena);
    defer names.deinit();

    name_exists: {
        _ = names.get(name) catch |e| if (e == error.NoData) break :name_exists;
        res.body = "Name already exists";
        return;
    }

    const acc_id = db.nextAccId() catch {
        res.body = "Database failure";
        return;
    };
    try login_data.set(.{ .account_id = acc_id });
    try names.set(name, acc_id);

    var out: [256]u8 = undefined;
    const scrypt = std.crypto.pwhash.scrypt;
    const hashed_pass = try scrypt.strHash(password, .{
        .allocator = res.arena,
        .params = scrypt.Params.interactive,
        .encoding = .crypt,
    }, &out);
    try login_data.set(.{ .hashed_password = hashed_pass });
    const token = db.csprng.random().int(u128);
    try login_data.set(.{ .token = token });

    var acc_data = db.AccountData.init(res.arena, acc_id);
    defer acc_data.deinit();

    const timestamp = std.time.milliTimestamp();

    try acc_data.set(.{ .email = email });
    try acc_data.set(.{ .name = name });
    try acc_data.set(.{ .hwid = hwid });
    try acc_data.set(.{ .register_timestamp = timestamp });
    try acc_data.set(.{ .last_login_timestamp = timestamp });
    try acc_data.set(.{ .mute_expiry = 0 });
    try acc_data.set(.{ .ban_expiry = 0 });
    try acc_data.set(.{ .gold = 0 });
    try acc_data.set(.{ .fame = 0 });
    try acc_data.set(.{ .rank = if (acc_id == 0) .admin else .default });
    try acc_data.set(.{ .next_char_id = 0 });
    try acc_data.set(.{ .alive_char_ids = &[0]u32{} });
    try acc_data.set(.{ .max_char_slots = 2 });
    try acc_data.set(.{ .stash_chests = &.{[_]u16{std.math.maxInt(u16)} ** 8} });
    var default_class_quests: std.ArrayListUnmanaged(network_data.ClassQuests) = .{};
    var iter = game_data.class.from_id.valueIterator();
    while (iter.next()) |data| {
        try default_class_quests.append(res.arena, .{ .class_id = data.id, .quests_complete = 0 });
    }
    try acc_data.set(.{ .class_quests = default_class_quests.items });

    const list: network_data.CharacterListData = .{
        .name = try acc_data.get(.name),
        .token = token,
        .rank = try acc_data.get(.rank),
        .next_char_id = try acc_data.get(.next_char_id),
        .max_chars = try acc_data.get(.max_char_slots),
        .class_quests = try acc_data.get(.class_quests),
        .characters = &.{},
        .servers = &.{.{
            .name = settings.server_name,
            .ip = settings.public_ip,
            .port = settings.game_port,
            .max_players = 500,
            .admin_only = false,
        }}, // todo
    };

    res.body = try std.json.stringifyAlloc(res.arena, list, .{});
}

fn handleAccountVerify(_: Handlers, req: *httpz.Request, res: *httpz.Response) !void {
    rpmalloc.initThread() catch {
        res.body = "Thread initialization failed";
        return;
    };
    defer rpmalloc.deinitThread(true);

    const query = try req.query();
    const email = query.get("email") orelse {
        res.body = "Invalid email";
        return;
    };
    const password = query.get("password") orelse {
        res.body = "Invalid password";
        return;
    };

    var login_data = db.LoginData.init(res.arena, email);
    defer login_data.deinit();
    const hashed_pw = login_data.get(.hashed_password) catch |e| {
        res.body = if (e == error.NoData)
            "Invalid email"
        else
            "Unknown error";
        return;
    };
    std.crypto.pwhash.scrypt.strVerify(hashed_pw, password, .{ .allocator = res.arena }) catch |e| {
        res.body = if (e == std.crypto.pwhash.HasherError.PasswordVerificationFailed)
            "Invalid credentials"
        else
            "Unknown error";
        return;
    };
    const acc_id = try login_data.get(.account_id);
    const token = db.csprng.random().int(u128);
    try login_data.set(.{ .token = token });

    var acc_data = db.AccountData.init(res.arena, acc_id);
    defer acc_data.deinit();

    if (try db.accountBanned(&acc_data)) {
        res.body = "Account banned";
        return;
    }

    var char_list: std.ArrayListUnmanaged(network_data.CharacterData) = .{};
    buildList: {
        for (acc_data.get(.alive_char_ids) catch break :buildList) |char_id| {
            var char_data = db.CharacterData.init(res.arena, acc_id, char_id);
            defer char_data.deinit();

            const stats = try char_data.get(.stats);
            try char_list.append(res.arena, .{
                .char_id = char_id,
                .class_id = try char_data.get(.class_id),
                .health = stats[0],
                .mana = stats[1],
                .attack = stats[2],
                .defense = stats[3],
                .speed = stats[4],
                .dexterity = stats[5],
                .vitality = stats[6],
                .wisdom = stats[7],
                .items = &try char_data.get(.items),
            });
        }
    }

    const list: network_data.CharacterListData = .{
        .name = try acc_data.get(.name),
        .token = token,
        .rank = try acc_data.get(.rank),
        .next_char_id = try acc_data.get(.next_char_id),
        .max_chars = try acc_data.get(.max_char_slots),
        .class_quests = try acc_data.get(.class_quests),
        .characters = char_list.items,
        .servers = &.{.{
            .name = settings.server_name,
            .ip = settings.public_ip,
            .port = settings.game_port,
            .max_players = 500,
            .admin_only = false,
        }}, // todo
    };

    res.body = try std.json.stringifyAlloc(res.arena, list, .{});
}

fn handleCharList(_: Handlers, req: *httpz.Request, res: *httpz.Response) !void {
    rpmalloc.initThread() catch {
        res.body = "Thread initialization failed";
        return;
    };
    defer rpmalloc.deinitThread(true);

    const query = try req.query();
    const email = query.get("email") orelse {
        res.body = "Invalid email";
        return;
    };
    const token = std.fmt.parseInt(u128, query.get("token") orelse {
        res.body = "Invalid token";
        return;
    }, 10) catch {
        res.body = "Invalid token";
        return;
    };

    const acc_id = db.login(email, token) catch |e| {
        res.body = switch (e) {
            error.NoData => "Invalid email",
            error.InvalidToken => "Invalid token",
            else => "Unknown error",
        };
        return;
    };

    var acc_data = db.AccountData.init(res.arena, acc_id);
    defer acc_data.deinit();

    if (try db.accountBanned(&acc_data)) {
        res.body = "Account banned";
        return;
    }

    var char_list: std.ArrayListUnmanaged(network_data.CharacterData) = .{};
    buildList: {
        for (acc_data.get(.alive_char_ids) catch break :buildList) |char_id| {
            var char_data = db.CharacterData.init(res.arena, acc_id, char_id);
            defer char_data.deinit();

            const stats = try char_data.get(.stats);
            try char_list.append(res.arena, .{
                .char_id = char_id,
                .class_id = try char_data.get(.class_id),
                .health = stats[0],
                .mana = stats[1],
                .attack = stats[2],
                .defense = stats[3],
                .speed = stats[4],
                .dexterity = stats[5],
                .vitality = stats[6],
                .wisdom = stats[7],
                .items = &try char_data.get(.items),
            });
        }
    }

    const list: network_data.CharacterListData = .{
        .name = try acc_data.get(.name),
        .token = 0,
        .rank = try acc_data.get(.rank),
        .next_char_id = try acc_data.get(.next_char_id),
        .max_chars = try acc_data.get(.max_char_slots),
        .class_quests = try acc_data.get(.class_quests),
        .characters = char_list.items,
        .servers = &.{.{
            .name = settings.server_name,
            .ip = settings.public_ip,
            .port = settings.game_port,
            .max_players = 500,
            .admin_only = false,
        }}, // todo
    };

    res.body = try std.json.stringifyAlloc(res.arena, list, .{});
}
