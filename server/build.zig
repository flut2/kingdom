const std = @import("std");

pub fn build(b: *std.Build) !void {
    const check_step = b.step("check", "Check if app compiles");
    const enable_tracy = b.option(bool, "enable_tracy", "Enable Tracy") orelse false;
    const use_dragonfly = b.option(bool, "use_dragonfly",
        \\Whether to use Dragonfly for the database.
        \\Redis is assumed otherwise, and TTL banning/muting will be permanent across HWIDs, but not accounts.
    ) orelse false;

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    var gen_file = try b.build_root.handle.createFile("src/_gen_behavior_file_dont_use.zig", .{});

    const dir = try b.build_root.handle.openDir("src/logic/behaviors/", .{ .iterate = true });
    var walker = try dir.walk(b.allocator);
    var i: usize = 0;
    while (try walker.next()) |entry| : (i += 1) {
        if (std.mem.endsWith(u8, entry.path, ".zig"))
            try gen_file.writeAll(try std.fmt.allocPrint(b.allocator, "pub const b{} = @import(\"logic/behaviors/{s}\");\n", .{ i, entry.path }));
    }

    inline for (.{ true, false }) |check| {
        const exe = b.addExecutable(.{
            .name = "Kingdom",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
            // .use_lld = check or optimize == .Debug,
            // .use_llvm = check or optimize == .Debug,
        });

        if (check) check_step.dependOn(&exe.step);

        const shared_dep = b.dependency("shared", .{
            .target = target,
            .optimize = optimize,
            .enable_tracy = enable_tracy,
        });
        exe.root_module.linkLibrary(shared_dep.artifact("libuv"));

        exe.root_module.addImport("shared", shared_dep.module("shared"));
        exe.root_module.addImport("rpmalloc", shared_dep.module("rpmalloc"));
        if (enable_tracy) exe.root_module.addImport("tracy", shared_dep.module("tracy"));

        exe.root_module.addImport("httpz", b.dependency("httpz", .{
            .target = target,
            .optimize = optimize,
        }).module("httpz"));

        const hiredis = b.dependency("hiredis", .{});
        const hiredis_path = hiredis.path(".");
        exe.addIncludePath(hiredis_path);
        exe.installHeadersDirectory(hiredis_path, "hiredis", .{ .include_extensions = &.{".h"} });
        exe.linkLibC();
        if (target.result.os.tag == .windows) {
            exe.linkSystemLibrary("ws2_32");
            exe.linkSystemLibrary("crypt32");
            exe.root_module.addCMacro("WIN32_LEAN_AND_MEAN", "");
            exe.root_module.addCMacro("_CRT_SECURE_NO_WARNINGS", "");
            exe.root_module.addCMacro("_WIN32", "");
        }
        exe.addCSourceFiles(.{
            .root = hiredis_path,
            .files = &.{
                "alloc.c",
                "async.c",
                "hiredis.c",
                "net.c",
                "read.c",
                "sds.c",
                "sockcompat.c",
            },
            .flags = &.{
                "-std=c99",
                "-fno-sanitize=undefined",
            },
        });

        var options = b.addOptions();
        options.addOption(bool, "enable_tracy", enable_tracy);
        options.addOption(bool, "use_dragonfly", use_dragonfly);
        options.addOption(usize, "behavs_len", i);
        exe.root_module.addOptions("options", options);

        if (!check) {
            b.installArtifact(exe);

            b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{
                .dest_dir = .{ .override = .{ .custom = "bin" } },
            }).step);

            exe.step.dependOn(&b.addInstallDirectory(.{
                .source_dir = b.path("../assets/shared"),
                .install_dir = .{ .bin = {} },
                .install_subdir = "assets",
            }).step);

            exe.step.dependOn(&b.addInstallDirectory(.{
                .source_dir = b.path("../assets/server"),
                .install_dir = .{ .bin = {} },
                .install_subdir = "assets",
            }).step);

            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| run_cmd.addArgs(args);
            b.step("run", "Run the Kingdom server").dependOn(&run_cmd.step);
        }
    }
}
