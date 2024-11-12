const std = @import("std");
const shared = @import("shared");
const utils = shared.utils;
const network_data = shared.network_data;
const element = @import("element.zig");
const input = @import("../input.zig");
const camera = @import("../camera.zig");
const main = @import("../main.zig");
const map = @import("../game/map.zig");
const assets = @import("../assets.zig");
const tooltip = @import("tooltips/tooltip.zig");
const dialog = @import("dialogs/dialog.zig");
const glfw = @import("zglfw");
const network = @import("../network.zig");

const AccountLoginScreen = @import("screens/account_login_screen.zig").AccountLoginScreen;
const AccountRegisterScreen = @import("screens/account_register_screen.zig").AccountRegisterScreen;
const CharCreateScreen = @import("screens/char_create_screen.zig").CharCreateScreen;
const CharSelectScreen = @import("screens/char_select_screen.zig").CharSelectScreen;
const MapEditorScreen = @import("screens/map_editor_screen.zig").MapEditorScreen;
const GameScreen = @import("screens/game_screen.zig").GameScreen;
const EmptyScreen = @import("screens/empty_screen.zig").EmptyScreen;

pub const ScreenType = enum {
    empty,
    main_menu,
    register,
    char_select,
    char_create,
    game,
    editor,
};

pub const Screen = union(ScreenType) {
    empty: *EmptyScreen,
    main_menu: *AccountLoginScreen,
    register: *AccountRegisterScreen,
    char_select: *CharSelectScreen,
    char_create: *CharCreateScreen,
    game: *GameScreen,
    editor: *MapEditorScreen,
};

pub var ui_lock: std.Thread.Mutex = .{};
pub var temp_elem_lock: std.Thread.Mutex = .{};
pub var elements: std.ArrayListUnmanaged(element.UiElement) = .{};
pub var elements_to_add: std.ArrayListUnmanaged(element.UiElement) = .{};
pub var temp_elements: std.ArrayListUnmanaged(element.Temporary) = .{};
pub var temp_elements_to_add: std.ArrayListUnmanaged(element.Temporary) = .{};
pub var screen: Screen = undefined;
pub var menu_background: *element.MenuBackground = undefined;
pub var hover_lock: std.Thread.Mutex = .{};
pub var hover_target: ?element.UiElement = null;
pub var editor_backup: ?*MapEditorScreen = null;

var last_element_update: i64 = 0;
pub var allocator: std.mem.Allocator = undefined;

pub fn init(ally: std.mem.Allocator) !void {
    allocator = ally;

    menu_background = try element.create(ally, element.MenuBackground{
        .x = 0,
        .y = 0,
        .w = camera.screen_width,
        .h = camera.screen_height,
    });

    screen = Screen{ .empty = EmptyScreen.init(ally) catch std.debug.panic("Initializing EmptyScreen failed", .{}) }; // todo re-add RLS when fixed

    try tooltip.init(ally);
    try dialog.init(ally);
}

pub fn deinit() void {
    ui_lock.lock();
    defer ui_lock.unlock();

    tooltip.deinit(allocator);
    dialog.deinit(allocator);

    switch (screen) {
        inline else => |inner_screen| inner_screen.deinit(),
    }

    element.destroy(menu_background);

    temp_elem_lock.lock();
    defer temp_elem_lock.unlock();

    // Do not dispose normal UI elements here, it's the screen's job to handle that

    for (temp_elements.items) |*elem| {
        switch (elem.*) {
            inline else => |*inner| {
                if (inner.disposed)
                    return;

                inner.disposed = true;

                allocator.free(inner.text_data.text);
                inner.text_data.deinit(allocator);
            },
        }
    }

    elements_to_add.deinit(allocator);
    temp_elements_to_add.deinit(allocator);
    elements.deinit(allocator);
    temp_elements.deinit(allocator);
}

pub fn switchScreen(comptime screen_type: ScreenType) void {
    if (screen == screen_type)
        return;

    std.debug.assert(!ui_lock.tryLock());

    camera.scale = 1.0;
    menu_background.visible = screen_type != .game and screen_type != .editor;
    input.selected_key_mapper = null;

    switch (screen) {
        inline else => |inner_screen| if (inner_screen.inited) inner_screen.deinit(),
    }

    screen = @unionInit(
        Screen,
        @tagName(screen_type),
        @typeInfo(std.meta.TagPayloadByName(Screen, @tagName(screen_type))).pointer.child.init(allocator) catch |e| {
            std.log.err("Initializing screen for {} failed: {}", .{ screen_type, e });
            return;
        },
    );
}

pub fn resize(w: f32, h: f32) void {
    ui_lock.lock();
    defer ui_lock.unlock();

    menu_background.w = camera.screen_width;
    menu_background.h = camera.screen_height;

    switch (screen) {
        inline else => |inner_screen| inner_screen.resize(w, h),
    }

    dialog.resize(w, h);
}

