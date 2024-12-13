const std = @import("std");
const shared = @import("shared");
const game_data = shared.game_data;
const network_data = shared.network_data;
const utils = shared.utils;
const camera = @import("../camera.zig");
const assets = @import("../assets.zig");
const main = @import("../main.zig");
const glfw = @import("zglfw");
const systems = @import("systems.zig");
const tooltip = @import("tooltips/tooltip.zig");
const input = @import("../input.zig");

const Settings = @import("../Settings.zig");

pub fn create(allocator: std.mem.Allocator, data: anytype) !*@TypeOf(data) {
    const T = @TypeOf(data);
    var elem = try allocator.create(T);
    elem.* = data;
    elem.allocator = allocator;
    if (std.meta.hasFn(T, "init")) elem.init();

    comptime var field_name: []const u8 = "";
    inline for (@typeInfo(UiElement).@"union".fields) |field| {
        if (@typeInfo(field.type).pointer.child == T) {
            field_name = field.name;
            break;
        }
    }

    if (field_name.len == 0)
        @compileError("Could not find field name");

    try systems.elements_to_add.append(allocator, @unionInit(UiElement, field_name, elem));
    return elem;
}

pub fn destroy(self: anytype) void {
    if (self.disposed)
        return;

    self.disposed = true;

    comptime var field_name: []const u8 = "";
    inline for (@typeInfo(UiElement).@"union".fields) |field| {
        if (field.type == @TypeOf(self)) {
            field_name = field.name;
            break;
        }
    }

    if (field_name.len == 0)
        @compileError("Could not find field name");

    const tag = std.meta.stringToEnum(std.meta.Tag(UiElement), field_name);

    systems.hover_lock.lock();
    defer systems.hover_lock.unlock();
    if (systems.hover_target != null and
        systems.hover_target.? == tag.? and
        self == @field(systems.hover_target.?, field_name))
        systems.hover_target = null;

    std.debug.assert(!systems.ui_lock.tryLock());

    removeFromList: inline for (.{ &systems.elements, &systems.elements_to_add }) |elems| {
        for (elems.items, 0..) |element, i| {
            if (element == tag.? and @field(element, field_name) == self) {
                _ = elems.orderedRemove(i);
                break :removeFromList;
            }
        }
    }

    if (std.meta.hasFn(@typeInfo(@TypeOf(self)).pointer.child, "deinit")) self.deinit();
    self.allocator.destroy(self);
}

fn intersects(self: anytype, x: f32, y: f32) bool {
    const has_scissor = @hasField(@typeInfo(@TypeOf(self)).pointer.child, "scissor");
    if (has_scissor and
        (self.scissor.min_x != ScissorRect.dont_scissor and x - self.x < self.scissor.min_x or
        self.scissor.min_y != ScissorRect.dont_scissor and y - self.y < self.scissor.min_y))
        return false;

    const w = if (has_scissor and self.scissor.max_x != ScissorRect.dont_scissor) @min(self.texWRaw(), self.scissor.max_x) else self.texWRaw();
    const h = if (has_scissor and self.scissor.max_y != ScissorRect.dont_scissor) @min(self.texHRaw(), self.scissor.max_y) else self.texHRaw();
    return utils.isInBounds(x, y, self.x, self.y, w, h);
}

pub const Layer = enum {
    default,
    dialog,
    tooltip,
};

pub const EventPolicy = packed struct {
    pass_press: bool = false,
    pass_release: bool = false,
    pass_move: bool = false,
    pass_scroll: bool = false,
};

pub const RGBF32 = extern struct {
    r: f32,
    g: f32,
    b: f32,

    pub fn fromValues(r: f32, g: f32, b: f32) RGBF32 {
        return .{ .r = r, .g = g, .b = b };
    }

    pub fn fromInt(int: u32) RGBF32 {
        return .{
            .r = @as(f32, @floatFromInt((int & 0xFF0000) >> 16)) / 255.0,
            .g = @as(f32, @floatFromInt((int & 0x00FF00) >> 8)) / 255.0,
            .b = @as(f32, @floatFromInt((int & 0x0000FF) >> 0)) / 255.0,
        };
    }
};

pub const TextType = enum {
    medium,
    medium_italic,
    bold,
    bold_italic,
};

pub const AlignHori = enum {
    left,
    middle,
    right,
};

pub const AlignVert = enum {
    top,
    middle,
    bottom,
};

pub const TextData = struct {
    text: []const u8,
    size: f32,
    // 0 implies that the backing buffer won't be used. if your element uses it, you must set this to something above 0
    max_chars: u32 = 0,
    text_type: TextType = .medium,
    color: u32 = 0xFFFFFF,
    alpha: f32 = 1.0,
    shadow_color: u32 = 0xFF000000,
    shadow_alpha_mult: f32 = 0.5,
    shadow_texel_offset_mult: f32 = 0.0,
    outline_color: u32 = 0xFF000000,
    outline_width: f32 = 1.0, // 0.5 for off
    password: bool = false,
    handle_special_chars: bool = true,
    scissor: ScissorRect = .{},
    // alignments other than default need max width/height defined respectively
    hori_align: AlignHori = .left,
    vert_align: AlignVert = .top,
    max_width: f32 = std.math.floatMax(f32),
    max_height: f32 = std.math.floatMax(f32),
    backing_buffer: []u8 = &.{},
    lock: std.Thread.Mutex = .{},
    width: f32 = 0.0,
    height: f32 = 0.0,
    line_count: f32 = 0.0,
    line_widths: ?std.ArrayListUnmanaged(f32) = null,
    break_indices: ?std.ArrayListUnmanaged(usize) = null,

    pub fn setText(self: *TextData, text: []const u8, allocator: std.mem.Allocator) void {
        self.lock.lock();
        defer self.lock.unlock();

        self.text = text;
        self.recalculateAttributes(allocator);
    }

    pub fn recalculateAttributes(self: *TextData, allocator: std.mem.Allocator) void {
        std.debug.assert(!self.lock.tryLock());

        if (self.backing_buffer.len == 0 and self.max_chars > 0)
            self.backing_buffer = allocator.alloc(u8, self.max_chars) catch std.debug.panic("Failed to allocate the backing buffer", .{});

        if (self.line_widths) |*line_widths| {
            line_widths.clearRetainingCapacity();
        } else {
            self.line_widths = .{};
        }

        if (self.break_indices) |*break_indices| {
            break_indices.clearRetainingCapacity();
        } else {
            self.break_indices = .{};
        }

        const size_scale = self.size / assets.CharacterData.size * assets.CharacterData.padding_mult;
        const start_line_height = assets.CharacterData.line_height * assets.CharacterData.size * size_scale;
        var line_height = start_line_height;

        var x_max: f32 = 0.0;
        var x_pointer: f32 = 0.0;
        var y_pointer: f32 = line_height;
        var current_size = size_scale;
        var current_type = self.text_type;
        var index_offset: u16 = 0;
        var word_start: usize = 0;
        var last_word_start_pointer: f32 = 0.0;
        var last_word_end_pointer: f32 = 0.0;
        var needs_new_word_idx = true;
        for (0..self.text.len) |i| {
            const offset_i = i + index_offset;
            if (offset_i >= self.text.len) {
                self.width = @max(x_max, x_pointer);
                self.line_widths.?.append(allocator, x_pointer) catch |e| {
                    std.log.err("Attribute recalculation for text data failed: {}", .{e});
                    return;
                };
                self.height = y_pointer;
                return;
            }

            var skip_space_check = false;
            var char = self.text[offset_i];
            specialChar: {
                if (!self.handle_special_chars)
                    break :specialChar;

                if (char == '&') {
                    const name_start = self.text[offset_i + 1 ..];
                    const reset = "reset";
                    if (self.text.len >= offset_i + 1 + reset.len and std.mem.eql(u8, name_start[0..reset.len], reset)) {
                        current_type = self.text_type;
                        current_size = size_scale;
                        line_height = assets.CharacterData.line_height * assets.CharacterData.size * current_size;
                        y_pointer += (line_height - start_line_height) / 2.0;
                        index_offset += @intCast(reset.len);
                        continue;
                    }

                    const space = "space";
                    if (self.text.len >= offset_i + 1 + space.len and std.mem.eql(u8, name_start[0..space.len], space)) {
                        char = ' ';
                        skip_space_check = true;
                        index_offset += @intCast(space.len);
                        break :specialChar;
                    }

                    if (std.mem.indexOfScalar(u8, name_start, '=')) |eql_idx| {
                        const value_start_idx = offset_i + 1 + eql_idx + 1;
                        if (self.text.len <= value_start_idx or self.text[value_start_idx] != '"')
                            break :specialChar;

                        const value_start = self.text[value_start_idx + 1 ..];
                        if (std.mem.indexOfScalar(u8, value_start, '"')) |value_end_idx| {
                            const name = name_start[0..eql_idx];
                            const value = value_start[0..value_end_idx];
                            if (std.mem.eql(u8, name, "size")) {
                                const size = std.fmt.parseFloat(f32, value) catch {
                                    std.log.err("Invalid size given to control code: {s}", .{value});
                                    break :specialChar;
                                };
                                current_size = size / assets.CharacterData.size * assets.CharacterData.padding_mult;
                                line_height = assets.CharacterData.line_height * assets.CharacterData.size * current_size;
                                y_pointer += (line_height - start_line_height) / 2.0;
                            } else if (std.mem.eql(u8, name, "type")) {
                                if (std.mem.eql(u8, value, "med")) {
                                    current_type = .medium;
                                } else if (std.mem.eql(u8, value, "med_it")) {
                                    current_type = .medium_italic;
                                } else if (std.mem.eql(u8, value, "bold")) {
                                    current_type = .bold;
                                } else if (std.mem.eql(u8, value, "bold_it")) {
                                    current_type = .bold_italic;
                                }
                            } else if (std.mem.eql(u8, name, "img")) {
                                var values = std.mem.splitScalar(u8, value, ',');
                                const sheet = values.next();
                                if (sheet == null or std.mem.eql(u8, sheet.?, value)) {
                                    std.log.err("Invalid sheet given to control code: {?s}", .{sheet});
                                    break :specialChar;
                                }

                                const index_str = values.next() orelse {
                                    std.log.err("Index was not found for control code with sheet {s}", .{sheet.?});
                                    break :specialChar;
                                };
                                const index = std.fmt.parseInt(u32, index_str, 0) catch {
                                    std.log.err("Invalid index given to control code with sheet {s}: {s}", .{ sheet.?, index_str });
                                    break :specialChar;
                                };
                                const data = assets.atlas_data.get(sheet.?) orelse {
                                    std.log.err("Sheet {s} given to control code was not found in atlas", .{sheet.?});
                                    break :specialChar;
                                };
                                if (index >= data.len) {
                                    std.log.err("The index {} given for sheet {s} in control code was out of bounds", .{ index, sheet.? });
                                    break :specialChar;
                                }

                                if (needs_new_word_idx) {
                                    word_start = i;
                                    last_word_start_pointer = x_pointer;
                                    needs_new_word_idx = false;
                                }

                                x_pointer += current_size * assets.CharacterData.size;
                                if (x_pointer > self.max_width) {
                                    self.width = @max(x_max, last_word_end_pointer);
                                    self.line_widths.?.append(allocator, last_word_end_pointer) catch |e| {
                                        std.log.err("Attribute recalculation for text data failed: {}", .{e});
                                        return;
                                    };
                                    self.break_indices.?.append(allocator, word_start) catch |e| {
                                        std.log.err("Attribute recalculation for text data failed: {}", .{e});
                                        return;
                                    };
                                    self.line_count += 1;
                                    x_pointer = x_pointer - last_word_start_pointer;
                                    y_pointer += line_height;
                                }
                            } else if (!std.mem.eql(u8, name, "col"))
                                break :specialChar;

                            index_offset += @intCast(1 + eql_idx + 1 + value_end_idx + 1);
                            continue;
                        } else break :specialChar;
                    } else break :specialChar;
                }
            }

            const mod_char = if (self.password) '*' else char;

            const char_data = switch (self.text_type) {
                .medium => assets.medium_chars[mod_char],
                .medium_italic => assets.medium_italic_chars[mod_char],
                .bold => assets.bold_chars[mod_char],
                .bold_italic => assets.bold_italic_chars[mod_char],
            };

            if (!skip_space_check and std.ascii.isWhitespace(char)) {
                last_word_end_pointer = x_pointer + char_data.x_advance * current_size;
                needs_new_word_idx = true;
            } else if (needs_new_word_idx) {
                word_start = i;
                last_word_start_pointer = x_pointer;
                needs_new_word_idx = false;
            }

            var next_x_pointer = x_pointer + char_data.x_advance * current_size;
            if (char == '\n' or next_x_pointer > self.max_width) {
                const next_pointer = if (char == '\n') next_x_pointer else last_word_end_pointer;
                self.width = @max(x_max, next_pointer);
                self.line_widths.?.append(allocator, next_pointer) catch |e| {
                    std.log.err("Attribute recalculation for text data failed: {}", .{e});
                    return;
                };
                self.break_indices.?.append(allocator, if (char == '\n') i else word_start) catch |e| {
                    std.log.err("Attribute recalculation for text data failed: {}", .{e});
                    return;
                };
                self.line_count += 1;
                next_x_pointer = if (char == '\n') char_data.x_advance * current_size else next_x_pointer - last_word_start_pointer;
                y_pointer += line_height;
            }

            x_pointer = next_x_pointer;
            if (x_pointer > x_max)
                x_max = x_pointer;
        }

        self.width = @max(x_max, x_pointer);
        self.line_widths.?.append(allocator, x_pointer) catch |e| {
            std.log.err("Attribute recalculation for text data failed: {}", .{e});
            return;
        };
        self.height = y_pointer;
    }

    pub fn deinit(self: *TextData, allocator: std.mem.Allocator) void {
        self.lock.lock();
        defer self.lock.unlock();

        allocator.free(self.backing_buffer);

        if (self.line_widths) |*line_widths| {
            line_widths.deinit(allocator);
            self.line_widths = null;
        }

        if (self.break_indices) |*break_indices| {
            break_indices.deinit(allocator);
            self.break_indices = null;
        }
    }
};

