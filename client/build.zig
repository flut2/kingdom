const std = @import("std");

pub const PacketLogType = enum {
    all,
    all_non_tick,
    all_tick,
    c2s,
    c2s_non_tick,
    c2s_tick,
    s2c,
    s2c_non_tick,
    s2c_tick,
    off,
};

pub fn build(b: *std.Build) !void {
    const check_step = b.step("check", "Check if app compiles");
    const enable_tracy = b.option(bool, "enable_tracy", "Enables Tracy integration") orelse false;
    const log_packets = b.option(PacketLogType, "log_packets", "Toggles various packet logging modes") orelse .off;
    const version = b.option([]const u8, "version", "Build version, for the version text and client-server version checks") orelse "1.0";
    const login_server_uri = b.option([]const u8, "login_server_uri", "The URI of the login server") orelse "http://127.0.0.1:2833/";

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

        var options = b.addOptions();
        options.addOption(bool, "enable_tracy", enable_tracy);
        options.addOption(PacketLogType, "log_packets", log_packets);
        options.addOption([]const u8, "version", version);
        options.addOption([]const u8, "login_server_uri", login_server_uri);
        exe.root_module.addOptions("options", options);

        const shared_dep = b.dependency("shared", .{
            .target = target,
            .optimize = optimize,
            .enable_tracy = enable_tracy,
        });
        exe.root_module.linkLibrary(shared_dep.artifact("libuv"));

        if (optimize != .Debug) {
            const rpmalloc_dep = b.dependency("rpmalloc", .{
                .target = target,
                .optimize = optimize,
            });
            exe.root_module.addImport("rpmalloc", rpmalloc_dep.module("rpmalloc"));
            exe.root_module.linkLibrary(rpmalloc_dep.artifact("rpmalloc-lib"));
        }

        exe.root_module.addImport("shared", shared_dep.module("shared"));
        if (enable_tracy) exe.root_module.addImport("tracy", shared_dep.module("tracy"));

        exe.root_module.addImport("turbopack", b.dependency("turbopack", .{
            .target = target,
            .optimize = optimize,
        }).module("turbopack"));

        exe.root_module.addImport("rpc", b.dependency("discord_rpc", .{}).module("root"));

        @import("system_sdk").addLibraryPathsTo(exe);
        @import("zgpu").addLibraryPathsTo(exe);
        const zgpu = b.dependency("zgpu", .{ .dawn_skip_validation = optimize != .Debug });
        exe.root_module.addImport("zgpu", zgpu.module("root"));
        exe.linkLibrary(zgpu.artifact("zdawn"));

        const zglfw_dep = b.dependency("zglfw", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zglfw", zglfw_dep.module("root"));
        exe.linkLibrary(zglfw_dep.artifact("glfw"));

        const zstbi_dep = b.dependency("zstbi", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zstbi", zstbi_dep.module("root"));
        exe.linkLibrary(zstbi_dep.artifact("zstbi"));

        const zaudio_dep = b.dependency("zaudio", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("zaudio", zaudio_dep.module("root"));
        exe.linkLibrary(zaudio_dep.artifact("miniaudio"));

        const nfd_dep = b.dependency("native_file_dialog", .{
            .target = target,
            .optimize = optimize,
        });
        exe.root_module.addImport("nfd", nfd_dep.module("root"));
        exe.linkLibrary(nfd_dep.artifact("nfd"));

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
                .source_dir = b.path("../assets/client"),
                .install_dir = .{ .bin = {} },
                .install_subdir = "assets",
            }).step);

            const run_cmd = b.addRunArtifact(exe);
            run_cmd.step.dependOn(b.getInstallStep());
            if (b.args) |args| run_cmd.addArgs(args);
            b.step("run", "Run the Kingdom client").dependOn(&run_cmd.step);
        }
    }
}
