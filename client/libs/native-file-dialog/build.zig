const std = @import("std");
const builtin = std.builtin;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("root", .{
        .root_source_file = b.path("src/lib.zig"),
    });

    const lib = b.addStaticLibrary(.{
        .name = "nfd",
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const cflags = [_][]const u8{ "-m64", "-g", "-Wall", "-Wextra", "-fno-exceptions" };
    lib.root_module.addIncludePath(b.path("nfd/src/include"));
    lib.root_module.addCSourceFile(.{ .file = b.path("nfd/src/nfd_common.c"), .flags = &cflags });
    if (target.result.os.tag == .macos) {
        lib.root_module.addCSourceFile(.{ .file = b.path("nfd/src/nfd_cocoa.m"), .flags = &cflags });
    } else if (target.result.os.tag == .windows) {
        lib.root_module.addCSourceFile(.{ .file = b.path("nfd/src/nfd_win.cpp"), .flags = &cflags });
    } else {
        lib.root_module.addCSourceFile(.{ .file = b.path("nfd/src/nfd_gtk.c"), .flags = &cflags });
    }

    lib.linkLibC();
    if (target.result.os.tag == .macos) {
        lib.root_module.linkFramework("AppKit", .{});
        lib.root_module.linkFramework("Foundation", .{});
    } else if (target.result.os.tag == .windows) {
        lib.root_module.linkSystemLibrary("shell32", .{});
        lib.root_module.linkSystemLibrary("ole32", .{});
        lib.root_module.linkSystemLibrary("uuid", .{}); // needed by MinGW
    } else {
        lib.root_module.linkSystemLibrary("atk-1.0", .{});
        lib.root_module.linkSystemLibrary("gdk-3", .{});
        lib.root_module.linkSystemLibrary("gtk-3", .{});
        lib.root_module.linkSystemLibrary("glib-2.0", .{});
        lib.root_module.linkSystemLibrary("gobject-2.0", .{});
    }

    if (target.result.os.tag == .macos) {
        lib.defineCMacro("__kernel_ptr_semantics", "");
    }

    b.installArtifact(lib);
}