pub const NineSliceImageData = struct {
    const AtlasData = assets.AtlasData;

    const top_left_idx = 0;
    const top_center_idx = 1;
    const top_right_idx = 2;
    const middle_left_idx = 3;
    const middle_center_idx = 4;
    const middle_right_idx = 5;
    const bottom_left_idx = 6;
    const bottom_center_idx = 7;
    const bottom_right_idx = 8;

    w: f32,
    h: f32,
    alpha: f32 = 1.0,
    color: u32 = std.math.maxInt(u32),
    color_intensity: f32 = 0,
    scissor: ScissorRect = .{},
    atlas_data: [9]AtlasData,

    pub fn fromAtlasData(data: AtlasData, w: f32, h: f32, slice_x: f32, slice_y: f32, slice_w: f32, slice_h: f32, alpha: f32) NineSliceImageData {
        const base_u = data.texURaw();
        const base_v = data.texVRaw();
        const base_w = data.width();
        const base_h = data.height();
        return .{
            .w = w,
            .h = h,
            .alpha = alpha,
            .atlas_data = .{
                AtlasData.fromRawF32(base_u, base_v, slice_x, slice_y, data.atlas_type),
                AtlasData.fromRawF32(base_u + slice_x, base_v, slice_w, slice_y, data.atlas_type),
                AtlasData.fromRawF32(base_u + slice_x + slice_w, base_v, base_w - slice_w - slice_x, slice_y, data.atlas_type),
                AtlasData.fromRawF32(base_u, base_v + slice_y, slice_x, slice_h, data.atlas_type),
                AtlasData.fromRawF32(base_u + slice_x, base_v + slice_y, slice_w, slice_h, data.atlas_type),
                AtlasData.fromRawF32(base_u + slice_x + slice_w, base_v + slice_y, base_w - slice_w - slice_x, slice_h, data.atlas_type),
                AtlasData.fromRawF32(base_u, base_v + slice_y + slice_h, slice_x, base_h - slice_h - slice_y, data.atlas_type),
                AtlasData.fromRawF32(base_u + slice_x, base_v + slice_y + slice_h, slice_w, base_h - slice_h - slice_y, data.atlas_type),
                AtlasData.fromRawF32(base_u + slice_x + slice_w, base_v + slice_y + slice_h, base_w - slice_w - slice_x, base_h - slice_h - slice_y, data.atlas_type),
            },
        };
    }

    pub fn topLeft(self: NineSliceImageData) AtlasData {
        return self.atlas_data[top_left_idx];
    }

    pub fn topCenter(self: NineSliceImageData) AtlasData {
        return self.atlas_data[top_center_idx];
    }

    pub fn topRight(self: NineSliceImageData) AtlasData {
        return self.atlas_data[top_right_idx];
    }

    pub fn middleLeft(self: NineSliceImageData) AtlasData {
        return self.atlas_data[middle_left_idx];
    }

    pub fn middleCenter(self: NineSliceImageData) AtlasData {
        return self.atlas_data[middle_center_idx];
    }

    pub fn middleRight(self: NineSliceImageData) AtlasData {
        return self.atlas_data[middle_right_idx];
    }

    pub fn bottomLeft(self: NineSliceImageData) AtlasData {
        return self.atlas_data[bottom_left_idx];
    }

    pub fn bottomCenter(self: NineSliceImageData) AtlasData {
        return self.atlas_data[bottom_center_idx];
    }

    pub fn bottomRight(self: NineSliceImageData) AtlasData {
        return self.atlas_data[bottom_right_idx];
    }
};

pub const NormalImageData = struct {
    scale_x: f32 = 1.0,
    scale_y: f32 = 1.0,
    alpha: f32 = 1.0,
    color: u32 = std.math.maxInt(u32),
    glow: bool = false,
    color_intensity: f32 = 0,
    scissor: ScissorRect = .{},
    atlas_data: assets.AtlasData,

    pub fn width(self: NormalImageData) f32 {
        return self.atlas_data.width() * self.scale_x;
    }

    pub fn height(self: NormalImageData) f32 {
        return self.atlas_data.height() * self.scale_y;
    }

    pub fn texWRaw(self: NormalImageData) f32 {
        return self.atlas_data.texWRaw() * self.scale_x;
    }

    pub fn texHRaw(self: NormalImageData) f32 {
        return self.atlas_data.texHRaw() * self.scale_y;
    }
};

pub const ImageData = union(enum) {
    nine_slice: NineSliceImageData,
    normal: NormalImageData,

    pub fn setScissor(self: *ImageData, scissor: ScissorRect) void {
        switch (self.*) {
            .nine_slice => |*nine_slice| nine_slice.scissor = scissor,
            .normal => |*normal| normal.scissor = scissor,
        }
    }

    pub fn scaleWidth(self: *ImageData, w: f32) void {
        switch (self.*) {
            .nine_slice => |*nine_slice| nine_slice.w = w,
            .normal => |*normal| normal.scale_x = normal.atlas_data.texWRaw() / w,
        }
    }

    pub fn scaleHeight(self: *ImageData, h: f32) void {
        switch (self.*) {
            .nine_slice => |*nine_slice| nine_slice.h = h,
            .normal => |*normal| normal.scale_y = normal.atlas_data.texHRaw() / h,
        }
    }

    pub fn width(self: ImageData) f32 {
        return switch (self) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |normal| normal.width(),
        };
    }

    pub fn height(self: ImageData) f32 {
        return switch (self) {
            .nine_slice => |nine_slice| nine_slice.h,
            .normal => |normal| normal.height(),
        };
    }

    pub fn texWRaw(self: ImageData) f32 {
        return switch (self) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |normal| normal.texWRaw(),
        };
    }

    pub fn texHRaw(self: ImageData) f32 {
        return switch (self) {
            .nine_slice => |nine_slice| nine_slice.h,
            .normal => |normal| normal.texHRaw(),
        };
    }
};

pub const InteractableState = enum {
    none,
    pressed,
    hovered,
};

pub const InteractableImageData = struct {
    base: ImageData,
    hover: ?ImageData = null,
    press: ?ImageData = null,

    pub fn current(self: InteractableImageData, state: InteractableState) ImageData {
        switch (state) {
            .none => return self.base,
            .pressed => return self.press orelse self.base,
            .hovered => return self.hover orelse self.base,
        }
    }

    pub fn width(self: InteractableImageData, state: InteractableState) f32 {
        return self.current(state).width();
    }

    pub fn height(self: InteractableImageData, state: InteractableState) f32 {
        return self.current(state).height();
    }

    pub fn texWRaw(self: InteractableImageData, state: InteractableState) f32 {
        return self.current(state).texWRaw();
    }

    pub fn texHRaw(self: InteractableImageData, state: InteractableState) f32 {
        return self.current(state).texHRaw();
    }

    pub fn setScissor(self: *InteractableImageData, scissor: ScissorRect) void {
        self.base.setScissor(scissor);
        if (self.hover) |*data| data.setScissor(scissor);
        if (self.press) |*data| data.setScissor(scissor);
    }

    pub fn scaleWidth(self: *InteractableImageData, w: f32) void {
        self.base.scaleWidth(w);
        if (self.hover) |*data| data.scaleWidth(w);
        if (self.press) |*data| data.scaleWidth(w);
    }

    pub fn scaleHeight(self: *InteractableImageData, h: f32) void {
        self.base.scaleHeight(h);
        if (self.hover) |*data| data.scaleHeight(h);
        if (self.press) |*data| data.scaleHeight(h);
    }

    pub fn fromImageData(base: assets.AtlasData, hover: ?assets.AtlasData, press: ?assets.AtlasData) InteractableImageData {
        var ret = InteractableImageData{
            .base = .{ .normal = .{ .atlas_data = base } },
        };

        if (hover) |hover_data| {
            ret.hover = .{ .normal = .{ .atlas_data = hover_data } };
        }

        if (press) |press_data| {
            ret.press = .{ .normal = .{ .atlas_data = press_data } };
        }

        return ret;
    }

    pub fn fromNineSlices(
        base: assets.AtlasData,
        hover: ?assets.AtlasData,
        press: ?assets.AtlasData,
        w: f32,
        h: f32,
        slice_x: f32,
        slice_y: f32,
        slice_w: f32,
        slice_h: f32,
        alpha: f32,
    ) InteractableImageData {
        const NineSlice = NineSliceImageData;
        var ret = InteractableImageData{
            .base = .{ .nine_slice = NineSlice.fromAtlasData(base, w, h, slice_x, slice_y, slice_w, slice_h, alpha) },
        };

        if (hover) |hover_data| {
            ret.hover = .{ .nine_slice = NineSlice.fromAtlasData(hover_data, w, h, slice_x, slice_y, slice_w, slice_h, alpha) };
        }

        if (press) |press_data| {
            ret.press = .{ .nine_slice = NineSlice.fromAtlasData(press_data, w, h, slice_x, slice_y, slice_w, slice_h, alpha) };
        }

        return ret;
    }
};

