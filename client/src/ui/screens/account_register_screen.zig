const std = @import("std");
const shared = @import("shared");
const requests = shared.requests;
const network_data = shared.network_data;
const element = @import("../element.zig");
const assets = @import("../../assets.zig");
const camera = @import("../../camera.zig");
const main = @import("../../main.zig");
const rpc = @import("rpc");
const dialog = @import("../dialogs/dialog.zig");
const build_options = @import("options");
const ui_systems = @import("../systems.zig");
const builtin = @import("builtin");

const Interactable = element.InteractableImageData;

pub const AccountRegisterScreen = struct {
    username_text: *element.Text = undefined,
    username_input: *element.Input = undefined,
    email_text: *element.Text = undefined,
    email_input: *element.Input = undefined,
    password_text: *element.Text = undefined,
    password_input: *element.Input = undefined,
    password_repeat_text: *element.Text = undefined,
    password_repeat_input: *element.Input = undefined,
    confirm_button: *element.Button = undefined,
    back_button: *element.Button = undefined,
    inited: bool = false,

    allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator) !*AccountRegisterScreen {
        var screen = try allocator.create(AccountRegisterScreen);
        screen.* = .{ .allocator = allocator };

        const presence = rpc.Packet.Presence{
            .assets = .{
                .large_image = rpc.Packet.ArrayString(256).create("logo"),
                .large_text = rpc.Packet.ArrayString(128).create("v" ++ build_options.version),
            },
            .state = rpc.Packet.ArrayString(128).create("Register Screen"),
            .timestamps = .{
                .start = main.rpc_start,
            },
        };
        try main.rpc_client.setPresence(presence);

        const input_w = 300;
        const input_h = 50;

        const input_data_base = assets.getUiData("text_input_base", 0);
        const input_data_hover = assets.getUiData("text_input_hover", 0);
        const input_data_press = assets.getUiData("text_input_press", 0);

        const x_offset = (camera.screen_width - input_w) / 2;
        var y_offset: f32 = camera.screen_height / 7.2;

        screen.username_text = try element.create(allocator, element.Text{
            .x = x_offset,
            .y = y_offset,
            .text_data = .{
                .text = "Username",
                .size = 20,
                .text_type = .bold,
                .hori_align = .middle,
                .vert_align = .middle,
                .max_width = input_w,
                .max_height = input_h,
            },
        });

        y_offset += 50;

        const cursor_data = assets.getUiData("chatbox_cursor", 0);
        screen.username_input = try element.create(allocator, element.Input{
            .x = x_offset,
            .y = y_offset,
            .text_inlay_x = 9,
            .text_inlay_y = 8,
            .image_data = Interactable.fromNineSlices(input_data_base, input_data_hover, input_data_press, input_w, input_h, 12, 12, 2, 2, 1.0),
            .cursor_image_data = .{ .normal = .{ .atlas_data = cursor_data } },
            .text_data = .{
                .text = "",
                .size = 20,
                .text_type = .bold,
                .max_chars = 256,
                .handle_special_chars = false,
            },
            .allocator = allocator,
        });

        y_offset += 50;

        screen.email_text = try element.create(allocator, element.Text{
            .x = x_offset,
            .y = y_offset,
            .text_data = .{
                .text = "E-mail",
                .size = 20,
                .text_type = .bold,
                .hori_align = .middle,
                .vert_align = .middle,
                .max_width = input_w,
                .max_height = input_h,
            },
        });

        y_offset += 50;

        screen.email_input = try element.create(allocator, element.Input{
            .x = x_offset,
            .y = y_offset,
            .text_inlay_x = 9,
            .text_inlay_y = 8,
            .image_data = Interactable.fromNineSlices(input_data_base, input_data_hover, input_data_press, input_w, input_h, 12, 12, 2, 2, 1.0),
            .cursor_image_data = .{ .normal = .{ .atlas_data = cursor_data } },
            .text_data = .{
                .text = "",
                .size = 20,
                .text_type = .bold,
                .max_chars = 256,
                .handle_special_chars = false,
            },
            .allocator = allocator,
        });

        y_offset += 50;

        screen.password_text = try element.create(allocator, element.Text{
            .x = x_offset,
            .y = y_offset,
            .text_data = .{
                .text = "Password",
                .size = 20,
                .text_type = .bold,
                .hori_align = .middle,
                .vert_align = .middle,
                .max_width = input_w,
                .max_height = input_h,
            },
        });

        y_offset += 50;

        screen.password_input = try element.create(allocator, element.Input{
            .x = x_offset,
            .y = y_offset,
            .text_inlay_x = 9,
            .text_inlay_y = 8,
            .image_data = Interactable.fromNineSlices(input_data_base, input_data_hover, input_data_press, input_w, input_h, 12, 12, 2, 2, 1.0),
            .cursor_image_data = .{ .normal = .{ .atlas_data = cursor_data } },
            .text_data = .{
                .text = "",
                .size = 20,
                .text_type = .bold,
                .password = true,
                .max_chars = 256,
                .handle_special_chars = false,
            },
            .allocator = allocator,
        });

        y_offset += 50;

        screen.password_repeat_text = try element.create(allocator, element.Text{
            .x = x_offset,
            .y = y_offset,
            .text_data = .{
                .text = "Confirm Password",
                .size = 20,
                .text_type = .bold,
                .hori_align = .middle,
                .vert_align = .middle,
                .max_width = input_w,
                .max_height = input_h,
            },
        });

        y_offset += 50;

        screen.password_repeat_input = try element.create(allocator, element.Input{
            .x = x_offset,
            .y = y_offset,
            .text_inlay_x = 9,
            .text_inlay_y = 8,
            .image_data = Interactable.fromNineSlices(input_data_base, input_data_hover, input_data_press, input_w, input_h, 12, 12, 2, 2, 1.0),
            .cursor_image_data = .{ .normal = .{ .atlas_data = cursor_data } },
            .text_data = .{
                .text = "",
                .size = 20,
                .text_type = .bold,
                .password = true,
                .max_chars = 256,
                .handle_special_chars = false,
            },
            .allocator = allocator,
        });

        y_offset += 75;

        const button_data_base = assets.getUiData("button_base", 0);
        const button_data_hover = assets.getUiData("button_hover", 0);
        const button_data_press = assets.getUiData("button_press", 0);
        const button_width = 100;
        const button_height = 35;

        screen.confirm_button = try element.create(allocator, element.Button{
            .x = x_offset + (input_w - (button_width * 2)) / 2 - 12.5,
            .y = y_offset,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Confirm",
                .size = 16,
                .text_type = .bold,
            },
            .userdata = screen,
            .press_callback = registerCallback,
        });

        screen.back_button = try element.create(allocator, element.Button{
            .x = screen.confirm_button.x + button_width + 25,
            .y = y_offset,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Back",
                .size = 16,
                .text_type = .bold,
            },
            .press_callback = backCallback,
        });

        screen.inited = true;
        return screen;
    }

    pub fn deinit(self: *AccountRegisterScreen) void {
        self.inited = false;

        element.destroy(self.username_text);
        element.destroy(self.username_input);
        element.destroy(self.email_text);
        element.destroy(self.email_input);
        element.destroy(self.password_text);
        element.destroy(self.password_input);
        element.destroy(self.password_repeat_input);
        element.destroy(self.password_repeat_text);
        element.destroy(self.confirm_button);
        element.destroy(self.back_button);

        self.allocator.destroy(self);
    }

    pub fn resize(self: *AccountRegisterScreen, w: f32, h: f32) void {
        self.username_text.x = (w - 300) / 2;
        self.username_text.y = h / 7.2;
        self.username_input.x = self.username_text.x;
        self.username_input.y = self.username_text.y + 50;
        self.email_text.x = self.username_input.x;
        self.email_text.y = self.username_input.y + 50;
        self.email_input.x = self.email_text.x;
        self.email_input.y = self.email_text.y + 50;
        self.password_text.x = self.email_input.x;
        self.password_text.y = self.email_input.y + 50;
        self.password_input.x = self.password_text.x;
        self.password_input.y = self.password_text.y + 50;
        self.password_repeat_text.x = self.password_input.x;
        self.password_repeat_text.y = self.password_input.y + 50;
        self.password_repeat_input.x = self.password_repeat_text.x;
        self.password_repeat_input.y = self.password_repeat_text.y + 50;
        self.confirm_button.x = self.password_repeat_input.x + 100 / 2 - 12.5;
        self.confirm_button.y = self.password_repeat_input.y + 75;
        self.back_button.x = self.confirm_button.x + 125;
        self.back_button.y = self.confirm_button.y;
    }

    pub fn update(_: *AccountRegisterScreen, _: i64, _: f32) !void {}

    fn getHwid(allocator: std.mem.Allocator) ![]const u8 {
        return switch (builtin.os.tag) {
            .windows => {
                const windows = std.os.windows;
                const sub_key = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "SOFTWARE\\Microsoft\\Cryptography");
                defer allocator.free(sub_key);
                const value = try std.unicode.utf8ToUtf16LeAllocZ(allocator, "MachineGuid");
                defer allocator.free(value);
                var buf: [128:0]u16 = undefined;
                var len: u32 = 128;
                _ = windows.advapi32.RegGetValueW(
                    windows.HKEY_LOCAL_MACHINE,
                    sub_key,
                    value,
                    windows.advapi32.RRF.SUBKEY_WOW6464KEY | windows.advapi32.RRF.RT_REG_SZ,
                    null,
                    &buf,
                    &len,
                );
                return try std.unicode.utf16LeToUtf8Alloc(allocator, std.mem.span(@as([*:0]const u16, &buf)));
            },
            .macos => {
                const proc = std.process.Child.run(.{
                    .allocator = allocator,
                    .argv = &.{ "ioreg", "-rd1", "-c", "IOPlatformExpertDevice" },
                }) catch @panic("Failed to spawn child process");
                defer {
                    allocator.free(proc.stdout);
                    allocator.free(proc.stderr);
                }
                var line_split = std.mem.splitScalar(u8, proc.stdout, '\n');
                while (line_split.next()) |line| {
                    if (std.mem.indexOf(u8, line, "IOPlatformUUID") != null) {
                        const left_bound = (std.mem.indexOf(u8, line, " = \"") orelse @panic("No HWID found")) + " = \"".len;
                        const right_bound = std.mem.lastIndexOfScalar(u8, line, '"') orelse @panic("No HWID found");
                        return allocator.dupe(u8, line[left_bound..right_bound]) catch @panic("OOM");
                    }
                }
                @panic("No HWID found");
            },
            .linux => {
                tryVar: {
                    const file = std.fs.cwd().openFile("/var/lib/dbus/machine-id", .{}) catch break :tryVar;
                    defer file.close();

                    var buf: [256]u8 = undefined;
                    const size = try file.readAll(&buf);
                    return std.mem.trim(u8, std.mem.trim(u8, buf[0..size], " "), "\n");
                }

                tryEtc: {
                    const file = std.fs.cwd().openFile("/etc/machine-id", .{}) catch break :tryEtc;
                    defer file.close();

                    var buf: [256]u8 = undefined;
                    const size = try file.readAll(&buf);
                    return std.mem.trim(u8, std.mem.trim(u8, buf[0..size], " "), "\n");
                }

                @panic("No hwid found");
            },
            else => @compileError("Unsupported OS"),
        };
    }

    fn register(allocator: std.mem.Allocator, email: []const u8, password: []const u8, name: []const u8) !bool {
        const hwid = try getHwid(allocator);
        defer if (builtin.os.tag == .windows or builtin.os.tag == .macos) allocator.free(hwid);
        var data: std.StringHashMapUnmanaged([]const u8) = .{};
        try data.put(allocator, "name", name);
        try data.put(allocator, "hwid", hwid);
        try data.put(allocator, "email", email);
        try data.put(allocator, "password", password);
        defer data.deinit(allocator);

        var needs_free = true;
        const response = requests.sendRequest(build_options.login_server_uri ++ "account/register", data) catch |e| blk: {
            switch (e) {
                error.ConnectionRefused => {
                    needs_free = false;
                    break :blk "Connection Refused";
                },
                else => return e,
            }
        };
        defer if (needs_free) requests.freeResponse(response);

        main.character_list = std.json.parseFromSliceLeaky(network_data.CharacterListData, allocator, response, .{ .allocate = .alloc_always }) catch {
            dialog.showDialog(.text, .{
                .title = "Login Failed",
                .body = try std.fmt.allocPrint(allocator, "Error: {s}", .{response}),
            });
            return false;
        };
        main.current_account = .{
            .email = try allocator.dupe(u8, email),
            .token = main.character_list.?.token,
        };

        if (main.character_list.?.characters.len > 0)
            ui_systems.switchScreen(.char_select)
        else
            ui_systems.switchScreen(.char_create);
        return true;
    }

    fn registerCallback(ud: ?*anyopaque) void {
        const current_screen: *AccountRegisterScreen = @alignCast(@ptrCast(ud.?));
        _ = register(
            main.account_arena_allocator,
            current_screen.email_input.text_data.text,
            current_screen.password_input.text_data.text,
            current_screen.username_input.text_data.text,
        ) catch |e| {
            std.log.err("Register failed: {}", .{e});
            return;
        };
    }

    fn backCallback(_: ?*anyopaque) void {
        ui_systems.switchScreen(.main_menu);
    }
};
