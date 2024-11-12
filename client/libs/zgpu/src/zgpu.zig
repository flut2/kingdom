//--------------------------------------------------------------------------------------------------
// zgpu is a small helper library built on top of native wgpu implementation (Dawn).
//
// It supports Windows 10+ (DirectX 12), macOS 12+ (Metal) and Linux (Vulkan).
//
// https://github.com/michal-z/zig-gamedev/tree/main/libs/zgpu
//--------------------------------------------------------------------------------------------------
const std = @import("std");
const math = std.math;
const assert = std.debug.assert;
const wgsl = @import("common_wgsl.zig");
const zgpu_options = @import("zgpu_options");
pub const wgpu = @import("wgpu.zig");

test {
    _ = wgpu;
}

pub const WindowProvider = struct {
    window: *anyopaque,
    fn_getTime: *const fn () f64,
    fn_getFramebufferSize: *const fn (window: *const anyopaque) [2]u32,
    fn_getWin32Window: *const fn (window: *const anyopaque) ?*anyopaque = undefined,
    fn_getX11Display: *const fn () ?*anyopaque = undefined,
    fn_getX11Window: *const fn (window: *const anyopaque) u32 = undefined,
    fn_getWaylandDisplay: ?*const fn () ?*anyopaque = null,
    fn_getWaylandSurface: ?*const fn (window: *const anyopaque) ?*anyopaque = null,
    fn_getCocoaWindow: *const fn (window: *const anyopaque) ?*anyopaque = undefined,

    fn getTime(self: WindowProvider) f64 {
        return self.fn_getTime();
    }

    fn getFramebufferSize(self: WindowProvider) [2]u32 {
        return self.fn_getFramebufferSize(self.window);
    }

    fn getWin32Window(self: WindowProvider) ?*anyopaque {
        return self.fn_getWin32Window(self.window);
    }

    fn getX11Display(self: WindowProvider) ?*anyopaque {
        return self.fn_getX11Display();
    }

    fn getX11Window(self: WindowProvider) u32 {
        return self.fn_getX11Window(self.window);
    }

    fn getWaylandDisplay(self: WindowProvider) ?*anyopaque {
        if (self.fn_getWaylandDisplay) |f| {
            return f();
        } else {
            return @as(?*anyopaque, null);
        }
    }

    fn getWaylandSurface(self: WindowProvider) ?*anyopaque {
        if (self.fn_getWaylandSurface) |f| {
            return f(self.window);
        } else {
            return @as(?*anyopaque, null);
        }
    }

    fn getCocoaWindow(self: WindowProvider) ?*anyopaque {
        return self.fn_getCocoaWindow(self.window);
    }
};

pub const GraphicsContextOptions = struct {
    present_mode: wgpu.PresentMode = .fifo,
    required_features: []const wgpu.FeatureName = &.{},
};

