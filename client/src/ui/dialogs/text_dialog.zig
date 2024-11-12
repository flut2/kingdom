const std = @import("std");
const element = @import("../element.zig");
const assets = @import("../../assets.zig");
const dialog = @import("dialog.zig");

const NineSlice = element.NineSliceImageData;
const Interactable = element.InteractableImageData;

const width = 300;
const height = 200;
const button_w = 100;
const button_h = 30;

pub const TextDialog = struct {
    root: *element.Container = undefined,
    title_decor: *element.Image = undefined,
    title_text: *element.Text = undefined,
    base_decor: *element.Image = undefined,
    base_text: *element.Text = undefined,
    close_button: *element.Button = undefined,
    dispose_title: bool = false,
    dispose_body: bool = false,

    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *TextDialog, allocator: std.mem.Allocator) !void {
        self.allocator = allocator;

        self.root = try element.create(allocator, element.Container{
            .visible = false,
            .layer = .dialog,
            .x = 0,
            .y = 0,
        });

        const base_data = assets.getUiData("dialog_base_background", 0);
        self.base_decor = try self.root.createChild(element.Image{
            .x = 0,
            .y = 0,
            .image_data = .{
                .nine_slice = NineSlice.fromAtlasData(base_data, width, height, 6, 6, 2, 2, 1.0),
            },
        });

        self.base_text = try self.root.createChild(element.Text{
            .x = 5,
            .y = 5,
            .text_data = .{
                .text = "",
                .size = 16,
                .hori_align = .middle,
                .vert_align = .middle,
                .max_width = width - 10,
                .max_height = height - button_h - 15 - 10,
            },
        });

        const title_data = assets.getUiData("dialog_title_background", 0);
        self.title_decor = try self.root.createChild(element.Image{
            .x = 0,
            .y = 0,
            .image_data = .{
                .nine_slice = NineSlice.fromAtlasData(title_data, 0, 0, 6, 11, 2, 2, 1.0),
            },
        });

        self.title_text = try self.root.createChild(element.Text{
            .x = 0,
            .y = 0,
            .text_data = .{
                .text = "",
                .size = 22,
                .hori_align = .middle,
                .vert_align = .middle,
                .text_type = .bold_italic,
            },
        });

        const button_data_base = assets.getUiData("button_base", 0);
        const button_data_hover = assets.getUiData("button_hover", 0);
        const button_data_press = assets.getUiData("button_press", 0);

        self.close_button = try self.root.createChild(element.Button{
            .x = (width - button_w) / 2.0,
            .y = height - button_h - 15,
            .image_data = Interactable.fromNineSlices(button_data_base, button_data_hover, button_data_press, button_w, button_h, 26, 21, 3, 3, 1.0),
            .text_data = .{
                .text = "Ok",
                .size = 16,
                .text_type = .bold,
            },
            .press_callback = closeDialog,
        });
    }

    fn closeDialog(_: ?*anyopaque) void {
        dialog.showDialog(.none, {});
    }

    pub fn deinit(self: *TextDialog) void {
        if (self.dispose_body)
            self.allocator.free(self.base_text.text_data.text);

        if (self.dispose_title)
            self.allocator.free(self.title_text.text_data.text);

        element.destroy(self.root);
    }

    pub fn setValues(self: *TextDialog, params: dialog.ParamsFor(TextDialog)) void {
        if (self.dispose_body)
            self.allocator.free(self.base_text.text_data.text);

        if (self.dispose_title)
            self.allocator.free(self.title_text.text_data.text);

        if (params.title) |title| {
            self.title_text.text_data.setText(title, self.allocator);
            switch (self.title_decor.image_data) {
                .nine_slice => |*nine_slice| {
                    nine_slice.w = self.title_text.width() + 25 * 2;
                    nine_slice.h = self.title_text.height() + 10 * 2;
                },
                .normal => |*image_data| {
                    image_data.scale_x = (self.title_text.width() + 25 * 2) / image_data.width();
                    image_data.scale_y = (self.title_text.height() + 10 * 2) / image_data.height();
                },
            }

            self.title_decor.x = (width - self.title_decor.width()) / 2.0;
            self.title_decor.y = -self.title_decor.height() + 6;
            self.title_text.x = self.title_decor.x;
            self.title_text.y = self.title_decor.y;
            self.title_text.text_data.max_width = self.title_decor.width();
            self.title_text.text_data.max_height = self.title_decor.height();
        }

        self.base_text.text_data.setText(params.body, self.allocator);

        self.dispose_title = params.title != null and params.dispose_title;
        self.dispose_body = params.dispose_body;
    }
};
