//! GPU Kernel Interface - Zig bindings for CUDA via dlopen
//!
//! Uses dlopen to load CUDA libraries at runtime, avoiding cImport issues
//! with CUDA's complex C++ headers.

const std = @import("std");
const work_unit = @import("work_unit");

// ==================== CUDA Types ====================

const CUresult = c_int;
const CUdevice = c_int;
const CUcontext = ?*anyopaque;
const CUmodule = ?*anyopaque;
const CUfunction = ?*anyopaque;
const CUdeviceptr = u64;
const CUstream = ?*anyopaque;

const cudaError_t = c_int;
const nvrtcResult = c_int;
const nvrtcProgram = ?*anyopaque;

const CUDA_SUCCESS: CUresult = 0;
const cudaSuccess: cudaError_t = 0;
const NVRTC_SUCCESS: nvrtcResult = 0;

const cudaMemcpyHostToDevice: c_int = 1;
const cudaMemcpyDeviceToHost: c_int = 2;

// ==================== Error Types ====================

pub const CudaError = error{
    CudaNotFound,
    CudaRuntimeNotFound,
    NvrtcNotFound,
    InitializationFailed,
    DeviceNotFound,
    OutOfMemory,
    InvalidDevice,
    KernelLaunchFailed,
    KernelCompilationFailed,
    MemcpyFailed,
    SyncFailed,
    InvalidKernel,
    NvrtcError,
    FunctionNotFound,
};

// ==================== Function Pointer Types ====================

const CuInitFn = *const fn (c_uint) callconv(.c) CUresult;
const CuDeviceGetCountFn = *const fn (*c_int) callconv(.c) CUresult;
const CuCtxCreateFn = *const fn (*CUcontext, c_uint, CUdevice) callconv(.c) CUresult;
const CuModuleLoadDataFn = *const fn (*CUmodule, [*]const u8) callconv(.c) CUresult;
const CuModuleGetFunctionFn = *const fn (*CUfunction, CUmodule, [*:0]const u8) callconv(.c) CUresult;
const CuModuleUnloadFn = *const fn (CUmodule) callconv(.c) CUresult;
const CuLaunchKernelFn = *const fn (CUfunction, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, c_uint, CUstream, ?[*]?*anyopaque, ?[*]?*anyopaque) callconv(.c) CUresult;
const CuMemAllocFn = *const fn (*CUdeviceptr, usize) callconv(.c) CUresult;
const CuMemFreeFn = *const fn (CUdeviceptr) callconv(.c) CUresult;
const CuMemcpyHtoDFn = *const fn (CUdeviceptr, *const anyopaque, usize) callconv(.c) CUresult;
const CuMemcpyDtoHFn = *const fn (*anyopaque, CUdeviceptr, usize) callconv(.c) CUresult;
const CuMemsetD8Fn = *const fn (CUdeviceptr, u8, usize) callconv(.c) CUresult;
const CuCtxSynchronizeFn = *const fn () callconv(.c) CUresult;
const CuDeviceGetAttributeFn = *const fn (*c_int, c_int, CUdevice) callconv(.c) CUresult;
const CuDeviceGetNameFn = *const fn ([*]u8, c_int, CUdevice) callconv(.c) CUresult;
const CuDeviceTotalMemFn = *const fn (*usize, CUdevice) callconv(.c) CUresult;

// Device attribute constants
const CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK: c_int = 1;
const CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT: c_int = 16;
const CU_DEVICE_ATTRIBUTE_WARP_SIZE: c_int = 10;
const CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR: c_int = 75;
const CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR: c_int = 76;

const NvrtcCreateProgramFn = *const fn (*nvrtcProgram, [*:0]const u8, [*:0]const u8, c_int, ?[*]const [*:0]const u8, ?[*]const [*:0]const u8) callconv(.c) nvrtcResult;
const NvrtcCompileProgramFn = *const fn (nvrtcProgram, c_int, ?[*]const [*:0]const u8) callconv(.c) nvrtcResult;
const NvrtcDestroyProgramFn = *const fn (*nvrtcProgram) callconv(.c) nvrtcResult;
const NvrtcGetPTXSizeFn = *const fn (nvrtcProgram, *usize) callconv(.c) nvrtcResult;
const NvrtcGetPTXFn = *const fn (nvrtcProgram, [*]u8) callconv(.c) nvrtcResult;
const NvrtcGetProgramLogSizeFn = *const fn (nvrtcProgram, *usize) callconv(.c) nvrtcResult;
const NvrtcGetProgramLogFn = *const fn (nvrtcProgram, [*]u8) callconv(.c) nvrtcResult;
const NvrtcGetErrorStringFn = *const fn (nvrtcResult) callconv(.c) [*:0]const u8;

