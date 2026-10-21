const std = @import("std");
pub const DevicePointer = u64;
const Handle = ?*anyopaque;
const Init = *const fn (c_uint) callconv(.c) c_int;
const DeviceGet = *const fn (*c_int, c_int) callconv(.c) c_int;
const DeviceName = *const fn ([*]u8, c_int, c_int) callconv(.c) c_int;
const Attribute = *const fn (*c_int, c_int, c_int) callconv(.c) c_int;
const CreateContext = *const fn (*Handle, c_uint, c_int) callconv(.c) c_int;
const DestroyContext = *const fn (Handle) callconv(.c) c_int;
const Allocate = *const fn (*DevicePointer, usize) callconv(.c) c_int;
const Free = *const fn (DevicePointer) callconv(.c) c_int;
const Upload = *const fn (DevicePointer, [*]const u8, usize) callconv(.c) c_int;
const Download = *const fn ([*]u8, DevicePointer, usize) callconv(.c) c_int;
const Zero = *const fn (DevicePointer, u8, usize) callconv(.c) c_int;
const ModuleLoad = *const fn (*Handle, [*:0]const u8) callconv(.c) c_int;
const ModuleUnload = *const fn (Handle) callconv(.c) c_int;
const FunctionGet = *const fn (*Handle, Handle, [*:0]const u8) callconv(.c) c_int;
const Launch = *const fn (Handle, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, Handle, [*]?*anyopaque, ?*anyopaque) callconv(.c) c_int;
const Synchronize = *const fn () callconv(.c) c_int;
const ErrorString = *const fn (c_int, *?[*:0]const u8) callconv(.c) c_int;
const CompileCreate = *const fn (*Handle, [*:0]const u8, [*:0]const u8, c_int, ?[*]const [*:0]const u8, ?[*]const [*:0]const u8) callconv(.c) c_int;
const Compile = *const fn (Handle, c_int, [*]const [*:0]const u8) callconv(.c) c_int;
const CompileSize = *const fn (Handle, *usize) callconv(.c) c_int;
const CompileOutput = *const fn (Handle, [*]u8) callconv(.c) c_int;
const CompileDestroy = *const fn (*Handle) callconv(.c) c_int;

fn symbol(library: *std.DynLib, comptime T: type, name: [:0]const u8) !T {
    return library.lookup(T, name) orelse error.MissingCudaSymbol;
}