// Scissor positions are relative to the element it's attached to
pub const ScissorRect = extern struct {
    pub const dont_scissor = -1.0;

    min_x: f32 = dont_scissor,
    max_x: f32 = dont_scissor,
    min_y: f32 = dont_scissor,
    max_y: f32 = dont_scissor,

    // hack
    pub fn isDefault(self: ScissorRect) bool {
        return @as(u128, @bitCast(self)) == @as(u128, @bitCast(ScissorRect{}));
    }
};

pub const UiElement = union(enum) {
    image: *Image,
    item: *Item,
    bar: *Bar,
    input_field: *Input,
    button: *Button,
    text: *Text,
    char_box: *CharacterBox,
    container: *Container,
    scrollable_container: *ScrollableContainer,
    menu_bg: *MenuBackground,
    toggle: *Toggle,
    key_mapper: *KeyMapper,
    slider: *Slider,
    dropdown: *Dropdown,
    // don't actually use this here. internal use only
    dropdown_container: *DropdownContainer,
};

pub const Temporary = union(enum) {
    balloon: SpeechBalloon,
    status: StatusText,
};

pub const Input = struct {
    x: f32,
    y: f32,
    text_inlay_x: f32,
    text_inlay_y: f32,
    image_data: InteractableImageData,
    cursor_image_data: ImageData,
    text_data: TextData,
    allocator: std.mem.Allocator,
    enter_callback: ?*const fn ([]const u8) void = null,
    state: InteractableState = .none,
    layer: Layer = .default,
    is_chat: bool = false,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    // -1 means not selected
    last_input: i64 = -1,
    x_offset: f32 = 0.0,
    index: u32 = 0,
    disposed: bool = false,

    pub fn mousePress(self: *Input, x: f32, y: f32, _: f32, _: f32, _: glfw.Mods) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            input.selected_input_field = self;
            self.last_input = 0;
            self.state = .pressed;
            return true;
        }

        return !(self.event_policy.pass_press or !intersects(self, x, y));
    }

    pub fn mouseRelease(self: *Input, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            self.state = .hovered;
        }

        return !(self.event_policy.pass_release or !intersects(self, x, y));
    }

    pub fn mouseMove(self: *Input, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            systems.hover_lock.lock();
            defer systems.hover_lock.unlock();
            systems.hover_target = UiElement{ .input_field = self }; // todo re-add RLS when fixed
            self.state = .hovered;
        } else {
            self.state = .none;
        }

        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn init(self: *Input) void {
        if (self.text_data.scissor.isDefault()) {
            self.text_data.scissor = .{
                .min_x = 0,
                .min_y = 0,
                .max_x = self.width() - self.text_inlay_x * 2,
                .max_y = self.height() - self.text_inlay_y * 2,
            };
        }

        {
            self.text_data.lock.lock();
            defer self.text_data.lock.unlock();

            self.text_data.recalculateAttributes(self.allocator);
        }

        switch (self.cursor_image_data) {
            .nine_slice => |*nine_slice| nine_slice.h = self.text_data.height,
            .normal => |*image_data| image_data.scale_y = self.text_data.height / image_data.height(),
        }
    }

    pub fn deinit(self: *Input) void {
        if (self == input.selected_input_field)
            input.selected_input_field = null;

        self.text_data.deinit(self.allocator);
    }

    pub fn width(self: Input) f32 {
        return @max(self.text_data.width, switch (self.image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.width(),
        });
    }

    pub fn height(self: Input) f32 {
        return @max(self.text_data.height, switch (self.image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.height(),
        });
    }

    pub fn texWRaw(self: Input) f32 {
        return @max(self.text_data.width, switch (self.image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.texWRaw(),
        });
    }

    pub fn texHRaw(self: Input) f32 {
        return @max(self.text_data.height, switch (self.image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.texHRaw(),
        });
    }

    pub fn clear(self: *Input) void {
        self.text_data.setText("", self.allocator);
        self.index = 0;
        self.inputUpdate();
    }

    pub fn inputUpdate(self: *Input) void {
        self.last_input = main.current_time;

        {
            self.text_data.lock.lock();
            defer self.text_data.lock.unlock();

            self.text_data.recalculateAttributes(self.allocator);
        }

        const cursor_width = switch (self.cursor_image_data) {
            .nine_slice => |nine_slice| if (nine_slice.alpha > 0) nine_slice.w else 0.0,
            .normal => |image_data| if (image_data.alpha > 0) image_data.width() else 0.0,
        };

        const img_width = switch (self.image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |image_data| image_data.width(),
        } - self.text_inlay_x * 2 - cursor_width;
        const offset = @max(0, self.text_data.width - img_width);
        self.x_offset = -offset;
        self.text_data.scissor.min_x = offset;
        self.text_data.scissor.max_x = offset + img_width;
    }
};

pub const Button = struct {
    x: f32,
    y: f32,
    userdata: ?*anyopaque = null,
    press_callback: *const fn (?*anyopaque) void,
    image_data: InteractableImageData,
    state: InteractableState = .none,
    layer: Layer = .default,
    text_data: ?TextData = null,
    tooltip_text: ?TextData = null,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn mousePress(self: *Button, x: f32, y: f32, _: f32, _: f32, _: glfw.Mods) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            self.state = .pressed;
            self.press_callback(self.userdata);
            assets.playSfx("button.mp3");
            return true;
        }

        return !(self.event_policy.pass_press or !intersects(self, x, y));
    }

    pub fn mouseRelease(self: *Button, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            self.state = .hovered;
        }

        return !(self.event_policy.pass_release or !intersects(self, x, y));
    }

    pub fn mouseMove(self: *Button, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            if (self.tooltip_text) |text| {
                tooltip.switchTooltip(.text, .{
                    .x = x + x_offset,
                    .y = y + y_offset,
                    .text_data = text,
                });
                return true;
            }

            systems.hover_lock.lock();
            defer systems.hover_lock.unlock();
            systems.hover_target = UiElement{ .button = self }; // todo re-add RLS when fixed
            self.state = .hovered;
        } else {
            self.state = .none;
        }

        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn init(self: *Button) void {
        if (self.text_data) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.max_width = self.width();
            text_data.max_height = self.height();
            text_data.vert_align = .middle;
            text_data.hori_align = .middle;

            text_data.recalculateAttributes(self.allocator);
        }

        if (self.tooltip_text) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.recalculateAttributes(self.allocator);
        }
    }

    pub fn deinit(self: *Button) void {
        if (self.text_data) |*text_data| {
            text_data.deinit(self.allocator);
        }

        if (self.tooltip_text) |*text_data| {
            text_data.deinit(self.allocator);
        }
    }

    pub fn width(self: Button) f32 {
        if (self.text_data) |text| {
            return @max(text.width, switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.w,
                .normal => |image_data| return image_data.width(),
            });
        } else {
            return switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.w,
                .normal => |image_data| return image_data.width(),
            };
        }
    }

    pub fn height(self: Button) f32 {
        if (self.text_data) |text| {
            return @max(text.height, switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.h,
                .normal => |image_data| return image_data.height(),
            });
        } else {
            return switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.h,
                .normal => |image_data| return image_data.height(),
            };
        }
    }

    pub fn texWRaw(self: Button) f32 {
        if (self.text_data) |text| {
            return @max(text.width, switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.w,
                .normal => |image_data| return image_data.texWRaw(),
            });
        } else {
            return switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.w,
                .normal => |image_data| return image_data.texWRaw(),
            };
        }
    }

    pub fn texHRaw(self: Button) f32 {
        if (self.text_data) |text| {
            return @max(text.height, switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.h,
                .normal => |image_data| return image_data.texHRaw(),
            });
        } else {
            return switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.h,
                .normal => |image_data| return image_data.texHRaw(),
            };
        }
    }
};

pub const KeyMapper = struct {
    x: f32,
    y: f32,
    set_key_callback: *const fn (*KeyMapper) void,
    image_data: InteractableImageData,
    settings_button: *Settings.Button,
    key: glfw.Key = .unknown,
    mouse: glfw.MouseButton = .eight,
    title_text_data: ?TextData = null,
    tooltip_text: ?TextData = null,
    state: InteractableState = .none,
    layer: Layer = .default,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    listening: bool = false,
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn mousePress(self: *KeyMapper, x: f32, y: f32, _: f32, _: f32, _: glfw.Mods) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            self.state = .pressed;

            if (input.selected_key_mapper == null) {
                self.listening = true;
                input.selected_key_mapper = self;
            }

            assets.playSfx("button.mp3");
            return true;
        }

        return !(self.event_policy.pass_press or !intersects(self, x, y));
    }

    pub fn mouseRelease(self: *KeyMapper, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            self.state = .hovered;
        }

        return !(self.event_policy.pass_release or !intersects(self, x, y));
    }

    pub fn mouseMove(self: *KeyMapper, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            if (self.tooltip_text) |text_data| {
                tooltip.switchTooltip(.text, .{
                    .x = x + x_offset,
                    .y = y + y_offset,
                    .text_data = text_data,
                });
                return true;
            }

            systems.hover_lock.lock();
            defer systems.hover_lock.unlock();
            systems.hover_target = UiElement{ .key_mapper = self }; // todo re-add RLS when fixed
            self.state = .hovered;
        } else {
            self.state = .none;
        }

        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn init(self: *KeyMapper) void {
        if (self.title_text_data) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.recalculateAttributes(self.allocator);
        }

        if (self.tooltip_text) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.recalculateAttributes(self.allocator);
        }
    }

    pub fn deinit(self: *KeyMapper) void {
        if (self.title_text_data) |*text_data| {
            text_data.deinit(self.allocator);
        }

        if (self.tooltip_text) |*text_data| {
            text_data.deinit(self.allocator);
        }
    }

    pub fn width(self: KeyMapper) f32 {
        const extra = if (self.title_text_data) |t| t.width else 0;
        return switch (self.image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.w + extra,
            .normal => |image_data| return image_data.width() + extra,
        };
    }

    pub fn height(self: KeyMapper) f32 {
        return switch (self.image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.height(),
        };
    }

    pub fn texWRaw(self: KeyMapper) f32 {
        const extra = if (self.title_text_data) |t| t.width else 0;
        return switch (self.image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.w + extra,
            .normal => |image_data| return image_data.texWRaw() + extra,
        };
    }

    pub fn texHRaw(self: KeyMapper) f32 {
        return switch (self.image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.texHRaw(),
        };
    }
};

