const std = @import("std");
const builtin = @import("builtin");

const LIBUV_SOURCES = [_][]const u8{
    "src/fs-poll.c",
    "src/idna.c",
    "src/inet.c",
    "src/random.c",
    "src/strscpy.c",
    "src/thread-common.c",
    "src/threadpool.c",
    "src/timer.c",
    "src/uv-common.c",
    "src/uv-data-getter-setters.c",
    "src/version.c",
    "src/strtok.c",
};

const LIBUV_SOURCES_WINDOWS = [_][]const u8{
    "src/win/async.c",
    "src/win/core.c",
    "src/win/detect-wakeup.c",
    "src/win/dl.c",
    "src/win/error.c",
    "src/win/fs.c",
    "src/win/fs-event.c",
    "src/win/getaddrinfo.c",
    "src/win/getnameinfo.c",
    "src/win/handle.c",
    "src/win/loop-watcher.c",
    "src/win/pipe.c",
    "src/win/poll.c",
    "src/win/process.c",
    "src/win/process-stdio.c",
    "src/win/signal.c",
    "src/win/snprintf.c",
    "src/win/stream.c",
    "src/win/tcp.c",
    "src/win/thread.c",
    "src/win/tty.c",
    "src/win/udp.c",
    "src/win/util.c",
    "src/win/winapi.c",
    "src/win/winsock.c",
};

const LIBUV_DEFINITIONS_WINDOWS = [_][]const u8{
    "-D_WIN32",
    "-DWIN32_LEAN_AND_MEAN",
    "-D_WIN32_WINNT=0x0602",
    "-D_CRT_DECLARE_NONSTDC_NAMES=0",
};

const LIBUV_LIBS_WINDOWS = [_][]const u8{
    "psapi",
    "user32",
    "advapi32",
    "iphlpapi",
    "userenv",
    "ws2_32",
    "dbghelp",
    "ole32",
    "shell32",
};

const LIBUV_SOURCES_UNIX = [_][]const u8{
    "src/unix/async.c",
    "src/unix/core.c",
    "src/unix/dl.c",
    "src/unix/fs.c",
    "src/unix/getaddrinfo.c",
    "src/unix/getnameinfo.c",
    "src/unix/loop-watcher.c",
    "src/unix/loop.c",
    "src/unix/pipe.c",
    "src/unix/poll.c",
    "src/unix/process.c",
    "src/unix/random-devurandom.c",
    "src/unix/signal.c",
    "src/unix/stream.c",
    "src/unix/tcp.c",
    "src/unix/thread.c",
    "src/unix/tty.c",
    "src/unix/udp.c",
    "src/unix/proctitle.c",
};

const LIBUV_DEFINITIONS_UNIX = [_][]const u8{
    // "-D_FILE_OFFSET_BITS=64",
    "-D_LARGEFILE_SOURCE",
};

const LIBUV_DEFINITIONS_APPLE = [_][]const u8{
    "-D_DARWIN_UNLIMITED_SELECT=1",
    "-D_DARWIN_USE_64_BIT_INODE=1",
};

const LIBUV_DEFINITIONS_LINUX = [_][]const u8{
    "-D_GNU_SOURCE",
};

const LIBUV_LIBS_LINUX = [_][]const u8{
    "dl", "rt",
};

const LIBUV_LIBS_UNIX = [_][]const u8{};

const LIBUV_SOURCES_LINUX = [_][]const u8{
    "src/unix/linux.c",
    "src/unix/proctitle.c",
    "src/unix/procfs-exepath.c",
    "src/unix/random-getrandom.c",
    "src/unix/random-sysctl-linux.c",
};

const LIBUV_SOURCES_APPLE = [_][]const u8{
    "src/unix/darwin-proctitle.c",
    "src/unix/darwin.c",
    "src/unix/fsevents.c",
    "src/unix/kqueue.c",
    "src/unix/proctitle.c",
    "src/unix/bsd-ifaddrs.c",
    "src/unix/random-getentropy.c",
};

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addModule("shared", .{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = optimize == .ReleaseFast or optimize == .ReleaseSmall,
        // .use_lld = optimize != .Debug,
        // .use_llvm = optimize != .Debug,
    });

    const libuv = b.addStaticLibrary(.{
        .name = "libuv",
        .root_source_file = b.path("src/" ++ switch (builtin.os.tag) {
            .windows => "uv_win.zig",
            .linux => "uv_linux.zig",
            .macos => "uv_mac.zig",
            else => @compileError("Unsupported OS"),
        }),
        .target = target,
        .optimize = optimize,
    });
    const libuv_dep = b.dependency("libuv", .{});

    inline for (.{ libuv_dep.path("include"), libuv_dep.path("src") }) |include_path| libuv.addIncludePath(include_path);
    for (switch (builtin.os.tag) {
        .windows => LIBUV_LIBS_WINDOWS,
        .linux => LIBUV_LIBS_LINUX ++ LIBUV_LIBS_UNIX,
        else => LIBUV_LIBS_UNIX,
    }) |lib_name| libuv.linkSystemLibrary(lib_name);
    libuv.linkLibC();
    libuv.addCSourceFiles(.{
        .root = libuv_dep.path("."),
        .files = &switch (builtin.os.tag) {
            .windows => LIBUV_SOURCES ++ LIBUV_SOURCES_WINDOWS,
            .linux => LIBUV_SOURCES ++ LIBUV_SOURCES_LINUX ++ LIBUV_SOURCES_UNIX,
            .macos => LIBUV_SOURCES ++ LIBUV_SOURCES_APPLE ++ LIBUV_SOURCES_UNIX,
            else => @compileError("Unsupported OS"),
        },
        .flags = &switch (builtin.os.tag) {
            .windows => LIBUV_DEFINITIONS_WINDOWS,
            .linux => LIBUV_DEFINITIONS_LINUX ++ LIBUV_DEFINITIONS_UNIX,
            .macos => LIBUV_DEFINITIONS_APPLE ++ LIBUV_DEFINITIONS_UNIX,
            else => @compileError("Unsupported OS"),
        },
    });
    b.installArtifact(libuv);

    const enable_tracy = b.option(bool, "enable_tracy", "Enable Tracy") orelse false;
    if (enable_tracy) {
        const tracy_dep = b.dependency("ztracy", .{
            .target = target,
            .optimize = optimize,
            .enable_ztracy = true,
        });
        b.modules.put(b.dupe("tracy"), tracy_dep.module("root")) catch @panic("OOM");
        lib.linkLibrary(tracy_dep.artifact("tracy"));
        lib.link_libcpp = true;
    }
}
