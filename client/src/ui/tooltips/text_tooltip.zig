const std = @import("std");
const element = @import("../element.zig");
const assets = @import("../../assets.zig");
const camera = @import("../../camera.zig");
const game_data = @import("shared").game_data;
const map = @import("../../game/map.zig");
const tooltip = @import("tooltip.zig");

const NineSlice = element.NineSliceImageData;

pub const TextTooltip = struct {
    root: *element.Container = undefined,
    decor: *element.Image = undefined,
    text: *element.Text = undefined,

    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *TextTooltip, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;

        self.root = try element.create(allocator, element.Container{
            .visible = false,
            .layer = .tooltip,
            .x = 0,
            .y = 0,
        });

        const tooltip_background_data = assets.getUiData("tooltip_background", 0);
        self.decor = try self.root.createChild(element.Image{
            .x = 0,
            .y = 0,
            .image_data = .{ .nine_slice = NineSlice.fromAtlasData(tooltip_background_data, 0, 0, 34, 34, 1, 1, 1.0) },
        });

        self.text = try self.root.createChild(element.Text{
            .x = 16,
            .y = 16,
            .text_data = .{ .text = "", .size = 0 },
        });

        self.text.text_data.lock.lock();
        defer self.text.text_data.lock.unlock();

        self.text.text_data.recalculateAttributes(self.allocator);
    }

    pub fn deinit(self: *TextTooltip) void {
        element.destroy(self.root);
    }

    pub fn update(self: *TextTooltip, params: tooltip.ParamsFor(TextTooltip)) void {
        inline for (@typeInfo(element.TextData).@"struct".fields) |field| {
            comptime if (std.mem.eql(u8, field.name, "backing_buffer") or
                std.mem.eql(u8, field.name, "line_widths") or
                std.mem.eql(u8, field.name, "break_indices") or
                std.mem.eql(u8, field.name, "lock")) continue;

            @field(self.text.text_data, field.name) = @field(params.text_data, field.name);
        }

        {
            self.text.text_data.lock.lock();
            defer self.text.text_data.lock.unlock();

            self.text.text_data.recalculateAttributes(self.allocator);
        }

        switch (self.decor.image_data) {
            .nine_slice => |*nine_slice| {
                nine_slice.w = self.text.width() + 16 * 2;
                nine_slice.h = self.text.height() + 16 * 2;
            },
            .normal => |*image_data| {
                image_data.scale_x = (self.text.width() + 16 * 2) / image_data.width();
                image_data.scale_y = (self.text.height() + 16 * 2) / image_data.height();
            },
        }

        const left_x = params.x - self.decor.width() - 15;
        const up_y = params.y - self.decor.height() - 15;
        self.root.x = if (left_x < 0) params.x + 15 else left_x;
        self.root.y = if (up_y < 0) params.y + 15 else up_y;
    }
};
