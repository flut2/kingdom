const glfw = @import("zglfw");
const std = @import("std");
const map = @import("game/map.zig");
const main = @import("main.zig");
const camera = @import("camera.zig");
const element = @import("ui/element.zig");
const assets = @import("assets.zig");
const network = @import("network.zig");
const game_data = @import("shared").game_data;
const ui_systems = @import("ui/systems.zig");

const Player = @import("game/player.zig").Player;
const GameScreen = @import("ui/screens/game_screen.zig").GameScreen;

var move_up: f32 = 0.0;
var move_down: f32 = 0.0;
var move_left: f32 = 0.0;
var move_right: f32 = 0.0;
var rotate_left: i8 = 0;
var rotate_right: i8 = 0;
pub var allocator: std.mem.Allocator = undefined;

pub var attacking: bool = false;
pub var walking_speed_multiplier: f32 = 1.0;
pub var rotate: i8 = 0;
pub var move_angle: f32 = std.math.nan(f32);
pub var mouse_x: f32 = 0.0;
pub var mouse_y: f32 = 0.0;

pub var selected_key_mapper: ?*element.KeyMapper = null;
pub var selected_input_field: ?*element.Input = null;
pub var input_history: std.ArrayListUnmanaged([]const u8) = .{};
pub var input_history_idx: u16 = 0;

pub var disable_input: bool = false;

pub fn reset() void {
    move_up = 0.0;
    move_down = 0.0;
    move_left = 0.0;
    move_right = 0.0;
    rotate_left = 0;
    rotate_right = 0;
    rotate = 0;
    attacking = false;
}

pub fn init(ally: std.mem.Allocator) void {
    allocator = ally;
}

pub fn deinit() void {
    for (input_history.items) |msg| {
        allocator.free(msg);
    }
    input_history.deinit(allocator);
}

fn keyPress(window: *glfw.Window, key: glfw.Key) void {
    if (ui_systems.screen != .game and ui_systems.screen != .editor)
        return;

    if (disable_input)
        return;

    if (key == main.settings.move_up.getKey()) {
        move_up = 1.0;
    } else if (key == main.settings.move_down.getKey()) {
        move_down = 1.0;
    } else if (key == main.settings.move_left.getKey()) {
        move_left = 1.0;
    } else if (key == main.settings.move_right.getKey()) {
        move_right = 1.0;
    } else if (key == main.settings.rotate_left.getKey()) {
        rotate_left = 1;
    } else if (key == main.settings.rotate_right.getKey()) {
        rotate_right = 1;
    } else if (key == main.settings.walk.getKey()) {
        walking_speed_multiplier = 0.5;
    } else if (key == main.settings.reset_camera.getKey()) {
        camera.angle = 0;
    } else if (key == main.settings.shoot.getKey()) {
        if (ui_systems.screen == .game) {
            attacking = true;
        }
    } else if (key == main.settings.ability.getKey()) {
        var lock = map.useLockForType(Player);
        lock.lock();
        defer lock.unlock();
        if (map.localPlayerRef()) |player| player.useAbility();
    } else if (key == main.settings.options.getKey()) {
        openOptions();
    } else if (key == main.settings.escape.getKey()) {
        if (ui_systems.screen == .game) main.server.sendPacket(.{ .escape = .{} });
    } else if (key == main.settings.interact.getKey()) {
        const int_id = map.interactive.map_id.load(.acquire);
        if (int_id != -1) {
            switch (map.interactive.type.load(.acquire)) {
                .portal => main.server.sendPacket(.{ .use_portal = .{ .portal_map_id = int_id } }),
                else => {},
            }
        }
    } else if (key == main.settings.chat.getKey()) {
        selected_input_field = ui_systems.screen.game.chat_input;
        selected_input_field.?.last_input = 0;
    } else if (key == main.settings.chat_cmd.getKey()) {
        charEvent(window, @intFromEnum(glfw.Key.slash));
        selected_input_field = ui_systems.screen.game.chat_input;
        selected_input_field.?.last_input = 0;
    } else if (key == main.settings.toggle_perf_stats.getKey()) {
        main.settings.stats_enabled = !main.settings.stats_enabled;
    } else if (key == main.settings.toggle_stats.getKey()) {
        if (ui_systems.screen == .game) {
            GameScreen.statsCallback(ui_systems.screen.game);
        }
    }
}

