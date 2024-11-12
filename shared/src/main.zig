pub const utils = @import("utils.zig");
pub const requests = @import("requests.zig");
pub const game_data = @import("game_data.zig");
pub const network_data = @import("network_data.zig");
pub const map_data = @import("map_data.zig");
pub const uv = switch (@import("builtin").os.tag) {
    .windows => @import("uv_win.zig"),
    .linux => @import("uv_linux.zig"),
    .macos => @import("uv_mac.zig"),
    else => @compileError("Unsupported OS"),
};