pub const GraphicsContext = struct {
    pub const swapchain_format = wgpu.TextureFormat.bgra8_unorm;

    window_provider: WindowProvider,

    stats: FrameStats = .{},

    native_instance: DawnNativeInstance,
    instance: wgpu.Instance,
    device: wgpu.Device,
    queue: wgpu.Queue,
    surface: wgpu.Surface,
    swapchain: wgpu.SwapChain,
    swapchain_descriptor: wgpu.SwapChainDescriptor,

    pub fn create(
        allocator: std.mem.Allocator,
        window_provider: WindowProvider,
        options: GraphicsContextOptions,
    ) !*GraphicsContext {
        dawnProcSetProcs(dnGetProcs());

        const native_instance = dniCreate();
        errdefer dniDestroy(native_instance);

        const instance = dniGetWgpuInstance(native_instance).?;

        const adapter = adapter: {
            const Response = struct {
                status: wgpu.RequestAdapterStatus = .unknown,
                adapter: wgpu.Adapter = undefined,
            };

            const callback = (struct {
                fn callback(
                    status: wgpu.RequestAdapterStatus,
                    adapter: wgpu.Adapter,
                    message: ?[*:0]const u8,
                    userdata: ?*anyopaque,
                ) callconv(.C) void {
                    _ = message;
                    const response = @as(*Response, @ptrCast(@alignCast(userdata)));
                    response.status = status;
                    response.adapter = adapter;
                }
            }).callback;

            var response = Response{};
            instance.requestAdapter(
                .{ .power_preference = .high_performance },
                callback,
                @ptrCast(&response),
            );

            if (response.status != .success) {
                std.log.err("Failed to request GPU adapter (status: {s}).", .{@tagName(response.status)});
                return error.NoGraphicsAdapter;
            }
            break :adapter response.adapter;
        };
        errdefer adapter.release();

        var properties: wgpu.AdapterProperties = undefined;
        properties.next_in_chain = null;
        adapter.getProperties(&properties);
        std.log.info("[zgpu] High-performance device has been selected:", .{});
        std.log.info("[zgpu]   Name: {s}", .{properties.name});
        std.log.info("[zgpu]   Driver: {s}", .{properties.driver_description});
        std.log.info("[zgpu]   Adapter type: {s}", .{@tagName(properties.adapter_type)});
        std.log.info("[zgpu]   Backend type: {s}", .{@tagName(properties.backend_type)});

        const device = device: {
            const Response = struct {
                status: wgpu.RequestDeviceStatus = .unknown,
                device: wgpu.Device = undefined,
            };

            const callback = (struct {
                fn callback(
                    status: wgpu.RequestDeviceStatus,
                    device: wgpu.Device,
                    message: ?[*:0]const u8,
                    userdata: ?*anyopaque,
                ) callconv(.C) void {
                    _ = message;
                    const response = @as(*Response, @ptrCast(@alignCast(userdata)));
                    response.status = status;
                    response.device = device;
                }
            }).callback;

            const toggles = [_][*:0]const u8{"skip_validation"};
            const dawn_toggles = wgpu.DawnTogglesDescriptor{
                .chain = .{ .next = null, .struct_type = .dawn_toggles_descriptor },
                .enabled_toggles_count = toggles.len,
                .enabled_toggles = &toggles,
            };

            var response = Response{};
            adapter.requestDevice(
                wgpu.DeviceDescriptor{
                    .next_in_chain = if (zgpu_options.dawn_skip_validation)
                        @ptrCast(&dawn_toggles)
                    else
                        null,
                    .required_features_count = options.required_features.len,
                    .required_features = options.required_features.ptr,
                },
                callback,
                @ptrCast(&response),
            );

            if (response.status != .success) {
                std.log.err("Failed to request GPU device (status: {s}).", .{@tagName(response.status)});
                return error.NoGraphicsDevice;
            }
            break :device response.device;
        };
        errdefer device.release();

        device.setUncapturedErrorCallback(logUnhandledError, null);

        const surface = createSurfaceForWindow(instance, window_provider);
        errdefer surface.release();

        const framebuffer_size = window_provider.getFramebufferSize();

        const swapchain_descriptor = wgpu.SwapChainDescriptor{
            .label = "zig-gamedev-gctx-swapchain",
            .usage = .{ .render_attachment = true },
            .format = swapchain_format,
            .width = @intCast(framebuffer_size[0]),
            .height = @intCast(framebuffer_size[1]),
            .present_mode = options.present_mode,
        };
        const swapchain = device.createSwapChain(surface, swapchain_descriptor);
        errdefer swapchain.release();

        const gctx = try allocator.create(GraphicsContext);
        gctx.* = .{
            .window_provider = window_provider,
            .native_instance = native_instance,
            .instance = instance,
            .device = device,
            .queue = device.getQueue(),
            .surface = surface,
            .swapchain = swapchain,
            .swapchain_descriptor = swapchain_descriptor,
        };

        return gctx;
    }

    pub fn destroy(gctx: *GraphicsContext, allocator: std.mem.Allocator) void {
        // Wait for the GPU to finish all encoded commands.
        while (gctx.stats.cpu_frame_number != gctx.stats.gpu_frame_number) {
            gctx.device.tick();
        }

        // Wait for all outstanding mapAsync() calls to complete.
        while (true) {
            gctx.device.tick();
            break;
        }

        gctx.surface.release();
        gctx.swapchain.release();
        gctx.queue.release();
        gctx.device.release();
        dniDestroy(gctx.native_instance);
        allocator.destroy(gctx);
    }

    fn gpuWorkDone(status: wgpu.QueueWorkDoneStatus, userdata: ?*anyopaque) callconv(.C) void {
        const gpu_frame_number: *u64 = @ptrCast(@alignCast(userdata));
        gpu_frame_number.* += 1;
        if (status != .success) {
            std.log.err("[zgpu] Failed to complete GPU work (status: {s}).", .{@tagName(status)});
        }
    }

    pub fn submit(gctx: *GraphicsContext, commands: []const wgpu.CommandBuffer, time_sec: f32) void {
        gctx.queue.onSubmittedWorkDone(0, gpuWorkDone, @ptrCast(&gctx.stats.gpu_frame_number));
        gctx.queue.submit(commands);
        gctx.stats.tick(time_sec);
    }

    pub fn present(gctx: *GraphicsContext) enum {
        normal_execution,
        swap_chain_resized,
    } {
        gctx.swapchain.present();

        const fb_size = gctx.window_provider.getFramebufferSize();
        if (gctx.swapchain_descriptor.width != fb_size[0] or
            gctx.swapchain_descriptor.height != fb_size[1])
        {
            if (fb_size[0] != 0 and fb_size[1] != 0) {
                gctx.swapchain_descriptor.width = @intCast(fb_size[0]);
                gctx.swapchain_descriptor.height = @intCast(fb_size[1]);
                gctx.swapchain.release();

                gctx.swapchain = gctx.device.createSwapChain(gctx.surface, gctx.swapchain_descriptor);

                std.log.info(
                    "[zgpu] Window has been resized to: {}x{}.",
                    .{ gctx.swapchain_descriptor.width, gctx.swapchain_descriptor.height },
                );
                return .swap_chain_resized;
            }
        }

        return .normal_execution;
    }
};