// ==================== CUDA Library Handle ====================

pub const CudaLibs = struct {
    cuda_lib: std.DynLib,
    nvrtc_lib: std.DynLib,

    // Driver API
    cuInit: CuInitFn,
    cuDeviceGetCount: CuDeviceGetCountFn,
    cuCtxCreate: CuCtxCreateFn,
    cuModuleLoadData: CuModuleLoadDataFn,
    cuModuleGetFunction: CuModuleGetFunctionFn,
    cuModuleUnload: CuModuleUnloadFn,
    cuLaunchKernel: CuLaunchKernelFn,
    cuMemAlloc: CuMemAllocFn,
    cuMemFree: CuMemFreeFn,
    cuMemcpyHtoD: CuMemcpyHtoDFn,
    cuMemcpyDtoH: CuMemcpyDtoHFn,
    cuMemsetD8: CuMemsetD8Fn,
    cuCtxSynchronize: CuCtxSynchronizeFn,
    cuDeviceGetAttribute: CuDeviceGetAttributeFn,
    cuDeviceGetName: CuDeviceGetNameFn,
    cuDeviceTotalMem: CuDeviceTotalMemFn,

    // NVRTC
    nvrtcCreateProgram: NvrtcCreateProgramFn,
    nvrtcCompileProgram: NvrtcCompileProgramFn,
    nvrtcDestroyProgram: NvrtcDestroyProgramFn,
    nvrtcGetPTXSize: NvrtcGetPTXSizeFn,
    nvrtcGetPTX: NvrtcGetPTXFn,
    nvrtcGetProgramLogSize: NvrtcGetProgramLogSizeFn,
    nvrtcGetProgramLog: NvrtcGetProgramLogFn,
    nvrtcGetErrorString: NvrtcGetErrorStringFn,

    // Context
    context: CUcontext,

    pub fn load() CudaError!CudaLibs {
        // Load CUDA driver
        var cuda_lib = std.DynLib.open("libcuda.so.1") catch
            std.DynLib.open("libcuda.so") catch
            return error.CudaNotFound;
        errdefer cuda_lib.close();

        // Load NVRTC
        var nvrtc_lib = std.DynLib.open("libnvrtc.so.12") catch
            std.DynLib.open("libnvrtc.so") catch
            return error.NvrtcNotFound;
        errdefer nvrtc_lib.close();

        var self = CudaLibs{
            .cuda_lib = cuda_lib,
            .nvrtc_lib = nvrtc_lib,
            .cuInit = cuda_lib.lookup(CuInitFn, "cuInit") orelse return error.FunctionNotFound,
            .cuDeviceGetCount = cuda_lib.lookup(CuDeviceGetCountFn, "cuDeviceGetCount") orelse return error.FunctionNotFound,
            .cuCtxCreate = cuda_lib.lookup(CuCtxCreateFn, "cuCtxCreate_v2") orelse return error.FunctionNotFound,
            .cuModuleLoadData = cuda_lib.lookup(CuModuleLoadDataFn, "cuModuleLoadData") orelse return error.FunctionNotFound,
            .cuModuleGetFunction = cuda_lib.lookup(CuModuleGetFunctionFn, "cuModuleGetFunction") orelse return error.FunctionNotFound,
            .cuModuleUnload = cuda_lib.lookup(CuModuleUnloadFn, "cuModuleUnload") orelse return error.FunctionNotFound,
            .cuLaunchKernel = cuda_lib.lookup(CuLaunchKernelFn, "cuLaunchKernel") orelse return error.FunctionNotFound,
            .cuMemAlloc = cuda_lib.lookup(CuMemAllocFn, "cuMemAlloc_v2") orelse return error.FunctionNotFound,
            .cuMemFree = cuda_lib.lookup(CuMemFreeFn, "cuMemFree_v2") orelse return error.FunctionNotFound,
            .cuMemcpyHtoD = cuda_lib.lookup(CuMemcpyHtoDFn, "cuMemcpyHtoD_v2") orelse return error.FunctionNotFound,
            .cuMemcpyDtoH = cuda_lib.lookup(CuMemcpyDtoHFn, "cuMemcpyDtoH_v2") orelse return error.FunctionNotFound,
            .cuMemsetD8 = cuda_lib.lookup(CuMemsetD8Fn, "cuMemsetD8_v2") orelse return error.FunctionNotFound,
            .cuCtxSynchronize = cuda_lib.lookup(CuCtxSynchronizeFn, "cuCtxSynchronize") orelse return error.FunctionNotFound,
            .cuDeviceGetAttribute = cuda_lib.lookup(CuDeviceGetAttributeFn, "cuDeviceGetAttribute") orelse return error.FunctionNotFound,
            .cuDeviceGetName = cuda_lib.lookup(CuDeviceGetNameFn, "cuDeviceGetName") orelse return error.FunctionNotFound,
            .cuDeviceTotalMem = cuda_lib.lookup(CuDeviceTotalMemFn, "cuDeviceTotalMem_v2") orelse return error.FunctionNotFound,
            .nvrtcCreateProgram = nvrtc_lib.lookup(NvrtcCreateProgramFn, "nvrtcCreateProgram") orelse return error.FunctionNotFound,
            .nvrtcCompileProgram = nvrtc_lib.lookup(NvrtcCompileProgramFn, "nvrtcCompileProgram") orelse return error.FunctionNotFound,
            .nvrtcDestroyProgram = nvrtc_lib.lookup(NvrtcDestroyProgramFn, "nvrtcDestroyProgram") orelse return error.FunctionNotFound,
            .nvrtcGetPTXSize = nvrtc_lib.lookup(NvrtcGetPTXSizeFn, "nvrtcGetPTXSize") orelse return error.FunctionNotFound,
            .nvrtcGetPTX = nvrtc_lib.lookup(NvrtcGetPTXFn, "nvrtcGetPTX") orelse return error.FunctionNotFound,
            .nvrtcGetProgramLogSize = nvrtc_lib.lookup(NvrtcGetProgramLogSizeFn, "nvrtcGetProgramLogSize") orelse return error.FunctionNotFound,
            .nvrtcGetProgramLog = nvrtc_lib.lookup(NvrtcGetProgramLogFn, "nvrtcGetProgramLog") orelse return error.FunctionNotFound,
            .nvrtcGetErrorString = nvrtc_lib.lookup(NvrtcGetErrorStringFn, "nvrtcGetErrorString") orelse return error.FunctionNotFound,
            .context = null,
        };

        // Initialize CUDA
        if (self.cuInit(0) != CUDA_SUCCESS) {
            return error.InitializationFailed;
        }

        // Check device count
        var device_count: c_int = 0;
        if (self.cuDeviceGetCount(&device_count) != CUDA_SUCCESS or device_count == 0) {
            return error.DeviceNotFound;
        }

        // Create context on device 0
        if (self.cuCtxCreate(&self.context, 0, 0) != CUDA_SUCCESS) {
            return error.InitializationFailed;
        }

        return self;
    }

    pub fn close(self: *CudaLibs) void {
        self.nvrtc_lib.close();
        self.cuda_lib.close();
    }
};