pub fn removeAttachedUi(obj_type: network_data.ObjectType, map_id: u32) void {
    temp_elem_lock.lock();
    defer temp_elem_lock.unlock();

    if (temp_elements.items.len <= 0)
        return;

    // We iterate in reverse in order to preserve integrity, because we remove elements in place
    var iter = std.mem.reverseIterator(temp_elements.items);
    var i: usize = temp_elements.items.len - 1;
    while (iter.nextPtr()) |elem| {
        defer i -%= 1;

        switch (elem.*) {
            .status => |*status| if (status.obj_type == obj_type and status.map_id == map_id) {
                status.destroy(allocator);
                _ = temp_elements.orderedRemove(i);
            },
            .balloon => |*balloon| if (balloon.target_obj_type == obj_type and balloon.target_map_id == map_id) {
                balloon.destroy(allocator);
                _ = temp_elements.orderedRemove(i);
            },
        }
    }
}

pub fn mouseMove(x: f32, y: f32) bool {
    ui_lock.lock();
    defer ui_lock.unlock();

    tooltip.switchTooltip(.none, {});
    {
        hover_lock.lock();
        defer hover_lock.unlock();
        if (hover_target) |target| {
            // this is intentionally not else-d. don't add
            switch (target) {
                .image => {},
                .item => {},
                .bar => {},
                .input_field => |input_field| input_field.state = .none,
                .button => |button| button.state = .none,
                .text => {},
                .char_box => |box| box.state = .none,
                .container => {},
                .scrollable_container => {},
                .menu_bg => {},
                .toggle => |toggle| toggle.state = .none,
                .key_mapper => |key_mapper| key_mapper.state = .none,
                .slider => {},
                .dropdown => |dropdown| dropdown.button_state = .none,
                .dropdown_container => |dc| dc.state = .none,
            }

            hover_target = null;
        }
    }

    var elem_iter_1 = std.mem.reverseIterator(elements.items);
    while (elem_iter_1.next()) |elem| {
        switch (elem) {
            else => {},
            .slider => |inner_elem| {
                if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "mouseMove") and inner_elem.mouseMove(x, y, 0, 0))
                    return true;
            },
        }
    }

    var elem_iter_2 = std.mem.reverseIterator(elements.items);
    while (elem_iter_2.next()) |elem| {
        switch (elem) {
            .slider => {},
            inline else => |inner_elem| {
                if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "mouseMove") and inner_elem.mouseMove(x, y, 0, 0))
                    return true;
            },
        }
    }

    return false;
}

pub fn mousePress(x: f32, y: f32, mods: glfw.Mods, button: glfw.MouseButton) bool {
    if (input.selected_input_field) |input_field| {
        input_field.last_input = -1;
        input.selected_input_field = null;
    }

    if (input.selected_key_mapper) |key_mapper| {
        key_mapper.key = .unknown;
        key_mapper.mouse = button;
        key_mapper.listening = false;
        key_mapper.set_key_callback(key_mapper);
        input.selected_key_mapper = null;
    }

    ui_lock.lock();
    defer ui_lock.unlock();

    var elem_iter = std.mem.reverseIterator(elements.items);
    while (elem_iter.next()) |elem| {
        switch (elem) {
            inline else => |inner_elem| {
                if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "mousePress") and inner_elem.mousePress(x, y, 0, 0, mods))
                    return true;
            },
        }
    }

    return false;
}

pub fn mouseRelease(x: f32, y: f32) bool {
    ui_lock.lock();
    defer ui_lock.unlock();

    var elem_iter = std.mem.reverseIterator(elements.items);
    while (elem_iter.next()) |elem| {
        switch (elem) {
            inline else => |inner_elem| {
                if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "mouseRelease") and inner_elem.mouseRelease(x, y, 0, 0))
                    return true;
            },
        }
    }

    return false;
}

pub fn mouseScroll(x: f32, y: f32, x_scroll: f32, y_scroll: f32) bool {
    ui_lock.lock();
    defer ui_lock.unlock();

    var elem_iter = std.mem.reverseIterator(elements.items);
    while (elem_iter.next()) |elem| {
        switch (elem) {
            inline else => |inner_elem| {
                if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "mouseScroll") and inner_elem.mouseScroll(x, y, 0, 0, x_scroll, y_scroll))
                    return true;
            },
        }
    }

    return false;
}

fn lessThan(_: void, lhs: element.UiElement, rhs: element.UiElement) bool {
    return switch (lhs) {
        inline else => |elem| @intFromEnum(elem.layer),
    } < switch (rhs) {
        inline else => |elem| @intFromEnum(elem.layer),
    };
}