// Defined in dawn.cpp
const DawnNativeInstance = ?*opaque {};
const DawnProcsTable = ?*opaque {};
extern fn dniCreate() DawnNativeInstance;
extern fn dniDestroy(dni: DawnNativeInstance) void;
extern fn dniGetWgpuInstance(dni: DawnNativeInstance) ?wgpu.Instance;
extern fn dnGetProcs() DawnProcsTable;

// Defined in Dawn codebase
extern fn dawnProcSetProcs(procs: DawnProcsTable) void;

/// Helper to create a buffer BindGroupLayoutEntry.
pub fn bufferEntry(
    binding: u32,
    visibility: wgpu.ShaderStage,
    binding_type: wgpu.BufferBindingType,
    has_dynamic_offset: bool,
    min_binding_size: u64,
) wgpu.BindGroupLayoutEntry {
    return .{
        .binding = binding,
        .visibility = visibility,
        .buffer = .{
            .binding_type = binding_type,
            .has_dynamic_offset = has_dynamic_offset,
            .min_binding_size = min_binding_size,
        },
    };
}

/// Helper to create a sampler BindGroupLayoutEntry.
pub fn samplerEntry(
    binding: u32,
    visibility: wgpu.ShaderStage,
    binding_type: wgpu.SamplerBindingType,
) wgpu.BindGroupLayoutEntry {
    return .{
        .binding = binding,
        .visibility = visibility,
        .sampler = .{ .binding_type = binding_type },
    };
}

/// Helper to create a texture BindGroupLayoutEntry.
pub fn textureEntry(
    binding: u32,
    visibility: wgpu.ShaderStage,
    sample_type: wgpu.TextureSampleType,
    view_dimension: wgpu.TextureViewDimension,
    multisampled: bool,
) wgpu.BindGroupLayoutEntry {
    return .{
        .binding = binding,
        .visibility = visibility,
        .texture = .{
            .sample_type = sample_type,
            .view_dimension = view_dimension,
            .multisampled = multisampled,
        },
    };
}

/// Helper to create a storage texture BindGroupLayoutEntry.
pub fn storageTextureEntry(
    binding: u32,
    visibility: wgpu.ShaderStage,
    access: wgpu.StorageTextureAccess,
    format: wgpu.TextureFormat,
    view_dimension: wgpu.TextureViewDimension,
) wgpu.BindGroupLayoutEntry {
    return .{
        .binding = binding,
        .visibility = visibility,
        .storage_texture = .{
            .access = access,
            .format = format,
            .view_dimension = view_dimension,
        },
    };
}

/// You may disable async shader compilation for debugging purposes.
const enable_async_shader_compilation = true;

pub fn createWgslShaderModule(
    device: wgpu.Device,
    source: [*:0]const u8,
    label: ?[*:0]const u8,
) wgpu.ShaderModule {
    const wgsl_desc = wgpu.ShaderModuleWGSLDescriptor{
        .chain = .{ .next = null, .struct_type = .shader_module_wgsl_descriptor },
        .code = source,
    };
    const desc = wgpu.ShaderModuleDescriptor{
        .next_in_chain = @ptrCast(&wgsl_desc),
        .label = if (label) |l| l else null,
    };
    return device.createShaderModule(desc);
}

