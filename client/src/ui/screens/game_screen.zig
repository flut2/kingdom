const std = @import("std");
const element = @import("../element.zig");
const assets = @import("../../assets.zig");
const camera = @import("../../camera.zig");
const network = @import("../../network.zig");
const main = @import("../../main.zig");
const shared = @import("shared");
const utils = shared.utils;
const game_data = shared.game_data;
const map = @import("../../game/map.zig");
const input = @import("../../input.zig");

const systems = @import("../systems.zig");
const Player = @import("../../game/player.zig").Player;
const Container = @import("../../game/container.zig").Container;
const Options = @import("options.zig").Options;
const Interactable = element.InteractableImageData;
const NineSlice = element.NineSliceImageData;

pub const GameScreen = struct {
    pub const Slot = struct {
        idx: u8,
        is_container: bool = false,

        fn findInvSlotId(screen: GameScreen, x: f32, y: f32) u8 {
            for (0..screen.inventory_items.len) |i| {
                const data = screen.inventory_pos_data[i];
                if (utils.isInBounds(
                    x,
                    y,
                    screen.inventory_decor.x + data.x - data.w_pad,
                    screen.inventory_decor.y + data.y - data.h_pad,
                    data.w + data.w_pad * 2,
                    data.h + data.h_pad * 2,
                )) {
                    return @intCast(i);
                }
            }

            return 255;
        }

        fn findContainerSlotId(screen: GameScreen, x: f32, y: f32) u8 {
            if (!systems.screen.game.container_visible)
                return 255;

            for (0..screen.container_items.len) |i| {
                const data = screen.container_pos_data[i];
                if (utils.isInBounds(
                    x,
                    y,
                    screen.container_decor.x + data.x - data.w_pad,
                    screen.container_decor.y + data.y - data.h_pad,
                    data.w + data.w_pad * 2,
                    data.h + data.h_pad * 2,
                )) {
                    return @intCast(i);
                }
            }

            return 255;
        }

        pub fn findSlotId(screen: GameScreen, x: f32, y: f32) Slot {
            const inv_slot = findInvSlotId(screen, x, y);
            if (inv_slot != 255) {
                return .{ .idx = inv_slot };
            }

            const container_slot = findContainerSlotId(screen, x, y);
            if (container_slot != 255) {
                return .{ .idx = container_slot, .is_container = true };
            }

            return .{ .idx = 255 };
        }

        pub fn nextEquippableSlot(item_types: []const game_data.ItemType, item_type: game_data.ItemType) Slot {
            for (0..20) |idx| {
                if (idx >= 4 or item_types[idx].typesMatch(item_type))
                    return .{ .idx = @intCast(idx) };
            }
            return .{ .idx = 255 };
        }

        pub fn nextAvailableSlot(screen: GameScreen, item_types: []const game_data.ItemType, item_type: game_data.ItemType) Slot {
            for (0..screen.inventory_items.len) |idx| {
                if (screen.inventory_items[idx].item == std.math.maxInt(u16) and
                    (idx >= 4 or item_types[idx].typesMatch(item_type)))
                    return .{ .idx = @intCast(idx) };
            }
            return .{ .idx = 255 };
        }
    };

    last_level: u8 = std.math.maxInt(u8),
    last_quests: u8 = std.math.maxInt(u8),
    last_exp: u32 = std.math.maxInt(u32),
    last_fame: u32 = std.math.maxInt(u32),
    last_hp: i32 = -1,
    last_max_hp: i32 = -1,
    last_max_hp_bonus: i32 = -1,
    last_mp: i32 = -1,
    last_max_mp: i32 = -1,
    last_max_mp_bonus: i32 = -1,
    container_visible: bool = false,
    container_id: u32 = std.math.maxInt(u32),

    options: *Options = undefined,

    fps_text: *element.Text = undefined,
    chat_input: *element.Input = undefined,
    chat_decor: *element.Image = undefined,
    chat_container: *element.ScrollableContainer = undefined,
    chat_lines: std.ArrayListUnmanaged(*element.Text) = .{},
    bars_decor: *element.Image = undefined,
    stats_button: *element.Button = undefined,
    stats_container: *element.Container = undefined,
    stats_decor: *element.Image = undefined,
    attack_stat_text: *element.Text = undefined,
    defense_stat_text: *element.Text = undefined,
    speed_stat_text: *element.Text = undefined,
    dexterity_stat_text: *element.Text = undefined,
    vitality_stat_text: *element.Text = undefined,
    wisdom_stat_text: *element.Text = undefined,
    health_bar: *element.Bar = undefined,
    mana_bar: *element.Bar = undefined,
    xp_bar: *element.Bar = undefined,
    fame_bar: *element.Bar = undefined,
    inventory_decor: *element.Image = undefined,
    inventory_items: [20]*element.Item = undefined,
    container_decor: *element.Image = undefined,
    container_name: *element.Text = undefined,
    container_items: [8]*element.Item = undefined,
    minimap_decor: *element.Image = undefined,
    minimap_slots: *element.Image = undefined,
    retrieve_button: *element.Button = undefined,
    options_button: *element.Button = undefined,

    inventory_pos_data: [20]utils.Rect = undefined,
    container_pos_data: [8]utils.Rect = undefined,

    inited: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator) !*GameScreen {
        var screen = try allocator.create(GameScreen);
        screen.* = .{ .allocator = allocator };

        const inventory_data = assets.getUiData("player_inventory", 0);
        screen.parseItemRects();

        const minimap_data = assets.getUiData("minimap", 0);
        screen.minimap_decor = try element.create(allocator, element.Image{
            .x = camera.screen_width - minimap_data.width() + 10,
            .y = -10,
            .image_data = .{ .normal = .{ .atlas_data = minimap_data } },
            .is_minimap_decor = true,
            .minimap_offset_x = 21.0,
            .minimap_offset_y = 21.0,
            .minimap_width = 212.0,
            .minimap_height = 212.0,
        });

        const minimap_slots_data = assets.getUiData("minimap_slots", 0);
        screen.minimap_slots = try element.create(allocator, element.Image{
            .x = screen.minimap_decor.x + 15,
            .y = screen.minimap_decor.y + 209,
            .image_data = .{ .normal = .{ .atlas_data = minimap_slots_data } },
        });

        const retrieve_button_data = assets.getUiData("retrieve_button", 0);
        screen.retrieve_button = try element.create(allocator, element.Button{
            .x = screen.minimap_slots.x + 6 + (18 - retrieve_button_data.width()) / 2.0,
            .y = screen.minimap_slots.y + 6 + (18 - retrieve_button_data.height()) / 2.0,
            .image_data = .{ .base = .{ .normal = .{ .atlas_data = retrieve_button_data } } },
            .tooltip_text = .{
                .text = "Return to the Retrieve",
                .size = 12,
                .text_type = .bold_italic,
            },
            .press_callback = returnToRetrieve,
        });

        const options_button_data = assets.getUiData("options_button", 0);
        screen.options_button = try element.create(allocator, element.Button{
            .x = screen.minimap_slots.x + 36 + (18 - options_button_data.width()) / 2.0,
            .y = screen.minimap_slots.y + 6 + (18 - options_button_data.height()) / 2.0,
            .image_data = .{ .base = .{ .normal = .{ .atlas_data = options_button_data } } },
            .tooltip_text = .{
                .text = "Open Options",
                .size = 12,
                .text_type = .bold_italic,
            },
            .press_callback = openOptions,
        });

        screen.inventory_decor = try element.create(allocator, element.Image{
            .x = camera.screen_width - inventory_data.width() + 10,
            .y = camera.screen_height - inventory_data.height() + 10,
            .image_data = .{ .normal = .{ .atlas_data = inventory_data } },
        });

        for (0..screen.inventory_items.len) |i| {
            screen.inventory_items[i] = try element.create(allocator, element.Item{
                .x = screen.inventory_decor.x + screen.inventory_pos_data[i].x + (screen.inventory_pos_data[i].w - assets.error_data.texWRaw() * 4.0) / 2 + assets.padding,
                .y = screen.inventory_decor.y + screen.inventory_pos_data[i].y + (screen.inventory_pos_data[i].h - assets.error_data.texHRaw() * 4.0) / 2 + assets.padding,
                .background_x = screen.inventory_decor.x + screen.inventory_pos_data[i].x,
                .background_y = screen.inventory_decor.y + screen.inventory_pos_data[i].y,
                .image_data = .{ .normal = .{ .scale_x = 4.0, .scale_y = 4.0, .atlas_data = assets.error_data, .glow = true } },
                .visible = false,
                .draggable = true,
                .drag_start_callback = itemDragStartCallback,
                .drag_end_callback = itemDragEndCallback,
                .double_click_callback = itemDoubleClickCallback,
                .shift_click_callback = itemShiftClickCallback,
            });
        }

        const container_data = assets.getUiData("container_view", 0);
        screen.container_decor = try element.create(allocator, element.Image{
            .x = screen.inventory_decor.x - container_data.width() + 10,
            .y = camera.screen_height - container_data.height() + 10,
            .image_data = .{ .normal = .{ .atlas_data = container_data } },
            .visible = false,
        });

        screen.container_name = try element.create(allocator, element.Text{
            .x = screen.container_decor.x + 22,
            .y = screen.container_decor.y + 126,
            .text_data = .{
                .text = "",
                .size = 14,
                .vert_align = .middle,
                .hori_align = .middle,
                .max_width = 196,
                .max_height = 18,
            },
        });

        for (0..screen.container_items.len) |i| {
            screen.container_items[i] = try element.create(allocator, element.Item{
                .x = screen.container_decor.x + screen.container_pos_data[i].x + (screen.container_pos_data[i].w - assets.error_data.texWRaw() * 4.0) / 2 + assets.padding,
                .y = screen.container_decor.y + screen.container_pos_data[i].y + (screen.container_pos_data[i].h - assets.error_data.texHRaw() * 4.0) / 2 + assets.padding,
                .background_x = screen.container_decor.x + screen.container_pos_data[i].x,
                .background_y = screen.container_decor.y + screen.container_pos_data[i].y,
                .image_data = .{ .normal = .{ .scale_x = 4.0, .scale_y = 4.0, .atlas_data = assets.error_data, .glow = true } },
                .visible = false,
                .draggable = true,
                .drag_start_callback = itemDragStartCallback,
                .drag_end_callback = itemDragEndCallback,
                .double_click_callback = itemDoubleClickCallback,
                .shift_click_callback = itemShiftClickCallback,
            });
        }

        const bars_data = assets.getUiData("player_abilities_bars", 0);
        screen.bars_decor = try element.create(allocator, element.Image{
            .x = (camera.screen_width - bars_data.width()) / 2,
            .y = camera.screen_height - bars_data.height() + 10,
            .image_data = .{ .normal = .{ .atlas_data = bars_data } },
        });

        const stats_button_data = assets.getUiData("stats_button", 0);
        screen.stats_button = try element.create(allocator, element.Button{
            .x = screen.bars_decor.x + 21 + (32 - stats_button_data.width()) / 2.0,
            .y = screen.bars_decor.y + 61 + (32 - stats_button_data.height()) / 2.0,
            .image_data = .{ .base = .{ .normal = .{ .atlas_data = stats_button_data, .glow = true } } },
            .userdata = screen,
            .press_callback = statsCallback,
        });

        const stats_decor_data = assets.getUiData("player_stats", 0);
        screen.stats_container = try element.create(allocator, element.Container{
            .x = screen.bars_decor.x + 63 - 15,
            .y = screen.bars_decor.y + 15 - stats_decor_data.height(),
            .visible = false,
        });

        screen.stats_decor = try screen.stats_container.createChild(element.Image{
            .x = 0,
            .y = 0,
            .image_data = .{ .normal = .{ .atlas_data = stats_decor_data } },
        });

        var idx: f32 = 0;
        try addStatText(screen.stats_container, &screen.attack_stat_text, &idx);
        try addStatText(screen.stats_container, &screen.defense_stat_text, &idx);
        try addStatText(screen.stats_container, &screen.speed_stat_text, &idx);
        try addStatText(screen.stats_container, &screen.dexterity_stat_text, &idx);
        try addStatText(screen.stats_container, &screen.vitality_stat_text, &idx);
        try addStatText(screen.stats_container, &screen.wisdom_stat_text, &idx);

        const health_bar_data = assets.getUiData("player_health_bar", 0);
        screen.health_bar = try element.create(allocator, element.Bar{
            .x = screen.bars_decor.x + 70,
            .y = screen.bars_decor.y + 46,
            .image_data = .{ .normal = .{ .atlas_data = health_bar_data } },
            .text_data = .{
                .text = "",
                .size = 12,
                .text_type = .bold_italic,
                .max_chars = 64,
            },
        });

        const mana_bar_data = assets.getUiData("player_mana_bar", 0);
        screen.mana_bar = try element.create(allocator, element.Bar{
            .x = screen.bars_decor.x + 70,
            .y = screen.bars_decor.y + 76,
            .image_data = .{ .normal = .{ .atlas_data = mana_bar_data } },
            .text_data = .{
                .text = "",
                .size = 12,
                .text_type = .bold_italic,
                .max_chars = 64,
            },
        });

        const xp_bar_data = assets.getUiData("player_xp_bar", 0);
        screen.xp_bar = try element.create(allocator, element.Bar{
            .x = screen.bars_decor.x + 70,
            .y = screen.bars_decor.y + 22,
            .image_data = .{ .normal = .{ .atlas_data = xp_bar_data } },
            .text_data = .{
                .text = "",
                .size = 10,
                .text_type = .bold_italic,
                .max_chars = 64,
            },
        });

        const fame_bar_data = assets.getUiData("player_fame_bar", 0);
        screen.fame_bar = try element.create(allocator, element.Bar{
            .x = screen.bars_decor.x + 70,
            .y = screen.bars_decor.y + 22,
            .image_data = .{ .normal = .{ .atlas_data = fame_bar_data } },
            .text_data = .{
                .text = "",
                .size = 10,
                .text_type = .bold_italic,
                .max_chars = 64,
            },
            .visible = false,
        });

        const chat_data = assets.getUiData("chatbox_background", 0);
        const input_data = assets.getUiData("chatbox_input", 0);
        screen.chat_decor = try element.create(allocator, element.Image{
            .x = -10,
            .y = camera.screen_height - chat_data.height() - input_data.height() + 15,
            .image_data = .{ .normal = .{ .atlas_data = chat_data } },
        });

        const cursor_data = assets.getUiData("chatbox_cursor", 0);
        screen.chat_input = try element.create(allocator, element.Input{
            .x = screen.chat_decor.x,
            .y = screen.chat_decor.y + screen.chat_decor.height() - 10,
            .text_inlay_x = 21,
            .text_inlay_y = 21,
            .image_data = .{ .base = .{ .normal = .{ .atlas_data = input_data } } },
            .cursor_image_data = .{ .normal = .{ .atlas_data = cursor_data } },
            .text_data = .{
                .text = "",
                .size = 12,
                .text_type = .bold,
                .max_chars = 256,
                .handle_special_chars = false,
            },
            .allocator = allocator,
            .enter_callback = chatCallback,
            .is_chat = true,
        });

        const scroll_background_data = assets.getUiData("scroll_background", 0);
        const scroll_knob_base = assets.getUiData("scroll_wheel_base", 0);
        const scroll_knob_hover = assets.getUiData("scroll_wheel_hover", 0);
        const scroll_knob_press = assets.getUiData("scroll_wheel_press", 0);
        const scroll_decor_data = assets.getUiData("scrollbar_decor", 0);
        screen.chat_container = try element.create(allocator, element.ScrollableContainer{
            .x = screen.chat_decor.x + 24,
            .y = screen.chat_decor.y + 24,
            .scissor_w = 380,
            .scissor_h = 240,
            .scroll_x = screen.chat_decor.x + 400,
            .scroll_y = screen.chat_decor.y + 24,
            .scroll_w = 4,
            .scroll_h = 240,
            .scroll_side_x = screen.chat_decor.x + 393,
            .scroll_side_y = screen.chat_decor.y + 24,
            .scroll_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_background_data, 4, 240, 0, 0, 2, 2, 1.0) },
            .scroll_knob_image_data = Interactable.fromNineSlices(scroll_knob_base, scroll_knob_hover, scroll_knob_press, 10, 16, 4, 4, 1, 2, 1.0),
            .scroll_side_decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(scroll_decor_data, 6, 240, 0, 41, 6, 3, 1.0) },
            .start_value = 1.0,
        });

        var fps_text_data: element.TextData = .{
            .text = "",
            .size = 12,
            .text_type = .bold,
            .hori_align = .middle,
            .max_width = screen.minimap_decor.width(),
            .max_chars = 256,
        };

        {
            fps_text_data.lock.lock();
            defer fps_text_data.lock.unlock();

            fps_text_data.recalculateAttributes(allocator);
        }

        screen.fps_text = try element.create(allocator, element.Text{
            .x = screen.minimap_decor.x,
            .y = screen.minimap_decor.y + screen.minimap_decor.height() - 10,
            .text_data = fps_text_data,
        });

        screen.options = try Options.init(allocator);

        screen.inited = true;
        return screen;
    }

    pub fn addChatLine(self: *GameScreen, name: []const u8, text: []const u8, name_color: u32, text_color: u32) !void {
        const container_h = self.chat_container.container.height();

        const line_str = try if (name.len > 0)
            std.fmt.allocPrint(self.allocator, "&col=\"{x}\"[{s}]: &col=\"{x}\"{s}", .{ name_color, name, text_color, text })
        else
            std.fmt.allocPrint(self.allocator, "&col=\"{x}\"{s}", .{ text_color, text });

        var chat_line = try self.chat_container.createChild(element.Text{
            .x = 0,
            .y = 0,
            .text_data = .{
                .text = line_str,
                .size = 12,
                .text_type = .bold,
                .max_width = 370,
                .backing_buffer = line_str, // putting it here to dispose automatically. kind of a hack
            },
        });

        const line_h = chat_line.height();
        const total_h = container_h + line_h;
        if (self.chat_container.scissor_h >= total_h) {
            chat_line.y = self.chat_container.scissor_h - line_h;

            for (self.chat_lines.items) |line| {
                line.y -= line_h;
            }
        } else {
            chat_line.y = container_h;
            const first_line_y = if (self.chat_lines.items.len == 0) 0 else self.chat_lines.items[0].y;
            if (first_line_y > 0) {
                for (self.chat_lines.items) |line| {
                    line.y -= first_line_y;
                }
            }
        }

        try self.chat_lines.append(self.allocator, chat_line);
        self.chat_container.update();
    }

    fn addStatText(container: *element.Container, text: **element.Text, idx: *f32) !void {
        defer idx.* += 1;

        const x = 54.0 + 104.0 * @mod(idx.*, 2.0);
        const y = 38.0 + 32.0 * @floor(idx.* / 2.0);
        text.* = try container.createChild(element.Text{ .x = x, .y = y, .text_data = .{
            .text = "",
            .size = 10,
            .text_type = .bold,
            .max_width = 67,
            .max_height = 18,
            .hori_align = .middle,
            .vert_align = .middle,
            .max_chars = 64,
        } });
    }

    pub fn deinit(self: *GameScreen) void {
        self.inited = false;

        element.destroy(self.minimap_decor);
        element.destroy(self.minimap_slots);
        element.destroy(self.inventory_decor);
        element.destroy(self.container_decor);
        element.destroy(self.container_name);
        element.destroy(self.bars_decor);
        element.destroy(self.stats_button);
        element.destroy(self.stats_container);
        element.destroy(self.chat_container);
        element.destroy(self.health_bar);
        element.destroy(self.mana_bar);
        element.destroy(self.xp_bar);
        element.destroy(self.fame_bar);
        element.destroy(self.chat_decor);
        element.destroy(self.chat_input);
        element.destroy(self.fps_text);
        element.destroy(self.options_button);
        element.destroy(self.retrieve_button);

        for (self.inventory_items) |item| {
            element.destroy(item);
        }

        for (self.container_items) |item| {
            element.destroy(item);
        }

        self.chat_lines.deinit(self.allocator);
        if (self.options.inited) self.options.deinit();

        self.allocator.destroy(self);
    }

    pub fn resize(self: *GameScreen, w: f32, h: f32) void {
        self.minimap_decor.x = w - self.minimap_decor.width() + 10;
        self.minimap_slots.x = self.minimap_decor.x + 15;
        self.minimap_slots.y = self.minimap_decor.y + 209;
        self.fps_text.x = self.minimap_decor.x;
        self.fps_text.y = self.minimap_decor.y + self.minimap_decor.height() - 10;
        self.inventory_decor.x = w - self.inventory_decor.width() + 10;
        self.inventory_decor.y = h - self.inventory_decor.height() + 10;
        self.container_decor.x = self.inventory_decor.x - self.container_decor.width() + 10;
        self.container_decor.y = h - self.container_decor.height() + 10;
        self.container_name.x = self.container_decor.x + 22;
        self.container_name.y = self.container_decor.y + 126;
        self.bars_decor.x = (w - self.bars_decor.width()) / 2;
        self.bars_decor.y = h - self.bars_decor.height() + 10;
        self.stats_container.x = self.bars_decor.x + 63 - 15;
        self.stats_container.y = self.bars_decor.y + 15 - self.stats_decor.height();
        self.stats_button.x = self.bars_decor.x + 21 + (32 - self.stats_button.width()) / 2.0;
        self.stats_button.y = self.bars_decor.y + 61 + (32 - self.stats_button.height()) / 2.0;
        self.health_bar.x = self.bars_decor.x + 70;
        self.health_bar.y = self.bars_decor.y + 46;
        self.mana_bar.x = self.bars_decor.x + 70;
        self.mana_bar.y = self.bars_decor.y + 76;
        self.xp_bar.x = self.bars_decor.x + 70;
        self.xp_bar.y = self.bars_decor.y + 22;
        self.fame_bar.x = self.bars_decor.x + 70;
        self.fame_bar.y = self.bars_decor.y + 22;
        const chat_decor_h = self.chat_decor.height();
        self.chat_decor.y = h - chat_decor_h - self.chat_input.image_data.current(self.chat_input.state).normal.height() + 15;
        self.chat_container.container.x = self.chat_decor.x + 26;
        const old_y = self.chat_container.base_y;
        self.chat_container.base_y = self.chat_decor.y + 26;
        self.chat_container.container.y += (self.chat_container.base_y - old_y);
        self.chat_container.scroll_bar.x = self.chat_decor.x + 400;
        self.chat_container.scroll_bar.y = self.chat_decor.y + 24;
        if (self.chat_container.hasScrollDecor()) {
            self.chat_container.scroll_bar_decor.x = self.chat_decor.x + 393;
            self.chat_container.scroll_bar_decor.y = self.chat_decor.y + 24;
        }
        self.chat_input.y = self.chat_decor.y + chat_decor_h - 10;
        self.retrieve_button.x = self.minimap_slots.x + 6 + (18 - self.retrieve_button.width()) / 2.0;
        self.retrieve_button.y = self.minimap_slots.y + 6 + (18 - self.retrieve_button.height()) / 2.0;
        self.options_button.x = self.minimap_slots.x + 36 + (18 - self.options_button.width()) / 2.0;
        self.options_button.y = self.minimap_slots.y + 6 + (18 - self.options_button.height()) / 2.0;

        for (0..self.inventory_items.len) |idx| {
            self.inventory_items[idx].x = self.inventory_decor.x + systems.screen.game.inventory_pos_data[idx].x + (systems.screen.game.inventory_pos_data[idx].w - self.inventory_items[idx].texWRaw()) / 2;
            self.inventory_items[idx].y = self.inventory_decor.y + systems.screen.game.inventory_pos_data[idx].y + (systems.screen.game.inventory_pos_data[idx].h - self.inventory_items[idx].texHRaw()) / 2;
            self.inventory_items[idx].background_x = self.inventory_decor.x + systems.screen.game.inventory_pos_data[idx].x;
            self.inventory_items[idx].background_y = self.inventory_decor.y + systems.screen.game.inventory_pos_data[idx].y;
        }

        for (0..self.container_items.len) |idx| {
            self.container_items[idx].x = self.container_decor.x + systems.screen.game.container_pos_data[idx].x + (systems.screen.game.container_pos_data[idx].w - self.container_items[idx].texWRaw()) / 2;
            self.container_items[idx].y = self.container_decor.y + systems.screen.game.container_pos_data[idx].y + (systems.screen.game.container_pos_data[idx].h - self.container_items[idx].texHRaw()) / 2;
            self.container_items[idx].background_x = self.container_decor.x + systems.screen.game.container_pos_data[idx].x;
            self.container_items[idx].background_y = self.container_decor.y + systems.screen.game.container_pos_data[idx].y;
        }

        self.options.resize(w, h);
    }

    pub fn update(self: *GameScreen, _: i64, _: f32) !void {
        self.fps_text.visible = main.settings.stats_enabled;

        var lock = map.useLockForType(Player);
        lock.lock();
        defer lock.unlock();
        if (map.localPlayerConst()) |local_player| {
            if (local_player.level >= 20) {
                setFameBar: {
                    if (main.character_list == null or main.class_quest_idx >= main.character_list.?.class_quests.len)
                        break :setFameBar;

                    const fame = @divFloor(local_player.exp, 1000);
                    const quests_complete = main.character_list.?.class_quests[main.class_quest_idx].quests_complete;
                    if (self.last_fame != fame or self.last_quests != quests_complete) {
                        self.fame_bar.visible = true;
                        self.xp_bar.visible = false;

                        var fame_text_data = &self.fame_bar.text_data;
                        if (quests_complete < 5) {
                            const fame_goal = game_data.fameGoal(quests_complete);
                            const fame_perc = @as(f32, @floatFromInt(fame)) / @as(f32, @floatFromInt(fame_goal));
                            self.fame_bar.scissor.max_x = self.fame_bar.texWRaw() * fame_perc;

                            fame_text_data.setText(
                                try std.fmt.bufPrint(fame_text_data.backing_buffer, "{}/{} Fame", .{ fame, fame_goal }),
                                self.allocator,
                            );
                        } else {
                            self.fame_bar.scissor.max_x = self.fame_bar.texWRaw();
                            fame_text_data.setText(
                                try std.fmt.bufPrint(fame_text_data.backing_buffer, "{} Fame", .{fame}),
                                self.allocator,
                            );
                        }

                        self.last_fame = fame;
                        self.last_quests = quests_complete;
                    }
                }
            } else {
                if (self.last_exp != local_player.exp or self.last_level != local_player.level) {
                    self.xp_bar.visible = true;
                    self.fame_bar.visible = false;
                    const next_exp_goal = game_data.expGoal(local_player.level);
                    const xp_perc = @as(f32, @floatFromInt(local_player.exp)) / @as(f32, @floatFromInt(next_exp_goal));
                    self.xp_bar.scissor.max_x = self.xp_bar.texWRaw() * xp_perc;

                    var xp_text_data = &self.xp_bar.text_data;
                    xp_text_data.setText(
                        try std.fmt.bufPrint(xp_text_data.backing_buffer, "Level {} - {}/{}", .{
                            local_player.level,
                            local_player.exp,
                            next_exp_goal,
                        }),
                        self.allocator,
                    );

                    self.last_exp = local_player.exp;
                    self.last_level = local_player.level;
                }
            }

            if (self.last_hp != local_player.hp or self.last_max_hp != local_player.max_hp or self.last_max_hp_bonus != local_player.max_hp_bonus) {
                const hp_perc = @as(f32, @floatFromInt(local_player.hp)) / @as(f32, @floatFromInt(local_player.max_hp + local_player.max_hp_bonus));
                self.health_bar.scissor.max_x = self.health_bar.texWRaw() * hp_perc;

                var health_text_data = &self.health_bar.text_data;
                if (local_player.max_hp_bonus > 0) {
                    health_text_data.setText(
                        try std.fmt.bufPrint(health_text_data.backing_buffer, "{}/{} &size=\"10\"&col=\"65E698\"(+{})", .{
                            local_player.hp,
                            local_player.max_hp + local_player.max_hp_bonus,
                            local_player.max_hp_bonus,
                        }),
                        self.allocator,
                    );
                } else if (local_player.max_hp_bonus < 0) {
                    health_text_data.setText(
                        try std.fmt.bufPrint(health_text_data.backing_buffer, "{}/{} &size=\"10\"&col=\"FF7070\"(+{})", .{
                            local_player.hp,
                            local_player.max_hp + local_player.max_hp_bonus,
                            local_player.max_hp_bonus,
                        }),
                        self.allocator,
                    );
                } else {
                    health_text_data.setText(
                        try std.fmt.bufPrint(health_text_data.backing_buffer, "{}/{}", .{ local_player.hp, local_player.max_hp }),
                        self.allocator,
                    );
                }

                self.last_hp = local_player.hp;
                self.last_max_hp = local_player.max_hp;
                self.last_max_hp_bonus = local_player.max_hp_bonus;
            }

            if (self.last_mp != local_player.mp or self.last_max_mp != local_player.max_mp or self.last_max_mp_bonus != local_player.max_mp_bonus) {
                const mp_perc = @as(f32, @floatFromInt(local_player.mp)) / @as(f32, @floatFromInt(local_player.max_mp + local_player.max_mp_bonus));
                self.mana_bar.scissor.max_x = self.mana_bar.texWRaw() * mp_perc;

                var mana_text_data = &self.mana_bar.text_data;
                if (local_player.max_mp_bonus > 0) {
                    mana_text_data.setText(
                        try std.fmt.bufPrint(mana_text_data.backing_buffer, "{}/{} &size=\"10\"&col=\"65E698\"(+{})", .{
                            local_player.mp,
                            local_player.max_mp + local_player.max_mp_bonus,
                            local_player.max_mp_bonus,
                        }),
                        self.allocator,
                    );
                } else if (local_player.max_mp_bonus < 0) {
                    mana_text_data.setText(
                        try std.fmt.bufPrint(mana_text_data.backing_buffer, "{}/{} &size=\"10\"&col=\"FF7070\"(+{})", .{
                            local_player.mp,
                            local_player.max_mp + local_player.max_mp_bonus,
                            local_player.max_mp_bonus,
                        }),
                        self.allocator,
                    );
                } else {
                    mana_text_data.setText(
                        try std.fmt.bufPrint(mana_text_data.backing_buffer, "{}/{}", .{ local_player.mp, local_player.max_mp }),
                        self.allocator,
                    );
                }

                self.last_mp = local_player.mp;
                self.last_max_mp = local_player.max_mp;
            }
        }
    }

    fn updateStat(allocator: std.mem.Allocator, text_data: *element.TextData, base_val: i32, bonus_val: i32, max_val: i32) void {
        text_data.color = if (base_val >= max_val) 0xFFE770 else 0xFFFFFF;
        text_data.setText((if (bonus_val > 0)
            std.fmt.bufPrint(
                text_data.backing_buffer,
                "{} &size=\"8\"&col=\"65E698\"(+{})",
                .{ base_val + bonus_val, bonus_val },
            )
        else if (bonus_val < 0)
            std.fmt.bufPrint(
                text_data.backing_buffer,
                "{} &size=\"8\"&col=\"FF7070\"({})",
                .{ base_val + bonus_val, bonus_val },
            )
        else
            std.fmt.bufPrint(text_data.backing_buffer, "{}", .{base_val + bonus_val})) catch text_data.text, allocator);
    }

    pub fn updateStats(self: *GameScreen) void {
        if (!self.inited)
            return;

        std.debug.assert(!map.useLockForType(Player).tryLock());
        if (map.localPlayerConst()) |player| {
            updateStat(self.allocator, &self.attack_stat_text.text_data, player.attack, player.attack_bonus, player.data.stats.attack.max);
            updateStat(self.allocator, &self.defense_stat_text.text_data, player.defense, player.defense_bonus, player.data.stats.defense.max);
            updateStat(self.allocator, &self.speed_stat_text.text_data, player.speed, player.speed_bonus, player.data.stats.speed.max);
            updateStat(self.allocator, &self.dexterity_stat_text.text_data, player.dexterity, player.dexterity_bonus, player.data.stats.dexterity.max);
            updateStat(self.allocator, &self.vitality_stat_text.text_data, player.vitality, player.vitality_bonus, player.data.stats.vitality.max);
            updateStat(self.allocator, &self.wisdom_stat_text.text_data, player.wisdom, player.wisdom_bonus, player.data.stats.wisdom.max);
        }
    }

    pub fn updateFpsText(self: *GameScreen, fps: usize, mem: f32) !void {
        const fmt =
            \\FPS: {}
            \\Memory: {d:.1} MB
        ;
        self.fps_text.text_data.setText(try std.fmt.bufPrint(self.fps_text.text_data.backing_buffer, fmt, .{ fps, mem }), self.allocator);
    }

    fn parseItemRects(self: *GameScreen) void {
        for (0..self.inventory_items.len) |i| {
            if (i < 4) {
                const fi: f32 = @floatFromInt(i);
                self.inventory_pos_data[i] = .{
                    .x = 15.0 + fi * 56.0,
                    .y = 15.0,
                    .w = 56.0,
                    .h = 56.0,
                    .w_pad = 0.0,
                    .h_pad = 0.0,
                };
            } else {
                const hori_idx: f32 = @floatFromInt(@mod(i - 4, 4));
                const vert_idx: f32 = @floatFromInt(@divFloor(i - 4, 4));
                self.inventory_pos_data[i] = .{
                    .x = 23.0 + hori_idx * 52.0,
                    .y = 73.0 + vert_idx * 52.0,
                    .w = 52.0,
                    .h = 52.0,
                    .w_pad = 0.0,
                    .h_pad = 0.0,
                };
            }
        }

        for (0..self.container_items.len) |i| {
            const hori_idx: f32 = @floatFromInt(@mod(i, 4));
            const vert_idx: f32 = @floatFromInt(@divFloor(i, 4));
            self.container_pos_data[i] = utils.Rect{
                .x = 15.0 + hori_idx * 52,
                .y = 15.0 + vert_idx * 52,
                .w = 52,
                .h = 52,
                .w_pad = 0.0,
                .h_pad = 0.0,
            };
        }
    }

    fn swapError(self: *GameScreen, start_slot: Slot, start_item: u16) void {
        if (start_slot.is_container) {
            self.setContainerItem(start_item, start_slot.idx);
        } else {
            self.setInvItem(start_item, start_slot.idx);
        }

        assets.playSfx("error.mp3");
    }

    pub fn swapSlots(self: *GameScreen, start_slot: Slot, end_slot: Slot) void {
        std.debug.assert(!map.useLockForType(Player).tryLock());

        const int_id = map.interactive.map_id.load(.acquire);

        const start_item = if (start_slot.is_container)
            self.container_items[start_slot.idx].item
        else
            self.inventory_items[start_slot.idx].item;

        if (end_slot.idx == 255) {
            if (!start_slot.is_container) {
                self.setInvItem(std.math.maxInt(u16), start_slot.idx);
                main.server.sendPacket(.{ .inv_drop = .{
                    .player_map_id = map.local_player_id,
                    .slot_id = start_slot.idx,
                } });
            } else {
                self.swapError(start_slot, start_item);
                return;
            }
        } else {
            if (map.localPlayerConst()) |local_player| {
                const start_data = game_data.item.from_id.get(start_item) orelse {
                    self.swapError(start_slot, start_item);
                    return;
                };

                const end_item_types = blk: {
                    if (end_slot.is_container) {
                        var cont_lock = map.useLockForType(Container);
                        cont_lock.lock();
                        defer cont_lock.unlock();
                        const container = map.findObjectConst(Container, self.container_id) orelse {
                            self.swapError(start_slot, start_item);
                            return;
                        };
                        break :blk container.data.item_types;
                    } else break :blk local_player.data.item_types;
                };

                if (!game_data.ItemType.typesMatch(start_data.item_type, if (end_slot.idx < 4) end_item_types[end_slot.idx] else .any)) {
                    self.swapError(start_slot, start_item);
                    return;
                }

                const end_item = if (end_slot.is_container)
                    self.container_items[end_slot.idx].item
                else
                    self.inventory_items[end_slot.idx].item;

                if (start_slot.is_container) {
                    self.setContainerItem(end_item, start_slot.idx);
                } else {
                    self.setInvItem(end_item, start_slot.idx);
                }

                if (end_slot.is_container) {
                    self.setContainerItem(start_item, end_slot.idx);
                } else {
                    self.setInvItem(start_item, end_slot.idx);
                }

                main.server.sendPacket(.{ .inv_swap = .{
                    .time = main.current_time,
                    .x = local_player.x,
                    .y = local_player.y,
                    .from_obj_type = if (start_slot.is_container) .container else .player,
                    .from_map_id = if (start_slot.is_container) int_id else map.local_player_id,
                    .from_slot_id = start_slot.idx,
                    .to_obj_type = if (end_slot.is_container) .container else .player,
                    .to_map_id = if (end_slot.is_container) int_id else map.local_player_id,
                    .to_slot_id = end_slot.idx,
                } });

                assets.playSfx("move_item.mp3");
            }
        }
    }

    fn itemDoubleClickCallback(item: *element.Item) void {
        if (item.item < 0)
            return;

        const start_slot = Slot.findSlotId(systems.screen.game.*, item.x + 4, item.y + 4);
        if (game_data.item.from_id.get(@intCast(item.item))) |props| {
            if (props.consumable and !start_slot.is_container) {
                var lock = map.useLockForType(Player);
                lock.lock();
                defer lock.unlock();
                if (map.localPlayerConst()) |local_player| {
                    main.server.sendPacket(.{ .use_item = .{
                        .obj_type = .player,
                        .map_id = map.local_player_id,
                        .slot_id = start_slot.idx,
                        .x = local_player.x,
                        .y = local_player.y,
                        .time = main.current_time,
                    } });
                    assets.playSfx("consume.mp3");
                }

                return;
            }
        }

        var lock = map.useLockForType(Player);
        lock.lock();
        defer lock.unlock();
        if (map.localPlayerConst()) |local_player| {
            if (game_data.item.from_id.get(@intCast(item.item))) |data| {
                if (start_slot.is_container) {
                    const end_slot = Slot.nextAvailableSlot(systems.screen.game.*, local_player.data.item_types, data.item_type);
                    if (start_slot.idx == end_slot.idx and start_slot.is_container == end_slot.is_container) {
                        item.x = item.drag_start_x;
                        item.y = item.drag_start_y;
                        return;
                    }

                    systems.screen.game.swapSlots(start_slot, end_slot);
                } else {
                    const end_slot = Slot.nextEquippableSlot(local_player.data.item_types, data.item_type);
                    if (end_slot.idx == 255 or // we don't want to drop
                        start_slot.idx == end_slot.idx and start_slot.is_container == end_slot.is_container)
                    {
                        item.x = item.drag_start_x;
                        item.y = item.drag_start_y;
                        return;
                    }

                    systems.screen.game.swapSlots(start_slot, end_slot);
                }
            }
        }
    }

    fn returnToRetrieve(_: ?*anyopaque) void {
        if (systems.screen == .game) main.server.sendPacket(.{ .escape = .{} });
    }

    fn openOptions(_: ?*anyopaque) void {
        input.openOptions();
    }

    pub fn statsCallback(ud: ?*anyopaque) void {
        const screen: *GameScreen = @alignCast(@ptrCast(ud.?));
        screen.stats_container.visible = !screen.stats_container.visible;
        if (screen.stats_container.visible) {
            var lock = map.useLockForType(Player);
            lock.lock();
            defer lock.unlock();
            screen.updateStats();
        }
    }

    fn chatCallback(input_text: []const u8) void {
        if (input_text.len > 0) {
            main.server.sendPacket(.{ .player_text = .{ .text = input_text } });

            const current_screen = systems.screen.game;
            const text_copy = current_screen.allocator.dupe(u8, input_text) catch unreachable;
            input.input_history.append(input.allocator, text_copy) catch unreachable;
            input.input_history_idx = @intCast(input.input_history.items.len);
        }
    }

    fn interactCallback() void {}

    fn itemDragStartCallback(item: *element.Item) void {
        item.background_image_data = null;
    }

    fn itemDragEndCallback(item: *element.Item) void {
        var current_screen = systems.screen.game;
        const start_slot = Slot.findSlotId(current_screen.*, item.drag_start_x + 4, item.drag_start_y + 4);
        const end_slot = Slot.findSlotId(current_screen.*, item.x - item.drag_offset_x, item.y - item.drag_offset_y);
        if (start_slot.idx == end_slot.idx and start_slot.is_container == end_slot.is_container) {
            item.x = item.drag_start_x;
            item.y = item.drag_start_y;

            // to update the background image
            if (start_slot.is_container) {
                current_screen.setContainerItem(item.item, start_slot.idx);
            } else {
                current_screen.setInvItem(item.item, start_slot.idx);
            }
            return;
        }

        var lock = map.useLockForType(Player);
        lock.lock();
        defer lock.unlock();
        current_screen.swapSlots(start_slot, end_slot);
    }

    fn itemShiftClickCallback(item: *element.Item) void {
        if (item.item < 0)
            return;

        const current_screen = systems.screen.game.*;
        const slot = Slot.findSlotId(current_screen, item.x + 4, item.y + 4);

        if (game_data.item.from_id.get(@intCast(item.item))) |props| {
            if (props.consumable) {
                var lock = map.useLockForType(Player);
                lock.lock();
                defer lock.unlock();
                if (map.localPlayerConst()) |local_player| {
                    main.server.sendPacket(.{ .use_item = .{
                        .obj_type = if (slot.is_container) .container else .player,
                        .map_id = if (slot.is_container) current_screen.container_id else map.local_player_id,
                        .slot_id = slot.idx,
                        .x = local_player.x,
                        .y = local_player.y,
                        .time = main.current_time,
                    } });
                    assets.playSfx("consume.mp3");
                }

                return;
            }
        }
    }

    pub fn useItem(self: *GameScreen, idx: u8) void {
        itemDoubleClickCallback(self.inventory_items[idx]);
    }

    pub fn setContainerItem(self: *GameScreen, item: u16, idx: u8) void {
        if (item == std.math.maxInt(u16)) {
            self.container_items[idx].item = std.math.maxInt(u16);
            self.container_items[idx].visible = false;
            return;
        }

        self.container_items[idx].visible = true;

        if (game_data.item.from_id.get(@intCast(item))) |data| {
            if (assets.atlas_data.get(data.texture.sheet)) |tex| {
                const atlas_data = tex[data.texture.index];
                const base_x = self.container_decor.x + self.container_pos_data[idx].x;
                const base_y = self.container_decor.y + self.container_pos_data[idx].y;
                const pos_w = self.container_pos_data[idx].w;
                const pos_h = self.container_pos_data[idx].h;

                if (std.mem.eql(u8, data.rarity, "Mythic")) {
                    self.container_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("mythic_slot", 0) } };
                } else if (std.mem.eql(u8, data.rarity, "Legendary")) {
                    self.container_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("legendary_slot", 0) } };
                } else if (std.mem.eql(u8, data.rarity, "Epic")) {
                    self.container_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("epic_slot", 0) } };
                } else if (std.mem.eql(u8, data.rarity, "Rare")) {
                    self.container_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("rare_slot", 0) } };
                } else {
                    self.container_items[idx].background_image_data = null;
                }

                self.container_items[idx].item = item;
                self.container_items[idx].image_data.normal.atlas_data = atlas_data;
                self.container_items[idx].x = base_x + (pos_w - self.container_items[idx].texWRaw()) / 2 + assets.padding;
                self.container_items[idx].y = base_y + (pos_h - self.container_items[idx].texHRaw()) / 2 + assets.padding;

                return;
            } else {
                std.log.err("Could not find ui sheet {s} for item with data id {}, index {}", .{ data.texture.sheet, item, idx });
            }
        } else {
            std.log.err("Attempted to populate inventory index {} with item {}, but props was not found", .{ idx, item });
        }

        self.container_items[idx].item = std.math.maxInt(u16);
        self.container_items[idx].image_data.normal.atlas_data = assets.error_data;
        self.container_items[idx].x = self.container_decor.x + self.container_pos_data[idx].x + (self.container_pos_data[idx].w - self.container_items[idx].texWRaw()) / 2 + assets.padding;
        self.container_items[idx].y = self.container_decor.y + self.container_pos_data[idx].y + (self.container_pos_data[idx].h - self.container_items[idx].texHRaw()) / 2 + assets.padding;
        self.container_items[idx].background_image_data = null;
    }

    pub fn setInvItem(self: *GameScreen, item: u16, idx: u8) void {
        if (item == std.math.maxInt(u16)) {
            self.inventory_items[idx].item = std.math.maxInt(u16);
            self.inventory_items[idx].visible = false;
            return;
        }

        self.inventory_items[idx].visible = true;

        if (game_data.item.from_id.get(@intCast(item))) |data| {
            if (assets.atlas_data.get(data.texture.sheet)) |tex| {
                const atlas_data = tex[data.texture.index];
                const base_x = self.inventory_decor.x + self.inventory_pos_data[idx].x;
                const base_y = self.inventory_decor.y + self.inventory_pos_data[idx].y;
                const pos_w = self.inventory_pos_data[idx].w;
                const pos_h = self.inventory_pos_data[idx].h;

                if (idx < 4) {
                    if (std.mem.eql(u8, data.rarity, "Mythic")) {
                        self.inventory_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("mythic_slot_equip", 0) } };
                    } else if (std.mem.eql(u8, data.rarity, "Legendary")) {
                        self.inventory_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("legendary_slot_equip", 0) } };
                    } else if (std.mem.eql(u8, data.rarity, "Epic")) {
                        self.inventory_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("epic_slot_equip", 0) } };
                    } else if (std.mem.eql(u8, data.rarity, "Rare")) {
                        self.inventory_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("rare_slot_equip", 0) } };
                    } else {
                        self.inventory_items[idx].background_image_data = null;
                    }
                } else {
                    if (std.mem.eql(u8, data.rarity, "Mythic")) {
                        self.inventory_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("mythic_slot", 0) } };
                    } else if (std.mem.eql(u8, data.rarity, "Legendary")) {
                        self.inventory_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("legendary_slot", 0) } };
                    } else if (std.mem.eql(u8, data.rarity, "Epic")) {
                        self.inventory_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("epic_slot", 0) } };
                    } else if (std.mem.eql(u8, data.rarity, "Rare")) {
                        self.inventory_items[idx].background_image_data = .{ .normal = .{ .atlas_data = assets.getUiData("rare_slot", 0) } };
                    } else {
                        self.inventory_items[idx].background_image_data = null;
                    }
                }

                self.inventory_items[idx].item = item;
                self.inventory_items[idx].image_data.normal.atlas_data = atlas_data;
                self.inventory_items[idx].x = base_x + (pos_w - self.inventory_items[idx].texWRaw()) / 2 + assets.padding;
                self.inventory_items[idx].y = base_y + (pos_h - self.inventory_items[idx].texHRaw()) / 2 + assets.padding;

                return;
            } else {
                std.log.err("Could not find ui sheet {s} for item with data id {}, index {}", .{ data.texture.sheet, item, idx });
            }
        } else {
            std.log.err("Attempted to populate inventory index {} with item id {}, but props was not found", .{ idx, item });
        }

        const atlas_data = assets.error_data;
        self.inventory_items[idx].item = std.math.maxInt(u16);
        self.inventory_items[idx].image_data.normal.atlas_data = atlas_data;
        self.inventory_items[idx].x = self.inventory_decor.x + self.inventory_pos_data[idx].x + (self.inventory_pos_data[idx].w - self.inventory_items[idx].texWRaw()) / 2 + assets.padding;
        self.inventory_items[idx].y = self.inventory_decor.y + self.inventory_pos_data[idx].y + (self.inventory_pos_data[idx].h - self.inventory_items[idx].texHRaw()) / 2 + assets.padding;
        self.inventory_items[idx].background_image_data = null;
    }

    pub fn setContainerVisible(self: *GameScreen, visible: bool) void {
        if (!self.inited)
            return;

        self.container_visible = visible;
        self.container_decor.visible = visible;
    }
};