pub const CharacterBox = struct {
    x: f32,
    y: f32,
    id: u32,
    class_data_id: u16,
    press_callback: *const fn (*CharacterBox) void,
    image_data: InteractableImageData,
    state: InteractableState = .none,
    layer: Layer = .default,
    text_data: ?TextData = null,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn mousePress(self: *CharacterBox, x: f32, y: f32, _: f32, _: f32, _: glfw.Mods) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            self.state = .pressed;
            self.press_callback(self);
            assets.playSfx("button.mp3");
            return true;
        }

        return !(self.event_policy.pass_press or !intersects(self, x, y));
    }

    pub fn mouseRelease(self: *CharacterBox, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            self.state = .hovered;
        }

        return !(self.event_policy.pass_release or !intersects(self, x, y));
    }

    pub fn mouseMove(self: *CharacterBox, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            systems.hover_lock.lock();
            defer systems.hover_lock.unlock();
            systems.hover_target = UiElement{ .char_box = self }; // todo re-add RLS when fixed
            self.state = .hovered;
        } else {
            self.state = .none;
        }

        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn init(self: *CharacterBox) void {
        if (self.text_data) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.recalculateAttributes(self.allocator);
        }
    }

    pub fn deinit(self: *CharacterBox) void {
        if (self.text_data) |*text_data| {
            text_data.deinit(self.allocator);
        }
    }

    pub fn width(self: CharacterBox) f32 {
        if (self.text_data) |text| {
            return @max(text.width, switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.w,
                .normal => |image_data| return image_data.width(),
            });
        } else {
            return switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.w,
                .normal => |image_data| return image_data.width(),
            };
        }
    }

    pub fn height(self: CharacterBox) f32 {
        if (self.text_data) |text| {
            return @max(text.height, switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.h,
                .normal => |image_data| return image_data.height(),
            });
        } else {
            return switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.h,
                .normal => |image_data| return image_data.height(),
            };
        }
    }

    pub fn texWRaw(self: CharacterBox) f32 {
        if (self.text_data) |text| {
            return @max(text.width, switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.w,
                .normal => |image_data| return image_data.texWRaw(),
            });
        } else {
            return switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.w,
                .normal => |image_data| return image_data.texWRaw(),
            };
        }
    }

    pub fn texHRaw(self: CharacterBox) f32 {
        if (self.text_data) |text| {
            return @max(text.height, switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.h,
                .normal => |image_data| return image_data.texHRaw(),
            });
        } else {
            return switch (self.image_data.current(self.state)) {
                .nine_slice => |nine_slice| return nine_slice.h,
                .normal => |image_data| return image_data.texHRaw(),
            };
        }
    }
};

pub const Image = struct {
    x: f32,
    y: f32,
    image_data: ImageData,
    layer: Layer = .default,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    // hack
    is_minimap_decor: bool = false,
    tooltip_text: ?TextData = null,
    minimap_offset_x: f32 = 0.0,
    minimap_offset_y: f32 = 0.0,
    minimap_width: f32 = 0.0,
    minimap_height: f32 = 0.0,
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn mouseMove(self: *Image, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            if (self.tooltip_text) |text| {
                tooltip.switchTooltip(.text, .{
                    .x = x + x_offset,
                    .y = y + y_offset,
                    .text_data = text,
                });
                return true;
            }
        }

        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn init(self: *Image) void {
        if (self.tooltip_text) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.recalculateAttributes(self.allocator);
        }
    }

    pub fn deinit(self: *Image) void {
        if (self.tooltip_text) |*text_data| {
            text_data.deinit(self.allocator);
        }
    }

    pub fn width(self: Image) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.width(),
        }
    }

    pub fn height(self: Image) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.height(),
        }
    }

    pub fn texWRaw(self: Image) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.texWRaw(),
        }
    }

    pub fn texHRaw(self: Image) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.texHRaw(),
        }
    }
};

pub const MenuBackground = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    layer: Layer = .default,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn width(_: MenuBackground) f32 {
        return @floatFromInt(assets.menu_background.width);
    }

    pub fn height(_: MenuBackground) f32 {
        return @floatFromInt(assets.menu_background.height);
    }

    pub fn texWRaw(_: MenuBackground) f32 {
        return @floatFromInt(assets.menu_background.width);
    }

    pub fn texHRaw(_: MenuBackground) f32 {
        return @floatFromInt(assets.menu_background.height);
    }
};

pub const Item = struct {
    x: f32,
    y: f32,
    background_x: f32,
    background_y: f32,
    image_data: ImageData,
    drag_start_callback: *const fn (*Item) void,
    drag_end_callback: *const fn (*Item) void,
    double_click_callback: *const fn (*Item) void,
    shift_click_callback: *const fn (*Item) void,
    layer: Layer = .default,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    draggable: bool = false,
    // don't set this to anything, it's used for item rarity backgrounds
    background_image_data: ?ImageData = null,
    is_dragging: bool = false,
    drag_start_x: f32 = 0,
    drag_start_y: f32 = 0,
    drag_offset_x: f32 = 0,
    drag_offset_y: f32 = 0,
    last_click_time: i64 = 0,
    item: u16 = std.math.maxInt(u16),
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn mousePress(self: *Item, x: f32, y: f32, _: f32, _: f32, mods: glfw.Mods) bool {
        if (!self.visible or !self.draggable)
            return false;

        if (intersects(self, x, y)) {
            if (mods.shift) {
                self.shift_click_callback(self);
                return true;
            }

            if (self.last_click_time + 333 * std.time.us_per_ms > main.current_time) {
                self.double_click_callback(self);
                return true;
            }

            self.is_dragging = true;
            self.drag_start_x = self.x;
            self.drag_start_y = self.y;
            self.drag_offset_x = self.x - x;
            self.drag_offset_y = self.y - y;
            self.last_click_time = main.current_time;
            self.drag_start_callback(self);
            return true;
        }

        return !(self.event_policy.pass_press or !intersects(self, x, y));
    }

    pub fn mouseRelease(self: *Item, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.is_dragging)
            return false;

        self.is_dragging = false;
        self.drag_end_callback(self);
        return !(self.event_policy.pass_release or !intersects(self, x, y));
    }

    pub fn mouseMove(self: *Item, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        if (!self.is_dragging) {
            if (intersects(self, x, y)) {
                tooltip.switchTooltip(.item, .{
                    .x = x + x_offset,
                    .y = y + y_offset,
                    .item = self.item,
                });
                return true;
            }

            return false;
        }

        self.x = x + self.drag_offset_x;
        self.y = y + self.drag_offset_y;
        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn width(self: Item) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.width(),
        }
    }

    pub fn height(self: Item) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.height(),
        }
    }

    pub fn texWRaw(self: Item) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.texWRaw(),
        }
    }

    pub fn texHRaw(self: Item) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.texHRaw(),
        }
    }
};

pub const Bar = struct {
    x: f32,
    y: f32,
    image_data: ImageData,
    layer: Layer = .default,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    text_data: TextData,
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *Bar) void {
        self.text_data.lock.lock();
        defer self.text_data.lock.unlock();

        self.text_data.recalculateAttributes(self.allocator);
    }

    pub fn deinit(self: *Bar) void {
        self.text_data.deinit(self.allocator);
    }

    pub fn width(self: Bar) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.width(),
        }
    }

    pub fn height(self: Bar) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.height(),
        }
    }

    pub fn texWRaw(self: Bar) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.texWRaw(),
        }
    }

    pub fn texHRaw(self: Bar) f32 {
        switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.texHRaw(),
        }
    }
};

pub const Text = struct {
    x: f32,
    y: f32,
    text_data: TextData,
    layer: Layer = .default,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *Text) void {
        self.text_data.lock.lock();
        defer self.text_data.lock.unlock();

        self.text_data.recalculateAttributes(self.allocator);
    }

    pub fn deinit(self: *Text) void {
        self.text_data.deinit(self.allocator);
    }

    pub fn width(self: Text) f32 {
        return self.text_data.width;
    }

    pub fn height(self: Text) f32 {
        return self.text_data.height;
    }

    pub fn texWRaw(self: Text) f32 {
        return self.text_data.width;
    }

    pub fn texHRaw(self: Text) f32 {
        return self.text_data.height;
    }
};

