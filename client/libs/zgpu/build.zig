const std = @import("std");
const log = std.log.scoped(.zgpu);

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const target = b.standardTargetOptions(.{});

    const skip_validation = b.option(
        bool,
        "dawn_skip_validation",
        "Disable Dawn validation",
    ) orelse true;

    const options = b.addOptions();
    options.addOption(bool, "dawn_skip_validation", skip_validation);

    const options_module = options.createModule();

    _ = b.addModule("root", .{
        .root_source_file = b.path("src/zgpu.zig"),
        .imports = &.{
            .{ .name = "zgpu_options", .module = options_module },
        },
    });

    const zdawn = b.addStaticLibrary(.{
        .name = "zdawn",
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(zdawn);

    @import("system_sdk").addLibraryPathsTo(zdawn);

    addLibraryPathsTo(zdawn);
    linkSystemDeps(zdawn);

    zdawn.linkSystemLibrary("dawn");
    zdawn.linkLibC();
    zdawn.linkLibCpp();

    zdawn.addIncludePath(b.path("libs/dawn/include"));
    zdawn.addIncludePath(b.path("src"));

    zdawn.addCSourceFile(.{
        .file = b.path("src/dawn.cpp"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined" },
    });
    zdawn.addCSourceFile(.{
        .file = b.path("src/dawn_proc.c"),
        .flags = &.{"-fno-sanitize=undefined"},
    });

    const test_step = b.step("test", "Run zgpu tests");

    const tests = b.addTest(.{
        .name = "zgpu-tests",
        .root_source_file = b.path("src/zgpu.zig"),
        .target = target,
        .optimize = optimize,
    });
    @import("system_sdk").addLibraryPathsTo(tests);
    tests.addIncludePath(b.path("libs/dawn/include"));
    tests.linkLibrary(zdawn);
    addLibraryPathsTo(tests);
    linkSystemDeps(tests);
    b.installArtifact(tests);

    test_step.dependOn(&b.addRunArtifact(tests).step);
}

pub fn linkSystemDeps(compile_step: *std.Build.Step.Compile) void {
    switch (compile_step.rootModuleTarget().os.tag) {
        .windows => {
            compile_step.linkSystemLibrary("ole32");
            compile_step.linkSystemLibrary("dxguid");
        },
        .macos => {
            compile_step.linkSystemLibrary("objc");
            compile_step.linkFramework("Metal");
            compile_step.linkFramework("CoreGraphics");
            compile_step.linkFramework("Foundation");
            compile_step.linkFramework("IOKit");
            compile_step.linkFramework("IOSurface");
            compile_step.linkFramework("QuartzCore");
        },
        else => {},
    }
}

pub fn addLibraryPathsTo(compile_step: *std.Build.Step.Compile) void {
    const b = compile_step.step.owner;
    const target = compile_step.rootModuleTarget();
    switch (target.os.tag) {
        .windows => {
            compile_step.addLibraryPath(b.dependency("dawn_x86_64_windows_gnu", .{}).path(""));
        },
        .linux => {
            compile_step.addLibraryPath(b.dependency(if (target.cpu.arch.isX86()) "dawn_x86_64_linux_gnu" else "dawn_aarch64_linux_gnu", .{}).path(""));
        },
        .macos => {
            compile_step.addLibraryPath(b.dependency(if (target.cpu.arch.isX86()) "dawn_x86_64_macos" else "dawn_aarch64_macos", .{}).path(""));
        },
        else => {},
    }
}

pub fn checkTargetSupported(target: std.Target) bool {
    const supported = switch (target.os.tag) {
        .windows => target.cpu.arch.isX86() and target.abi.isGnu(),
        .linux => (target.cpu.arch.isX86() or target.cpu.arch.isAARCH64()) and target.abi.isGnu(),
        .macos => blk: {
            if (!target.cpu.arch.isX86() and !target.cpu.arch.isAARCH64()) break :blk false;

            // If min. target macOS version is lesser than the min version we have available, then
            // our Dawn binary is incompatible with the target.
            if (target.os.version_range.semver.min.order(
                .{ .major = 12, .minor = 0, .patch = 0 },
            ) == .lt) break :blk false;
            break :blk true;
        },
        else => false,
    };
    if (supported == false) {
        log.warn("\n" ++
            \\---------------------------------------------------------------------------
            \\
            \\Dawn/WebGPU binary for this target is not available.
            \\
            \\Following targets are supported:
            \\
            \\x86_64-windows-gnu
            \\x86_64-linux-gnu
            \\x86_64-macos.12.0.0-none
            \\aarch64-linux-gnu
            \\aarch64-macos.12.0.0-none
            \\
            \\---------------------------------------------------------------------------
            \\
        , .{});
    }
    return supported;
}
