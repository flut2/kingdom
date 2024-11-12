const std = @import("std");
const glfw = @import("zglfw");
const nfd = @import("nfd");
const assets = @import("../../assets.zig");
const camera = @import("../../camera.zig");
const main = @import("../../main.zig");
const input = @import("../../input.zig");
const map = @import("../../game/map.zig");
const element = @import("../element.zig");
const dialog = @import("../dialogs/dialog.zig");
const shared = @import("shared");
const map_data = shared.map_data;
const game_data = shared.game_data;
const utils = shared.utils;
const rpc = @import("rpc");

const ui_systems = @import("../systems.zig");

const Settings = @import("../../Settings.zig");
const Player = @import("../../game/player.zig").Player;
const Entity = @import("../../game/entity.zig").Entity;
const Enemy = @import("../../game/enemy.zig").Enemy;
const Portal = @import("../../game/portal.zig").Portal;
const Container = @import("../../game/container.zig").Container;
const Square = @import("../../game/square.zig").Square;

const Interactable = element.InteractableImageData;
const NineSlice = element.NineSliceImageData;

const control_decor_w = 220;
const control_decor_h = 400;

const palette_decor_w = 200;
const palette_decor_h = 400;

const dropdown_w = 200;
const dropdown_h = 130;

const MapEditorTile = struct {
    // map ids
    entity: u32 = std.math.maxInt(u32),
    enemy: u32 = std.math.maxInt(u32),
    portal: u32 = std.math.maxInt(u32),
    container: u32 = std.math.maxInt(u32),

    // data ids
    ground: u16 = Square.editor_tile,
    region: u16 = std.math.maxInt(u16),
};

pub const EditorCommand = union(enum) {
    place: Place,
    multi_place: MultiPlace,
};

const EditorAction = enum {
    none,
    place,
    erase,
    random,
    undo,
    redo,
    sample,
    fill,
};

const Layer = enum(u8) {
    entity,
    enemy,
    portal,
    container,
    ground,
    region,
};

const Place = packed struct {
    x: u16,
    y: u16,
    new_id: u16,
    old_id: u16,
    layer: Layer,

    pub fn execute(self: Place) void {
        switch (self.layer) {
            .ground => ui_systems.screen.editor.setTile(self.x, self.y, self.new_id),
            .region => ui_systems.screen.editor.setRegion(self.x, self.y, self.new_id),
            .entity => ui_systems.screen.editor.setObject(Entity, self.x, self.y, self.new_id),
            .enemy => ui_systems.screen.editor.setObject(Enemy, self.x, self.y, self.new_id),
            .portal => ui_systems.screen.editor.setObject(Portal, self.x, self.y, self.new_id),
            .container => ui_systems.screen.editor.setObject(Container, self.x, self.y, self.new_id),
        }
    }

    pub fn unexecute(self: Place) void {
        switch (self.layer) {
            .ground => ui_systems.screen.editor.setTile(self.x, self.y, self.old_id),
            .region => ui_systems.screen.editor.setRegion(self.x, self.y, self.old_id),
            .entity => ui_systems.screen.editor.setObject(Entity, self.x, self.y, self.old_id),
            .enemy => ui_systems.screen.editor.setObject(Enemy, self.x, self.y, self.old_id),
            .portal => ui_systems.screen.editor.setObject(Portal, self.x, self.y, self.old_id),
            .container => ui_systems.screen.editor.setObject(Container, self.x, self.y, self.old_id),
        }
    }
};

const MultiPlace = struct {
    places: []Place,

    pub fn execute(self: MultiPlace) void {
        for (self.places) |place| place.execute();
    }

    pub fn unexecute(self: MultiPlace) void {
        for (self.places) |place| place.unexecute();
    }
};

const CommandQueue = struct {
    command_list: std.ArrayListUnmanaged(EditorCommand) = .{},
    current_position: usize = 0,
    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *CommandQueue, allocator: std.mem.Allocator) void {
        self.allocator = allocator;
    }

    pub fn clear(self: *CommandQueue) void {
        self.command_list.clearRetainingCapacity();
        self.current_position = 0;
    }

    pub fn deinit(self: *CommandQueue) void {
        for (self.command_list.items) |cmd| {
            if (cmd == .multi_place)
                self.allocator.free(cmd.multi_place.places);
        }
        self.command_list.deinit(self.allocator);
    }

    pub fn addCommand(self: *CommandQueue, command: EditorCommand) void {
        var i = self.command_list.items.len;
        while (i > self.current_position) : (i -= 1) {
            _ = self.command_list.pop();
        }

        switch (command) {
            inline else => |c| c.execute(),
        }

        self.command_list.append(self.allocator, command) catch return;
        self.current_position += 1;
    }

    pub fn undo(self: *CommandQueue) void {
        if (self.current_position == 0)
            return;

        self.current_position -= 1;

        const command = self.command_list.items[self.current_position];
        switch (command) {
            inline else => |c| c.unexecute(),
        }
    }

    pub fn redo(self: *CommandQueue) void {
        if (self.current_position == self.command_list.items.len)
            return;

        const command = self.command_list.items[self.current_position];
        switch (command) {
            inline else => |c| c.execute(),
        }

        self.current_position += 1;
    }
};