// Global CUDA library instance
var cuda_libs: ?CudaLibs = null;

fn getCudaLibs() CudaError!*CudaLibs {
    if (cuda_libs == null) {
        cuda_libs = try CudaLibs.load();
    }
    return &cuda_libs.?;
}

// ==================== GPU Device ====================

pub const GpuDevice = struct {
    device_id: c_int,
    name: [256]u8,
    total_memory: usize,
    compute_capability_major: c_int,
    compute_capability_minor: c_int,
    multiprocessor_count: c_int,
    max_threads_per_block: c_int,
    warp_size: c_int,

    pub fn init() CudaError!GpuDevice {
        const libs = try getCudaLibs();

        var device = GpuDevice{
            .device_id = 0,
            .name = undefined,
            .total_memory = 0,
            .compute_capability_major = 0,
            .compute_capability_minor = 0,
            .multiprocessor_count = 0,
            .max_threads_per_block = 0,
            .warp_size = 0,
        };

        // Query device name
        if (libs.cuDeviceGetName(&device.name, 256, 0) != CUDA_SUCCESS) {
            const fallback = "Unknown GPU";
            @memcpy(device.name[0..fallback.len], fallback);
            @memset(device.name[fallback.len..], 0);
        }

        // Query total memory
        _ = libs.cuDeviceTotalMem(&device.total_memory, 0);

        // Query attributes
        _ = libs.cuDeviceGetAttribute(&device.compute_capability_major, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR, 0);
        _ = libs.cuDeviceGetAttribute(&device.compute_capability_minor, CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR, 0);
        _ = libs.cuDeviceGetAttribute(&device.multiprocessor_count, CU_DEVICE_ATTRIBUTE_MULTIPROCESSOR_COUNT, 0);
        _ = libs.cuDeviceGetAttribute(&device.max_threads_per_block, CU_DEVICE_ATTRIBUTE_MAX_THREADS_PER_BLOCK, 0);
        _ = libs.cuDeviceGetAttribute(&device.warp_size, CU_DEVICE_ATTRIBUTE_WARP_SIZE, 0);

        return device;
    }

    pub fn printInfo(self: *const GpuDevice) void {
        std.debug.print("\n", .{});
        std.debug.print("GPU Device: {s}\n", .{std.mem.sliceTo(&self.name, 0)});
        std.debug.print("  Memory: {} MB\n", .{self.total_memory / (1024 * 1024)});
        std.debug.print("  Compute Capability: {}.{}\n", .{ self.compute_capability_major, self.compute_capability_minor });
        std.debug.print("  Multiprocessors: {}\n", .{self.multiprocessor_count});
        std.debug.print("  Max Threads/Block: {}\n", .{self.max_threads_per_block});
        std.debug.print("  Warp Size: {}\n", .{self.warp_size});
        std.debug.print("\n", .{});
    }

    pub fn optimalDimensions(_: *const GpuDevice, total_threads: u64) struct { grid_dim: u32, block_dim: u32 } {
        const block_dim: u32 = 256;
        const grid_dim: u32 = @intCast((total_threads + block_dim - 1) / block_dim);
        const max_grid: u32 = 65535;
        return .{
            .grid_dim = @min(grid_dim, max_grid),
            .block_dim = block_dim,
        };
    }
};