pub const Runtime = struct {
    allocator: std.mem.Allocator,
    driver: std.DynLib,
    compiler: std.DynLib,
    context: Handle,
    module: Handle,
    device_name: [256]u8,
    alloc_fn: Allocate,
    free_fn: Free,
    upload_fn: Upload,
    download_fn: Download,
    zero_fn: Zero,
    launch_fn: Launch,
    function_fn: FunctionGet,
    sync_fn: Synchronize,
    destroy_fn: DestroyContext,
    unload_fn: ModuleUnload,
    error_fn: ErrorString,

    pub fn init(allocator: std.mem.Allocator, source: [:0]const u8) !Runtime {
        var driver = std.DynLib.open("libcuda.so.1") catch return error.CudaDriverUnavailable;
        errdefer driver.close();
        var compiler = std.DynLib.open("libnvrtc.so.13") catch return error.CudaCompilerUnavailable;
        errdefer compiler.close();
        try checkRaw(try symbol(&driver, Init, "cuInit"), 0);
        var device: c_int = undefined;
        if ((try symbol(&driver, DeviceGet, "cuDeviceGet"))(&device, 0) != 0) return error.CudaDeviceUnavailable;
        var device_label: [256]u8 = @splat(0);
        if ((try symbol(&driver, DeviceName, "cuDeviceGetName"))(&device_label, device_label.len, device) != 0) return error.CudaDeviceUnavailable;
        if (std.mem.indexOf(u8, &device_label, "B300") == null) return error.RequiredB300Unavailable;
        const attribute = try symbol(&driver, Attribute, "cuDeviceGetAttribute");
        var major: c_int = undefined;
        var minor: c_int = undefined;
        if (attribute(&major, 75, device) != 0 or attribute(&minor, 76, device) != 0) return error.CudaDeviceUnavailable;
        var context: Handle = null;
        const destroy = try symbol(&driver, DestroyContext, "cuCtxDestroy_v2");
        if ((try symbol(&driver, CreateContext, "cuCtxCreate_v2"))(&context, 0, device) != 0) return error.CudaContextCreationFailed;
        errdefer _ = destroy(context);
        var program: Handle = null;
        if ((try symbol(&compiler, CompileCreate, "nvrtcCreateProgram"))(&program, source.ptr, "model_kernels.cu", 0, null, null) != 0) return error.CudaCompilationFailed;
        const compiler_destroy = try symbol(&compiler, CompileDestroy, "nvrtcDestroyProgram");
        defer _ = compiler_destroy(&program);
        const architecture = try std.fmt.allocPrintZ(allocator, "--gpu-architecture=compute_{d}{d}", .{ major, minor });
        defer allocator.free(architecture);
        const options = [_][*:0]const u8{ architecture.ptr, "--std=c++17" };
        const result = (try symbol(&compiler, Compile, "nvrtcCompileProgram"))(program, options.len, &options);
        if (result != 0) {
            var size: usize = 0;
            if ((try symbol(&compiler, CompileSize, "nvrtcGetProgramLogSize"))(program, &size) == 0 and size > 0) {
                const log = try allocator.alloc(u8, size);
                defer allocator.free(log);
                if ((try symbol(&compiler, CompileOutput, "nvrtcGetProgramLog"))(program, log.ptr) == 0) try std.io.getStdErr().writer().writeAll(log);
            }
            return error.CudaCompilationFailed;
        }
        var size: usize = 0;
        if ((try symbol(&compiler, CompileSize, "nvrtcGetPTXSize"))(program, &size) != 0 or size == 0) return error.CudaCompilationFailed;
        const ptx = try allocator.allocSentinel(u8, size, 0);
        defer allocator.free(ptx);
        if ((try symbol(&compiler, CompileOutput, "nvrtcGetPTX"))(program, ptx.ptr) != 0) return error.CudaCompilationFailed;
        var module: Handle = null;
        if ((try symbol(&driver, ModuleLoad, "cuModuleLoadData"))(&module, ptx.ptr) != 0) return error.CudaModuleLoadFailed;
        const unload = try symbol(&driver, ModuleUnload, "cuModuleUnload");
        errdefer _ = unload(module);
        return .{
            .allocator = allocator, .driver = driver, .compiler = compiler, .context = context, .module = module, .device_name = device_label,
            .alloc_fn = try symbol(&driver, Allocate, "cuMemAlloc_v2"), .free_fn = try symbol(&driver, Free, "cuMemFree_v2"),
            .upload_fn = try symbol(&driver, Upload, "cuMemcpyHtoD_v2"), .download_fn = try symbol(&driver, Download, "cuMemcpyDtoH_v2"),
            .zero_fn = try symbol(&driver, Zero, "cuMemsetD8_v2"), .launch_fn = try symbol(&driver, Launch, "cuLaunchKernel"),
            .function_fn = try symbol(&driver, FunctionGet, "cuModuleGetFunction"), .sync_fn = try symbol(&driver, Synchronize, "cuCtxSynchronize"),
            .destroy_fn = destroy, .unload_fn = unload, .error_fn = try symbol(&driver, ErrorString, "cuGetErrorString"),
        };
    }
    fn checkRaw(function: Init, value: c_uint) !void {
        if (function(value) != 0) return error.CudaInitializationFailed;
    }
    fn check(self: *Runtime, result: c_int) !void {
        if (result == 0) return;
        var description: ?[*:0]const u8 = null;
        if (self.error_fn(result, &description) == 0) if (description) |text| {
            std.io.getStdErr().writer().print("CUDA {d}: {s}\n", .{ result, text }) catch {};
        };
        return error.CudaOperationFailed;
    }
    pub fn deinit(self: *Runtime) void {
        _ = self.sync_fn();
        _ = self.unload_fn(self.module);
        _ = self.destroy_fn(self.context);
        self.compiler.close();
        self.driver.close();
    }
    pub fn name(self: *const Runtime) []const u8 { return std.mem.sliceTo(&self.device_name, 0); }
    pub fn allocate(self: *Runtime, bytes: usize) !DevicePointer {
        if (bytes == 0) return error.InvalidTensorShape;
        var pointer: DevicePointer = 0;
        try self.check(self.alloc_fn(&pointer, bytes));
        return pointer;
    }
    pub fn free(self: *Runtime, pointer: DevicePointer) void {
        if (pointer != 0) self.check(self.free_fn(pointer)) catch {};
    }
    pub fn upload(self: *Runtime, destination: DevicePointer, bytes: []const u8) !void { try self.check(self.upload_fn(destination, bytes.ptr, bytes.len)); }
    pub fn download(self: *Runtime, bytes: []u8, source: DevicePointer) !void { try self.check(self.download_fn(bytes.ptr, source, bytes.len)); }
    pub fn zero(self: *Runtime, pointer: DevicePointer, bytes: usize) !void { try self.check(self.zero_fn(pointer, 0, bytes)); }
    pub fn synchronize(self: *Runtime) !void { try self.check(self.sync_fn()); }
    pub fn launch(self: *Runtime, name_value: [:0]const u8, count: usize, arguments: anytype) !void {
        if (count == 0) return error.InvalidKernelLaunch;
        var function: Handle = null;
        try self.check(self.function_fn(&function, self.module, name_value));
        const types = comptime blk: {
            const fields = @typeInfo(@TypeOf(arguments)).@"struct".fields;
            var result: [fields.len]type = undefined;
            for (fields, 0..) |field, i| result[i] = field.type;
            break :blk result;
        };
        var values: std.meta.Tuple(&types) = arguments;
        var pointers: [@typeInfo(@TypeOf(values)).@"struct".fields.len]?*anyopaque = undefined;
        inline for (0..pointers.len) |i| pointers[i] = @ptrCast(&values[i]);
        const blocks = std.math.cast(c_uint, (try std.math.add(usize, count, 127)) / 128) orelse return error.TensorTooLarge;
        try self.check(self.launch_fn(function, blocks, 1, 1, 128, 1, 1, 0, null, &pointers, null));
    }
};
