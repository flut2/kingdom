const std = @import("std");
const element = @import("../element.zig");
const assets = @import("../../assets.zig");
const camera = @import("../../camera.zig");
const game_data = @import("shared").game_data;
const map = @import("../../game/map.zig");
const tooltip = @import("tooltip.zig");

const Player = @import("../../game/player.zig").Player;

pub const ItemTooltip = struct {
    root: *element.Container = undefined,
    item: u16 = std.math.maxInt(u16),
    decor: *element.Image = undefined,
    image: *element.Image = undefined,
    item_name: *element.Text = undefined,
    rarity: *element.Text = undefined,
    line_break_one: *element.Image = undefined,
    main_text: *element.Text = undefined,
    line_break_two: *element.Image = undefined,
    footer: *element.Text = undefined,

    main_buffer_front: bool = false,
    footer_buffer_front: bool = false,
    allocator: std.mem.Allocator = undefined,

    pub fn init(self: *ItemTooltip, allocator: std.mem.Allocator) !void {
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
            .image_data = .{ .nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_background_data, 360, 360, 34, 34, 1, 1, 1.0) },
        });

        self.image = try self.root.createChild(element.Image{
            .x = 20 - assets.padding * 4,
            .y = 18 - assets.padding * 4,
            .image_data = .{ .normal = .{ .atlas_data = undefined, .scale_x = 4, .scale_y = 4, .glow = true } },
        });

        self.item_name = try self.root.createChild(element.Text{
            .x = 8 * 4 + 30,
            .y = 10,
            .text_data = .{ .text = "", .size = 16, .text_type = .bold_italic },
        });

        self.rarity = try self.root.createChild(element.Text{
            .x = 8 * 4 + 30,
            .y = self.item_name.text_data.height + 12,
            .text_data = .{
                .text = "",
                .size = 14,
                .color = 0xB3B3B3,
                .max_chars = 64,
                .text_type = .medium_italic,
            },
        });

        const tooltip_line_spacer_top_data = assets.getUiData("tooltip_line_spacer_top", 0);
        self.line_break_one = try self.root.createChild(element.Image{
            .x = 20,
            .y = self.image.y + 40 + 12,
            .image_data = .{
                .nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_top_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0),
            },
        });

        self.main_text = try self.root.createChild(element.Text{
            .x = 10,
            .y = self.line_break_one.y + self.line_break_one.height() - 10,
            .text_data = .{
                .text = "",
                .size = 14,
                .max_width = self.decor.width() - 20,
                .color = 0x9B9B9B,
                // only half of the buffer is used at a time to avoid aliasing, so the max len is half of this
                .max_chars = 2048 * 2,
            },
        });

        const tooltip_line_spacer_bottom_data = assets.getUiData("tooltip_line_spacer_bottom", 0);
        self.line_break_two = try self.root.createChild(element.Image{
            .x = 20,
            .y = self.main_text.y + self.main_text.text_data.height + 11,
            .image_data = .{
                .nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_bottom_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0),
            },
        });

        self.footer = try self.root.createChild(element.Text{
            .x = 10,
            .y = self.line_break_two.y + self.line_break_two.height() - 10,
            .text_data = .{
                .text = "",
                .size = 14,
                .max_width = self.decor.width() - 20,
                .color = 0x9B9B9B,
                // only half of the buffer is used at a time to avoid aliasing, so the max len is half of this
                .max_chars = 256 * 2,
            },
        });
    }

    pub fn deinit(self: *ItemTooltip) void {
        element.destroy(self.root);
    }

    fn getMainBuffer(self: *ItemTooltip) []u8 {
        const buffer_len_half = @divExact(self.main_text.text_data.backing_buffer.len, 2);
        const back_buffer = self.main_text.text_data.backing_buffer[0..buffer_len_half];
        const front_buffer = self.main_text.text_data.backing_buffer[buffer_len_half..];

        if (self.main_buffer_front) {
            self.main_buffer_front = false;
            return front_buffer;
        } else {
            self.main_buffer_front = true;
            return back_buffer;
        }
    }

    fn getFooterBuffer(self: *ItemTooltip) []u8 {
        const buffer_len_half = @divExact(self.footer.text_data.backing_buffer.len, 2);
        const back_buffer = self.footer.text_data.backing_buffer[0..buffer_len_half];
        const front_buffer = self.footer.text_data.backing_buffer[buffer_len_half..];

        if (self.footer_buffer_front) {
            self.footer_buffer_front = false;
            return front_buffer;
        } else {
            self.footer_buffer_front = true;
            return back_buffer;
        }
    }

    pub fn update(self: *ItemTooltip, params: tooltip.ParamsFor(ItemTooltip)) void {
        const left_x = params.x - self.decor.width() - 15;
        const up_y = params.y - self.decor.height() - 15;
        self.root.x = if (left_x < 0) params.x + 15 else left_x;
        self.root.y = if (up_y < 0) params.y + 15 else up_y;

        if (self.item == params.item)
            return;

        self.item = params.item;

        if (game_data.item.from_id.get(@intCast(params.item))) |data| {
            self.decor.image_data.nine_slice.color_intensity = 0;
            self.line_break_one.image_data.nine_slice.color_intensity = 0;
            self.line_break_two.image_data.nine_slice.color_intensity = 0;

            var rarity_text_color: u32 = 0xB3B3B3;
            if (std.mem.eql(u8, data.rarity, "Mythic")) {
                const tooltip_background_data = assets.getUiData("tooltip_background_mythic", 0);
                const tooltip_line_spacer_top_data = assets.getUiData("tooltip_line_spacer_top_mythic", 0);
                const tooltip_line_spacer_bottom_data = assets.getUiData("tooltip_line_spacer_bottom_mythic", 0);
                self.decor.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_background_data, 360, 360, 34, 34, 1, 1, 1.0);
                self.line_break_one.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_top_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
                self.line_break_two.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_bottom_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
                rarity_text_color = 0xB80000;
            } else if (std.mem.eql(u8, data.rarity, "Legendary")) {
                const tooltip_background_data = assets.getUiData("tooltip_background_legendary", 0);
                const tooltip_line_spacer_top_data = assets.getUiData("tooltip_line_spacer_top_legendary", 0);
                const tooltip_line_spacer_bottom_data = assets.getUiData("tooltip_line_spacer_bottom_legendary", 0);
                self.decor.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_background_data, 360, 360, 34, 34, 1, 1, 1.0);
                self.line_break_one.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_top_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
                self.line_break_two.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_bottom_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
                rarity_text_color = 0xE6A100;
            } else if (std.mem.eql(u8, data.rarity, "Epic")) {
                const tooltip_background_data = assets.getUiData("tooltip_background_epic", 0);
                const tooltip_line_spacer_top_data = assets.getUiData("tooltip_line_spacer_top_epic", 0);
                const tooltip_line_spacer_bottom_data = assets.getUiData("tooltip_line_spacer_bottom_epic", 0);
                self.decor.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_background_data, 360, 360, 34, 34, 1, 1, 1.0);
                self.line_break_one.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_top_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
                self.line_break_two.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_bottom_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
                rarity_text_color = 0xA825E6;
            } else if (std.mem.eql(u8, data.rarity, "Rare")) {
                const tooltip_background_data = assets.getUiData("tooltip_background_rare", 0);
                const tooltip_line_spacer_top_data = assets.getUiData("tooltip_line_spacer_top_rare", 0);
                const tooltip_line_spacer_bottom_data = assets.getUiData("tooltip_line_spacer_bottom_rare", 0);
                self.decor.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_background_data, 360, 360, 34, 34, 1, 1, 1.0);
                self.line_break_one.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_top_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
                self.line_break_two.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_bottom_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
                rarity_text_color = 0x2575E6;
            } else {
                const tooltip_background_data = assets.getUiData("tooltip_background", 0);
                const tooltip_line_spacer_top_data = assets.getUiData("tooltip_line_spacer_top", 0);
                const tooltip_line_spacer_bottom_data = assets.getUiData("tooltip_line_spacer_bottom", 0);
                self.decor.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_background_data, 360, 360, 34, 34, 1, 1, 1.0);
                self.line_break_one.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_top_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
                self.line_break_two.image_data.nine_slice = element.NineSliceImageData.fromAtlasData(tooltip_line_spacer_bottom_data, self.decor.width() - 40, 6, 16, 0, 1, 6, 1.0);
            }

            self.rarity.text_data.setText(std.fmt.bufPrint(
                self.rarity.text_data.backing_buffer,
                "{s} {s}",
                .{ data.rarity, data.item_type.toString() },
            ) catch self.rarity.text_data.text, self.allocator);
            self.rarity.text_data.color = rarity_text_color;

            if (assets.atlas_data.get(data.texture.sheet)) |tex_data| {
                self.image.image_data.normal.atlas_data = tex_data[data.texture.index];
                const scale_x = self.image.image_data.normal.scale_x;
                const scale_y = self.image.image_data.normal.scale_y;
                self.image.x = 20 - assets.padding * 4 + (8 * scale_x - self.image.width()) / 2;
                self.image.y = 18 - assets.padding * 4 + (8 * scale_y - self.image.height()) / 2;
            }

            self.item_name.text_data.setText(data.name, self.allocator);

            self.line_break_one.y = self.image.y + 40 + 10;
            self.main_text.y = self.line_break_one.y - 10;

            const line_base = "{s}\n";
            const line_base_inset = line_base ++ "- ";

            const string_fmt = "&col=\"FFFF8F\"{s}&col=\"9B9B9B\"";
            const decimal_fmt = "&col=\"FFFF8F\"{}&col=\"9B9B9B\"";
            const float_fmt = "&col=\"FFFF8F\"{d:.1}&col=\"9B9B9B\"";

            var written_on_use = false;
            var text: []u8 = "";
            if (data.activations) |activation_data| {
                for (activation_data) |activation| {
                    if (!written_on_use) {
                        text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "On Use:", .{text}) catch text;
                        written_on_use = true;
                    }

                    text = switch (activation) {
                        .increment_stat => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Increases " ++ string_fmt ++ " by " ++ decimal_fmt,
                            .{ text, value.toString(), value.amount() },
                        ),
                        .heal => |value| std.fmt.bufPrint(self.getMainBuffer(), line_base_inset ++ "Restores " ++ decimal_fmt ++ " HP", .{ text, value }),
                        .magic => |value| std.fmt.bufPrint(self.getMainBuffer(), line_base_inset ++ "Restores " ++ decimal_fmt ++ " MP", .{ text, value }),
                        .heal_nova => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Restores " ++ decimal_fmt ++ " HP within " ++ float_fmt ++ " tiles",
                            .{ text, value.amount, value.radius },
                        ),
                        .magic_nova => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Restores " ++ decimal_fmt ++ " HP within " ++ float_fmt ++ " tiles",
                            .{ text, value.amount, value.radius },
                        ),
                        .stat_boost_self => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Gain +" ++ decimal_fmt ++ " " ++ string_fmt ++ " for " ++ float_fmt ++ " seconds",
                            .{ text, value.stat_incr.amount(), value.stat_incr.toString(), value.duration },
                        ),
                        .stat_boost_aura => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Grant players +" ++ decimal_fmt ++ " " ++ string_fmt ++ " within " ++ float_fmt ++
                                " tiles for " ++ float_fmt ++ " seconds",
                            .{ text, value.stat_incr.amount(), value.stat_incr.toString(), value.radius, value.duration },
                        ),
                        .condition_effect_self => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Grant yourself " ++ string_fmt ++ " for " ++ float_fmt ++ " seconds",
                            .{ text, value.type.toString(), value.duration },
                        ),
                        .condition_effect_aura => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Grant players " ++ string_fmt ++ " within " ++ float_fmt ++ " tiles for " ++ float_fmt ++ " seconds",
                            .{ text, value.cond.type.toString(), value.radius, value.cond.duration },
                        ),
                        .teleport => std.fmt.bufPrint(self.getMainBuffer(), line_base_inset ++ "Teleport to cursor", .{text}),
                        .spell => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Cast a spell blast of " ++ decimal_fmt ++ " projectiles on your cursor, travelling " ++ float_fmt ++ " tiles and dealing " ++ decimal_fmt ++ " damage",
                            .{ text, value.projectile_count, value.projectile.range(), value.projectile.damage },
                        ),
                        .create_portal => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Opens the following dungeon: " ++ string_fmt,
                            .{ text, value },
                        ),
                        inline .create_enemy, .create_entity => |value| std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Spawn the following: " ++ string_fmt,
                            .{ text, value },
                        ),
                    } catch text;
                }
            }

            if (data.projectile) |proj| {
                text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "Projectiles: " ++ decimal_fmt, .{ text, data.projectile_count }) catch text;
                if (proj.damage > 0)
                    text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "Damage: " ++ decimal_fmt, .{ text, proj.damage }) catch text;
                text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "Range: " ++ float_fmt, .{ text, proj.range() }) catch text;

                if (proj.conditions) |conditions| {
                    for (conditions, 0..) |cond, i| {
                        if (i == 0)
                            text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "Shot effect:", .{text}) catch text;
                        text = std.fmt.bufPrint(
                            self.getMainBuffer(),
                            line_base_inset ++ "Inflict " ++ string_fmt ++ " for " ++ float_fmt ++ " seconds",
                            .{ text, cond.type.toString(), cond.duration },
                        ) catch text;
                    }
                }

                if (data.fire_rate != 1.0)
                    text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "Rate of Fire: " ++ float_fmt ++ "%", .{ text, data.fire_rate * 100 }) catch text;

                if (proj.piercing)
                    text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "Projectiles pierce", .{text}) catch text;
                if (proj.boomerang)
                    text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "Projectiles boomerang", .{text}) catch text;
            }

            if (data.stat_increases) |stat_increases| {
                for (stat_increases, 0..) |incr, i| {
                    if (i == 0)
                        text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "On Equip: ", .{text}) catch text;

                    const amount = incr.amount();
                    if (amount > 0) {
                        text = std.fmt.bufPrint(
                            self.getMainBuffer(),
                            "{s}+" ++ decimal_fmt ++ " {s}{s}",
                            .{ text, amount, incr.toControlCode(), if (i == stat_increases.len - 1) "" else ", " },
                        ) catch text;
                    } else {
                        text = std.fmt.bufPrint(
                            self.getMainBuffer(),
                            "{s}" ++ decimal_fmt ++ " {s}{s}",
                            .{ text, amount, incr.toControlCode(), if (i == stat_increases.len - 1) "" else ", " },
                        ) catch text;
                    }
                }
            }

            if (data.mana_cost != 0)
                text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "Cost: " ++ decimal_fmt ++ " MP", .{ text, data.mana_cost }) catch text;

            if (data.activations != null and data.cooldown > 0.0)
                text = std.fmt.bufPrint(self.getMainBuffer(), line_base ++ "Cooldown: " ++ float_fmt ++ " seconds", .{ text, data.cooldown }) catch text;

            self.main_text.text_data.setText(text, self.allocator);

            self.line_break_two.y = self.main_text.y + self.main_text.text_data.height + 5;
            self.footer.y = self.line_break_two.y - 10;

            var footer_text: []u8 = "";
            if (data.untradeable)
                footer_text = std.fmt.bufPrint(self.getFooterBuffer(), line_base ++ "Can not be traded", .{footer_text}) catch footer_text;

            if (data.item_type == .accessory) {
                footer_text = std.fmt.bufPrint(self.getFooterBuffer(), line_base ++ "Usable by: " ++ string_fmt, .{ footer_text, "All Classes" }) catch footer_text;
            } else if (data.item_type != .any and data.item_type != .consumable) {
                var lock = map.useLockForType(Player);
                lock.lock();
                defer lock.unlock();
                if (map.localPlayerConst()) |player| {
                    const has_type = blk: {
                        for (player.data.item_types) |item_type| {
                            if (item_type != .any and item_type.typesMatch(data.item_type))
                                break :blk true;
                        }

                        break :blk false;
                    };

                    if (!has_type) {
                        footer_text = std.fmt.bufPrint(
                            self.getFooterBuffer(),
                            line_base ++ "&col=\"D00000\"Not usable by: " ++ string_fmt,
                            .{ footer_text, player.data.name },
                        ) catch footer_text;

                        self.decor.image_data.nine_slice.color = 0x8B0000;
                        self.decor.image_data.nine_slice.color_intensity = 0.4;

                        self.line_break_one.image_data.nine_slice.color = 0x8B0000;
                        self.line_break_one.image_data.nine_slice.color_intensity = 0.4;

                        self.line_break_two.image_data.nine_slice.color = 0x8B0000;
                        self.line_break_two.image_data.nine_slice.color_intensity = 0.4;
                    } else {
                        footer_text = std.fmt.bufPrint(self.getFooterBuffer(), line_base ++ "Usable by: ", .{footer_text}) catch footer_text;

                        var first = true;
                        var class_iter = game_data.class.from_id.valueIterator();
                        typesMatch: while (class_iter.next()) |class| {
                            for (class.item_types) |item_type| {
                                if (item_type != .any and item_type.typesMatch(data.item_type)) {
                                    if (first) {
                                        footer_text = std.fmt.bufPrint(self.getFooterBuffer(), "{s}" ++ string_fmt, .{ footer_text, class.name }) catch footer_text;
                                    } else {
                                        footer_text = std.fmt.bufPrint(self.getFooterBuffer(), "{s}, " ++ string_fmt, .{ footer_text, class.name }) catch footer_text;
                                    }

                                    first = false;
                                    continue :typesMatch;
                                }
                            }
                        }
                    }
                }
            }

            if (data.consumable)
                footer_text = std.fmt.bufPrint(self.getFooterBuffer(), line_base ++ "Consumed on use", .{footer_text}) catch footer_text;

            self.footer.text_data.setText(footer_text, self.allocator);

            if (footer_text.len == 0) {
                self.line_break_two.visible = false;
                self.decor.image_data.nine_slice.h = self.line_break_two.y + 5;
            } else {
                self.line_break_two.visible = true;
                self.decor.image_data.nine_slice.h = self.footer.y + self.footer.text_data.height + 10;
            }

            self.root.x = params.x - self.decor.width() - 15;
            self.root.y = params.y - self.decor.height() - 15;
        }
    }
};