// ==================== GPU Memory ====================

pub fn GpuBuffer(comptime T: type) type {
    return struct {
        const Self = @This();

        device_ptr: CUdeviceptr,
        len: usize,
        byte_size: usize,

        pub fn alloc(count: usize) CudaError!Self {
            const libs = try getCudaLibs();
            const byte_size = count * @sizeOf(T);
            var ptr: CUdeviceptr = 0;

            if (libs.cuMemAlloc(&ptr, byte_size) != CUDA_SUCCESS) {
                return error.OutOfMemory;
            }

            return Self{
                .device_ptr = ptr,
                .len = count,
                .byte_size = byte_size,
            };
        }

        pub fn free(self: *Self) void {
            if (cuda_libs) |*libs| {
                _ = libs.cuMemFree(self.device_ptr);
            }
            self.device_ptr = 0;
            self.len = 0;
        }

        pub fn copyFromHost(self: *Self, host_data: []const T) CudaError!void {
            const libs = try getCudaLibs();
            const copy_size = @min(self.len, host_data.len) * @sizeOf(T);
            if (libs.cuMemcpyHtoD(self.device_ptr, @ptrCast(host_data.ptr), copy_size) != CUDA_SUCCESS) {
                return error.MemcpyFailed;
            }
        }

        pub fn copyToHost(self: *Self, host_data: []T) CudaError!void {
            const libs = try getCudaLibs();
            const copy_size = @min(self.len, host_data.len) * @sizeOf(T);
            if (libs.cuMemcpyDtoH(@ptrCast(host_data.ptr), self.device_ptr, copy_size) != CUDA_SUCCESS) {
                return error.MemcpyFailed;
            }
        }

        pub fn zero(self: *Self) CudaError!void {
            const libs = try getCudaLibs();
            if (libs.cuMemsetD8(self.device_ptr, 0, self.byte_size) != CUDA_SUCCESS) {
                return error.MemcpyFailed;
            }
        }
    };
}