fn keyRelease(key: glfw.Key) void {
    if (ui_systems.screen != .game and ui_systems.screen != .editor)
        return;

    if (disable_input)
        return;

    if (key == main.settings.move_up.getKey()) {
        move_up = 0.0;
    } else if (key == main.settings.move_down.getKey()) {
        move_down = 0.0;
    } else if (key == main.settings.move_left.getKey()) {
        move_left = 0.0;
    } else if (key == main.settings.move_right.getKey()) {
        move_right = 0.0;
    } else if (key == main.settings.rotate_left.getKey()) {
        rotate_left = 0;
    } else if (key == main.settings.rotate_right.getKey()) {
        rotate_right = 0;
    } else if (key == main.settings.walk.getKey()) {
        walking_speed_multiplier = 1.0;
    } else if (key == main.settings.shoot.getKey()) {
        if (ui_systems.screen == .game) {
            attacking = false;
        }
    }
}

fn mousePress(window: *glfw.Window, button: glfw.MouseButton) void {
    if (ui_systems.screen != .game and ui_systems.screen != .editor)
        return;

    if (disable_input)
        return;

    if (button == main.settings.move_up.getMouse()) {
        move_up = 1.0;
    } else if (button == main.settings.move_down.getMouse()) {
        move_down = 1.0;
    } else if (button == main.settings.move_left.getMouse()) {
        move_left = 1.0;
    } else if (button == main.settings.move_right.getMouse()) {
        move_right = 1.0;
    } else if (button == main.settings.rotate_left.getMouse()) {
        rotate_left = 1;
    } else if (button == main.settings.rotate_right.getMouse()) {
        rotate_right = 1;
    } else if (button == main.settings.walk.getMouse()) {
        walking_speed_multiplier = 0.5;
    } else if (button == main.settings.reset_camera.getMouse()) {
        camera.angle = 0;
    } else if (button == main.settings.shoot.getMouse()) {
        if (ui_systems.screen == .game) {
            attacking = true;
        }
    } else if (button == main.settings.ability.getMouse()) {
        var lock = map.useLockForType(Player);
        lock.lock();
        defer lock.unlock();
        if (map.localPlayerRef()) |player| player.useAbility();
    } else if (button == main.settings.options.getMouse()) {
        openOptions();
    } else if (button == main.settings.escape.getMouse()) {
        if (ui_systems.screen == .game) main.server.sendPacket(.{ .escape = .{} });
    } else if (button == main.settings.interact.getMouse()) {
        const int_id = map.interactive.map_id.load(.acquire);
        if (int_id != -1) {
            switch (map.interactive.type.load(.acquire)) {
                .portal => main.server.sendPacket(.{ .use_portal = .{ .portal_map_id = int_id } }),
                else => {},
            }
        }
    } else if (button == main.settings.chat.getMouse()) {
        if (ui_systems.screen == .game) {
            selected_input_field = ui_systems.screen.game.chat_input;
            selected_input_field.?.last_input = 0;
        }
    } else if (button == main.settings.chat_cmd.getMouse()) {
        if (ui_systems.screen == .game) {
            charEvent(window, @intFromEnum(glfw.Key.slash));
            selected_input_field = ui_systems.screen.game.chat_input;
            selected_input_field.?.last_input = 0;
        }
    } else if (button == main.settings.toggle_perf_stats.getMouse()) {
        main.settings.stats_enabled = !main.settings.stats_enabled;
    } else if (button == main.settings.toggle_stats.getMouse()) {
        if (ui_systems.screen == .game) {
            GameScreen.statsCallback(ui_systems.screen.game);
        }
    }
}