pub fn imageInfoToTextureFormat(num_components: u32, bytes_per_component: u32, is_hdr: bool) wgpu.TextureFormat {
    assert(num_components == 1 or num_components == 2 or num_components == 4);
    assert(bytes_per_component == 1 or bytes_per_component == 2);
    assert(if (is_hdr and bytes_per_component != 2) false else true);

    if (is_hdr) {
        if (num_components == 1) return .r16_float;
        if (num_components == 2) return .rg16_float;
        if (num_components == 4) return .rgba16_float;
    } else {
        if (bytes_per_component == 1) {
            if (num_components == 1) return .r8_unorm;
            if (num_components == 2) return .rg8_unorm;
            if (num_components == 4) return .rgba8_unorm;
        } else {
            // TODO: Looks like wgpu does not support 16 bit unorm formats.
            unreachable;
        }
    }
    unreachable;
}

const FrameStats = struct {
    time: f32 = 0.0,
    delta_time: f32 = 0.0,
    fps_counter: u32 = 0,
    fps: f32 = 0.0,
    average_cpu_time: f32 = 0.0,
    previous_time: f32 = 0.0,
    fps_refresh_time: f32 = 0.0,
    cpu_frame_number: u64 = 0,
    gpu_frame_number: u64 = 0,

    fn tick(stats: *FrameStats, now_secs: f32) void {
        stats.time = now_secs;
        stats.delta_time = @floatCast(stats.time - stats.previous_time);
        stats.previous_time = stats.time;

        if ((stats.time - stats.fps_refresh_time) >= 1.0) {
            const t = stats.time - stats.fps_refresh_time;
            const fps = @as(f32, @floatFromInt(stats.fps_counter)) / t;
            const ms = (1.0 / fps) * 1000.0;

            stats.fps = fps;
            stats.average_cpu_time = ms;
            stats.fps_refresh_time = stats.time;
            stats.fps_counter = 0;
        }
        stats.fps_counter += 1;
        stats.cpu_frame_number += 1;
    }
};

const SurfaceDescriptorTag = enum {
    metal_layer,
    windows_hwnd,
    xlib,
    wayland,
};

const SurfaceDescriptor = union(SurfaceDescriptorTag) {
    metal_layer: struct {
        label: ?[*:0]const u8 = null,
        layer: *anyopaque,
    },
    windows_hwnd: struct {
        label: ?[*:0]const u8 = null,
        hinstance: *anyopaque,
        hwnd: *anyopaque,
    },
    xlib: struct {
        label: ?[*:0]const u8 = null,
        display: *anyopaque,
        window: u32,
    },
    wayland: struct {
        label: ?[*:0]const u8 = null,
        display: *anyopaque,
        surface: *anyopaque,
    },
};

fn isLinuxDesktopLike(tag: std.Target.Os.Tag) bool {
    return switch (tag) {
        .linux,
        .freebsd,
        .openbsd,
        .dragonfly,
        => true,
        else => false,
    };
}

fn createSurfaceForWindow(instance: wgpu.Instance, window_provider: WindowProvider) wgpu.Surface {
    const os_tag = @import("builtin").target.os.tag;

    const descriptor = switch (os_tag) {
        .windows => SurfaceDescriptor{
            .windows_hwnd = .{
                .label = "basic surface",
                .hinstance = std.os.windows.kernel32.GetModuleHandleW(null).?,
                .hwnd = window_provider.getWin32Window().?,
            },
        },
        .macos => macos: {
            const ns_window = window_provider.getCocoaWindow().?;
            const ns_view = msgSend(ns_window, "contentView", .{}, *anyopaque); // [nsWindow contentView]

            // Create a CAMetalLayer that covers the whole window that will be passed to CreateSurface.
            msgSend(ns_view, "setWantsLayer:", .{true}, void); // [view setWantsLayer:YES]
            const layer = msgSend(objc.objc_getClass("CAMetalLayer"), "layer", .{}, ?*anyopaque); // [CAMetalLayer layer]
            if (layer == null) @panic("failed to create Metal layer");
            msgSend(ns_view, "setLayer:", .{layer.?}, void); // [view setLayer:layer]

            // Use retina if the window was created with retina support.
            const scale_factor = msgSend(ns_window, "backingScaleFactor", .{}, f64); // [ns_window backingScaleFactor]
            msgSend(layer.?, "setContentsScale:", .{scale_factor}, void); // [layer setContentsScale:scale_factor]

            break :macos SurfaceDescriptor{
                .metal_layer = .{
                    .label = "basic surface",
                    .layer = layer.?,
                },
            };
        },
        else => if (isLinuxDesktopLike(os_tag)) linux: {
            if (window_provider.getWaylandDisplay()) |wl_display| {
                break :linux SurfaceDescriptor{
                    .wayland = .{
                        .label = "basic surface",
                        .display = wl_display,
                        .surface = window_provider.getWaylandSurface().?,
                    },
                };
            } else {
                break :linux SurfaceDescriptor{
                    .xlib = .{
                        .label = "basic surface",
                        .display = window_provider.getX11Display().?,
                        .window = window_provider.getX11Window(),
                    },
                };
            }
        } else unreachable,
    };

    return switch (descriptor) {
        .metal_layer => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromMetalLayer = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_metal_layer;
            desc.layer = src.layer;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(&desc),
                .label = if (src.label) |l| l else null,
            });
        },
        .windows_hwnd => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromWindowsHWND = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_windows_hwnd;
            desc.hinstance = src.hinstance;
            desc.hwnd = src.hwnd;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(&desc),
                .label = if (src.label) |l| l else null,
            });
        },
        .xlib => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromXlibWindow = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_xlib_window;
            desc.display = src.display;
            desc.window = src.window;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(&desc),
                .label = if (src.label) |l| l else null,
            });
        },
        .wayland => |src| blk: {
            var desc: wgpu.SurfaceDescriptorFromWaylandSurface = undefined;
            desc.chain.next = null;
            desc.chain.struct_type = .surface_descriptor_from_wayland_surface;
            desc.display = src.display;
            desc.surface = src.surface;
            break :blk instance.createSurface(.{
                .next_in_chain = @ptrCast(&desc),
                .label = if (src.label) |l| l else null,
            });
        },
    };
}