// ==================== Kernel Compilation ====================

pub const hash_match_kernel =
    \\// CUDA built-in types: use unsigned long long for 64-bit, unsigned int for 32-bit
    \\typedef unsigned long long u64;
    \\typedef unsigned int u32;
    \\typedef unsigned char u8;
    \\
    \\__device__ u64 simple_hash(u64 x) {
    \\    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    \\    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    \\    x = x ^ (x >> 31);
    \\    return x;
    \\}
    \\
    \\struct WorkUnitHeader {
    \\    u64 start_index;
    \\    u32 count;
    \\    u32 search_type;
    \\    u8 target_hash[32];
    \\    u8 _reserved[16];
    \\};
    \\
    \\struct WorkUnitResult {
    \\    u32 found;
    \\    u32 match_index;
    \\    u64 match_value;
    \\    u8 match_hash[16];
    \\};
    \\
    \\extern "C" __global__ void hash_match_kernel(
    \\    const WorkUnitHeader* headers,
    \\    WorkUnitResult* results,
    \\    u32 num_units
    \\) {
    \\    u32 unit_idx = blockIdx.x * blockDim.x + threadIdx.x;
    \\    if (unit_idx >= num_units) return;
    \\
    \\    const WorkUnitHeader* header = &headers[unit_idx];
    \\    WorkUnitResult* result = &results[unit_idx];
    \\
    \\    u64 target = *((u64*)header->target_hash);
    \\
    \\    for (u32 i = 0; i < header->count; i++) {
    \\        u64 candidate = header->start_index + i;
    \\        u64 hash = simple_hash(candidate);
    \\
    \\        if (hash == target) {
    \\            result->found = 1;
    \\            result->match_index = i;
    \\            result->match_value = candidate;
    \\            *((u64*)result->match_hash) = hash;
    \\            return;
    \\        }
    \\    }
    \\}
;

pub const CompiledKernel = struct {
    module: CUmodule,
    function: CUfunction,

    pub fn compile(source: []const u8, kernel_name: []const u8) CudaError!CompiledKernel {
        const libs = try getCudaLibs();

        // Create null-terminated strings
        var source_buf: [8192]u8 = undefined;
        @memcpy(source_buf[0..source.len], source);
        source_buf[source.len] = 0;

        var prog: nvrtcProgram = null;
        if (libs.nvrtcCreateProgram(&prog, @ptrCast(&source_buf), "kernel.cu", 0, null, null) != NVRTC_SUCCESS) {
            return error.KernelCompilationFailed;
        }
        defer _ = libs.nvrtcDestroyProgram(&prog);

        // Compile
        const opts = [_][*:0]const u8{"--gpu-architecture=compute_86"};
        const compile_result = libs.nvrtcCompileProgram(prog, 1, &opts);
        if (compile_result != NVRTC_SUCCESS) {
            var log_size: usize = 0;
            _ = libs.nvrtcGetProgramLogSize(prog, &log_size);
            if (log_size > 1) {
                var log_buf: [4096]u8 = undefined;
                _ = libs.nvrtcGetProgramLog(prog, &log_buf);
                std.debug.print("NVRTC Log: {s}\n", .{log_buf[0..@min(log_size, 4096)]});
            }
            return error.KernelCompilationFailed;
        }

        // Get PTX
        var ptx_size: usize = 0;
        if (libs.nvrtcGetPTXSize(prog, &ptx_size) != NVRTC_SUCCESS) {
            return error.KernelCompilationFailed;
        }

        const ptx_buf = std.heap.page_allocator.alloc(u8, ptx_size) catch return error.OutOfMemory;
        defer std.heap.page_allocator.free(ptx_buf);

        if (libs.nvrtcGetPTX(prog, ptx_buf.ptr) != NVRTC_SUCCESS) {
            return error.KernelCompilationFailed;
        }

        // Load module
        var module: CUmodule = null;
        if (libs.cuModuleLoadData(&module, ptx_buf.ptr) != CUDA_SUCCESS) {
            return error.KernelCompilationFailed;
        }

        // Get function
        var name_buf: [256]u8 = undefined;
        @memcpy(name_buf[0..kernel_name.len], kernel_name);
        name_buf[kernel_name.len] = 0;

        var function: CUfunction = null;
        if (libs.cuModuleGetFunction(&function, module, @ptrCast(&name_buf)) != CUDA_SUCCESS) {
            return error.InvalidKernel;
        }

        return CompiledKernel{ .module = module, .function = function };
    }

    pub fn deinit(self: *CompiledKernel) void {
        if (cuda_libs) |*libs| {
            _ = libs.cuModuleUnload(self.module);
        }
    }

    pub fn launch(self: *const CompiledKernel, grid_dim: u32, block_dim: u32, args: []const ?*anyopaque) CudaError!void {
        const libs = try getCudaLibs();

        if (libs.cuLaunchKernel(
            self.function,
            grid_dim,
            1,
            1,
            block_dim,
            1,
            1,
            0,
            null,
            @constCast(@ptrCast(args.ptr)),
            null,
        ) != CUDA_SUCCESS) {
            return error.KernelLaunchFailed;
        }
    }
};