fn mouseRelease(button: glfw.MouseButton) void {
    if (ui_systems.screen != .game and ui_systems.screen != .editor)
        return;

    if (disable_input)
        return;

    if (button == main.settings.move_up.getMouse()) {
        move_up = 0.0;
    } else if (button == main.settings.move_down.getMouse()) {
        move_down = 0.0;
    } else if (button == main.settings.move_left.getMouse()) {
        move_left = 0.0;
    } else if (button == main.settings.move_right.getMouse()) {
        move_right = 0.0;
    } else if (button == main.settings.rotate_left.getMouse()) {
        rotate_left = 0;
    } else if (button == main.settings.rotate_right.getMouse()) {
        rotate_right = 0;
    } else if (button == main.settings.walk.getMouse()) {
        walking_speed_multiplier = 1.0;
    } else if (button == main.settings.shoot.getMouse()) {
        if (ui_systems.screen == .game) {
            attacking = false;
        }
    }
}

pub fn charEvent(_: *glfw.Window, char: u32) callconv(.C) void {
    if (selected_input_field) |input_field| {
        if (char > std.math.maxInt(u8) or char < std.math.minInt(u8)) {
            return;
        }

        const byte_code: u8 = @intCast(char);
        if (!std.ascii.isASCII(byte_code) or input_field.index >= 256)
            return;

        input_field.text_data.backing_buffer[input_field.index] = byte_code;
        input_field.index += 1;
        input_field.text_data.text = input_field.text_data.backing_buffer[0..input_field.index];
        input_field.inputUpdate();
        return;
    }
}

pub fn keyEvent(window: *glfw.Window, key: glfw.Key, _: i32, action: glfw.Action, mods: glfw.Mods) callconv(.C) void {
    if (action == .press or action == .repeat) {
        if (selected_key_mapper) |key_mapper| {
            key_mapper.mouse = .eight;
            key_mapper.key = key;
            key_mapper.listening = false;
            key_mapper.set_key_callback(key_mapper);
            selected_key_mapper = null;
        }

        if (selected_input_field) |input_field| {
            if (mods.control) {
                switch (key) {
                    .c => {
                        const old = input_field.text_data.text;
                        input_field.text_data.backing_buffer[input_field.index] = 0;
                        window.setClipboardString(input_field.text_data.backing_buffer[0..input_field.index :0]);
                        input_field.text_data.text = old;
                    },
                    .v => {
                        if (window.getClipboardString()) |clip_str| {
                            const clip_len = clip_str.len;
                            @memcpy(input_field.text_data.backing_buffer[input_field.index .. input_field.index + clip_len], clip_str);
                            input_field.index += @intCast(clip_len);
                            input_field.text_data.text = input_field.text_data.backing_buffer[0..input_field.index];
                            input_field.inputUpdate();
                            return;
                        }
                    },
                    .x => {
                        input_field.text_data.backing_buffer[input_field.index] = 0;
                        window.setClipboardString(input_field.text_data.backing_buffer[0..input_field.index :0]);
                        input_field.clear();
                        return;
                    },
                    else => {},
                }
            }

            switch (key) {
                .enter => {
                    if (input_field.enter_callback) |enter_cb| {
                        enter_cb(input_field.text_data.text);
                        input_field.clear();
                        input_field.last_input = -1;
                        selected_input_field = null;
                    }

                    return;
                },
                .backspace => {
                    if (input_field.index > 0) {
                        input_field.index -= 1;
                        input_field.text_data.text = input_field.text_data.backing_buffer[0..input_field.index];
                        input_field.inputUpdate();
                        return;
                    }
                },
                else => {},
            }

            if (input_field.is_chat) {
                if (key == .up) {
                    if (input_history_idx > 0) {
                        input_history_idx -= 1;
                        const msg = input_history.items[input_history_idx];
                        const msg_len = msg.len;
                        @memcpy(input_field.text_data.backing_buffer[0..msg_len], msg);
                        input_field.text_data.text = input_field.text_data.backing_buffer[0..msg_len];
                        input_field.index = @intCast(msg_len);
                        input_field.inputUpdate();
                    }

                    return;
                }

                if (key == .down) {
                    if (input_history_idx < input_history.items.len) {
                        input_history_idx += 1;

                        if (input_history_idx == input_history.items.len) {
                            input_field.clear();
                        } else {
                            const msg = input_history.items[input_history_idx];
                            const msg_len = msg.len;
                            @memcpy(input_field.text_data.backing_buffer[0..msg_len], msg);
                            input_field.text_data.text = input_field.text_data.backing_buffer[0..msg_len];
                            input_field.index = @intCast(msg_len);
                            input_field.inputUpdate();
                        }
                    }

                    return;
                }
            }

            return;
        }
    }

    if (action == .press) {
        keyPress(window, key);
        if (ui_systems.screen == .editor) {
            ui_systems.screen.editor.onKeyPress(key);
        }
    } else if (action == .release) {
        keyRelease(key);
        if (ui_systems.screen == .editor) {
            ui_systems.screen.editor.onKeyRelease(key);
        }
    }

    updateState();
}