const objc = struct {
    const SEL = ?*opaque {};
    const Class = ?*opaque {};

    extern fn sel_getUid(str: [*:0]const u8) SEL;
    extern fn objc_getClass(name: [*:0]const u8) Class;
    extern fn objc_msgSend() void;
};

fn msgSend(obj: anytype, sel_name: [:0]const u8, args: anytype, comptime ReturnType: type) ReturnType {
    const args_meta = @typeInfo(@TypeOf(args)).@"struct".fields;

    const FnType = switch (args_meta.len) {
        0 => *const fn (@TypeOf(obj), objc.SEL) callconv(.C) ReturnType,
        1 => *const fn (@TypeOf(obj), objc.SEL, args_meta[0].type) callconv(.C) ReturnType,
        2 => *const fn (
            @TypeOf(obj),
            objc.SEL,
            args_meta[0].type,
            args_meta[1].type,
        ) callconv(.C) ReturnType,
        3 => *const fn (
            @TypeOf(obj),
            objc.SEL,
            args_meta[0].type,
            args_meta[1].type,
            args_meta[2].type,
        ) callconv(.C) ReturnType,
        4 => *const fn (
            @TypeOf(obj),
            objc.SEL,
            args_meta[0].type,
            args_meta[1].type,
            args_meta[2].type,
            args_meta[3].type,
        ) callconv(.C) ReturnType,
        else => @compileError("[zgpu] Unsupported number of args"),
    };

    const func = @as(FnType, @ptrCast(&objc.objc_msgSend));
    const sel = objc.sel_getUid(sel_name.ptr);

    return @call(.never_inline, func, .{ obj, sel } ++ args);
}

fn logUnhandledError(
    err_type: wgpu.ErrorType,
    message: ?[*:0]const u8,
    userdata: ?*anyopaque,
) callconv(.C) void {
    _ = userdata;
    switch (err_type) {
        .no_error => std.log.info("[zgpu] No error: {?s}", .{message}),
        .validation => std.log.err("[zgpu] Validation: {?s}", .{message}),
        .out_of_memory => std.log.err("[zgpu] Out of memory: {?s}", .{message}),
        .device_lost => std.log.err("[zgpu] Device lost: {?s}", .{message}),
        .internal => std.log.err("[zgpu] Internal error: {?s}", .{message}),
        .unknown => std.log.err("[zgpu] Unknown error: {?s}", .{message}),
    }

    // Exit the process for easier debugging.
    if (@import("builtin").mode == .Debug)
        std.process.exit(1);
}

fn formatToShaderFormat(format: wgpu.TextureFormat) []const u8 {
    // TODO: Add missing formats.
    return switch (format) {
        .rgba8_unorm => "rgba8unorm",
        .rgba8_snorm => "rgba8snorm",
        .rgba16_float => "rgba16float",
        .rgba32_float => "rgba32float",
        else => unreachable,
    };
}