pub const ScrollableContainer = struct {
    x: f32,
    y: f32,
    scissor_w: f32,
    scissor_h: f32,
    scroll_x: f32,
    scroll_y: f32,
    scroll_w: f32,
    scroll_h: f32,
    scroll_side_x: f32 = -1.0,
    scroll_side_y: f32 = -1.0,
    scroll_side_decor_image_data: ImageData = undefined,
    scroll_decor_image_data: ImageData,
    scroll_knob_image_data: InteractableImageData,
    layer: Layer = .default,
    // Range is [0.0, 1.0]
    start_value: f32 = 0.0,

    visible: bool = true,
    event_policy: EventPolicy = .{},
    base_y: f32 = 0.0,
    container: *Container = undefined,
    scroll_bar: *Slider = undefined,
    scroll_bar_decor: *Image = undefined,
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn mousePress(self: *ScrollableContainer, x: f32, y: f32, x_offset: f32, y_offset: f32, mods: glfw.Mods) bool {
        if (!self.visible)
            return false;

        var container = self.container;
        if (container.mousePress(x, y, x_offset, y_offset, mods) or
            self.scroll_bar.mousePress(x, y, x_offset, y_offset, mods))
            return true;

        return !(self.event_policy.pass_press or !intersects(self, x, y));
    }

    pub fn mouseRelease(self: *ScrollableContainer, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        var container = self.container;
        if (container.mouseRelease(x, y, x_offset, y_offset) or
            self.scroll_bar.mouseRelease(x, y, x_offset, y_offset))
            return true;

        return !(self.event_policy.pass_release or !intersects(self, x, y));
    }

    pub fn mouseMove(self: *ScrollableContainer, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        var container = self.container;
        if (container.mouseMove(x, y, x_offset, y_offset) or
            self.scroll_bar.mouseMove(x, y, x_offset, y_offset))
            return true;

        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn mouseScroll(self: *ScrollableContainer, x: f32, y: f32, _: f32, _: f32, _: f32, y_scroll: f32) bool {
        if (!self.visible)
            return false;

        const container = self.container;
        if (intersects(container, x, y)) {
            const scroll_bar = self.scroll_bar;
            self.scroll_bar.setValue(
                @min(
                    scroll_bar.max_value,
                    @max(
                        scroll_bar.min_value,
                        scroll_bar.current_value + (scroll_bar.max_value - scroll_bar.min_value) * -y_scroll / (self.container.height() / 10.0),
                    ),
                ),
            );
            return true;
        }

        return !(self.event_policy.pass_scroll or !intersects(self, x, y));
    }

    pub fn init(self: *ScrollableContainer) void {
        if (self.start_value < 0.0 or self.start_value > 1.0) {
            std.debug.panic("Invalid start_value for ScrollableContainer: {d:.2}", .{self.start_value});
        }

        self.base_y = self.y;

        self.container = self.allocator.create(Container) catch std.debug.panic("ScrollableContainer child container alloc failed", .{});
        self.container.* = .{
            .x = self.x,
            .y = self.y,
            .scissor = .{
                .min_x = 0,
                .min_y = 0,
                .max_x = self.scissor_w,
                .max_y = self.scissor_h,
            },
            .layer = self.layer,
            .allocator = self.allocator,
        };

        self.scroll_bar = self.allocator.create(Slider) catch std.debug.panic("ScrollableContainer scroll bar alloc failed", .{});
        self.scroll_bar.* = .{
            .x = self.scroll_x,
            .y = self.scroll_y,
            .w = self.scroll_w,
            .h = self.scroll_h,
            .decor_image_data = self.scroll_decor_image_data,
            .knob_image_data = self.scroll_knob_image_data,
            .min_value = 0.0,
            .max_value = 1.0,
            .continous_event_fire = true,
            .state_change = onScrollChanged,
            .vertical = true,
            .visible = false,
            .userdata = self,
            .current_value = self.start_value,
            .allocator = self.allocator,
            .layer = self.layer,
        };
        self.scroll_bar.init();

        if (self.hasScrollDecor()) {
            self.scroll_bar_decor = self.allocator.create(Image) catch std.debug.panic("ScrollableContainer scroll bar decor alloc failed", .{});
            self.scroll_bar_decor.* = .{
                .x = self.scroll_side_x,
                .y = self.scroll_side_y,
                .scissor = .{
                    .min_x = 0,
                    .min_y = 0,
                    .max_x = self.scissor_w,
                    .max_y = self.scissor_h,
                },
                .allocator = self.allocator,
                .image_data = self.scroll_side_decor_image_data,
                .event_policy = .{
                    .pass_press = true,
                    .pass_release = true,
                    .pass_move = true,
                    .pass_scroll = true,
                },
                .visible = false,
                .layer = self.layer,
            };
            self.scroll_bar_decor.init();
        }
    }

    pub fn deinit(self: *ScrollableContainer) void {
        self.container.deinit();
        self.allocator.destroy(self.container);

        self.scroll_bar.deinit();
        self.allocator.destroy(self.scroll_bar);

        if (self.hasScrollDecor()) {
            self.scroll_bar_decor.deinit();
            self.allocator.destroy(self.scroll_bar_decor);
        }
    }

    pub fn width(self: ScrollableContainer) f32 {
        return @max(self.container.width(), (self.scroll_bar.x - self.container.x) + self.scroll_bar.width());
    }

    pub fn height(self: ScrollableContainer) f32 {
        return @max(self.container.height(), (self.scroll_bar.y - self.container.y) + self.scroll_bar.height());
    }

    pub fn texWRaw(self: ScrollableContainer) f32 {
        return @max(self.container.texWRaw(), (self.scroll_bar.x - self.container.x) + self.scroll_bar.texWRaw());
    }

    pub fn texHRaw(self: ScrollableContainer) f32 {
        return @max(self.container.texHRaw(), (self.scroll_bar.y - self.container.y) + self.scroll_bar.texHRaw());
    }

    pub fn hasScrollDecor(self: ScrollableContainer) bool {
        return self.scroll_side_x > 0 and self.scroll_side_y > 0;
    }

    pub fn createChild(self: *ScrollableContainer, data: anytype) !*@TypeOf(data) {
        const elem = self.container.createChild(data);
        self.update();
        return elem;
    }

    pub fn update(self: *ScrollableContainer) void {
        if (self.scissor_h >= self.container.height()) {
            self.scroll_bar.visible = false;
            if (self.hasScrollDecor()) self.scroll_bar_decor.visible = false;
            return;
        }

        const h_dt_base = (self.scissor_h - self.container.height());
        const h_dt = self.scroll_bar.current_value * h_dt_base;
        const new_h = self.scroll_bar.h / (2.0 + -h_dt_base / self.scissor_h);
        self.scroll_bar.knob_image_data.scaleHeight(new_h);
        self.scroll_bar.setValue(self.scroll_bar.current_value);
        self.scroll_bar.visible = true;
        if (self.hasScrollDecor()) self.scroll_bar_decor.visible = true;

        self.container.y = self.base_y + h_dt;
        self.container.scissor.min_y = -h_dt;
        self.container.scissor.max_y = -h_dt + self.scissor_h;
        self.container.updateScissors();
    }

    fn onScrollChanged(scroll_bar: *Slider) void {
        var parent: *ScrollableContainer = @alignCast(@ptrCast(scroll_bar.userdata));
        if (parent.scissor_h >= parent.container.height()) {
            parent.scroll_bar.visible = false;
            if (parent.hasScrollDecor()) parent.scroll_bar_decor.visible = false;
            return;
        }

        const h_dt_base = (parent.scissor_h - parent.container.height());
        const h_dt = scroll_bar.current_value * h_dt_base;
        const new_h = parent.scroll_bar.h / (2.0 + -h_dt_base / parent.scissor_h);
        parent.scroll_bar.knob_image_data.scaleHeight(new_h);
        parent.scroll_bar.visible = true;
        if (parent.hasScrollDecor()) parent.scroll_bar_decor.visible = true;

        parent.container.y = parent.base_y + h_dt;
        parent.container.scissor.min_y = -h_dt;
        parent.container.scissor.max_y = -h_dt + parent.scissor_h;
        parent.container.updateScissors();
    }
};

pub const Container = struct {
    x: f32,
    y: f32,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    draggable: bool = false,
    layer: Layer = .default,

    elements: std.ArrayListUnmanaged(UiElement) = .{},
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    drag_start_x: f32 = 0,
    drag_start_y: f32 = 0,
    drag_offset_x: f32 = 0,
    drag_offset_y: f32 = 0,
    is_dragging: bool = false,
    clamp_x: bool = false,
    clamp_y: bool = false,
    clamp_to_screen: bool = false,

    pub fn mousePress(self: *Container, x: f32, y: f32, x_offset: f32, y_offset: f32, mods: glfw.Mods) bool {
        if (!self.visible)
            return false;

        var iter = std.mem.reverseIterator(self.elements.items);
        while (iter.next()) |elem| {
            switch (elem) {
                inline else => |inner_elem| {
                    if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "mousePress") and
                        inner_elem.mousePress(x - self.x, y - self.y, self.x + x_offset, self.y + y_offset, mods))
                        return true;
                },
            }
        }

        const in_bounds = intersects(self, x, y);
        if (self.draggable and in_bounds) {
            self.is_dragging = true;
            self.drag_start_x = self.x;
            self.drag_start_y = self.y;
            self.drag_offset_x = self.x - x;
            self.drag_offset_y = self.y - y;
        }

        return !(self.event_policy.pass_press or !in_bounds);
    }

    pub fn mouseRelease(self: *Container, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        if (self.is_dragging)
            self.is_dragging = false;

        var iter = std.mem.reverseIterator(self.elements.items);
        while (iter.next()) |elem| {
            switch (elem) {
                inline else => |inner_elem| {
                    if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "mouseRelease") and
                        inner_elem.mouseRelease(x - self.x, y - self.y, self.x + x_offset, self.y + y_offset))
                        return true;
                },
            }
        }

        return !(self.event_policy.pass_release or !intersects(self, x, y));
    }

    pub fn mouseMove(self: *Container, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        if (self.is_dragging) {
            if (!self.clamp_x) {
                self.x = x + self.drag_offset_x;
                if (self.clamp_to_screen) {
                    if (self.x > 0)
                        self.x = 0;

                    const bottom_x = self.x + self.width();
                    if (bottom_x < camera.screen_width)
                        self.x = self.width();
                }
            }
            if (!self.clamp_y) {
                self.y = y + self.drag_offset_y;
                if (self.clamp_to_screen) {
                    if (self.y > 0)
                        self.y = 0;

                    const bottom_y = self.y + self.height();
                    if (bottom_y < camera.screen_height)
                        self.y = bottom_y;
                }
            }
        }

        var iter = std.mem.reverseIterator(self.elements.items);
        while (iter.next()) |elem| {
            switch (elem) {
                inline else => |inner_elem| {
                    if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "mouseMove") and
                        inner_elem.mouseMove(x - self.x, y - self.y, self.x + x_offset, self.y + y_offset))
                        return true;
                },
            }
        }

        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn mouseScroll(self: *Container, x: f32, y: f32, x_offset: f32, y_offset: f32, x_scroll: f32, y_scroll: f32) bool {
        if (!self.visible)
            return false;

        var iter = std.mem.reverseIterator(self.elements.items);
        while (iter.next()) |elem| {
            switch (elem) {
                inline else => |inner_elem| {
                    if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "mouseScroll") and
                        inner_elem.mouseScroll(x - self.x, y - self.y, self.x + x_offset, self.y + y_offset, x_scroll, y_scroll))
                        return true;
                },
            }
        }

        return !(self.event_policy.pass_scroll or !intersects(self, x, y));
    }

    pub fn deinit(self: *Container) void {
        for (self.elements.items) |*elem| {
            switch (elem.*) {
                inline else => |inner_elem| {
                    comptime var field_name: []const u8 = "";
                    inline for (@typeInfo(UiElement).@"union".fields) |field| {
                        if (field.type == @TypeOf(inner_elem)) {
                            field_name = field.name;
                            break;
                        }
                    }

                    if (field_name.len == 0)
                        @compileError("Could not find field name");

                    const tag = std.meta.stringToEnum(std.meta.Tag(UiElement), field_name);
                    if (systems.hover_target != null and
                        std.meta.activeTag(systems.hover_target.?) == tag and
                        inner_elem == @field(systems.hover_target.?, field_name))
                        systems.hover_target = null;

                    if (std.meta.hasFn(@typeInfo(@TypeOf(inner_elem)).pointer.child, "deinit")) inner_elem.deinit();
                    self.allocator.destroy(inner_elem);
                },
            }
        }
        self.elements.deinit(self.allocator);
    }

    pub fn width(self: *Container) f32 {
        if (self.elements.items.len <= 0)
            return 0.0;

        var min_x = std.math.floatMax(f32);
        var max_x = std.math.floatMin(f32);
        for (self.elements.items) |elem| {
            switch (elem) {
                inline else => |inner_elem| {
                    min_x = @min(min_x, inner_elem.x);
                    max_x = @max(max_x, inner_elem.x + inner_elem.width());
                },
            }
        }

        return max_x - min_x;
    }

    pub fn height(self: *Container) f32 {
        if (self.elements.items.len <= 0)
            return 0.0;

        var min_y = std.math.floatMax(f32);
        var max_y = std.math.floatMin(f32);
        for (self.elements.items) |elem| {
            switch (elem) {
                inline else => |inner_elem| {
                    min_y = @min(min_y, inner_elem.y);
                    max_y = @max(max_y, inner_elem.y + inner_elem.height());
                },
            }
        }

        return max_y - min_y;
    }

    pub fn texWRaw(self: *Container) f32 {
        if (self.elements.items.len <= 0)
            return 0.0;

        var min_x = std.math.floatMax(f32);
        var max_x = std.math.floatMin(f32);
        for (self.elements.items) |elem| {
            switch (elem) {
                inline else => |inner_elem| {
                    min_x = @min(min_x, inner_elem.x);
                    max_x = @max(max_x, inner_elem.x + inner_elem.texWRaw());
                },
            }
        }

        return max_x - min_x;
    }

    pub fn texHRaw(self: *Container) f32 {
        if (self.elements.items.len <= 0)
            return 0.0;

        var min_y = std.math.floatMax(f32);
        var max_y = std.math.floatMin(f32);
        for (self.elements.items) |elem| {
            switch (elem) {
                inline else => |inner_elem| {
                    min_y = @min(min_y, inner_elem.y);
                    max_y = @max(max_y, inner_elem.y + inner_elem.texHRaw());
                },
            }
        }

        return max_y - min_y;
    }

    pub fn createChild(self: *Container, data: anytype) !*@TypeOf(data) {
        const T = @TypeOf(data);
        var elem = try self.allocator.create(T);
        elem.* = data;
        elem.allocator = self.allocator;
        if (std.meta.hasFn(T, "init")) elem.init();
        elem.scissor = .{
            .min_x = if (self.scissor.min_x == ScissorRect.dont_scissor)
                ScissorRect.dont_scissor
            else
                self.scissor.min_x - elem.x,
            .min_y = if (self.scissor.min_y == ScissorRect.dont_scissor)
                ScissorRect.dont_scissor
            else
                self.scissor.min_y - elem.y,
            .max_x = if (self.scissor.max_x == ScissorRect.dont_scissor)
                ScissorRect.dont_scissor
            else
                self.scissor.max_x - elem.x,
            .max_y = if (self.scissor.max_y == ScissorRect.dont_scissor)
                ScissorRect.dont_scissor
            else
                self.scissor.max_y - elem.y,
        };

        comptime var field_name: []const u8 = "";
        inline for (@typeInfo(UiElement).@"union".fields) |field| {
            if (@typeInfo(field.type).pointer.child == T) {
                field_name = field.name;
                break;
            }
        }

        if (field_name.len == 0)
            @compileError("Could not find field name");

        try self.elements.append(self.allocator, @unionInit(UiElement, field_name, elem));
        return elem;
    }

    pub fn updateScissors(self: *Container) void {
        for (self.elements.items) |elem| {
            switch (elem) {
                .scrollable_container => {},
                inline else => |inner_elem| {
                    inner_elem.scissor = .{
                        .min_x = if (self.scissor.min_x == ScissorRect.dont_scissor)
                            ScissorRect.dont_scissor
                        else
                            self.scissor.min_x - inner_elem.x,
                        .min_y = if (self.scissor.min_y == ScissorRect.dont_scissor)
                            ScissorRect.dont_scissor
                        else
                            self.scissor.min_y - inner_elem.y,
                        .max_x = if (self.scissor.max_x == ScissorRect.dont_scissor)
                            ScissorRect.dont_scissor
                        else
                            self.scissor.max_x - inner_elem.x,
                        .max_y = if (self.scissor.max_y == ScissorRect.dont_scissor)
                            ScissorRect.dont_scissor
                        else
                            self.scissor.max_y - inner_elem.y,
                    };
                },
            }

            if (elem == .container) {
                elem.container.updateScissors();
            } else if (elem == .dropdown_container) {
                // lol
                elem.dropdown_container.background_data.setScissor(elem.dropdown_container.scissor);
                elem.dropdown_container.container.scissor = elem.dropdown_container.scissor;
                elem.dropdown_container.container.updateScissors();
            }
        }
    }
};