pub fn mouseEvent(window: *glfw.Window, button: glfw.MouseButton, action: glfw.Action, mods: glfw.Mods) callconv(.C) void {
    if (action == .press) {
        window.setCursor(switch (main.settings.cursor_type) {
            .basic => assets.default_cursor_pressed,
            .royal => assets.royal_cursor_pressed,
            .ranger => assets.ranger_cursor_pressed,
            .aztec => assets.aztec_cursor_pressed,
            .fiery => assets.fiery_cursor_pressed,
            .target_enemy => assets.target_enemy_cursor_pressed,
            .target_ally => assets.target_ally_cursor_pressed,
        });
    } else if (action == .release) {
        window.setCursor(switch (main.settings.cursor_type) {
            .basic => assets.default_cursor,
            .royal => assets.royal_cursor,
            .ranger => assets.ranger_cursor,
            .aztec => assets.aztec_cursor,
            .fiery => assets.fiery_cursor,
            .target_enemy => assets.target_enemy_cursor,
            .target_ally => assets.target_ally_cursor,
        });
    }
    if (action == .press) {
        if (!ui_systems.mousePress(mouse_x, mouse_y, mods, button)) {
            mousePress(window, button);

            if (ui_systems.screen == .editor) {
                ui_systems.screen.editor.onMousePress(button);
            }
        }
    } else if (action == .release) {
        if (!ui_systems.mouseRelease(mouse_x, mouse_y)) {
            if (ui_systems.screen == .editor) {
                ui_systems.screen.editor.onMouseRelease(button);
            }
            mouseRelease(button);
        }
    }

    updateState();
}

pub fn updateState() void {
    rotate = rotate_right - rotate_left;
    const y_dt = move_down - move_up;
    const x_dt = move_right - move_left;
    move_angle = if (y_dt == 0 and x_dt == 0) std.math.nan(f32) else std.math.atan2(y_dt, x_dt);
}

pub fn mouseMoveEvent(_: *glfw.Window, x_pos: f64, y_pos: f64) callconv(.C) void {
    mouse_x = @floatCast(x_pos);
    mouse_y = @floatCast(y_pos);

    _ = ui_systems.mouseMove(mouse_x, mouse_y);
}

pub fn scrollEvent(_: *glfw.Window, x_offset: f64, y_offset: f64) callconv(.C) void {
    if (!ui_systems.mouseScroll(mouse_x, mouse_y, @floatCast(x_offset), @floatCast(y_offset))) {
        switch (ui_systems.screen) {
            .game => {
                const size = @max(map.info.width, map.info.height);
                const max_zoom: f32 = @floatFromInt(@divFloor(size, 32));
                const scroll_speed = @as(f32, @floatFromInt(size)) / 1280;

                camera.minimap_zoom += @floatCast(y_offset * scroll_speed);
                camera.minimap_zoom = @max(1, @min(max_zoom, camera.minimap_zoom));
            },
            .editor => {
                const min_zoom = 0.05;
                const scroll_speed = 0.01;

                camera.scale += @floatCast(y_offset * scroll_speed);
                camera.scale = @min(1, @max(min_zoom, camera.scale));
            },
            else => {},
        }
    }
}

pub fn openOptions() void {
    if (ui_systems.screen == .game) {
        ui_systems.screen.game.options.setVisible(true);
        disable_input = true;
    }
}