pub const MapEditorScreen = struct {
    const layers_text = [_][]const u8{ "Tiles", "Entities", "Enemies", "Portal", "Container", "Regions" };
    const layers = [_]Layer{ .ground, .entity, .enemy, .portal, .container, .region };

    const sizes_text = [_][]const u8{ "64x64", "128x128", "256x256", "512x512", "1024x1024", "2048x2048" };
    const sizes = [_]u16{ 64, 128, 256, 512, 1024, 2048 };

    allocator: std.mem.Allocator,
    inited: bool = false,

    next_map_ids: struct {
        entity: u32 = 0,
        enemy: u32 = 0,
        portal: u32 = 0,
        container: u32 = 0,
    } = .{},
    editor_ready: bool = false,

    map_size: u16 = 64,
    map_tile_data: []MapEditorTile = &.{},

    command_queue: CommandQueue = .{},

    action: EditorAction = .none,
    active_layer: Layer = .ground,
    selected: struct {
        entity: u16 = defaultType(.entity),
        enemy: u16 = defaultType(.enemy),
        portal: u16 = defaultType(.portal),
        container: u16 = defaultType(.container),
        ground: u16 = defaultType(.ground),
        region: u16 = defaultType(.region),
    } = .{},

    brush_size: f32 = 0.5,
    random_chance: f32 = 0.01,

    fps_text: *element.Text = undefined,
    controls_container: *element.Container = undefined,
    map_size_dropdown: *element.Dropdown = undefined,
    palette_decor: *element.Image = undefined,
    palette_containers: struct {
        ground: *element.ScrollableContainer,
        entity: *element.ScrollableContainer,
        enemy: *element.ScrollableContainer,
        portal: *element.ScrollableContainer,
        container: *element.ScrollableContainer,
        region: *element.ScrollableContainer,
    } = undefined,
    layer_dropdown: *element.Dropdown = undefined,

    place_key: Settings.Button = .{ .mouse = .left },
    sample_key: Settings.Button = .{ .mouse = .middle },
    erase_key: Settings.Button = .{ .mouse = .right },
    random_key: Settings.Button = .{ .key = .t },
    undo_key: Settings.Button = .{ .key = .u },
    redo_key: Settings.Button = .{ .key = .r },
    fill_key: Settings.Button = .{ .key = .f },

    start_x_override: u16 = std.math.maxInt(u16),
    start_y_override: u16 = std.math.maxInt(u16),

    pub fn nextMapIdForType(self: *MapEditorScreen, comptime T: type) *u32 {
        return switch (T) {
            Entity => &self.next_map_ids.entity,
            Enemy => &self.next_map_ids.enemy,
            Portal => &self.next_map_ids.portal,
            Container => &self.next_map_ids.container,
            else => @compileError("Invalid type"),
        };
    }

    pub fn init(allocator: std.mem.Allocator) !*MapEditorScreen {
        var screen = try allocator.create(MapEditorScreen);
        screen.* = .{ .allocator = allocator };

        const presence: rpc.Packet.Presence = .{
            .assets = .{
                .large_image = rpc.Packet.ArrayString(256).create("logo"),
                .large_text = rpc.Packet.ArrayString(128).create(main.version_text),
            },
            .state = rpc.Packet.ArrayString(128).create("Map Editor"),
            .timestamps = .{ .start = main.rpc_start },
        };
        try main.rpc_client.setPresence(presence);

        screen.command_queue.init(allocator);

        const button_data_base = assets.getUiData("button_base", 0);
        const button_data_hover = assets.getUiData("button_hover", 0);
        const button_data_press = assets.getUiData("button_press", 0);

        const button_width = 90.0;
        const button_height = 35.0;
        const button_inset = 15.0;
        const button_pad_w = 10.0;
        const button_pad_h = 5.0;

        const key_mapper_width = 35.0;
        const key_mapper_height = 35.0;

        var fps_text_data: element.TextData = .{
            .text = "",
            .size = 12,
            .text_type = .bold,
            .hori_align = .left,
            .max_width = control_decor_w,
            .max_chars = 64,
            .color = 0x6F573F,
        };

        {
            fps_text_data.lock.lock();
            defer fps_text_data.lock.unlock();

            fps_text_data.recalculateAttributes(allocator);
        }

        screen.fps_text = try element.create(allocator, element.Text{
            .x = 5 + control_decor_w + 5,
            .y = 5,
            .text_data = fps_text_data,
        });

        screen.controls_container = try element.create(allocator, element.Container{
            .x = 5,
            .y = 5,
        });

        const collapsed_icon_base = assets.getUiData("dropdown_collapsed_icon_base", 0);
        const collapsed_icon_hover = assets.getUiData("dropdown_collapsed_icon_hover", 0);
        const collapsed_icon_press = assets.getUiData("dropdown_collapsed_icon_press", 0);
        const extended_icon_base = assets.getUiData("dropdown_extended_icon_base", 0);
        const extended_icon_hover = assets.getUiData("dropdown_extended_icon_hover", 0);
        const extended_icon_press = assets.getUiData("dropdown_extended_icon_press", 0);
        const dropdown_main_color_base = assets.getUiData("dropdown_main_color_base", 0);
        const dropdown_main_color_hover = assets.getUiData("dropdown_main_color_hover", 0);
        const dropdown_main_color_press = assets.getUiData("dropdown_main_color_press", 0);
        const dropdown_alt_color_base = assets.getUiData("dropdown_alt_color_base", 0);
        const dropdown_alt_color_hover = assets.getUiData("dropdown_alt_color_hover", 0);
        const dropdown_alt_color_press = assets.getUiData("dropdown_alt_color_press", 0);
        const title_background = assets.getUiData("dropdown_title_background", 0);
        const background_data = assets.getUiData("dropdown_background", 0);

        const scroll_background_data = assets.getUiData("scroll_background", 0);
        const scroll_knob_base = assets.getUiData("scroll_wheel_base", 0);
        const scroll_knob_hover = assets.getUiData("scroll_wheel_hover", 0);
        const scroll_knob_press = assets.getUiData("scroll_wheel_press", 0);
        const scroll_decor_data = assets.getUiData("scrollbar_decor", 0);

        screen.map_size_dropdown = try element.create(allocator, element.Dropdown{
            .x = 5,
            .y = 5 + control_decor_h + 5,
            .w = control_decor_w,
            .container_inlay_x = 8,
            .container_inlay_y = 2,
            .button_data_collapsed = Interactable.fromImageData(collapsed_icon_base, collapsed_icon_hover, collapsed_icon_press),
            .button_data_extended = Interactable.fromImageData(extended_icon_base, extended_icon_hover, extended_icon_press),
            .main_background_data = Interactable.fromNineSlices(dropdown_main_color_base, dropdown_main_color_hover, dropdown_main_color_press, dropdown_w, 40, 0, 0, 2, 2, 1.0),
            .alt_background_data = Interactable.fromNineSlices(dropdown_alt_color_base, dropdown_alt_color_hover, dropdown_alt_color_press, dropdown_w, 40, 0, 0, 2, 2, 1.0),
            .title_data = .{ .nine_slice = NineSlice.fromAtlasData(title_background, dropdown_w, dropdown_h, 20, 20, 4, 4, 1.0) },
            .title_text = .{
                .text = "Map Size",
                .size = 20,
                .text_type = .bold_italic,
            },
            .background_data = .{ .nine_slice = NineSlice.fromAtlasData(background_data, dropdown_w, dropdown_h, 20, 8, 4, 4, 1.0) },
            .scroll_w = 4,
            .scroll_h = dropdown_h - 10,
            .scroll_side_x_rel = -6,
            .scroll_side_y_rel = 0,
            .scroll_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_background_data, 4, dropdown_h - 10, 0, 0, 2, 2, 1.0) },
            .scroll_knob_image_data = Interactable.fromNineSlices(scroll_knob_base, scroll_knob_hover, scroll_knob_press, 10, 16, 4, 4, 1, 2, 1.0),
            .scroll_side_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_decor_data, 6, dropdown_h - 10, 0, 41, 6, 3, 1.0) },
            .selected_index = 0,
        });

        for (sizes_text) |size| {
            const line = try screen.map_size_dropdown.createChild(sizeCallback);
            _ = try line.container.createChild(element.Text{
                .x = 0,
                .y = 0,
                .text_data = .{
                    .text = size,
                    .size = 20,
                    .text_type = .bold,
                    .hori_align = .middle,
                    .vert_align = .middle,
                    .max_width = line.background_data.width(.none),
                    .max_height = line.background_data.height(.none),
                },
            });
        }

        const background_decor = assets.getUiData("tooltip_background", 0);
        _ = try screen.controls_container.createChild(element.Image{
            .x = 0,
            .y = 0,
            .image_data = .{ .nine_slice = NineSlice.fromAtlasData(background_decor, control_decor_w, control_decor_h, 34, 34, 1, 1, 1.0) },
        });

        _ = try screen.controls_container.createChild(element.Button{
            .x = button_inset,
            .y = button_inset,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Open",
                .size = 16,
                .text_type = .bold,
            },
            .userdata = screen,
            .press_callback = openCallback,
        });

        _ = try screen.controls_container.createChild(element.Button{
            .x = button_inset + button_pad_w + button_width,
            .y = button_inset,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Save",
                .size = 16,
                .text_type = .bold,
            },
            .userdata = screen,
            .press_callback = saveCallback,
        });

        _ = try screen.controls_container.createChild(element.Button{
            .x = button_inset,
            .y = button_inset + button_pad_h + button_height,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Test",
                .size = 16,
                .text_type = .bold,
            },
            .userdata = screen,
            .press_callback = testCallback,
        });

        _ = try screen.controls_container.createChild(element.Button{
            .x = button_inset + button_pad_w + button_width,
            .y = button_inset + button_pad_h + button_height,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Exit",
                .size = 16,
                .text_type = .bold,
            },
            .press_callback = exitCallback,
        });

        _ = try screen.controls_container.createChild(element.KeyMapper{
            .x = button_inset,
            .y = button_inset + (button_pad_h + button_height) * 2,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, key_mapper_width, key_mapper_height, 26, 21, 3, 3, 1.0),
            .title_text_data = .{
                .text = "Place",
                .size = 12,
                .text_type = .bold,
            },
            .key = screen.place_key.getKey(),
            .mouse = screen.place_key.getMouse(),
            .settings_button = &screen.place_key,
            .set_key_callback = noAction,
        });
        _ = try screen.controls_container.createChild(element.KeyMapper{
            .x = button_inset + button_pad_w + button_width,
            .y = button_inset + (button_pad_h + button_height) * 2,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, key_mapper_width, key_mapper_height, 26, 21, 3, 3, 1.0),
            .title_text_data = .{
                .text = "Sample",
                .size = 12,
                .text_type = .bold,
            },
            .key = screen.sample_key.getKey(),
            .mouse = screen.sample_key.getMouse(),
            .settings_button = &screen.sample_key,
            .set_key_callback = noAction,
        });
        _ = try screen.controls_container.createChild(element.KeyMapper{
            .x = button_inset,
            .y = button_inset + (button_pad_h + button_height) * 3,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, key_mapper_width, key_mapper_height, 26, 21, 3, 3, 1.0),
            .title_text_data = .{
                .text = "Erase",
                .size = 12,
                .text_type = .bold,
            },
            .key = screen.erase_key.getKey(),
            .mouse = screen.erase_key.getMouse(),
            .settings_button = &screen.erase_key,
            .set_key_callback = noAction,
        });
        _ = try screen.controls_container.createChild(element.KeyMapper{
            .x = button_inset + button_pad_w + button_width,
            .y = button_inset + (button_pad_h + button_height) * 3,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, key_mapper_width, key_mapper_height, 26, 21, 3, 3, 1.0),
            .title_text_data = .{
                .text = "Random",
                .size = 12,
                .text_type = .bold,
            },
            .key = screen.random_key.getKey(),
            .mouse = screen.random_key.getMouse(),
            .settings_button = &screen.random_key,
            .set_key_callback = noAction,
        });
        _ = try screen.controls_container.createChild(element.KeyMapper{
            .x = button_inset,
            .y = button_inset + (button_pad_h + button_height) * 4,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, key_mapper_width, key_mapper_height, 26, 21, 3, 3, 1.0),
            .title_text_data = .{
                .text = "Undo",
                .size = 12,
                .text_type = .bold,
            },
            .key = screen.undo_key.getKey(),
            .mouse = screen.undo_key.getMouse(),
            .settings_button = &screen.undo_key,
            .set_key_callback = noAction,
        });
        _ = try screen.controls_container.createChild(element.KeyMapper{
            .x = button_inset + button_pad_w + button_width,
            .y = button_inset + (button_pad_h + button_height) * 4,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, key_mapper_width, key_mapper_height, 26, 21, 3, 3, 1.0),
            .title_text_data = .{
                .text = "Redo",
                .size = 12,
                .text_type = .bold,
            },
            .key = screen.redo_key.getKey(),
            .mouse = screen.redo_key.getMouse(),
            .settings_button = &screen.redo_key,
            .set_key_callback = noAction,
        });

        _ = try screen.controls_container.createChild(element.KeyMapper{
            .x = button_inset,
            .y = button_inset + (button_pad_h + button_height) * 5,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, key_mapper_width, key_mapper_height, 26, 21, 3, 3, 1.0),
            .title_text_data = .{
                .text = "Fill",
                .size = 12,
                .text_type = .bold,
            },
            .key = screen.fill_key.getKey(),
            .mouse = screen.fill_key.getMouse(),
            .settings_button = &screen.fill_key,
            .set_key_callback = noAction,
        });

        const slider_background_data = assets.getUiData("slider_background", 0);
        const knob_data_base = assets.getUiData("slider_knob_base", 0);
        const knob_data_hover = assets.getUiData("slider_knob_hover", 0);
        const knob_data_press = assets.getUiData("slider_knob_press", 0);

        const slider_w = control_decor_w - button_inset * 2 - 5;
        const slider_h = button_height - 5 - 10;
        const knob_size = button_height - 5;

        _ = try screen.controls_container.createChild(element.Slider{
            .x = button_inset + 2,
            .y = (button_pad_h + button_height) * 7,
            .w = slider_w,
            .h = slider_h,
            .min_value = 0.5,
            .max_value = 9.9,
            .decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(slider_background_data, slider_w, slider_h, 6, 6, 1, 1, 1.0) },
            .knob_image_data = Interactable.fromNineSlices(knob_data_base, knob_data_hover, knob_data_press, knob_size, knob_size, 12, 12, 1, 1, 1.0),
            .target = &screen.brush_size,
            .title_text_data = .{
                .text = "Brush Size",
                .size = 12,
                .text_type = .bold,
            },
            .value_text_data = .{
                .text = "",
                .size = 10,
                .text_type = .bold,
                .max_chars = 64,
            },
        });

        _ = try screen.controls_container.createChild(element.Slider{
            .x = button_inset + 2,
            .y = (button_pad_h + button_height) * 8 + 20,
            .w = slider_w,
            .h = slider_h,
            .min_value = 0.01,
            .max_value = 1.0,
            .decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(slider_background_data, slider_w, slider_h, 6, 6, 1, 1, 1.0) },
            .knob_image_data = Interactable.fromNineSlices(knob_data_base, knob_data_hover, knob_data_press, knob_size, knob_size, 12, 12, 1, 1, 1.0),
            .target = &screen.random_chance,
            .title_text_data = .{
                .text = "Random Chance",
                .size = 12,
                .text_type = .bold,
            },
            .value_text_data = .{
                .text = "",
                .size = 10,
                .text_type = .bold,
                .max_chars = 64,
            },
        });

        screen.palette_decor = try element.create(allocator, element.Image{
            .x = camera.screen_width - palette_decor_w - 5,
            .y = 5,
            .image_data = .{ .nine_slice = element.NineSliceImageData.fromAtlasData(background_decor, palette_decor_w, palette_decor_h, 34, 34, 1, 1, 1.0) },
        });

        screen.palette_containers.ground = try element.create(allocator, element.ScrollableContainer{
            .x = screen.palette_decor.x + 8,
            .y = screen.palette_decor.y + 9,
            .scissor_w = palette_decor_w - 20 - 6,
            .scissor_h = palette_decor_h - 17,
            .scroll_x = screen.palette_decor.x + palette_decor_w - 20 + 2,
            .scroll_y = screen.palette_decor.y + 9,
            .scroll_w = 4,
            .scroll_h = palette_decor_h - 17,
            .scroll_side_x = screen.palette_decor.x + palette_decor_w - 20 + 2 - 6,
            .scroll_side_y = screen.palette_decor.y + 9,
            .scroll_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_background_data, 4, palette_decor_h - 17, 0, 0, 2, 2, 1.0) },
            .scroll_knob_image_data = Interactable.fromNineSlices(scroll_knob_base, scroll_knob_hover, scroll_knob_press, 10, 16, 4, 4, 1, 2, 1.0),
            .scroll_side_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_decor_data, 6, palette_decor_h - 17, 0, 41, 6, 3, 1.0) },
        });

        var tile_iter = game_data.ground.from_id.iterator();
        var i: isize = 0;
        while (tile_iter.next()) |entry| : (i += 1) {
            if (entry.key_ptr.* == Square.editor_tile) {
                i -= 1;
                continue;
            }

            var atlas_data = blk: {
                if (entry.value_ptr.textures.len <= 0) {
                    std.log.err("Tile with data id {} has an empty texture list. Using error texture", .{entry.key_ptr.*});
                    break :blk assets.error_data;
                }

                const tex = if (entry.value_ptr.textures.len == 1) entry.value_ptr.textures[0] else entry.value_ptr.textures[utils.rng.next() % entry.value_ptr.textures.len];

                if (assets.atlas_data.get(tex.sheet)) |data| {
                    if (tex.index >= data.len) {
                        std.log.err("Could not find index {} for tile with data id {}. Using error texture", .{ tex.index, entry.key_ptr.* });
                        break :blk assets.error_data;
                    }

                    break :blk data[tex.index];
                } else {
                    std.log.err("Could not find sheet {s} for tile with data id {}. Using error texture", .{ tex.sheet, entry.key_ptr.* });
                    break :blk assets.error_data;
                }
            };

            if (atlas_data.tex_w <= 0 or atlas_data.tex_h <= 0) {
                std.log.err("Tile with data id {} has an empty texture. Using error texture", .{entry.key_ptr.*});
                atlas_data = assets.error_data;
            }

            _ = try screen.palette_containers.ground.createChild(element.Button{
                .x = @floatFromInt(@mod(i, 5) * 34),
                .y = @floatFromInt(@divFloor(i, 5) * 34),
                .image_data = .{ .base = .{ .normal = .{ .atlas_data = atlas_data, .scale_x = 4.0, .scale_y = 4.0 } } },
                .userdata = entry.key_ptr,
                .press_callback = groundClicked,
                .tooltip_text = .{
                    .text = (game_data.ground.from_id.get(entry.key_ptr.*) orelse {
                        std.log.err("Could find name for tile with data id {}. Not adding to tile list", .{entry.key_ptr.*});
                        i -= 1;
                        continue;
                    }).name,
                    .size = 12,
                    .text_type = .bold_italic,
                },
            });
        }

        try addObjectContainer(
            &screen.palette_containers.entity,
            allocator,
            screen.palette_decor.x,
            screen.palette_decor.y,
            scroll_background_data,
            scroll_knob_base,
            scroll_knob_hover,
            scroll_knob_press,
            scroll_decor_data,
            game_data.EntityData,
            game_data.entity,
            entityClicked,
        );
        try addObjectContainer(
            &screen.palette_containers.enemy,
            allocator,
            screen.palette_decor.x,
            screen.palette_decor.y,
            scroll_background_data,
            scroll_knob_base,
            scroll_knob_hover,
            scroll_knob_press,
            scroll_decor_data,
            game_data.EnemyData,
            game_data.enemy,
            enemyClicked,
        );
        try addObjectContainer(
            &screen.palette_containers.portal,
            allocator,
            screen.palette_decor.x,
            screen.palette_decor.y,
            scroll_background_data,
            scroll_knob_base,
            scroll_knob_hover,
            scroll_knob_press,
            scroll_decor_data,
            game_data.PortalData,
            game_data.portal,
            portalClicked,
        );
        try addObjectContainer(
            &screen.palette_containers.container,
            allocator,
            screen.palette_decor.x,
            screen.palette_decor.y,
            scroll_background_data,
            scroll_knob_base,
            scroll_knob_hover,
            scroll_knob_press,
            scroll_decor_data,
            game_data.ContainerData,
            game_data.container,
            containerClicked,
        );

        screen.palette_containers.region = try element.create(allocator, element.ScrollableContainer{
            .x = screen.palette_decor.x + 8,
            .y = screen.palette_decor.y + 9,
            .scissor_w = palette_decor_w - 20 - 6,
            .scissor_h = palette_decor_h - 17,
            .scroll_x = screen.palette_decor.x + palette_decor_w - 20 + 2,
            .scroll_y = screen.palette_decor.y + 9,
            .scroll_w = 4,
            .scroll_h = palette_decor_h - 17,
            .scroll_side_x = screen.palette_decor.x + palette_decor_w - 20 + 2 - 6,
            .scroll_side_y = screen.palette_decor.y + 9,
            .scroll_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_background_data, 4, palette_decor_h - 17, 0, 0, 2, 2, 1.0) },
            .scroll_knob_image_data = Interactable.fromNineSlices(scroll_knob_base, scroll_knob_hover, scroll_knob_press, 10, 16, 4, 4, 1, 2, 1.0),
            .scroll_side_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_decor_data, 6, palette_decor_h - 17, 0, 41, 6, 3, 1.0) },
            .visible = false,
        });

        var region_iter = game_data.region.from_id.iterator();
        i = 0;
        while (region_iter.next()) |entry| : (i += 1) {
            _ = try screen.palette_containers.region.createChild(element.Button{
                .x = @floatFromInt(@mod(i, 5) * 34),
                .y = @floatFromInt(@divFloor(i, 5) * 34),
                .image_data = .{ .base = .{ .normal = .{
                    .atlas_data = assets.wall_backface_data,
                    .scale_x = 4.0,
                    .scale_y = 4.0,
                    .alpha = 0.6,
                    .color = entry.value_ptr.color,
                    .color_intensity = 1.0,
                } } },
                .userdata = entry.key_ptr,
                .press_callback = regionClicked,
                .tooltip_text = .{
                    .text = entry.value_ptr.name,
                    .size = 12,
                    .text_type = .bold_italic,
                },
            });
        }

        screen.layer_dropdown = try element.create(allocator, element.Dropdown{
            .x = screen.palette_decor.x,
            .y = screen.palette_decor.y + screen.palette_decor.height() + 5,
            .w = dropdown_w,
            .container_inlay_x = 8,
            .container_inlay_y = 2,
            .button_data_collapsed = Interactable.fromImageData(collapsed_icon_base, collapsed_icon_hover, collapsed_icon_press),
            .button_data_extended = Interactable.fromImageData(extended_icon_base, extended_icon_hover, extended_icon_press),
            .main_background_data = Interactable.fromNineSlices(dropdown_main_color_base, dropdown_main_color_hover, dropdown_main_color_press, dropdown_w, 40, 0, 0, 2, 2, 1.0),
            .alt_background_data = Interactable.fromNineSlices(dropdown_alt_color_base, dropdown_alt_color_hover, dropdown_alt_color_press, dropdown_w, 40, 0, 0, 2, 2, 1.0),
            .title_data = .{ .nine_slice = NineSlice.fromAtlasData(title_background, dropdown_w, dropdown_h, 20, 20, 4, 4, 1.0) },
            .title_text = .{
                .text = "Layer",
                .size = 20,
                .text_type = .bold_italic,
            },
            .background_data = .{ .nine_slice = NineSlice.fromAtlasData(background_data, dropdown_w, dropdown_h, 20, 8, 4, 4, 1.0) },
            .scroll_w = 4,
            .scroll_h = dropdown_h - 10,
            .scroll_side_x_rel = -6,
            .scroll_side_y_rel = 0,
            .scroll_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_background_data, 4, dropdown_h - 10, 0, 0, 2, 2, 1.0) },
            .scroll_knob_image_data = Interactable.fromNineSlices(scroll_knob_base, scroll_knob_hover, scroll_knob_press, 10, 16, 4, 4, 1, 2, 1.0),
            .scroll_side_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_decor_data, 6, dropdown_h - 10, 0, 41, 6, 3, 1.0) },
            .selected_index = 0,
        });

        for (layers_text) |layer| {
            const layer_line = try screen.layer_dropdown.createChild(layerCallback);
            _ = try layer_line.container.createChild(element.Text{
                .x = 0,
                .y = 0,
                .text_data = .{
                    .text = layer,
                    .size = 20,
                    .text_type = .bold,
                    .hori_align = .middle,
                    .vert_align = .middle,
                    .max_width = layer_line.background_data.width(.none),
                    .max_height = layer_line.background_data.height(.none),
                },
            });
        }

        screen.inited = true;
        screen.initialize();
        return screen;
    }

    fn addObjectContainer(
        container: **element.ScrollableContainer,
        allocator: std.mem.Allocator,
        px: f32,
        py: f32,
        scroll_background_data: assets.AtlasData,
        scroll_knob_base: assets.AtlasData,
        scroll_knob_hover: assets.AtlasData,
        scroll_knob_press: assets.AtlasData,
        scroll_decor_data: assets.AtlasData,
        comptime T: type,
        data: game_data.Maps(T),
        callback: *const fn (?*anyopaque) void,
    ) !void {
        container.* = try element.create(allocator, element.ScrollableContainer{
            .x = px + 8,
            .y = py + 9,
            .scissor_w = palette_decor_w - 20 - 6,
            .scissor_h = palette_decor_h - 17,
            .scroll_x = px + palette_decor_w - 20 + 2,
            .scroll_y = py + 9,
            .scroll_w = 4,
            .scroll_h = palette_decor_h - 17,
            .scroll_side_x = px + palette_decor_w - 20 + 2 - 6,
            .scroll_side_y = py + 9,
            .scroll_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_background_data, 4, palette_decor_h - 17, 0, 0, 2, 2, 1.0) },
            .scroll_knob_image_data = Interactable.fromNineSlices(scroll_knob_base, scroll_knob_hover, scroll_knob_press, 10, 16, 4, 4, 1, 2, 1.0),
            .scroll_side_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_decor_data, 6, palette_decor_h - 17, 0, 41, 6, 3, 1.0) },
            .visible = false,
        });

        var iter = data.from_id.iterator();
        var i: usize = 0;
        while (iter.next()) |entry| : (i += 1) {
            var atlas_data = blk: {
                const tex = texBlk: {
                    if (@hasField(@TypeOf(entry.value_ptr.*), "texture"))
                        break :texBlk entry.value_ptr.texture;

                    const tex_list = entry.value_ptr.textures;
                    if (tex_list.len <= 0) {
                        std.log.err("Object with data id {} has an empty texture list. Using error texture", .{entry.key_ptr.*});
                        break :blk assets.error_data;
                    }

                    break :texBlk tex_list[utils.rng.next() % tex_list.len];
                };

                if (assets.anim_enemies.get(tex.sheet)) |anim_data| {
                    if (tex.index >= anim_data.len) {
                        std.log.err("Could not find index {} for object with data id {}. Using error texture", .{ tex.index, entry.key_ptr.* });
                        break :blk assets.error_data;
                    }

                    break :blk anim_data[tex.index].walk_anims[0];
                } else if (assets.atlas_data.get(tex.sheet)) |atlas_data| {
                    if (tex.index >= atlas_data.len) {
                        std.log.err("Could not find index {} for object with data id {}. Using error texture", .{ tex.index, entry.key_ptr.* });
                        break :blk assets.error_data;
                    }

                    break :blk atlas_data[tex.index];
                } else {
                    std.log.err("Could not find sheet {s} for object with data id {}. Using error texture", .{ tex.sheet, entry.key_ptr.* });
                    break :blk assets.error_data;
                }
            };

            if (atlas_data.tex_w <= 0 or atlas_data.tex_h <= 0) {
                std.log.err("Object with data id {} has an empty texture. Using error texture", .{entry.key_ptr.*});
                atlas_data = assets.error_data;
            }

            const scale = 8.0 / @max(atlas_data.width(), atlas_data.height()) * 3.0;

            _ = try container.*.createChild(element.Button{
                .x = @as(f32, @floatFromInt(@mod(i, 5) * 32)) + (32 - atlas_data.width() * scale) / 2.0,
                .y = @as(f32, @floatFromInt(@divFloor(i, 5) * 32)) + (32 - atlas_data.height() * scale) / 2.0,
                .image_data = .{ .base = .{ .normal = .{ .atlas_data = atlas_data, .scale_x = scale, .scale_y = scale } } },
                .userdata = entry.key_ptr,
                .press_callback = callback,
                .tooltip_text = .{
                    .text = entry.value_ptr.name,
                    .size = 12,
                    .text_type = .bold_italic,
                },
            });
        }
    }

    fn groundClicked(ud: ?*anyopaque) void {
        ui_systems.screen.editor.selected.ground = @as(*u16, @alignCast(@ptrCast(ud))).*;
    }

    fn entityClicked(ud: ?*anyopaque) void {
        ui_systems.screen.editor.selected.entity = @as(*u16, @alignCast(@ptrCast(ud))).*;
    }

    fn enemyClicked(ud: ?*anyopaque) void {
        ui_systems.screen.editor.selected.enemy = @as(*u16, @alignCast(@ptrCast(ud))).*;
    }

    fn portalClicked(ud: ?*anyopaque) void {
        ui_systems.screen.editor.selected.portal = @as(*u16, @alignCast(@ptrCast(ud))).*;
    }

    fn containerClicked(ud: ?*anyopaque) void {
        ui_systems.screen.editor.selected.container = @as(*u16, @alignCast(@ptrCast(ud))).*;
    }

    fn regionClicked(ud: ?*anyopaque) void {
        ui_systems.screen.editor.selected.region = @as(*u8, @alignCast(@ptrCast(ud))).*;
    }

    fn sizeCallback(dc: *element.DropdownContainer) void {
        const screen = ui_systems.screen.editor;
        screen.map_size = sizes[dc.index];
        screen.initialize();
    }

    fn layerCallback(dc: *element.DropdownContainer) void {
        const next_layer = layers[dc.index];
        const screen = ui_systems.screen.editor;
        screen.active_layer = next_layer;
        inline for (@typeInfo(@TypeOf(screen.palette_containers)).@"struct".fields) |field| {
            @field(screen.palette_containers, field.name).visible = false;
        }
        switch (next_layer) {
            inline else => |tag| @field(screen.palette_containers, @tagName(tag)).visible = true,
        }
    }

    fn noAction(_: *element.KeyMapper) void {}

    fn initialize(self: *MapEditorScreen) void {
        map.dispose(self.allocator);
        map.setMapInfo(.{
            .width = self.map_size,
            .height = self.map_size,
            .bg_color = 0,
            .bg_intensity = 0.15,
        }, self.allocator);
        self.command_queue.clear();

        self.map_tile_data = if (self.map_tile_data.len == 0)
            self.allocator.alloc(MapEditorTile, @as(u32, self.map_size) * @as(u32, self.map_size)) catch return
        else
            self.allocator.realloc(self.map_tile_data, @as(u32, self.map_size) * @as(u32, self.map_size)) catch return;

        @memset(self.map_tile_data, MapEditorTile{});

        const center = @as(f32, @floatFromInt(self.map_size)) / 2.0;

        {
            map.square_lock.lock();
            defer map.square_lock.unlock();
            for (0..self.map_size) |y| {
                for (0..self.map_size) |x| {
                    var square: Square = .{
                        .x = @floatFromInt(x),
                        .y = @floatFromInt(y),
                        .data_id = Square.editor_tile,
                    };
                    square.addToMap();
                }
            }
        }

        map.local_player_id = std.math.maxInt(u32) - 1;
        var player: Player = .{
            .x = if (self.start_x_override == std.math.maxInt(u16)) center else @floatFromInt(self.start_x_override),
            .y = if (self.start_y_override == std.math.maxInt(u16)) center else @floatFromInt(self.start_y_override),
            .map_id = map.local_player_id,
            .data_id = 0,
            .speed = 300,
        };
        player.addToMap(self.allocator);

        main.editing_map = true;
        ui_systems.menu_background.visible = false;
        self.start_x_override = std.math.maxInt(u16);
        self.start_y_override = std.math.maxInt(u16);
    }

    // for easier error handling
    fn openInner(screen: *MapEditorScreen) !void {
        // TODO: popup for save

        const file_path = try nfd.openFileDialog("map", null);
        if (file_path) |path| {
            defer nfd.freePath(path);

            const file = try std.fs.openFileAbsolute(path, .{});
            defer file.close();

            const parsed_map = try map_data.parseMap(file, screen.allocator);
            screen.start_x_override = parsed_map.x + @divFloor(parsed_map.w, 2);
            screen.start_y_override = parsed_map.y + @divFloor(parsed_map.h, 2);
            screen.map_size = utils.nextPowerOfTwo(@max(parsed_map.x + parsed_map.w, parsed_map.y + parsed_map.h));
            screen.initialize();

            for (parsed_map.tiles, 0..) |tile, i| {
                const ux: u16 = @intCast(i % parsed_map.w + parsed_map.x);
                const uy: u16 = @intCast(@divFloor(i, parsed_map.w) + parsed_map.y);
                if (tile.ground_id != Square.empty_tile and tile.ground_id != Square.editor_tile) screen.setTile(ux, uy, tile.ground_id);
                if (tile.region_id != std.math.maxInt(u16)) screen.setRegion(ux, uy, tile.region_id);
                if (tile.entity_id != std.math.maxInt(u16)) screen.setObject(Entity, ux, uy, tile.entity_id);
                if (tile.enemy_id != std.math.maxInt(u16)) screen.setObject(Enemy, ux, uy, tile.enemy_id);
                if (tile.portal_id != std.math.maxInt(u16)) screen.setObject(Portal, ux, uy, tile.portal_id);
                if (tile.container_id != std.math.maxInt(u16)) screen.setObject(Container, ux, uy, tile.container_id);
            }
        }
    }

    fn openCallback(ud: ?*anyopaque) void {
        openInner(@alignCast(@ptrCast(ud.?))) catch |e| {
            std.log.err("Error while parsing map: {}", .{e});
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        };
    }

    fn tileBounds(tiles: []MapEditorTile) struct { min_x: u16, max_x: u16, min_y: u16, max_y: u16 } {
        var min_x = map.info.width;
        var min_y = map.info.height;
        var max_x: u16 = 0;
        var max_y: u16 = 0;

        for (0..map.info.height) |y| {
            for (0..map.info.width) |x| {
                const map_tile = tiles[@intCast(y * map.info.width + x)];
                inline for (@typeInfo(MapEditorTile).@"struct".fields) |field| {
                    if (comptime std.mem.eql(u8, field.name, "object_id"))
                        continue;

                    if (@field(map_tile, field.name) != @as(*const field.type, @ptrCast(@alignCast(field.default_value.?))).*) {
                        const ux: u16 = @intCast(x);
                        const uy: u16 = @intCast(y);

                        min_x = @min(min_x, ux);
                        min_y = @min(min_y, uy);
                        max_x = @max(max_x, ux);
                        max_y = @max(max_y, uy);
                        break;
                    }
                }
            }
        }

        return .{ .min_x = @intCast(min_x), .min_y = @intCast(min_y), .max_x = @intCast(max_x + 1), .max_y = @intCast(max_y + 1) };
    }

    pub fn indexOfTile(tiles: []const map_data.Tile, value: map_data.Tile) ?usize {
        tileLoop: for (tiles, 0..) |tile, i| {
            inline for (@typeInfo(map_data.Tile).@"struct".fields) |field| {
                if (@field(tile, field.name) != @field(value, field.name))
                    continue :tileLoop;
            }

            return i;
        }

        return null;
    }

    fn mapData(screen: *MapEditorScreen) ![]u8 {
        var data: std.ArrayListUnmanaged(u8) = .{};

        const bounds = tileBounds(screen.map_tile_data);
        if (bounds.min_x >= bounds.max_x or bounds.min_y >= bounds.max_y)
            return error.InvalidMap;

        var writer = data.writer(screen.allocator);
        try writer.writeInt(u8, 0, .little); // version
        try writer.writeInt(u16, bounds.min_x, .little);
        try writer.writeInt(u16, bounds.min_y, .little);
        try writer.writeInt(u16, bounds.max_x - bounds.min_x, .little);
        try writer.writeInt(u16, bounds.max_y - bounds.min_y, .little);

        var tiles: std.ArrayListUnmanaged(map_data.Tile) = .{};
        defer tiles.deinit(screen.allocator);

        for (bounds.min_y..bounds.max_y) |y| {
            for (bounds.min_x..bounds.max_x) |x| {
                const map_tile = screen.getTile(x, y);
                const tile: map_data.Tile = .{
                    .ground_id = map_tile.ground,
                    .region_id = map_tile.region,
                    .enemy_id = blk: {
                        var lock = map.useLockForType(Enemy);
                        lock.lock();
                        defer lock.unlock();
                        break :blk if (map.findObjectConst(Enemy, map_tile.enemy)) |e| e.data_id else std.math.maxInt(u16);
                    },
                    .entity_id = blk: {
                        var lock = map.useLockForType(Entity);
                        lock.lock();
                        defer lock.unlock();
                        break :blk if (map.findObjectConst(Entity, map_tile.entity)) |e| e.data_id else std.math.maxInt(u16);
                    },
                    .portal_id = blk: {
                        var lock = map.useLockForType(Portal);
                        lock.lock();
                        defer lock.unlock();
                        break :blk if (map.findObjectConst(Portal, map_tile.portal)) |p| p.data_id else std.math.maxInt(u16);
                    },
                    .container_id = blk: {
                        var lock = map.useLockForType(Container);
                        lock.lock();
                        defer lock.unlock();
                        break :blk if (map.findObjectConst(Container, map_tile.container)) |c| c.data_id else std.math.maxInt(u16);
                    },
                };

                if (indexOfTile(tiles.items, tile) == null)
                    try tiles.append(screen.allocator, tile);
            }
        }

        try writer.writeInt(u16, @intCast(tiles.items.len), .little);
        const byte_len = tiles.items.len <= 256;

        for (tiles.items) |tile| {
            inline for (@typeInfo(map_data.Tile).@"struct".fields) |field| {
                try writer.writeInt(field.type, @field(tile, field.name), .little);
            }
        }

        for (bounds.min_y..bounds.max_y) |y| {
            for (bounds.min_x..bounds.max_x) |x| {
                const map_tile = screen.getTile(x, y);
                const tile: map_data.Tile = .{
                    .ground_id = map_tile.ground,
                    .region_id = map_tile.region,
                    .enemy_id = blk: {
                        var lock = map.useLockForType(Enemy);
                        lock.lock();
                        defer lock.unlock();
                        break :blk if (map.findObjectConst(Enemy, map_tile.enemy)) |e| e.data_id else std.math.maxInt(u16);
                    },
                    .entity_id = blk: {
                        var lock = map.useLockForType(Entity);
                        lock.lock();
                        defer lock.unlock();
                        break :blk if (map.findObjectConst(Entity, map_tile.entity)) |e| e.data_id else std.math.maxInt(u16);
                    },
                    .portal_id = blk: {
                        var lock = map.useLockForType(Portal);
                        lock.lock();
                        defer lock.unlock();
                        break :blk if (map.findObjectConst(Portal, map_tile.portal)) |p| p.data_id else std.math.maxInt(u16);
                    },
                    .container_id = blk: {
                        var lock = map.useLockForType(Container);
                        lock.lock();
                        defer lock.unlock();
                        break :blk if (map.findObjectConst(Container, map_tile.container)) |c| c.data_id else std.math.maxInt(u16);
                    },
                };

                if (indexOfTile(tiles.items, tile)) |idx| {
                    if (byte_len)
                        try writer.writeInt(u8, @intCast(idx), .little)
                    else
                        try writer.writeInt(u16, @intCast(idx), .little);
                } else @panic("No index found");
            }
        }

        return try data.toOwnedSlice(screen.allocator);
    }

    fn saveInner(screen: *MapEditorScreen) !void {
        if (!main.editing_map) return;

        const file_path = nfd.saveFileDialog("map", null) catch return;
        if (file_path) |path| {
            defer nfd.freePath(path);

            const data = mapData(screen) catch {
                dialog.showDialog(.text, .{
                    .title = "Map Error",
                    .body = "Map was invalid",
                });
                return;
            };
            defer screen.allocator.free(data);

            const file = try std.fs.createFileAbsolute(path, .{});
            defer file.close();

            var fbs = std.io.fixedBufferStream(data);
            try std.compress.zlib.compress(fbs.reader(), file.writer(), .{});
        }
    }

    fn saveCallback(ud: ?*anyopaque) void {
        saveInner(@alignCast(@ptrCast(ud.?))) catch |e| {
            std.log.err("Error while saving map: {}", .{e});
            if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
        };
    }

    fn exitCallback(_: ?*anyopaque) void {
        if (main.character_list.?.characters.len > 0)
            ui_systems.switchScreen(.char_select)
        else
            ui_systems.switchScreen(.char_create);
    }

    fn testCallback(ud: ?*anyopaque) void {
        if (main.character_list) |list| {
            if (list.servers.len > 0) {
                const screen: *MapEditorScreen = @alignCast(@ptrCast(ud.?));

                const data = mapData(screen) catch |e| {
                    std.log.err("Error while testing map: {}", .{e});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                    return;
                };
                defer screen.allocator.free(data);

                if (ui_systems.editor_backup == null)
                    ui_systems.editor_backup = screen.allocator.create(MapEditorScreen) catch return;
                // @memcpy(ui_systems.editor_backup.?, screen);

                var test_map: std.ArrayListUnmanaged(u8) = .{};
                var fbs = std.io.fixedBufferStream(data);
                std.compress.zlib.compress(fbs.reader(), test_map.writer(screen.allocator), .{}) catch |e| {
                    std.log.err("Error while testing map: {}", .{e});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                    return;
                };
                main.enterTest(list.servers[0], list.characters[0].char_id, test_map.toOwnedSlice(screen.allocator) catch return);
                return;
            }
        }
    }

    pub fn deinit(self: *MapEditorScreen) void {
        self.inited = false;

        self.command_queue.deinit();

        element.destroy(self.fps_text);
        element.destroy(self.palette_decor);
        inline for (@typeInfo(@TypeOf(self.palette_containers)).@"struct".fields) |field| {
            element.destroy(@field(self.palette_containers, field.name));
        }
        element.destroy(self.layer_dropdown);
        element.destroy(self.controls_container);
        element.destroy(self.map_size_dropdown);

        self.allocator.free(self.map_tile_data);

        main.editing_map = false;
        map.dispose(self.allocator);

        self.allocator.destroy(self);

        ui_systems.menu_background.visible = true;
    }

    pub fn resize(self: *MapEditorScreen, w: f32, _: f32) void {
        const palette_x = w - palette_decor_w - 5;
        const cont_x = palette_x + 8;

        self.palette_decor.x = palette_x;
        inline for (@typeInfo(@TypeOf(self.palette_containers)).@"struct".fields) |field| {
            @field(self.palette_containers, field.name).x = cont_x;
        }
        self.layer_dropdown.x = palette_x;
        self.layer_dropdown.container.x = palette_x + self.layer_dropdown.container_inlay_x;
        self.layer_dropdown.container.container.x = palette_x + self.layer_dropdown.container_inlay_x;
        self.layer_dropdown.y = self.palette_decor.y + self.palette_decor.height() + 5;
    }

    pub fn onMousePress(self: *MapEditorScreen, button: glfw.MouseButton) void {
        if (button == self.undo_key.getMouse())
            self.action = .undo
        else if (button == self.redo_key.getMouse())
            self.action = .redo
        else if (button == self.place_key.getMouse())
            self.action = .place
        else if (button == self.erase_key.getMouse())
            self.action = .erase
        else if (button == self.sample_key.getMouse())
            self.action = .sample
        else if (button == self.random_key.getMouse())
            self.action = .random
        else if (button == self.fill_key.getMouse())
            self.action = .fill;
    }

    pub fn onMouseRelease(self: *MapEditorScreen, button: glfw.MouseButton) void {
        if (button == self.undo_key.getMouse() or
            button == self.redo_key.getMouse() or
            button == self.place_key.getMouse() or
            button == self.erase_key.getMouse() or
            button == self.sample_key.getMouse() or
            button == self.random_key.getMouse() or
            button == self.fill_key.getMouse())
            self.action = .none;
    }

    pub fn onKeyPress(self: *MapEditorScreen, key: glfw.Key) void {
        if (key == self.undo_key.getKey())
            self.action = .undo
        else if (key == self.redo_key.getKey())
            self.action = .redo
        else if (key == self.place_key.getKey())
            self.action = .place
        else if (key == self.erase_key.getKey())
            self.action = .erase
        else if (key == self.sample_key.getKey())
            self.action = .sample
        else if (key == self.random_key.getKey())
            self.action = .random
        else if (key == self.fill_key.getKey())
            self.action = .fill;
    }

    pub fn onKeyRelease(self: *MapEditorScreen, key: glfw.Key) void {
        if (key == self.undo_key.getKey() or
            key == self.redo_key.getKey() or
            key == self.place_key.getKey() or
            key == self.erase_key.getKey() or
            key == self.sample_key.getKey() or
            key == self.random_key.getKey() or
            key == self.fill_key.getKey())
            self.action = .none;
    }

    fn getTile(self: *MapEditorScreen, x: usize, y: usize) MapEditorTile {
        return self.map_tile_data[y * self.map_size + x];
    }

    fn getTilePtr(self: *MapEditorScreen, x: usize, y: usize) *MapEditorTile {
        return &self.map_tile_data[y * self.map_size + x];
    }

    fn setTile(self: *MapEditorScreen, x: u16, y: u16, data_id: u16) void {
        const tile = self.getTilePtr(x, y);
        if (tile.ground == data_id) return;

        if (game_data.ground.from_id.get(data_id) == null) {
            std.log.err("Data not found for tile with data id {}, setting at x={}, y={} cancelled", .{ data_id, x, y });
            return;
        }

        tile.ground = data_id;

        map.square_lock.lock();
        defer map.square_lock.unlock();
        var square: Square = .{
            .x = @floatFromInt(x),
            .y = @floatFromInt(y),
            .data_id = data_id,
        };
        square.addToMap();
    }

    fn setRegion(self: *MapEditorScreen, x: u16, y: u16, data_id: u16) void {
        const tile = self.getTilePtr(x, y);
        if (tile.region == data_id) return;

        if (data_id != std.math.maxInt(u16) and game_data.region.from_id.get(data_id) == null) {
            std.log.err("Data not found for region with data id {}, setting at x={}, y={} cancelled", .{ data_id, x, y });
            return;
        }

        tile.region = data_id;
    }

    fn setObject(self: *MapEditorScreen, comptime ObjType: type, x: u16, y: u16, data_id: u16) void {
        const tile = self.getTilePtr(x, y);
        const field = switch (ObjType) {
            Entity => &tile.entity,
            Enemy => &tile.enemy,
            Portal => &tile.portal,
            Container => &tile.container,
            else => @compileError("Invalid type"),
        };

        var lock = map.useLockForType(ObjType);
        if (data_id == std.math.maxInt(u16)) {
            lock.lock();
            defer lock.unlock();
            _ = map.removeEntity(ObjType, self.allocator, field.*);
            field.* = std.math.maxInt(u32);
        } else {
            if (game_data.entity.from_id.get(data_id) == null) {
                std.log.err("Data not found for object with data id {}, setting at x={}, y={} cancelled", .{ data_id, x, y });
                return;
            }

            if (field.* != std.math.maxInt(u32)) {
                lock.lock();
                defer lock.unlock();
                if (map.findObjectConst(ObjType, field.*)) |obj| if (obj.data_id == data_id) return;
                _ = map.removeEntity(ObjType, self.allocator, field.*);
            }

            const next_map_id = self.nextMapIdForType(ObjType);
            defer next_map_id.* += 1;

            field.* = next_map_id.*;

            var obj: ObjType = .{
                .x = @floatFromInt(x),
                .y = @floatFromInt(y),
                .map_id = next_map_id.*,
                .data_id = data_id,
            };
            obj.addToMap(self.allocator);
        }
    }

    fn place(self: *MapEditorScreen, center_x: f32, center_y: f32, comptime place_type: enum { place, erase, random }) !void {
        var places: std.ArrayListUnmanaged(Place) = .{};
        const size_sqr = self.brush_size * self.brush_size;
        const sel_type: u16 = if (place_type == .erase) defaultType(self.active_layer) else switch (self.active_layer) {
            inline else => |tag| @field(self.selected, @tagName(tag)),
        };
        if (place_type != .erase and sel_type == defaultType(self.active_layer))
            return;

        const size: f32 = @floatFromInt(self.map_size - 1);
        const y_left: usize = @intFromFloat(@max(0, @floor(center_y - self.brush_size)));
        const y_right: usize = @intFromFloat(@min(size, @ceil(center_y + self.brush_size)));
        const x_left: usize = @intFromFloat(@max(0, @floor(center_x - self.brush_size)));
        const x_right: usize = @intFromFloat(@min(size, @ceil(center_x + self.brush_size)));
        for (y_left..y_right) |y| {
            for (x_left..x_right) |x| {
                const fx: f32 = @floatFromInt(x);
                const fy: f32 = @floatFromInt(y);
                const dx = center_x - fx;
                const dy = center_y - fy;
                if (dx * dx + dy * dy <= size_sqr) {
                    if (place_type == .random and utils.rng.random().float(f32) > self.random_chance)
                        continue;

                    try places.append(self.allocator, .{
                        .x = @intCast(x),
                        .y = @intCast(y),
                        .new_id = sel_type,
                        .old_id = blk: {
                            const tile = self.map_tile_data[y * self.map_size + x];
                            switch (self.active_layer) {
                                .ground => break :blk tile.ground,
                                .region => break :blk tile.region,
                                .entity => break :blk lockBlk: {
                                    var lock = map.useLockForType(Entity);
                                    lock.lock();
                                    defer lock.unlock();
                                    break :lockBlk if (map.findObjectConst(Entity, tile.entity)) |e| e.data_id else std.math.maxInt(u16);
                                },
                                .enemy => break :blk lockBlk: {
                                    var lock = map.useLockForType(Enemy);
                                    lock.lock();
                                    defer lock.unlock();
                                    break :lockBlk if (map.findObjectConst(Enemy, tile.enemy)) |e| e.data_id else std.math.maxInt(u16);
                                },
                                .portal => break :blk lockBlk: {
                                    var lock = map.useLockForType(Portal);
                                    lock.lock();
                                    defer lock.unlock();
                                    break :lockBlk if (map.findObjectConst(Portal, tile.portal)) |p| p.data_id else std.math.maxInt(u16);
                                },
                                .container => break :blk lockBlk: {
                                    var lock = map.useLockForType(Container);
                                    lock.lock();
                                    defer lock.unlock();
                                    break :lockBlk if (map.findObjectConst(Container, tile.container)) |c| c.data_id else std.math.maxInt(u16);
                                },
                            }

                            break :blk defaultType(self.active_layer);
                        },
                        .layer = self.active_layer,
                    });
                }
            }
        }

        if (places.items.len <= 1) {
            if (places.items.len == 1) self.command_queue.addCommand(.{ .place = places.items[0] });
            places.deinit(self.allocator);
        } else {
            self.command_queue.addCommand(.{ .multi_place = .{ .places = try places.toOwnedSlice(self.allocator) } });
        }
    }

    fn placesContain(places: []Place, x: i32, y: i32) bool {
        if (x < 0 or y < 0)
            return false;

        for (places) |p| {
            if (p.x == x and p.y == y)
                return true;
        }

        return false;
    }

    fn defaultType(layer: Layer) u16 {
        return switch (layer) {
            .ground => Square.editor_tile,
            else => std.math.maxInt(u16),
        };
    }

    fn typeAt(layer: Layer, screen: *MapEditorScreen, x: u16, y: u16) u16 {
        if (x < 0 or y < 0)
            return defaultType(layer);

        const map_tile = screen.getTile(x, y);
        return switch (layer) {
            .ground => map_tile.ground,
            .region => map_tile.region,
            .enemy => blk: {
                var lock = map.useLockForType(Enemy);
                lock.lock();
                defer lock.unlock();
                break :blk if (map.findObjectConst(Enemy, map_tile.entity)) |e| e.data_id else std.math.maxInt(u16);
            },
            .entity => blk: {
                var lock = map.useLockForType(Entity);
                lock.lock();
                defer lock.unlock();
                break :blk if (map.findObjectConst(Entity, map_tile.entity)) |e| e.data_id else std.math.maxInt(u16);
            },
            .portal => blk: {
                var lock = map.useLockForType(Portal);
                lock.lock();
                defer lock.unlock();
                break :blk if (map.findObjectConst(Portal, map_tile.entity)) |p| p.data_id else std.math.maxInt(u16);
            },
            .container => blk: {
                var lock = map.useLockForType(Container);
                lock.lock();
                defer lock.unlock();
                break :blk if (map.findObjectConst(Container, map_tile.entity)) |c| c.data_id else std.math.maxInt(u16);
            },
        };
    }

    fn inside(screen: *MapEditorScreen, places: []Place, x: i32, y: i32, layer: Layer, current_type: u16) bool {
        return x >= 0 and y >= 0 and x < screen.map_size and y < screen.map_size and
            !placesContain(places, x, y) and typeAt(layer, screen, @intCast(x), @intCast(y)) == current_type;
    }

    fn fill(screen: *MapEditorScreen, x: u16, y: u16) !void {
        const FillData = struct { x1: i32, x2: i32, y: i32, dy: i32 };

        var places: std.ArrayListUnmanaged(Place) = .{};

        const layer = screen.active_layer;
        const target_id = switch (screen.active_layer) {
            inline else => |tag| @field(screen.selected, @tagName(tag)),
        };

        const current_id = typeAt(layer, screen, x, y);
        if (current_id == target_id or target_id == defaultType(layer))
            return;

        var stack: std.ArrayListUnmanaged(FillData) = .{};
        defer stack.deinit(screen.allocator);

        try stack.append(screen.allocator, .{ .x1 = x, .x2 = x, .y = y, .dy = 1 });
        try stack.append(screen.allocator, .{ .x1 = x, .x2 = x, .y = y - 1, .dy = -1 });

        while (stack.items.len > 0) {
            const pop = stack.pop();
            var px = pop.x1;

            if (inside(screen, places.items, px, pop.y, layer, current_id)) {
                while (inside(screen, places.items, px - 1, pop.y, layer, current_id)) {
                    try places.append(screen.allocator, .{
                        .x = @intCast(px - 1),
                        .y = @intCast(pop.y),
                        .new_id = target_id,
                        .old_id = current_id,
                        .layer = layer,
                    });
                    px -= 1;
                }

                if (px < pop.x1)
                    try stack.append(screen.allocator, .{ .x1 = px, .x2 = pop.x1 - 1, .y = pop.y - pop.dy, .dy = -pop.dy });
            }

            var x1 = pop.x1;
            while (x1 <= pop.x2) {
                while (inside(screen, places.items, x1, pop.y, layer, current_id)) {
                    try places.append(screen.allocator, .{
                        .x = @intCast(x1),
                        .y = @intCast(pop.y),
                        .old_id = current_id,
                        .new_id = target_id,
                        .layer = layer,
                    });
                    x1 += 1;
                }

                if (x1 > px)
                    try stack.append(screen.allocator, .{ .x1 = px, .x2 = x1 - 1, .y = pop.y + pop.dy, .dy = pop.dy });

                if (x1 - 1 > pop.x2)
                    try stack.append(screen.allocator, .{ .x1 = pop.x2 + 1, .x2 = x1 - 1, .y = pop.y - pop.dy, .dy = -pop.dy });

                x1 += 1;
                while (x1 < pop.x2 and !inside(screen, places.items, x1, pop.y, layer, current_id))
                    x1 += 1;
                px = x1;
            }
        }

        if (places.items.len <= 1) {
            if (places.items.len == 1) screen.command_queue.addCommand(.{ .place = places.items[0] });
            places.deinit(screen.allocator);
        } else {
            screen.command_queue.addCommand(.{ .multi_place = .{ .places = try places.toOwnedSlice(screen.allocator) } });
        }
    }

    pub fn update(self: *MapEditorScreen, _: i64, _: f32) !void {
        if (self.map_tile_data.len <= 0)
            return;

        const world_point = camera.screenToWorld(input.mouse_x, input.mouse_y);
        const size: f32 = @floatFromInt(self.map_size - 1);
        const x = @floor(@max(0, @min(world_point.x, size)));
        const y = @floor(@max(0, @min(world_point.y, size)));
        const ux: u16 = @intFromFloat(x);
        const uy: u16 = @intFromFloat(y);
        const map_tile = self.getTile(ux, uy);

        switch (self.action) {
            .place => try place(self, x, y, .place),
            .erase => try place(self, x, y, .erase),
            .random => try place(self, x, y, .random),
            .undo => self.command_queue.undo(),
            .redo => self.command_queue.redo(),
            .sample => switch (self.active_layer) {
                .ground => self.selected.ground = map_tile.ground,
                .region => self.selected.region = map_tile.region,
                .enemy => self.selected.enemy = blk: {
                    var lock = map.useLockForType(Enemy);
                    lock.lock();
                    defer lock.unlock();
                    break :blk if (map.findObjectConst(Enemy, map_tile.entity)) |e| e.data_id else std.math.maxInt(u16);
                },
                .entity => self.selected.entity = blk: {
                    var lock = map.useLockForType(Entity);
                    lock.lock();
                    defer lock.unlock();
                    break :blk if (map.findObjectConst(Entity, map_tile.entity)) |e| e.data_id else std.math.maxInt(u16);
                },
                .portal => self.selected.portal = blk: {
                    var lock = map.useLockForType(Portal);
                    lock.lock();
                    defer lock.unlock();
                    break :blk if (map.findObjectConst(Portal, map_tile.entity)) |p| p.data_id else std.math.maxInt(u16);
                },
                .container => self.selected.container = blk: {
                    var lock = map.useLockForType(Container);
                    lock.lock();
                    defer lock.unlock();
                    break :blk if (map.findObjectConst(Container, map_tile.entity)) |c| c.data_id else std.math.maxInt(u16);
                },
            },
            .fill => try fill(self, ux, uy),
            .none => {},
        }
    }

    pub fn updateFpsText(self: *MapEditorScreen, fps: usize, mem: f32) !void {
        if (!self.inited)
            return;

        self.fps_text.text_data.setText(
            try std.fmt.bufPrint(self.fps_text.text_data.backing_buffer, "FPS: {}\nMemory: {d:.1} MB", .{ fps, mem }),
            self.allocator,
        );
    }
};