pub const Toggle = struct {
    x: f32,
    y: f32,
    toggled: *bool,
    off_image_data: InteractableImageData,
    on_image_data: InteractableImageData,
    scissor: ScissorRect = .{},
    state: InteractableState = .none,
    layer: Layer = .default,
    text_data: ?TextData = null,
    tooltip_text: ?TextData = null,
    state_change: ?*const fn (*Toggle) void = null,
    visible: bool = true,
    event_policy: EventPolicy = .{},
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn mousePress(self: *Toggle, x: f32, y: f32, _: f32, _: f32, _: glfw.Mods) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            self.state = .pressed;
            self.toggled.* = !self.toggled.*;
            if (self.state_change) |callback| {
                callback(self);
            }
            assets.playSfx("button.mp3");
            return true;
        }

        return !(self.event_policy.pass_press or !intersects(self, x, y));
    }

    pub fn mouseRelease(self: *Toggle, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            self.state = .hovered;
        }

        return !(self.event_policy.pass_release or !intersects(self, x, y));
    }

    pub fn mouseMove(self: *Toggle, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        if (intersects(self, x, y)) {
            if (self.tooltip_text) |text_data| {
                tooltip.switchTooltip(.text, .{
                    .x = x + x_offset,
                    .y = y + y_offset,
                    .text_data = text_data,
                });
                return true;
            }

            systems.hover_lock.lock();
            defer systems.hover_lock.unlock();
            systems.hover_target = UiElement{ .toggle = self }; // todo re-add RLS when fixed
            self.state = .hovered;
        } else {
            self.state = .none;
        }

        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn init(self: *Toggle) void {
        if (self.text_data) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.recalculateAttributes(self.allocator);
        }

        if (self.tooltip_text) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.recalculateAttributes(self.allocator);
        }
    }

    pub fn deinit(self: *Toggle) void {
        if (self.text_data) |*text_data| {
            text_data.deinit(self.allocator);
        }

        if (self.tooltip_text) |*text_data| {
            text_data.deinit(self.allocator);
        }
    }

    pub fn width(self: Toggle) f32 {
        switch (if (self.toggled.*)
            self.on_image_data.current(self.state)
        else
            self.off_image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.width(),
        }
    }

    pub fn height(self: Toggle) f32 {
        switch (if (self.toggled.*)
            self.on_image_data.current(self.state)
        else
            self.off_image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.height(),
        }
    }

    pub fn texWRaw(self: Toggle) f32 {
        switch (if (self.toggled.*)
            self.on_image_data.current(self.state)
        else
            self.off_image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.texWRaw(),
        }
    }

    pub fn texHRaw(self: Toggle) f32 {
        switch (if (self.toggled.*)
            self.on_image_data.current(self.state)
        else
            self.off_image_data.current(self.state)) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.texHRaw(),
        }
    }
};

