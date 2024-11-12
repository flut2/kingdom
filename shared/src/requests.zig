const std = @import("std");

const u16_max = std.math.maxInt(u16);

var arena: std.heap.ArenaAllocator = undefined;
var allocator: std.mem.Allocator = undefined;
var client: std.http.Client = undefined;

pub fn init(ally: std.mem.Allocator) void {
    arena = std.heap.ArenaAllocator.init(ally);
    allocator = arena.allocator();
    client = .{ .allocator = allocator };
}

pub fn deinit() void {
    client.deinit();
    arena.deinit();
}

pub fn sendRequest(uri: []const u8, values: std.StringHashMapUnmanaged([]const u8)) ![]const u8 {
    const header_buffer = try allocator.alloc(u8, std.math.maxInt(u12));
    defer allocator.free(header_buffer);

    var mod_uri: std.ArrayListUnmanaged(u8) = .{};
    defer mod_uri.deinit(allocator);

    var mod_uri_writer = mod_uri.writer(allocator);
    var iter = values.iterator();
    var idx: usize = 0;
    _ = try mod_uri_writer.writeAll(uri);
    _ = try mod_uri_writer.write("?");
    while (iter.next()) |entry| : (idx += 1) {
        try mod_uri_writer.writeAll(entry.key_ptr.*);
        try mod_uri_writer.writeAll("=");
        try mod_uri_writer.writeAll(entry.value_ptr.*);
        if (idx < values.count() - 1) {
            try mod_uri_writer.writeAll("&");
        }
    }

    var req = client.open(.POST, try std.Uri.parse(mod_uri.items), .{ .server_header_buffer = header_buffer }) catch |e| {
        std.log.err("Could not send {s}: {}", .{ uri, e });
        return e;
    };
    defer req.deinit();

    req.transfer_encoding = .chunked;
    try req.send();
    try req.finish();
    try req.wait();

    const body_buffer = try allocator.alloc(u8, std.math.maxInt(u12));
    const len = try req.readAll(body_buffer);
    return try allocator.realloc(body_buffer, len);
}

pub fn freeResponse(buf: []const u8) void {
    allocator.free(buf);
}