fn updateElements(time: i64, dt: f32) !void {
    ui_lock.lock();
    defer ui_lock.unlock();

    elements.appendSlice(allocator, elements_to_add.items) catch |e| {
        @branchHint(.cold);
        std.log.err("Adding new elements failed: {}, returning", .{e});
        return;
    };
    elements_to_add.clearRetainingCapacity();

    std.sort.block(element.UiElement, elements.items, {}, lessThan);

    switch (screen) {
        inline else => |inner_screen| if (inner_screen.inited) try inner_screen.update(time, dt),
    }
}

fn updateTempElements(time: i64, _: f32) !void {
    if (!temp_elem_lock.tryLock())
        return;
    defer temp_elem_lock.unlock();

    temp_elements.appendSlice(allocator, temp_elements_to_add.items) catch |e| {
        @branchHint(.cold);
        std.log.err("Adding new temporary elements failed: {}, returning", .{e});
        return;
    };
    temp_elements_to_add.clearRetainingCapacity();

    if (temp_elements.items.len <= 0)
        return;

    // We iterate in reverse in order to preserve integrity, because we remove elements in place
    var iter = std.mem.reverseIterator(temp_elements.items);
    var i: usize = temp_elements.items.len - 1;
    while (iter.nextPtr()) |elem| {
        defer i -%= 1;

        switch (elem.*) {
            .status => |*status_text| {
                @branchHint(.likely);
                const elapsed = time - status_text.start_time;
                if (elapsed > status_text.lifetime * std.time.us_per_ms) {
                    @branchHint(.unlikely);
                    status_text.destroy(allocator);
                    _ = temp_elements.orderedRemove(i);
                    continue;
                }

                status_text.visible = false;
                switch (status_text.obj_type) {
                    inline else => |obj_enum| {
                        const T = network.ObjEnumToType(obj_enum);
                        var lock = map.useLockForType(T);
                        lock.lock();
                        defer lock.unlock();
                        if (map.findObjectConst(T, status_text.map_id)) |obj| {
                            @branchHint(.likely);
                            status_text.visible = true;

                            const frac = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(status_text.lifetime * std.time.us_per_ms));
                            status_text.text_data.size = status_text.initial_size * @min(1.0, @max(0.7, 1.0 - frac * 0.3 + 0.075));
                            status_text.text_data.alpha = 1.0 - frac + 0.33;

                            {
                                status_text.text_data.lock.lock();
                                defer status_text.text_data.lock.unlock();

                                status_text.text_data.recalculateAttributes(allocator);
                            }

                            if (@hasField(@TypeOf(obj), "dead") and obj.dead) {
                                @branchHint(.unlikely);
                                status_text.destroy(allocator);
                                _ = temp_elements.orderedRemove(i);
                                continue;
                            }
                            status_text.screen_x = obj.screen_x - status_text.text_data.width / 2;
                            status_text.screen_y = obj.screen_y - status_text.text_data.height - frac * 40;
                        }
                    },
                }
            },
            .balloon => |*speech_balloon| {
                @branchHint(.unlikely);
                const elapsed = time - speech_balloon.start_time;
                const lifetime = 5 * std.time.us_per_s;
                if (elapsed > lifetime) {
                    @branchHint(.unlikely);
                    speech_balloon.destroy(allocator);
                    _ = temp_elements.orderedRemove(i);
                    continue;
                }

                speech_balloon.visible = false;
                switch (speech_balloon.target_obj_type) {
                    inline else => |obj_enum| {
                        const T = network.ObjEnumToType(obj_enum);
                        var lock = map.useLockForType(T);
                        lock.lock();
                        defer lock.unlock();
                        if (map.findObjectConst(T, speech_balloon.target_map_id)) |obj| {
                            @branchHint(.likely);
                            speech_balloon.visible = true;

                            const frac = @as(f32, @floatFromInt(elapsed)) / @as(f32, lifetime);
                            const alpha = 1.0 - frac * 2.0 + 0.9;
                            speech_balloon.image_data.normal.alpha = alpha; // assume no 9 slice
                            speech_balloon.text_data.alpha = alpha;

                            if (@hasField(@TypeOf(obj), "dead") and obj.dead) {
                                @branchHint(.unlikely);
                                speech_balloon.destroy(allocator);
                                _ = temp_elements.orderedRemove(i);
                                continue;
                            }
                            speech_balloon.screen_x = obj.screen_x - speech_balloon.width() / 2;
                            speech_balloon.screen_y = obj.screen_y - speech_balloon.height();
                        }
                    },
                }
            },
        }
    }
}

pub fn update(time: i64, dt: f32) !void {
    try updateElements(time, dt);
    try updateTempElements(time, dt);
}