pub const Slider = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    min_value: f32,
    max_value: f32,
    decor_image_data: ImageData,
    knob_image_data: InteractableImageData,
    state_change: ?*const fn (*Slider) void = null,
    step: f32 = 0.0,
    scissor: ScissorRect = .{},
    vertical: bool = false,
    continous_event_fire: bool = true,
    state: InteractableState = .none,
    layer: Layer = .default,
    // the alignments and max w/h on these will be overwritten, don't bother setting it
    value_text_data: ?TextData = null,
    title_text_data: ?TextData = null,
    tooltip_text: ?TextData = null,
    title_offset: f32 = 30.0,
    target: ?*f32 = null,
    userdata: ?*anyopaque = null,
    visible: bool = true,
    // will be overwritten
    event_policy: EventPolicy = .{},
    knob_x: f32 = 0.0,
    knob_y: f32 = 0.0,
    knob_offset_x: f32 = 0.0,
    knob_offset_y: f32 = 0.0,
    current_value: f32 = 0.0,
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn mousePress(self: *Slider, x: f32, y: f32, _: f32, _: f32, _: glfw.Mods) bool {
        if (!self.visible)
            return false;

        if (utils.isInBounds(x, y, self.x, self.y, self.w, self.h)) {
            const knob_w = switch (self.knob_image_data.current(self.state)) {
                .nine_slice => |nine_slice| nine_slice.w,
                .normal => |normal| normal.width(),
            };

            const knob_h = switch (self.knob_image_data.current(self.state)) {
                .nine_slice => |nine_slice| nine_slice.h,
                .normal => |normal| normal.height(),
            };

            self.knob_offset_x = -((x - self.x) - self.knob_x);
            self.knob_offset_y = -((y - self.y) - self.knob_y);
            self.pressed(x, y, knob_h, knob_w);
        }

        return !(self.event_policy.pass_press or !intersects(self, x, y));
    }

    pub fn mouseRelease(self: *Slider, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible)
            return false;

        if (self.state == .pressed) {
            const knob_w = switch (self.knob_image_data.current(self.state)) {
                .nine_slice => |nine_slice| nine_slice.w,
                .normal => |normal| normal.width(),
            };

            const knob_h = switch (self.knob_image_data.current(self.state)) {
                .nine_slice => |nine_slice| nine_slice.h,
                .normal => |normal| normal.height(),
            };

            if (utils.isInBounds(x, y, self.knob_x, self.knob_y, knob_w, knob_h)) {
                systems.hover_lock.lock();
                defer systems.hover_lock.unlock();
                systems.hover_target = UiElement{ .slider = self }; // todo re-add RLS when fixed
                self.state = .hovered;
            } else {
                self.state = .none;
            }

            if (self.target) |target| target.* = self.current_value;
            if (self.state_change) |sc| sc(self);
        }

        return !(self.event_policy.pass_release or !intersects(self, x, y));
    }

    pub fn mouseMove(self: *Slider, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        const knob_w = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |normal| normal.width(),
        };

        const knob_h = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.h,
            .normal => |normal| normal.height(),
        };

        if (intersects(self, x, y)) {
            if (self.tooltip_text) |text_data| {
                tooltip.switchTooltip(.text, .{
                    .x = x + x_offset,
                    .y = y + y_offset,
                    .text_data = text_data,
                });
            }
        }

        if (self.state == .pressed) {
            self.pressed(x, y, knob_h, knob_w);
        } else if (utils.isInBounds(x, y, self.x + self.knob_x, self.y + self.knob_y, knob_w, knob_h)) {
            systems.hover_lock.lock();
            defer systems.hover_lock.unlock();
            systems.hover_target = UiElement{ .slider = self }; // todo re-add RLS when fixed
            self.state = .hovered;
        } else if (self.state == .hovered) {
            self.state = .none;
        }

        return !(self.event_policy.pass_move or !intersects(self, x, y));
    }

    pub fn mouseScroll(self: *Slider, x: f32, y: f32, _: f32, _: f32, _: f32, y_scroll: f32) bool {
        if (intersects(self, x, y)) {
            self.setValue(
                @min(
                    self.max_value,
                    @max(
                        self.min_value,
                        self.current_value + (self.max_value - self.min_value) * -y_scroll / 64.0,
                    ),
                ),
            );
            return true;
        }

        return !(self.event_policy.pass_scroll or !intersects(self, x, y));
    }

    pub fn init(self: *Slider) void {
        self.event_policy = .{
            .pass_move = true,
            .pass_press = true,
            .pass_scroll = true,
            .pass_release = true,
        };

        if (self.target) |value_ptr| {
            value_ptr.* = @min(self.max_value, @max(self.min_value, value_ptr.*));
            self.current_value = value_ptr.*;
        }

        switch (self.decor_image_data) {
            .nine_slice => |*nine_slice| {
                nine_slice.w = self.w;
                nine_slice.h = self.h;
            },
            .normal => |*image_data| {
                image_data.scale_x = self.w / image_data.width();
                image_data.scale_y = self.h / image_data.height();
            },
        }

        const knob_w = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |normal| normal.width(),
        };
        const knob_h = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.h,
            .normal => |normal| normal.height(),
        };

        if (self.vertical) {
            const offset = (self.w - knob_w) / 2.0;
            if (offset < 0)
                self.x = self.x - offset;
            self.knob_x = self.knob_x + offset;

            if (self.value_text_data) |*text_data| {
                text_data.hori_align = .left;
                text_data.vert_align = .middle;
                text_data.max_height = knob_h;
            }
        } else {
            const offset = (self.h - knob_h) / 2.0;
            if (offset < 0)
                self.y = self.y - offset;
            self.knob_y = self.knob_y + offset;

            if (self.value_text_data) |*text_data| {
                text_data.hori_align = .middle;
                text_data.vert_align = .top;
                text_data.max_width = knob_w;
            }
        }

        if (self.value_text_data) |*text_data| {
            // have to do it for the backing buffer init
            {
                text_data.lock.lock();
                defer text_data.lock.unlock();

                text_data.recalculateAttributes(self.allocator);
            }

            text_data.setText(std.fmt.bufPrint(text_data.backing_buffer, "{d:.2}", .{self.current_value}) catch "-1.00", self.allocator);
        }

        if (self.title_text_data) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.vert_align = .middle;
            text_data.hori_align = .middle;
            text_data.max_width = self.w;
            text_data.max_height = self.title_offset;
            text_data.recalculateAttributes(self.allocator);
        }

        if (self.tooltip_text) |*text_data| {
            text_data.lock.lock();
            defer text_data.lock.unlock();

            text_data.recalculateAttributes(self.allocator);
        }

        self.setValue(self.current_value);
    }

    pub fn deinit(self: *Slider) void {
        if (self.value_text_data) |*text_data| {
            text_data.deinit(self.allocator);
        }

        if (self.title_text_data) |*text_data| {
            text_data.deinit(self.allocator);
        }

        if (self.tooltip_text) |*text_data| {
            text_data.deinit(self.allocator);
        }
    }

    pub fn width(self: Slider) f32 {
        const decor_w = switch (self.decor_image_data) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |image_data| image_data.width(),
        };

        const knob_w = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |normal| normal.width(),
        };

        return @max(decor_w, knob_w);
    }

    pub fn height(self: Slider) f32 {
        const decor_h = switch (self.decor_image_data) {
            .nine_slice => |nine_slice| nine_slice.h,
            .normal => |image_data| image_data.height(),
        };

        const knob_h = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.h,
            .normal => |normal| normal.height(),
        };

        return @max(decor_h, knob_h);
    }

    pub fn texWRaw(self: Slider) f32 {
        const decor_w = switch (self.decor_image_data) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |image_data| image_data.texWRaw(),
        };

        const knob_w = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |normal| normal.texWRaw(),
        };

        return @max(decor_w, knob_w);
    }

    pub fn texHRaw(self: Slider) f32 {
        const decor_h = switch (self.decor_image_data) {
            .nine_slice => |nine_slice| nine_slice.h,
            .normal => |image_data| image_data.texHRaw(),
        };

        const knob_h = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.h,
            .normal => |normal| normal.texHRaw(),
        };

        return @max(decor_h, knob_h);
    }

    fn pressed(self: *Slider, x: f32, y: f32, knob_h: f32, knob_w: f32) void {
        const prev_value = self.current_value;

        if (self.vertical) {
            self.knob_y = @min(self.h - knob_h, @max(0, y - self.y + self.knob_offset_y));
            self.current_value = self.knob_y / (self.h - knob_h) * (self.max_value - self.min_value) + self.min_value;
        } else {
            self.knob_x = @min(self.w - knob_w, @max(0, x - self.x + self.knob_offset_x));
            self.current_value = self.knob_x / (self.w - knob_w) * (self.max_value - self.min_value) + self.min_value;
        }

        if (self.current_value != prev_value) {
            if (self.value_text_data) |*text_data| {
                text_data.setText(std.fmt.bufPrint(text_data.backing_buffer, "{d:.2}", .{self.current_value}) catch "-1.00", self.allocator);
            }

            if (self.continous_event_fire) {
                if (self.target) |target| target.* = self.current_value;
                if (self.state_change) |sc| sc(self);
            }
        }

        self.state = .pressed;
    }

    pub fn setValue(self: *Slider, value: f32) void {
        const prev_value = self.current_value;

        const knob_w = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.w,
            .normal => |normal| normal.width(),
        };

        const knob_h = switch (self.knob_image_data.current(self.state)) {
            .nine_slice => |nine_slice| nine_slice.h,
            .normal => |normal| normal.height(),
        };

        self.current_value = value;
        if (self.vertical) {
            self.knob_y = (value - self.min_value) / (self.max_value - self.min_value) * (self.h - knob_h);
        } else {
            self.knob_x = (value - self.min_value) / (self.max_value - self.min_value) * (self.w - knob_w);
        }

        if (self.current_value != prev_value) {
            if (self.value_text_data) |*text_data| {
                text_data.setText(std.fmt.bufPrint(text_data.backing_buffer, "{d:.2}", .{self.current_value}) catch "-1.00", self.allocator);
            }

            if (self.continous_event_fire) {
                if (self.target) |target| target.* = self.current_value;
                if (self.state_change) |sc| sc(self);
            }
        }
    }
};

pub const DropdownContainer = struct {
    x: f32,
    y: f32,
    parent: *Dropdown,
    container: Container,
    pressCallback: *const fn (*DropdownContainer) void,
    background_data: InteractableImageData,
    state: InteractableState = .none,
    index: u32 = std.math.maxInt(u32),

    layer: Layer = .default,
    scissor: ScissorRect = .{},
    visible: bool = true,
    event_policy: EventPolicy = .{},
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn mousePress(self: *DropdownContainer, x: f32, y: f32, _: f32, _: f32, _: glfw.Mods) bool {
        if (!self.visible or self.index == self.parent.selected_index)
            return false;

        const in_bounds = intersects(self, x, y);
        if (in_bounds) {
            self.state = .pressed;
            if (self.parent.selected_index != std.math.maxInt(u32))
                self.parent.children.items[self.parent.selected_index].state = .none;
            self.parent.selected_index = self.index;
            if (self.parent.auto_close)
                self.parent.toggled = false;
            systems.hover_lock.lock();
            defer systems.hover_lock.unlock();
            if (systems.hover_target != null and
                systems.hover_target.? == .dropdown_container and
                systems.hover_target.?.dropdown_container == self)
                systems.hover_target = null;
            self.pressCallback(self);
            return true;
        }

        return !(self.event_policy.pass_press or !in_bounds);
    }

    pub fn mouseRelease(self: *DropdownContainer, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible or self.index == self.parent.selected_index)
            return false;

        const in_bounds = intersects(self, x, y);
        if (in_bounds) {
            self.state = .hovered;
        }

        return !(self.event_policy.pass_release or !in_bounds);
    }

    pub fn mouseMove(self: *DropdownContainer, x: f32, y: f32, _: f32, _: f32) bool {
        if (!self.visible or self.index == self.parent.selected_index)
            return false;

        const in_bounds = intersects(self, x, y);
        if (in_bounds) {
            systems.hover_lock.lock();
            defer systems.hover_lock.unlock();
            systems.hover_target = UiElement{ .dropdown_container = self }; // todo re-add RLS when fixed
            self.state = .hovered;
        } else {
            self.state = .none;
        }

        return !(self.event_policy.pass_move or !in_bounds);
    }

    pub fn deinit(self: *DropdownContainer) void {
        self.container.deinit();
    }

    pub fn width(self: *DropdownContainer) f32 {
        return @max(self.background_data.width(self.state), self.container.width());
    }

    pub fn height(self: *DropdownContainer) f32 {
        return @max(self.background_data.height(self.state), self.container.height());
    }

    pub fn texWRaw(self: *DropdownContainer) f32 {
        return @max(self.background_data.texWRaw(self.state), self.container.texWRaw());
    }

    pub fn texHRaw(self: *DropdownContainer) f32 {
        return @max(self.background_data.texHRaw(self.state), self.container.texHRaw());
    }
};

