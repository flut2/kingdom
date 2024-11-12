pub const std = @import("std");

pub const Tile = struct {
    ground_id: u16,
    entity_id: u16,
    enemy_id: u16,
    portal_id: u16,
    container_id: u16,
    region_id: u16,
};

pub const Map = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,
    tiles: []Tile,
};

// Tiles field is allocated
pub fn parseMap(file: std.fs.File, allocator: std.mem.Allocator) !Map {
    var dcp = std.compress.zlib.decompressor(file.reader());
    var reader = dcp.reader();

    const version = try reader.readInt(u8, .little);
    if (version != 0)
        std.log.err("Reading map failed, unsupported version: {}", .{version});

    var ret: Map = .{
        .x = try reader.readInt(u16, .little),
        .y = try reader.readInt(u16, .little),
        .w = try reader.readInt(u16, .little),
        .h = try reader.readInt(u16, .little),
        .tiles = undefined,
    };
    ret.tiles = try allocator.alloc(Tile, ret.w * ret.h);

    const tiles = try allocator.alloc(Tile, try reader.readInt(u16, .little));
    for (tiles) |*tile| {
        inline for (@typeInfo(Tile).@"struct".fields) |field| {
            @field(tile, field.name) = try reader.readInt(field.type, .little);
        }
    }

    var i: usize = 0;
    const byte_len = tiles.len <= 256;
    for (0..ret.h) |_| {
        for (0..ret.w) |_| {
            defer i += 1;
            const idx = if (byte_len) try reader.readInt(u8, .little) else try reader.readInt(u16, .little);
            ret.tiles[i] = tiles[idx];
        }
    }

    return ret;
}
