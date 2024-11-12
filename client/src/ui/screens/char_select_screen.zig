const std = @import("std");
const element = @import("../element.zig");
const assets = @import("../../assets.zig");
const camera = @import("../../camera.zig");
const main = @import("../../main.zig");
const rpc = @import("rpc");
const ui_systems = @import("../systems.zig");
const build_options = @import("options");
const game_data = @import("shared").game_data;

const Interactable = element.InteractableImageData;

pub const CharSelectScreen = struct {
    boxes: std.ArrayListUnmanaged(*element.CharacterBox) = .{},
    inited: bool = false,

    allocator: std.mem.Allocator = undefined,
    new_char_button: *element.Button = undefined,
    editor_button: *element.Button = undefined,
    back_button: *element.Button = undefined,

    pub fn init(allocator: std.mem.Allocator) !*CharSelectScreen {
        var screen = try allocator.create(CharSelectScreen);
        screen.* = .{ .allocator = allocator };

        const presence: rpc.Packet.Presence = .{
            .assets = .{
                .large_image = rpc.Packet.ArrayString(256).create("logo"),
                .large_text = rpc.Packet.ArrayString(128).create("v" ++ build_options.version),
            },
            .state = rpc.Packet.ArrayString(128).create("Character Select"),
            .timestamps = .{ .start = main.rpc_start },
        };
        try main.rpc_client.setPresence(presence);

        const button_data_base = assets.getUiData("button_base", 0);
        const button_data_hover = assets.getUiData("button_hover", 0);
        const button_data_press = assets.getUiData("button_press", 0);
        const button_width = 100;
        const button_height = 40;

        var counter: u32 = 0;
        if (main.character_list) |list| {
            for (list.characters, 0..) |char, i| {
                counter += 1;

                if (game_data.class.from_id.get(char.class_id)) |class| {
                    const box = try element.create(allocator, element.CharacterBox{
                        .x = (camera.screen_width - button_data_base.width()) / 2,
                        .y = @floatFromInt(50 * i),
                        .id = char.char_id,
                        .class_data_id = char.class_id,
                        .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
                        .text_data = .{
                            .text = class.name,
                            .size = 16,
                            .text_type = .bold,
                        },
                        .press_callback = boxClickCallback,
                    });
                    try screen.boxes.append(allocator, box);
                }
            }
        }

        screen.new_char_button = try element.create(allocator, element.Button{
            .x = (camera.screen_width - button_data_base.width()) / 2,
            .y = @floatFromInt(50 * (counter + 1)),
            .visible = false,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "New Character",
                .size = 16,
                .text_type = .bold,
            },
            .press_callback = newCharCallback,
        });

        if (counter < if (main.character_list) |list| list.max_chars else 0)
            screen.new_char_button.visible = true;

        screen.editor_button = try element.create(allocator, element.Button{
            .x = 100,
            .y = 100,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, 200, 35, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Editor",
                .size = 16,
                .text_type = .bold,
            },
            .press_callback = editorCallback,
        });

        screen.back_button = try element.create(allocator, element.Button{
            .x = 100,
            .y = 200,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, 200, 35, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Back to Login",
                .size = 16,
                .text_type = .bold,
            },
            .press_callback = backCallback,
        });

        screen.inited = true;
        return screen;
    }

    pub fn deinit(self: *CharSelectScreen) void {
        self.inited = false;

        for (self.boxes.items) |box| element.destroy(box);
        self.boxes.clearAndFree(self.allocator);

        element.destroy(self.new_char_button);
        element.destroy(self.editor_button);
        element.destroy(self.back_button);

        self.allocator.destroy(self);
    }

    pub fn resize(_: *CharSelectScreen, _: f32, _: f32) void {}

    pub fn update(_: *CharSelectScreen, _: i64, _: f32) !void {}

    fn boxClickCallback(box: *element.CharacterBox) void {
        if (main.character_list) |list| {
            if (list.servers.len > 0) {
                main.enterGame(list.servers[0], box.id, std.math.maxInt(u16));
                return;
            }
        }

        std.log.err("No servers found", .{});
    }

    fn newCharCallback(_: ?*anyopaque) void {
        ui_systems.switchScreen(.char_create);
    }

    pub fn editorCallback(_: ?*anyopaque) void {
        ui_systems.switchScreen(.editor);
    }

    pub fn backCallback(_: ?*anyopaque) void {
        ui_systems.switchScreen(.main_menu);
    }
};