pub const Dropdown = struct {
    x: f32,
    y: f32,
    w: f32,
    container_inlay_x: f32,
    container_inlay_y: f32,
    // w/h will be overwritten
    title_data: ImageData,
    title_text: TextData,
    // make sure h is appriopriate. w will be overwritten
    background_data: ImageData,
    button_data_collapsed: InteractableImageData,
    button_data_extended: InteractableImageData,
    // the w on these will be overwritten. h must match
    main_background_data: InteractableImageData,
    alt_background_data: InteractableImageData,
    scroll_w: f32,
    scroll_h: f32,
    scroll_side_x_rel: f32 = std.math.floatMax(f32),
    scroll_side_y_rel: f32 = std.math.floatMax(f32),
    scroll_side_decor_image_data: ImageData = undefined,
    scroll_decor_image_data: ImageData,
    scroll_knob_image_data: InteractableImageData,
    button_state: InteractableState = .none,
    container: *ScrollableContainer = undefined,
    layer: Layer = .default,
    scissor: ScissorRect = .{},
    auto_close: bool = true,
    visible: bool = true,
    toggled: bool = false,
    event_policy: EventPolicy = .{},
    disposed: bool = false,
    allocator: std.mem.Allocator = undefined,
    next_index: u32 = 0,
    selected_index: u32 = std.math.maxInt(u32),
    lock: std.Thread.Mutex = .{},
    children: std.ArrayListUnmanaged(*DropdownContainer) = .{},

    pub fn mousePress(self: *Dropdown, x: f32, y: f32, x_offset: f32, y_offset: f32, mods: glfw.Mods) bool {
        if (!self.visible)
            return false;

        const button_data = if (self.toggled) self.button_data_collapsed else self.button_data_extended;
        const current_button = button_data.current(self.button_state);
        const in_bounds = utils.isInBounds(x, y, self.x + self.title_data.width(), self.y, current_button.width(), current_button.height());
        if (in_bounds) {
            self.button_state = .pressed;
            self.toggled = !self.toggled;
            assets.playSfx("button.mp3");
            return true;
        }

        const block = !(self.event_policy.pass_press or !in_bounds);
        if (!block)
            return self.container.mousePress(x, y, x_offset, y_offset, mods);

        return block;
    }

    pub fn mouseRelease(self: *Dropdown, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        const button_data = if (self.toggled) self.button_data_collapsed else self.button_data_extended;
        const current_button = button_data.current(self.button_state);
        const in_bounds = utils.isInBounds(x, y, self.x + self.title_data.width(), self.y, current_button.width(), current_button.height());
        if (in_bounds) {
            self.button_state = .none;
        }

        const block = !(self.event_policy.pass_release or !in_bounds);
        if (!block)
            return self.container.mouseRelease(x, y, x_offset, y_offset);

        return block;
    }

    pub fn mouseMove(self: *Dropdown, x: f32, y: f32, x_offset: f32, y_offset: f32) bool {
        if (!self.visible)
            return false;

        const button_data = if (self.toggled) self.button_data_collapsed else self.button_data_extended;
        const current_button = button_data.current(self.button_state);
        const in_bounds = utils.isInBounds(x, y, self.x + self.title_data.width(), self.y, current_button.width(), current_button.height());
        if (in_bounds) {
            systems.hover_lock.lock();
            defer systems.hover_lock.unlock();
            systems.hover_target = UiElement{ .dropdown = self }; // todo re-add RLS when fixed
            self.button_state = .hovered;
        } else {
            self.button_state = .none;
        }

        const block = !(self.event_policy.pass_move or !in_bounds);
        if (!block)
            return self.container.mouseMove(x, y, x_offset, y_offset);

        return block;
    }

    pub fn mouseScroll(self: *Dropdown, x: f32, y: f32, x_offset: f32, y_offset: f32, x_scroll: f32, y_scroll: f32) bool {
        if (!self.visible)
            return false;

        if (self.container.mouseScroll(x, y, x_offset, y_offset, x_scroll, y_scroll))
            return true;

        return !(self.event_policy.pass_scroll or !intersects(self, x, y));
    }

    pub fn init(self: *Dropdown) void {
        std.debug.assert(self.button_data_collapsed.width(.none) == self.button_data_extended.width(.none) and
            self.button_data_collapsed.height(.none) == self.button_data_extended.height(.none) and
            self.button_data_collapsed.width(.hovered) == self.button_data_extended.width(.hovered) and
            self.button_data_collapsed.height(.hovered) == self.button_data_extended.height(.hovered) and
            self.button_data_collapsed.width(.pressed) == self.button_data_extended.width(.pressed) and
            self.button_data_collapsed.height(.pressed) == self.button_data_extended.height(.pressed));

        std.debug.assert(self.main_background_data.height(.none) == self.alt_background_data.height(.none) and
            self.main_background_data.height(.hovered) == self.alt_background_data.height(.hovered) and
            self.main_background_data.height(.pressed) == self.alt_background_data.height(.pressed));

        self.background_data.scaleWidth(self.w);
        self.title_data.scaleWidth(self.w - self.button_data_collapsed.width(.none));
        self.title_data.scaleHeight(self.button_data_collapsed.height(.none));

        self.title_text.max_width = self.title_data.width();
        self.title_text.max_height = self.title_data.height();
        self.title_text.vert_align = .middle;
        self.title_text.hori_align = .middle;
        {
            self.title_text.lock.lock();
            defer self.title_text.lock.unlock();
            self.title_text.recalculateAttributes(self.allocator);
        }

        const w_base = self.w - self.container_inlay_x * 2;
        const scroll_max_w = @max(self.scroll_w, self.scroll_knob_image_data.width(.none));
        const scissor_w = w_base - scroll_max_w - 2 +
            (if (self.scroll_side_x_rel > 0.0) 0.0 else self.scroll_side_x_rel);

        self.main_background_data.scaleWidth(w_base);
        self.alt_background_data.scaleWidth(w_base);

        const scroll_x_base = self.x + self.container_inlay_x + scissor_w + 2;
        const scroll_y_base = self.y + self.container_inlay_y + self.title_data.height();
        self.container = self.allocator.create(ScrollableContainer) catch std.debug.panic("Dropdown child container alloc failed", .{});
        self.container.* = .{
            .x = self.x + self.container_inlay_x,
            .y = self.y + self.container_inlay_y + self.title_data.height(),
            .scissor_w = scissor_w,
            .scissor_h = self.background_data.height() - self.container_inlay_y * 2 - 6,
            .scroll_x = scroll_x_base + if (self.scroll_side_x_rel == std.math.floatMax(f32)) 0.0 else -self.scroll_side_x_rel,
            .scroll_y = scroll_y_base + if (self.scroll_side_y_rel == std.math.floatMax(f32)) 0.0 else -self.scroll_side_y_rel,
            .scroll_w = self.scroll_w,
            .scroll_h = self.scroll_h,
            .scroll_side_x = scroll_x_base,
            .scroll_side_y = scroll_y_base,
            .scroll_decor_image_data = self.scroll_decor_image_data,
            .scroll_knob_image_data = self.scroll_knob_image_data,
            .scroll_side_decor_image_data = self.scroll_side_decor_image_data,
            .layer = self.layer,
            .allocator = self.allocator,
        };
        self.container.init();
    }

    pub fn deinit(self: *Dropdown) void {
        self.title_text.deinit(self.allocator);
        self.container.deinit();
        self.children.deinit(self.allocator);
        self.allocator.destroy(self.container);
    }

    pub fn width(self: Dropdown) f32 {
        return self.background_data.width();
    }

    pub fn height(self: Dropdown) f32 {
        return self.title_data.height() + (if (self.toggled) self.background_data.height() else 0.0);
    }

    pub fn texWRaw(self: Dropdown) f32 {
        return self.background_data.texWRaw();
    }

    pub fn texHRaw(self: Dropdown) f32 {
        return self.title_data.texHRaw() + (if (self.toggled) self.background_data.texHRaw() else 0.0);
    }

    // the container field's x/y are relative to parents
    pub fn createChild(self: *Dropdown, pressCallback: *const fn (*DropdownContainer) void) !*DropdownContainer {
        self.lock.lock();
        defer self.lock.unlock();

        const scroll_vis_pre = self.container.scroll_bar.visible;

        const next_idx: f32 = @floatFromInt(self.next_index);
        const ret = try self.container.createChild(DropdownContainer{
            .x = 0,
            .y = self.main_background_data.height(.none) * next_idx,
            .parent = self,
            .container = .{
                .x = 0,
                .y = 0,
                .allocator = self.allocator,
                .visible = self.visible,
            },
            .pressCallback = pressCallback,
            .index = self.next_index,
            .layer = self.layer,
            .visible = self.visible,
            .background_data = if (@mod(self.next_index, 2) == 0) self.main_background_data else self.alt_background_data,
        });
        self.next_index += 1;
        try self.children.append(self.allocator, ret);

        if (self.container.scroll_bar.visible and !scroll_vis_pre) {
            self.main_background_data.scaleWidth(self.container.scissor_w);
            self.alt_background_data.scaleWidth(self.container.scissor_w);

            // for (self.children.items) |child| {

            // }
        }

        return ret;
    }
};

pub const SpeechBalloon = struct {
    image_data: ImageData,
    text_data: TextData,
    target_obj_type: network_data.ObjectType,
    target_map_id: u32,
    start_time: i64 = 0,
    visible: bool = true,
    // the texts' internal x/y, don't touch outside of systems.update()
    screen_x: f32 = 0.0,
    screen_y: f32 = 0.0,
    disposed: bool = false,

    pub fn width(self: SpeechBalloon) f32 {
        return @max(self.text_data.width, switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.width(),
        });
    }

    pub fn height(self: SpeechBalloon) f32 {
        return @max(self.text_data.height, switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.height(),
        });
    }

    pub fn texWRaw(self: SpeechBalloon) f32 {
        return @max(self.text_data.width, switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.w,
            .normal => |image_data| return image_data.texWRaw(),
        });
    }

    pub fn texHRaw(self: SpeechBalloon) f32 {
        return @max(self.text_data.height, switch (self.image_data) {
            .nine_slice => |nine_slice| return nine_slice.h,
            .normal => |image_data| return image_data.texHRaw(),
        });
    }

    pub fn add(data: SpeechBalloon) !void {
        var balloon = Temporary{ .balloon = data };
        balloon.balloon.start_time = main.current_time;
        {
            balloon.balloon.text_data.lock.lock();
            defer balloon.balloon.text_data.lock.unlock();

            balloon.balloon.text_data.recalculateAttributes(main.allocator);
        }

        try systems.temp_elements_to_add.append(systems.allocator, balloon);
    }

    pub fn destroy(self: *SpeechBalloon, allocator: std.mem.Allocator) void {
        if (self.disposed)
            return;

        self.disposed = true;

        self.text_data.lock.lock();
        allocator.free(self.text_data.text);
        self.text_data.lock.unlock();

        self.text_data.deinit(allocator);
    }
};

pub const StatusText = struct {
    text_data: TextData,
    initial_size: f32,
    obj_type: network_data.ObjectType,
    map_id: u32,
    lifetime: i64 = 500,
    start_time: i64 = 0,
    delay: i64 = 0,
    visible: bool = true,
    // the texts' internal x/y, don't touch outside of systems.update()
    screen_x: f32 = 0.0,
    screen_y: f32 = 0.0,
    disposed: bool = false,

    pub fn width(self: StatusText) f32 {
        return self.text_data.width;
    }

    pub fn height(self: StatusText) f32 {
        return self.text_data.height;
    }

    pub fn texWRaw(self: StatusText) f32 {
        return self.text_data.width;
    }

    pub fn texHRaw(self: StatusText) f32 {
        return self.text_data.height;
    }

    pub fn add(data: StatusText) !void {
        var status = Temporary{ .status = data };
        status.status.start_time = main.current_time + data.delay;
        {
            status.status.text_data.lock.lock();
            defer status.status.text_data.lock.unlock();

            status.status.text_data.recalculateAttributes(main.allocator);
        }
        try systems.temp_elements_to_add.append(systems.allocator, status);
    }

    pub fn destroy(self: *StatusText, allocator: std.mem.Allocator) void {
        if (self.disposed)
            return;

        self.disposed = true;

        self.text_data.lock.lock();
        allocator.free(self.text_data.text);
        self.text_data.lock.unlock();

        self.text_data.deinit(allocator);
    }
};