// ==================== Hydra Engine ====================

pub const Hydra = struct {
    device: GpuDevice,
    kernel: CompiledKernel,
    headers_gpu: GpuBuffer(work_unit.WorkUnitHeader),
    results_gpu: GpuBuffer(work_unit.WorkUnitResult),
    max_batch_size: u32,

    pub fn init(max_batch_size: u32) CudaError!Hydra {
        const device = try GpuDevice.init();
        device.printInfo();

        std.debug.print("Compiling GPU kernel...\n", .{});
        const kernel = try CompiledKernel.compile(hash_match_kernel, "hash_match_kernel");

        std.debug.print("Allocating GPU memory for {} work units...\n", .{max_batch_size});
        const headers_gpu = try GpuBuffer(work_unit.WorkUnitHeader).alloc(max_batch_size);
        const results_gpu = try GpuBuffer(work_unit.WorkUnitResult).alloc(max_batch_size);

        return Hydra{
            .device = device,
            .kernel = kernel,
            .headers_gpu = headers_gpu,
            .results_gpu = results_gpu,
            .max_batch_size = max_batch_size,
        };
    }

    pub fn deinit(self: *Hydra) void {
        self.headers_gpu.free();
        self.results_gpu.free();
        self.kernel.deinit();
    }

    pub fn executeBatch(self: *Hydra, batch: *work_unit.GpuBatch) CudaError!void {
        if (batch.count > self.max_batch_size) {
            return error.OutOfMemory;
        }

        // Zero results
        try self.results_gpu.zero();

        // Copy headers to GPU
        try self.headers_gpu.copyFromHost(batch.headers[0..batch.count]);

        // Launch kernel
        const dims = self.device.optimalDimensions(batch.count);
        const headers_ptr = self.headers_gpu.device_ptr;
        const results_ptr = self.results_gpu.device_ptr;
        const num_units = batch.count;

        const args = [_]?*anyopaque{
            @ptrCast(@constCast(&headers_ptr)),
            @ptrCast(@constCast(&results_ptr)),
            @ptrCast(@constCast(&num_units)),
        };

        try self.kernel.launch(dims.grid_dim, dims.block_dim, &args);

        // Synchronize
        const libs = try getCudaLibs();
        if (libs.cuCtxSynchronize() != CUDA_SUCCESS) {
            return error.SyncFailed;
        }

        // Copy results back
        try self.results_gpu.copyToHost(batch.results[0..batch.count]);
    }

    pub fn getStats(self: *const Hydra) struct {
        device_name: []const u8,
        memory_mb: usize,
        multiprocessors: c_int,
        max_batch: u32,
    } {
        return .{
            .device_name = std.mem.sliceTo(&self.device.name, 0),
            .memory_mb = self.device.total_memory / (1024 * 1024),
            .multiprocessors = self.device.multiprocessor_count,
            .max_batch = self.max_batch_size,
        };
    }
};
