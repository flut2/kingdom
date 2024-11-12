const std = @import("std");
const element = @import("../element.zig");
const assets = @import("../../assets.zig");
const camera = @import("../../camera.zig");
const main = @import("../../main.zig");
const game_data = @import("shared").game_data;
const systems = @import("../systems.zig");
const rpc = @import("rpc");

const Interactable = element.InteractableImageData;

pub const CharCreateScreen = struct {
    inited: bool = false,
    boxes: std.ArrayListUnmanaged(*element.CharacterBox) = .{},
    allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator) !*CharCreateScreen {
        var screen = try allocator.create(CharCreateScreen);
        screen.* = .{ .allocator = allocator };

        const presence: rpc.Packet.Presence = .{
            .assets = .{
                .large_image = rpc.Packet.ArrayString(256).create("logo"),
                .large_text = rpc.Packet.ArrayString(128).create(main.version_text),
            },
            .state = rpc.Packet.ArrayString(128).create("Character Create"),
            .timestamps = .{
                .start = main.rpc_start,
            },
        };
        try main.rpc_client.setPresence(presence);

        const button_data_base = assets.getUiData("button_base", 0);
        const button_data_hover = assets.getUiData("button_hover", 0);
        const button_data_press = assets.getUiData("button_press", 0);

        //TODO Check which classes are locked as it kicks you to character select if class is locked
        var class_iter = game_data.class.from_id.valueIterator();
        var i: usize = 0;
        while (class_iter.next()) |char| {
            defer i += 1;
            const box = element.create(allocator, element.CharacterBox{
                .x = (camera.screen_width - button_data_base.width()) / 2,
                .y = @floatFromInt(50 * i),
                .id = 0,
                .class_data_id = char.id,
                .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, 100, 40, 26, 21, 3, 3, 1.0),
                .text_data = element.TextData{
                    .text = char.name[0..],
                    .size = 16,
                    .text_type = .bold,
                },
                .press_callback = boxClickCallback,
            }) catch return screen;
            screen.boxes.append(allocator, box) catch return screen;
        }

        screen.inited = true;
        return screen;
    }

    pub fn deinit(self: *CharCreateScreen) void {
        self.inited = false;

        for (self.boxes.items) |box| {
            element.destroy(box);
        }
        self.boxes.clearAndFree(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn resize(_: *CharCreateScreen, _: f32, _: f32) void {}

    pub fn update(_: *CharCreateScreen, _: i64, _: f32) !void {}

    fn boxClickCallback(box: *element.CharacterBox) void {
        if (main.character_list) |*list| {
            if (list.servers.len > 0) {
                main.enterGame(list.servers[0], list.next_char_id, box.class_data_id);
                list.next_char_id += 1;
                return;
            }
        }

        std.log.err("No servers found", .{});
    }
};
