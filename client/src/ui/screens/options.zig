const std = @import("std");
const element = @import("../element.zig");
const assets = @import("../../assets.zig");
const camera = @import("../../camera.zig");
const main = @import("../../main.zig");
const input = @import("../../input.zig");

const Settings = @import("../../Settings.zig");
const NineSlice = element.NineSliceImageData;
const Interactable = element.InteractableImageData;
const systems = @import("../systems.zig");

const button_width = 150;
const button_height = 50;

pub const TabType = enum { general, graphics, misc };

pub const Options = struct {
    visible: bool = false,
    inited: bool = false,
    selected_tab: TabType = .general,
    main: *element.Container = undefined,
    buttons: *element.Container = undefined,
    tabs: *element.Container = undefined,
    general_tab: *element.Container = undefined,
    graphics_tab: *element.Container = undefined,
    misc_tab: *element.Container = undefined,
    options_bg: *element.Image = undefined,
    options_text: *element.Text = undefined,
    continue_button: *element.Button = undefined,
    disconnect_button: *element.Button = undefined,
    defaults_button: *element.Button = undefined,
    allocator: std.mem.Allocator = undefined,

    pub fn init(allocator: std.mem.Allocator) !*Options {
        var screen = try allocator.create(Options);
        screen.* = .{ .allocator = allocator };

        const width = camera.screen_width;
        const height = camera.screen_height;

        screen.main = try element.create(allocator, element.Container{
            .x = 0,
            .y = 0,
            .visible = screen.visible,
        });

        screen.buttons = try element.create(allocator, element.Container{
            .x = 0,
            .y = height - button_height - 50,
            .visible = screen.visible,
        });

        screen.tabs = try element.create(allocator, element.Container{
            .x = 0,
            .y = 25,
            .visible = screen.visible,
        });

        screen.general_tab = try element.create(allocator, element.Container{
            .x = 100,
            .y = 150,
            .visible = screen.visible and screen.selected_tab == .general,
        });

        screen.graphics_tab = try element.create(allocator, element.Container{
            .x = 100,
            .y = 150,
            .visible = screen.visible and screen.selected_tab == .graphics,
        });

        screen.misc_tab = try element.create(allocator, element.Container{
            .x = 100,
            .y = 150,
            .visible = screen.visible and screen.selected_tab == .misc,
        });

        const options_background = assets.getUiData("options_background", 0);
        screen.options_bg = try screen.main.createChild(element.Image{ .x = 0, .y = 0, .image_data = .{
            .nine_slice = NineSlice.fromAtlasData(options_background, width, height, 0, 0, 8, 8, 1.0),
        } });

        screen.options_text = try screen.main.createChild(element.Text{ .x = 0, .y = 25, .text_data = .{
            .text = "Options",
            .size = 32,
            .text_type = .bold,
        } });
        screen.options_text.x = (width - screen.options_text.width()) / 2;

        const button_data_base = assets.getUiData("button_base", 0);
        const button_data_hover = assets.getUiData("button_hover", 0);
        const button_data_press = assets.getUiData("button_press", 0);
        screen.continue_button = try screen.buttons.createChild(element.Button{
            .x = (width - button_width) / 2,
            .y = button_height / 2 - 20,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Continue",
                .size = 16,
                .text_type = .bold,
            },
            .userdata = screen,
            .press_callback = closeCallback,
        });

        screen.disconnect_button = try screen.buttons.createChild(element.Button{
            .x = width - button_width - 50,
            .y = button_height / 2 - 20,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Disconnect",
                .size = 16,
                .text_type = .bold,
            },
            .userdata = screen,
            .press_callback = disconnectCallback,
        });

        screen.defaults_button = try screen.buttons.createChild(element.Button{
            .x = 50,
            .y = button_height / 2 - 20,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Defaults",
                .size = 16,
                .text_type = .bold,
            },
            .press_callback = resetToDefaultsCallback,
        });

        var tabx_offset: f32 = 50;
        const tab_y = 50;

        _ = try screen.tabs.createChild(element.Button{
            .x = tabx_offset,
            .y = tab_y,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "General",
                .size = 16,
                .text_type = .bold,
            },
            .userdata = screen,
            .press_callback = generalTabCallback,
        });

        tabx_offset += button_width + 10;

        _ = try screen.tabs.createChild(element.Button{
            .x = tabx_offset,
            .y = tab_y,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Graphics",
                .size = 16,
                .text_type = .bold,
            },
            .userdata = screen,
            .press_callback = graphicsTabCallback,
        });

        tabx_offset += button_width + 10;

        _ = try screen.tabs.createChild(element.Button{
            .x = tabx_offset,
            .y = tab_y,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_width, button_height, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Misc",
                .size = 16,
                .text_type = .bold,
            },
            .userdata = screen,
            .press_callback = miscTabCallback,
        });

        try addKeyMap(screen.general_tab, &main.settings.move_up, "Move Up", "");
        try addKeyMap(screen.general_tab, &main.settings.move_down, "Move Down", "");
        try addKeyMap(screen.general_tab, &main.settings.move_right, "Move Right", "");
        try addKeyMap(screen.general_tab, &main.settings.move_left, "Move Left", "");
        try addKeyMap(screen.general_tab, &main.settings.rotate_left, "Rotate Left", "");
        try addKeyMap(screen.general_tab, &main.settings.rotate_right, "Rotate Right", "");
        try addKeyMap(screen.general_tab, &main.settings.escape, "Return to the Retrieve", "");
        try addKeyMap(screen.general_tab, &main.settings.interact, "Interact", "");
        try addKeyMap(screen.general_tab, &main.settings.shoot, "Shoot", "");
        try addKeyMap(screen.general_tab, &main.settings.ability, "Use Ability", "");
        try addKeyMap(screen.general_tab, &main.settings.reset_camera, "Reset Camera", "This resets the camera's angle to the default of 0");
        try addKeyMap(screen.general_tab, &main.settings.toggle_stats, "Toggle Stats", "This toggles whether to show the stats view");
        try addKeyMap(screen.general_tab, &main.settings.toggle_perf_stats, "Toggle Performance Counter", "This toggles whether to show the performance counter");

        try addToggle(screen.graphics_tab, &main.settings.enable_vsync, "V-Sync", "Toggles vertical syncing, which can reduce screen tearing");
        try addToggle(screen.graphics_tab, &main.settings.enable_lights, "Lights", "Toggles lights, which can reduce frame rates");
        try addToggle(screen.graphics_tab, &main.settings.enable_glow, "Glow", "Toggles glow, which can reduce frame rates");

        try addSlider(screen.misc_tab, &main.settings.sfx_volume, 0.0, 1.0, "SFX Volume", "Changes the volume of sound effects");
        try addSlider(screen.misc_tab, &main.settings.music_volume, 0.0, 1.0, "Music Volume", "Changes the volume of music");

        switch (screen.selected_tab) {
            .general => positionElements(screen.general_tab),
            .graphics => positionElements(screen.graphics_tab),
            .misc => positionElements(screen.misc_tab),
        }

        screen.inited = true;
        return screen;
    }

    pub fn deinit(self: *Options) void {
        self.inited = false;

        element.destroy(self.main);
        element.destroy(self.buttons);
        element.destroy(self.tabs);
        element.destroy(self.general_tab);
        element.destroy(self.graphics_tab);
        element.destroy(self.misc_tab);

        self.allocator.destroy(self);
    }

    pub fn resize(self: *Options, w: f32, h: f32) void {
        self.options_bg.image_data.nine_slice.w = w;
        self.options_bg.image_data.nine_slice.h = h;
        self.options_text.x = (w - self.options_text.width()) / 2;
        self.buttons.y = h - button_height - 50;
        self.disconnect_button.x = w - button_width - 50;
        self.continue_button.x = (w - button_width) / 2;
        switch (self.selected_tab) {
            .general => positionElements(self.general_tab),
            .graphics => positionElements(self.graphics_tab),
            .misc => positionElements(self.misc_tab),
        }
    }

    fn addKeyMap(target_tab: *element.Container, button: *Settings.Button, title: []const u8, desc: []const u8) !void {
        const button_data_base = assets.getUiData("button_base", 0);
        const button_data_hover = assets.getUiData("button_hover", 0);
        const button_data_press = assets.getUiData("button_press", 0);

        const w = 50;
        const h = 50;

        _ = try target_tab.createChild(element.KeyMapper{
            .x = 0,
            .y = 0,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, w, h, 26, 21, 3, 3, 1.0),
            .title_text_data = .{
                .text = title,
                .size = 18,
                .text_type = .bold,
            },
            .tooltip_text = if (desc.len > 0) .{
                .text = desc,
                .size = 16,
                .text_type = .bold_italic,
            } else null,
            .key = button.getKey(),
            .mouse = button.getMouse(),
            .settings_button = button,
            .set_key_callback = keyCallback,
        });
    }

    fn addToggle(target_tab: *element.Container, value: *bool, title: []const u8, desc: []const u8) !void {
        const toggle_data_base_off = assets.getUiData("toggle_slider_base_off", 0);
        const toggle_data_hover_off = assets.getUiData("toggle_slider_hover_off", 0);
        const toggle_data_press_off = assets.getUiData("toggle_slider_press_off", 0);
        const toggle_data_base_on = assets.getUiData("toggle_slider_base_on", 0);
        const toggle_data_hover_on = assets.getUiData("toggle_slider_hover_on", 0);
        const toggle_data_press_on = assets.getUiData("toggle_slider_press_on", 0);

        _ = try target_tab.createChild(element.Toggle{
            .x = 0,
            .y = 0,
            .off_image_data = Interactable.fromImageData(toggle_data_base_off, toggle_data_hover_off, toggle_data_press_off),
            .on_image_data = Interactable.fromImageData(toggle_data_base_on, toggle_data_hover_on, toggle_data_press_on),
            .text_data = .{
                .text = title,
                .size = 16,
                .text_type = .bold,
            },
            .tooltip_text = if (desc.len > 0) .{
                .text = desc,
                .size = 16,
                .text_type = .bold_italic,
            } else null,
            .toggled = value,
        });
    }

    fn addSlider(target_tab: *element.Container, value: *f32, min_value: f32, max_value: f32, title: []const u8, desc: []const u8) !void {
        const background_data = assets.getUiData("slider_background", 0);
        const knob_data_base = assets.getUiData("slider_knob_base", 0);
        const knob_data_hover = assets.getUiData("slider_knob_hover", 0);
        const knob_data_press = assets.getUiData("slider_knob_press", 0);

        const w = 250;
        const h = 30;
        const knob_size = 40;

        _ = try target_tab.createChild(element.Slider{
            .x = 0,
            .y = 0,
            .w = w,
            .h = h,
            .min_value = min_value,
            .max_value = max_value,
            .decor_image_data = .{ .nine_slice = NineSlice.fromAtlasData(background_data, w, h, 6, 6, 1, 1, 1.0) },
            .knob_image_data = Interactable.fromNineSlices(knob_data_base, knob_data_hover, knob_data_press, knob_size, knob_size, 12, 12, 1, 1, 1.0),
            .title_text_data = .{
                .text = title,
                .size = 16,
                .text_type = .bold,
            },
            .value_text_data = .{
                .text = "",
                .size = 10,
                .text_type = .bold,
                .max_chars = 64,
            },
            .tooltip_text = if (desc.len > 0) .{
                .text = desc,
                .size = 16,
                .text_type = .bold_italic,
            } else null,
            .target = value,
            .state_change = sliderCallback,
        });
    }

    fn positionElements(container: *element.Container) void {
        for (container.elements.items, 0..) |elem, i| {
            switch (elem) {
                .scrollable_container, .container => {},
                inline else => |inner| {
                    inner.x = @as(f32, @floatFromInt(@divFloor(i, 6))) * (camera.screen_width / 4.0);
                    inner.y = @as(f32, @floatFromInt(@mod(i, 6))) * (camera.screen_height / 9.0);
                },
            }
        }
    }

    fn sliderCallback(slider: *element.Slider) void {
        if (slider.target) |target| {
            if (target == &main.settings.music_volume)
                assets.main_music.setVolume(slider.current_value);
        } else @panic("Options slider has no target pointer. This is a bug, please add");

        trySave();
    }

    fn keyCallback(key_mapper: *element.KeyMapper) void {
        key_mapper.settings_button.* = switch (key_mapper.key) {
            .escape => .{ .key = .unknown },
            .unknown => .{ .mouse = key_mapper.mouse },
            else => .{ .key = key_mapper.key },
        };

        if (key_mapper.settings_button == &main.settings.interact)
            assets.interact_key_tex = assets.getKeyTexture(main.settings.interact);

        trySave();
    }

    fn closeCallback(ud: ?*anyopaque) void {
        const screen: *Options = @alignCast(@ptrCast(ud.?));
        screen.setVisible(false);
        input.disable_input = false;

        trySave();
    }

    fn resetToDefaultsCallback(_: ?*anyopaque) void {
        main.settings.resetToDefaults();
    }

    fn generalTabCallback(ud: ?*anyopaque) void {
        switchTab(@alignCast(@ptrCast(ud.?)), .general);
    }

    fn graphicsTabCallback(ud: ?*anyopaque) void {
        switchTab(@alignCast(@ptrCast(ud.?)), .graphics);
    }

    fn miscTabCallback(ud: ?*anyopaque) void {
        switchTab(@alignCast(@ptrCast(ud.?)), .misc);
    }

    fn disconnectCallback(ud: ?*anyopaque) void {
        closeCallback(ud);
        main.server.signalShutdown();
    }

    fn trySave() void {
        main.settings.save() catch |e| {
            std.log.err("Error while saving settings in options: {}", .{e});
            return;
        };
    }

    pub fn switchTab(self: *Options, tab: TabType) void {
        self.selected_tab = tab;
        self.general_tab.visible = tab == .general;
        self.graphics_tab.visible = tab == .graphics;
        self.misc_tab.visible = tab == .misc;

        switch (tab) {
            .general => positionElements(self.general_tab),
            .graphics => positionElements(self.graphics_tab),
            .misc => positionElements(self.misc_tab),
        }
    }

    pub fn setVisible(self: *Options, val: bool) void {
        self.visible = val;
        self.main.visible = val;
        self.buttons.visible = val;
        self.tabs.visible = val;

        if (val) {
            self.switchTab(.general);
        } else {
            self.general_tab.visible = false;
            self.graphics_tab.visible = false;
            self.misc_tab.visible = false;
        }
    }
};
