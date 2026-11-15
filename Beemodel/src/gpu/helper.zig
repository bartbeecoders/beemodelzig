// beemodel-gpu: the optional GPU helper, the port's own (helper.s). BeeModel links
// nothing; this separate program loads the Vulkan loader (libvulkan.so.1, at run
// time, so that building it needs no Vulkan at all) and runs compute kernels for
// it: the Hive path tracer (pt.comp) as SPIR-V built in, with shader graphs, and
// through ray queries when the device has them (RTX).
//
// BeeModel starts it with a SOCK_SEQPACKET socket on fd 3 (ipc.zig):
//   1. it says MSG_HELLO: whether a device was found, its type and name;
//   2. MSG_MAP hands it a slot's shared memory (a memfd);
//   3. MSG_RUN: the slot's table of bindings is read and checked, the inputs
//      copied to device-local buffers through private staging (whole, or only
//      the ranges listed), the kernel dispatched, the outputs copied back, and
//      MSG_REPLY sent;
//   4. MSG_QUIT or the socket closing ends it.
// A failure is answered and ends the helper: BeeModel falls back to the CPU.
//
// It picks a discrete GPU first, then an integrated or virtual one; a CPU
// implementation (llvmpipe) only with BEEMODEL_GPU=any (the tests).
//
// The slot is untrusted: every offset and size is checked before use, the
// constants are read from the private copy, and the device runs with
// robustBufferAccess, so a wild index in a scene stays inside its buffer.
const std = @import("std");
const vk = @import("vk.zig");
const ipc = @import("ipc.zig");
const linux = std.os.linux;
const c = std.c;
const ca = std.heap.c_allocator;

const SOCK_FD = 3;
const FENCE_NS: u64 = 60_000_000_000; // a run: a minute at most
const MAX_SLOT: u64 = 1 << 37; // 128 GiB

var f: vk.Fns = .{};
var gipa: ?*const fn (vk.Handle, [*:0]const u8) callconv(.c) ?*anyopaque = null;
var allow_cpu = false;
var fail_at: u32 = 0; // tests: die at this run
var hang_at: u32 = 0; // tests: stop answering at this run
var slow_ms: u32 = 0; // tests: each run takes this much longer
var debug = false;
var runs: u32 = 0;

var instance: vk.Handle = null;
var phys: vk.Handle = null;
var device: vk.Handle = null;
var queue: vk.Handle = null;
var cbuf: vk.Handle = null;
var cpool: u64 = 0;
var fence: u64 = 0;
var dpool: u64 = 0;
var family: u32 = 0;
var memprops: vk.MemProps = undefined;
var props: [824 / 8]u64 = undefined;
var feats: [55]u32 = undefined;
var rtx = false;
var gfx = false; // the viewport kernel can run
var hostmem = false; // shared memory imported as staging (no copies)
var host_align: u64 = 4096;
var scratch_align: u64 = 256;
var max_range: u64 = 1 << 27;

const Kernel = struct { module: u64 = 0, dsl: u64 = 0, layout: u64 = 0, pipe: u64 = 0, set: u64 = 0 };
var kernels: [ipc.NKERN]Kernel = @splat(.{});

const Slot = struct {
    base: ?[*]u8 = null,
    size: u64 = 0,
    dbuf: u64 = 0,
    dmem: u64 = 0,
    sbuf: u64 = 0,
    smem: u64 = 0,
    sptr: ?[*]u8 = null,
    host: bool = false, // the staging buffer is the shared memory itself
    stcap: u64 = 0, // our own staging's size (not imported)
    cap: u64 = 0,
    // RTX: one buffer for the structures and the scratch; the instance record
    abuf: u64 = 0,
    amem: u64 = 0,
    acap: u64 = 0,
    ibuf: u64 = 0,
    imem: u64 = 0,
    iptr: ?*vk.AsInstance = null,
    blas: u64 = 0,
    tlas: u64 = 0,
    nt: u32 = 0,
    asok: bool = false,
};
var slots: [ipc.NSLOT]Slot = @splat(.{});

fn env(name: [*:0]const u8) ?[]const u8 {
    const p = c.getenv(name) orelse return null;
    return std.mem.sliceTo(p, 0);
}

fn envInt(name: [*:0]const u8) u32 {
    const s = env(name) orelse return 0;
    return std.fmt.parseInt(u32, s, 10) catch 0;
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

// --- messages --------------------------------------------------------------------------

fn send(m: *const ipc.Msg) void {
    var iov = [1]std.posix.iovec_const{.{ .base = @ptrCast(m), .len = ipc.GM_SZ }};
    const h = linux.msghdr_const{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = null, .controllen = 0, .flags = 0 };
    _ = linux.sendmsg(SOCK_FD, &h, 0x4000); // MSG_NOSIGNAL
}

/// A message (a passed fd in `fd`), or null when the socket closed.
fn recv(m: *ipc.Msg, fd: *i32) bool {
    var ctl: [64]u8 align(8) = undefined;
    var iov = [1]std.posix.iovec{.{ .base = @ptrCast(m), .len = ipc.GM_SZ }};
    var h = linux.msghdr{ .name = null, .namelen = 0, .iov = &iov, .iovlen = 1, .control = &ctl, .controllen = ctl.len, .flags = 0 };
    fd.* = -1;
    while (true) {
        const r = linux.recvmsg(SOCK_FD, &h, 0);
        const e = linux.errno(r);
        if (e == .INTR) continue;
        if (e != .SUCCESS or r != ipc.GM_SZ) return false;
        break;
    }
    if (h.controllen >= 20) {
        const level = std.mem.readInt(u32, ctl[8..12], .little);
        const ty = std.mem.readInt(u32, ctl[12..16], .little);
        if (level == 1 and ty == 1) fd.* = std.mem.readInt(i32, ctl[16..20], .little);
    }
    return true;
}

// --- set-up --------------------------------------------------------------------------------

fn load(comptime name: []const u8, h: vk.Handle) void {
    const p = gipa.?(h, "vk" ++ name ++ "\x00");
    @field(f, name) = @ptrCast(p);
}

fn loadAll(h: vk.Handle) void {
    inline for (comptime std.meta.fieldNames(vk.Fns)) |nm| {
        if (@field(f, nm) == null) load(nm, h);
    }
}

fn nameIs(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, std.mem.sliceTo(a, 0), b);
}

fn pdType(p: *const [824 / 8]u64) u32 {
    return @truncate(p[2]);
}

/// Better devices first: 0 none.
fn rank(ty: u32) u32 {
    return switch (ty) {
        vk.DT_DISCRETE => 4,
        vk.DT_INTEGRATED => 3,
        vk.DT_VIRTUAL => 2,
        vk.DT_CPU => if (allow_cpu) 1 else 0,
        else => 0,
    };
}

fn findQueue(pd: vk.Handle) ?u32 {
    var n: u32 = 32;
    var q: [32]vk.QueueFamily = undefined;
    f.GetPhysicalDeviceQueueFamilyProperties.?(pd, &n, &q);
    var best: ?u32 = null;
    for (q[0..n], 0..) |qf, i| {
        if (qf.flags & vk.QUEUE_COMPUTE != 0 and qf.count > 0) {
            // (the viewport wants a graphics queue too)
            if (best == null or qf.flags & vk.QUEUE_GRAPHICS != 0 and q[best.?].flags & vk.QUEUE_GRAPHICS == 0) best = @intCast(i);
        }
    }
    return best;
}

const EXT_AS = "VK_KHR_acceleration_structure";
const EXT_RQ = "VK_KHR_ray_query";
const EXT_DHO = "VK_KHR_deferred_host_operations";

fn probeRtx() void {
    var p: [824 / 8]u64 = undefined;
    f.GetPhysicalDeviceProperties.?(phys, &p);
    if (@as(u32, @truncate(p[0])) < vk.API_1_2) return;
    if (envIs("BEEMODEL_GPU_RTX", "off")) return;
    var n: u32 = 0;
    if (f.EnumerateDeviceExtensionProperties.?(phys, null, &n, null) != 0) return;
    const ex = ca.alloc(vk.ExtProps, n) catch return;
    defer ca.free(ex);
    if (f.EnumerateDeviceExtensionProperties.?(phys, null, &n, ex.ptr) != 0) return;
    var found: u32 = 0;
    for (ex[0..n]) |*e| {
        if (nameIs(&e.name, EXT_AS)) found |= 1;
        if (nameIs(&e.name, EXT_RQ)) found |= 2;
        if (nameIs(&e.name, EXT_DHO)) found |= 4;
    }
    if (found != 7) return;
    var bda = vk.BdaFeats{};
    var as = vk.AsFeats{ .next = &bda };
    var rq = vk.RqFeats{ .next = &as };
    var f2 = vk.Feats2{ .next = &rq };
    f.GetPhysicalDeviceFeatures2.?(phys, &f2);
    if (bda.bda == 0 or as.as == 0 or rq.rq == 0) return;
    var ap = vk.AsProps{};
    var p2 = vk.Props2{ .next = &ap };
    f.GetPhysicalDeviceProperties2.?(phys, &p2);
    if (ap.scratch == 0 or ap.scratch > 4096) return;
    scratch_align = ap.scratch;
    rtx = true;
}

const EXT_HOST = "VK_EXT_external_memory_host";
const EXT_EXTMEM = "VK_KHR_external_memory";

/// Shared memory can be imported as staging: the device has the extension, and
/// BEEMODEL_GPU_HOSTMEM=off does not forbid it.
fn probeHost() void {
    if (envIs("BEEMODEL_GPU_HOSTMEM", "off")) return;
    var n: u32 = 0;
    if (f.EnumerateDeviceExtensionProperties.?(phys, null, &n, null) != 0) return;
    const ex = ca.alloc(vk.ExtProps, n) catch return;
    defer ca.free(ex);
    if (f.EnumerateDeviceExtensionProperties.?(phys, null, &n, ex.ptr) != 0) return;
    var found: u32 = 0;
    for (ex[0..n]) |*e| {
        if (nameIs(&e.name, EXT_HOST)) found |= 1;
        if (nameIs(&e.name, EXT_EXTMEM)) found |= 2;
    }
    if (found != 3) return;
    var hp = vk.ExtHostProps{};
    var p2 = vk.Props2{ .next = &hp };
    f.GetPhysicalDeviceProperties2.?(phys, &p2);
    if (hp.alignment == 0 or hp.alignment > 1 << 20) return;
    host_align = hp.alignment;
    hostmem = true;
}

/// A buffer over the slot's shared memory; false: our own staging instead.
fn importHost(s: *Slot) bool {
    const base = s.base.?;
    if (@intFromPtr(base) % host_align != 0 or s.size % host_align != 0) return false;
    var hp = vk.HostPtrProps{};
    if (f.GetMemoryHostPointerPropertiesEXT.?(device, vk.HT_HOST, base, &hp) != 0 or hp.bits == 0) return false;
    const eb = vk.ExtBufCI{};
    const bci = vk.BufferCI{ .next = &eb, .size = s.size, .usage = vk.USAGE_TSRC | vk.USAGE_TDST };
    if (f.CreateBuffer.?(device, &bci, null, &s.sbuf) != 0) return false;
    var req: vk.MemReq = undefined;
    f.GetBufferMemoryRequirements.?(device, s.sbuf, &req);
    const bits = hp.bits & req.bits;
    const ty = memType(bits, vk.MEM_HOST_VISIBLE | vk.MEM_HOST_COHERENT | vk.MEM_HOST_CACHED) orelse memType(bits, vk.MEM_HOST_VISIBLE | vk.MEM_HOST_COHERENT) orelse {
        f.DestroyBuffer.?(device, s.sbuf, null);
        s.sbuf = 0;
        return false;
    };
    const imp = vk.ImportHost{ .ptr = base };
    const ma = vk.MemAlloc{ .next = &imp, .size = s.size, .type = ty };
    if (f.AllocateMemory.?(device, &ma, null, &s.smem) != 0 or f.BindBufferMemory.?(device, s.sbuf, s.smem, 0) != 0) {
        dropBuffer(&s.sbuf, &s.smem);
        return false;
    }
    s.sptr = base;
    s.host = true;
    return true;
}

fn dropStaging(s: *Slot) void {
    if (s.sptr != null and !s.host) f.UnmapMemory.?(device, s.smem);
    s.sptr = null;
    s.host = false;
    s.stcap = 0;
    dropBuffer(&s.sbuf, &s.smem);
}

fn queueHasGraphics(pd: vk.Handle, fam: u32) bool {
    var n: u32 = 32;
    var q: [32]vk.QueueFamily = undefined;
    f.GetPhysicalDeviceQueueFamilyProperties.?(pd, &n, &q);
    return fam < n and q[fam].flags & vk.QUEUE_GRAPHICS != 0;
}

fn envIs(name: [*:0]const u8, v: []const u8) bool {
    const s = env(name) orelse return false;
    return std.mem.eql(u8, s, v);
}

fn setup() u32 {
    const lib = c.dlopen("libvulkan.so.1", .{ .LAZY = true }) orelse return ipc.GH_NOLOADER;
    gipa = @ptrCast(c.dlsym(lib, "vkGetInstanceProcAddr") orelse return ipc.GH_NOLOADER);
    load("CreateInstance", null);
    load("EnumerateInstanceVersion", null);
    var api: u32 = vk.API_1_1;
    if (f.EnumerateInstanceVersion) |ev| {
        var v: u32 = 0;
        if (ev(&v) == 0 and v >= vk.API_1_2) api = vk.API_1_2;
    }
    const app = vk.AppInfo{ .name = "beemodel-gpu", .engine = "beemodel-gpu", .api = api };
    const ici = vk.InstanceCI{ .app = &app };
    if (f.CreateInstance == null or f.CreateInstance.?(&ici, null, &instance) != 0) return ipc.GH_NOLOADER;
    // (device functions through the instance: Fns' missing ones stay null)
    loadAll(instance);
    if (f.CreateDevice == null or f.CreateBuffer == null) return ipc.GH_NOLOADER;

    var n: u32 = 16;
    var list: [16]vk.Handle = undefined;
    if (f.EnumeratePhysicalDevices.?(instance, &n, &list) < 0) return ipc.GH_NOLOADER;
    var best: u32 = 0;
    for (list[0..n]) |pd| {
        var p: [824 / 8]u64 = undefined;
        f.GetPhysicalDeviceProperties.?(pd, &p);
        var ft: [55]u32 = undefined;
        f.GetPhysicalDeviceFeatures.?(pd, &ft);
        if (ft[40] == 0) continue; // shaderInt64
        const q = findQueue(pd) orelse continue;
        const r = rank(pdType(&p));
        if (r > best) {
            best = r;
            phys = pd;
            family = q;
            props = p;
            feats = ft;
        }
    }
    if (best == 0) return ipc.GH_NODEVICE;
    const pb: [*]const u8 = @ptrCast(&props);
    max_range = std.mem.readInt(u32, pb[324..][0..4], .little);
    f.GetPhysicalDeviceMemoryProperties.?(phys, &memprops);
    if (f.GetPhysicalDeviceFeatures2 != null and f.GetPhysicalDeviceProperties2 != null) probeRtx();

    probeHost();
    const prio = [1]f32{1};
    const dq = vk.DevQCI{ .family = family, .prio = &prio };
    var want: [55]u32 = @splat(0);
    want[40] = 1;
    want[0] = feats[0]; // robustBufferAccess: the slot is untrusted
    gfx = feats[9] != 0 and feats[10] != 0 and queueHasGraphics(phys, family) and !envIs("BEEMODEL_GPU_VIEW", "off");
    if (gfx) {
        want[9] = 1; // multiDrawIndirect
        want[10] = 1; // drawIndirectFirstInstance
    }
    var bda = vk.BdaFeats{ .bda = 1 };
    var as = vk.AsFeats{ .next = &bda, .as = 1 };
    var rq = vk.RqFeats{ .next = &as, .rq = 1 };
    const exts = [3][*:0]const u8{ EXT_AS, EXT_RQ, EXT_DHO };
    var f2 = vk.Feats2{ .next = &rq, .f = want };
    var dci = vk.DeviceCI{ .q = &dq, .feats = &want };
    var extl: [8][*:0]const u8 = undefined;
    var nx: u32 = 0;
    if (rtx) {
        dci.next = &f2;
        dci.feats = null;
        for (exts) |e| {
            extl[nx] = e;
            nx += 1;
        }
    }
    if (hostmem) {
        extl[nx] = EXT_HOST;
        extl[nx + 1] = EXT_EXTMEM;
        nx += 2;
    }
    if (nx > 0) {
        dci.next_ = nx;
        dci.exts = &extl;
    }
    if (f.CreateDevice.?(phys, &dci, null, &device) != 0) return ipc.GH_NODEVICE;
    f.GetDeviceQueue.?(device, family, 0, &queue);
    if (hostmem) {
        const gd: ?*const fn (vk.Handle, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(gipa.?(instance, "vkGetDeviceProcAddr"));
        f.GetMemoryHostPointerPropertiesEXT = if (gd) |g| @ptrCast(g(device, "vkGetMemoryHostPointerPropertiesEXT")) else null;
        if (f.GetMemoryHostPointerPropertiesEXT == null) hostmem = false;
    }
    if (rtx) {
        // (the instance's trampolines reach these once the device has them)
        const gdpa: ?*const fn (vk.Handle, [*:0]const u8) callconv(.c) ?*anyopaque = @ptrCast(gipa.?(instance, "vkGetDeviceProcAddr"));
        if (gdpa) |g| {
            f.GetBufferDeviceAddress = @ptrCast(g(device, "vkGetBufferDeviceAddress"));
            f.CreateAccelerationStructureKHR = @ptrCast(g(device, "vkCreateAccelerationStructureKHR"));
            f.DestroyAccelerationStructureKHR = @ptrCast(g(device, "vkDestroyAccelerationStructureKHR"));
            f.GetAccelerationStructureBuildSizesKHR = @ptrCast(g(device, "vkGetAccelerationStructureBuildSizesKHR"));
            f.GetAccelerationStructureDeviceAddressKHR = @ptrCast(g(device, "vkGetAccelerationStructureDeviceAddressKHR"));
            f.CmdBuildAccelerationStructuresKHR = @ptrCast(g(device, "vkCmdBuildAccelerationStructuresKHR"));
        }
        if (f.GetBufferDeviceAddress == null or f.CreateAccelerationStructureKHR == null or f.CmdBuildAccelerationStructuresKHR == null) rtx = false;
    }
    const pool = vk.CPoolCI{ .family = family };
    if (f.CreateCommandPool.?(device, &pool, null, &cpool) != 0) return ipc.GH_NODEVICE;
    const cba = vk.CbAlloc{ .pool = cpool };
    if (f.AllocateCommandBuffers.?(device, &cba, &cbuf) != 0) return ipc.GH_NODEVICE;
    const fci = vk.FenceCI{};
    if (f.CreateFence.?(device, &fci, null, &fence) != 0) return ipc.GH_NODEVICE;
    const sizes = [2]vk.PoolSize{ .{ .type = vk.DESC_STORAGE, .count = 32 * ipc.NKERN }, .{ .type = vk.DESC_AS, .count = ipc.NKERN } };
    // (graphics needs nothing more of the pool)
    const dp = vk.DPoolCI{ .max = ipc.NKERN, .n = if (rtx) 2 else 1, .sizes = &sizes };
    if (f.CreateDescriptorPool.?(device, &dp, null, &dpool) != 0) return ipc.GH_NODEVICE;
    return ipc.GH_OK;
}

// --- kernels ---------------------------------------------------------------------------------

const code = [ipc.NKERN]?[]const u8{
    @embedFile("spv/pt.spv"),
    @embedFile("spv/raster.spv"),
    @embedFile("spv/ptg.spv"),
    @embedFile("spv/ptr.spv"),
    @embedFile("spv/ptgr.spv"),
    @embedFile("spv/asprep.spv"),
    null,
};
const k_nbind = [ipc.NKERN]u32{ ipc.PT_NBIND, ipc.RS_NB, ipc.PT_NBIND, ipc.PT_NBIND + 1, ipc.PT_NBIND + 1, 5, ipc.GV_NB };

fn makeKernel(ki: usize) bool {
    const k = &kernels[ki];
    if (k.pipe != 0) return true;
    if (ki == ipc.K_VIEW) return makeView();
    const bytes = code[ki] orelse return false;
    if ((ki == ipc.K_PTR or ki == ipc.K_PTGR or ki == ipc.K_PREP) and !rtx) return false;
    const words = ca.alloc(u32, bytes.len / 4) catch return false;
    defer ca.free(words);
    @memcpy(std.mem.sliceAsBytes(words), bytes[0 .. words.len * 4]);
    const sci = vk.ShaderCI{ .size = words.len * 4, .code = words.ptr };
    if (f.CreateShaderModule.?(device, &sci, null, &k.module) != 0) return false;
    var b: [ipc.PT_NBIND + 1]vk.DslBinding = undefined;
    const n = k_nbind[ki];
    for (0..n) |i| b[i] = .{ .binding = @intCast(i) };
    if ((ki == ipc.K_PTR or ki == ipc.K_PTGR)) b[ipc.PT_NBIND].type = vk.DESC_AS;
    const dci = vk.DslCI{ .n = n, .b = &b };
    if (f.CreateDescriptorSetLayout.?(device, &dci, null, &k.dsl) != 0) return false;
    const pci = vk.PlCI{ .dsl = &k.dsl };
    if (f.CreatePipelineLayout.?(device, &pci, null, &k.layout) != 0) return false;
    const cci = vk.ComputeCI{ .stage = .{ .module = k.module }, .layout = k.layout };
    if (f.CreateComputePipelines.?(device, 0, 1, &cci, null, &k.pipe) != 0) {
        k.pipe = 0;
        return false;
    }
    const dsa = vk.DsAlloc{ .pool = dpool, .dsl = &k.dsl };
    if (f.AllocateDescriptorSets.?(device, &dsa, &k.set) != 0) {
        k.pipe = 0;
        return false;
    }
    return true;
}

// --- memory -------------------------------------------------------------------------------------

fn memType(bits: u32, want: u32) ?u32 {
    for (0..memprops.ntype) |i| {
        if (bits & (@as(u32, 1) << @intCast(i)) != 0 and memprops.types[i].flags & want == want) return @intCast(i);
    }
    return null;
}

fn makeBuffer(size: u64, usage: u32, want: [2]u32, addr: bool, buf: *u64, mem: *u64) bool {
    const bci = vk.BufferCI{ .size = size, .usage = usage };
    if (f.CreateBuffer.?(device, &bci, null, buf) != 0) return false;
    var req: vk.MemReq = undefined;
    f.GetBufferMemoryRequirements.?(device, buf.*, &req);
    const ty = memType(req.bits, want[0]) orelse memType(req.bits, want[1]) orelse {
        f.DestroyBuffer.?(device, buf.*, null);
        buf.* = 0;
        return false;
    };
    const flg = vk.MemAllocFlags{};
    var ma = vk.MemAlloc{ .size = req.size, .type = ty };
    if (addr) ma.next = &flg;
    if (f.AllocateMemory.?(device, &ma, null, mem) != 0 or f.BindBufferMemory.?(device, buf.*, mem.*, 0) != 0) {
        f.DestroyBuffer.?(device, buf.*, null);
        buf.* = 0;
        return false;
    }
    return true;
}

fn dropBuffer(buf: *u64, mem: *u64) void {
    if (buf.* != 0) f.DestroyBuffer.?(device, buf.*, null);
    if (mem.* != 0) f.FreeMemory.?(device, mem.*, null);
    buf.* = 0;
    mem.* = 0;
}

fn begin() bool {
    if (f.ResetCommandBuffer.?(cbuf, 0) != 0) return false;
    const bi = vk.CbBegin{};
    return f.BeginCommandBuffer.?(cbuf, &bi) == 0;
}

fn submitWait() bool {
    if (f.EndCommandBuffer.?(cbuf) != 0) return false;
    const si = vk.Submit{ .cb = &cbuf };
    if (f.QueueSubmit.?(queue, 1, &si, fence) != 0) return false;
    if (f.WaitForFences.?(device, 1, &fence, 1, FENCE_NS) != 0) return false;
    return f.ResetFences.?(device, 1, &fence) == 0;
}

fn barrier(src: u32, dst: u32, sa: u32, da: u32) void {
    const b = vk.MemBarrier{ .src = sa, .dst = da };
    f.CmdPipelineBarrier.?(cbuf, src, dst, 0, 1, &b, 0, null, 0, null);
}

fn doMap(m: *const ipc.Msg, fd: i32) u32 {
    if (fd < 0) return 1;
    defer _ = linux.close(fd);
    if (m.slot >= ipc.NSLOT) return 1;
    const s = &slots[m.slot];
    const size = m.size();
    if (size < ipc.GPU_DATA0 or size > MAX_SLOT) return 1;
    // (mapping past the file's end would be a SIGBUS on first touch)
    var st: linux.Statx = undefined;
    if (linux.errno(linux.statx(fd, "", linux.AT.EMPTY_PATH, .{ .SIZE = true }, &st)) != .SUCCESS) return 1;
    if (st.size < size) return 1;
    const r = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    if (linux.errno(r) != .SUCCESS) return 1;
    // (an imported staging buffer goes with its mapping, before it is unmapped)
    if (s.host) dropStaging(s);
    if (s.base) |b| _ = linux.munmap(b, s.size);
    s.base = @ptrFromInt(r);
    s.size = size;
    if (size > s.cap) {
        // (no work is in flight between messages)
        dropBuffer(&s.dbuf, &s.dmem);
        s.asok = false;
        s.cap = 0;
        var usage: u32 = vk.USAGE_STORAGE | vk.USAGE_TSRC | vk.USAGE_TDST;
        if (rtx) usage |= vk.USAGE_ADDR | vk.USAGE_ASIN;
        usage |= vk.USAGE_INDIRECT;
        if (!makeBuffer(size, usage, .{ vk.MEM_DEVICE_LOCAL, 0 }, rtx, &s.dbuf, &s.dmem)) return 1;
        s.cap = size;
        // zeros: what a run reads before anything is sent is the same each time
        if (!begin()) return 1;
        f.CmdFillBuffer.?(cbuf, s.dbuf, 0, ~@as(u64, 0), 0);
        if (!submitWait()) return 1;
    }
    if (hostmem and importHost(s)) return 0;
    // staging of our own (host-visible, cached when it can be: outputs are read)
    if (size > s.stcap) {
        dropStaging(s);
        if (!makeBuffer(size, vk.USAGE_TSRC | vk.USAGE_TDST, .{
            vk.MEM_HOST_VISIBLE | vk.MEM_HOST_COHERENT | vk.MEM_HOST_CACHED,
            vk.MEM_HOST_VISIBLE | vk.MEM_HOST_COHERENT,
        }, false, &s.sbuf, &s.smem)) return 1;
        if (f.MapMemory.?(device, s.smem, 0, ~@as(u64, 0), 0, &s.sptr) != 0) return 1;
        s.stcap = size;
    }
    return 0;
}

// --- a run --------------------------------------------------------------------------------------

var table: [ipc.GPU_MAXBIND]ipc.Binding = undefined;
var regions: [ipc.GPU_MAXBIND + ipc.GPU_MAXRANGE]vk.BufCopy = undefined;
var writes: [ipc.GPU_MAXBIND]vk.Write = undefined;
var infos: [ipc.GPU_MAXBIND]vk.BufInfo = undefined;
var nreg: usize = 0;

fn upRange(s: *Slot, off: u64, n: u64) bool {
    if (nreg >= regions.len) return false;
    if (!s.host) @memcpy(s.sptr.?[off..][0..n], s.base.?[off..][0..n]);
    regions[nreg] = .{ .src = off, .dst = off, .size = n };
    nreg += 1;
    return true;
}

/// The private copy of the constants: bindings that must hold what they say.
fn checkParams(s: *Slot, rtx_run: bool, gx: u32, gy: u32) ?u32 {
    const t = &table;
    if (t[ipc.B_PARAMS].bytes < 4 * ipc.P_HEAD or t[ipc.B_PARAMS].flags & ipc.GBF_IN == 0 or t[ipc.B_PARAMS].flags & ipc.GBF_DELTA != 0) return null;
    if (t[ipc.B_PARAMS].off % 4 != 0) return null;
    // (imported, the staging is the client's own memory: read once, here)
    var head: [ipc.P_HEAD]u32 = undefined;
    @memcpy(std.mem.sliceAsBytes(&head), (s.sptr.? + t[ipc.B_PARAMS].off)[0 .. ipc.P_HEAD * 4]);
    const w = &head;
    const pw: u64 = w[ipc.P_W];
    const ph: u64 = w[ipc.P_H];
    const ntri: u64 = w[ipc.P_NTRI];
    if (debug) std.debug.print("params {d} x {d} ntri {d} gx {d} gy {d} flags {x} accum {d} aux {d} m2 {d}\n", .{ pw, ph, ntri, gx, gy, w[ipc.P_CAM + 14], t[ipc.B_ACCUM].bytes, t[ipc.B_AUX].bytes, t[ipc.B_M2].bytes });
    if (pw == 0 or ph == 0 or pw > 16384 or ph > 16384) return null;
    if (gx == 0 or gy == 0 or gx > 4096 or gy > 4096) return null;
    if (t[ipc.B_ACCUM].bytes < pw * ph * 12 or t[ipc.B_AUX].bytes < pw * ph * 28 or t[ipc.B_M2].bytes < pw * ph * 4) return null;
    const flags = w[ipc.P_CAM + 14];
    if (flags & 16 != 0 and t[ipc.B_FILM].bytes < pw * ph * 16) return null;
    if (t[ipc.B_TV].bytes < ntri * 36 or t[ipc.B_TN].bytes < ntri * 36 or t[ipc.B_TM].bytes < ntri * 4) return null;
    if (rtx_run) {
        if (ntri == 0 or ntri > 1 << 27 or t[ipc.B_VP].bytes < ntri * 36) return null;
        if (w[ipc.P_CAM + 13] != 0) return null; // (no balls in this port)
    }
    return @intCast(ntri);
}

fn addrOf(buf: u64) u64 {
    const i = vk.BdaInfo{ .buf = buf };
    return f.GetBufferDeviceAddress.?(device, &i);
}

fn asAddr(as: u64) u64 {
    const i = vk.AsAddrInfo{ .as = as };
    return f.GetAccelerationStructureDeviceAddressKHR.?(device, &i);
}

fn up256(x: u64, a: u64) u64 {
    return (x + a - 1) / a * a;
}

const ident = [12]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0 };

fn triGeom(addr: u64, ntri: u32) vk.AsGeom {
    return .{ .type = vk.GEOM_TRIS, .flags = 2, .g = .{ .tris = .{ .vdata = addr, .maxv = ntri * 3 - 1 } } };
}

fn instGeom(addr: u64) vk.AsGeom {
    return .{ .type = vk.GEOM_INST, .g = .{ .inst = .{ .data = addr } } };
}

const AsWork = struct { build: bool = false, blas: vk.AsBuild = .{}, tlas: vk.AsBuild = .{}, gb: vk.AsGeom = undefined, gt: vk.AsGeom = undefined, ntri: u32 = 0 };
var aswork: AsWork = .{};

/// The structures this run needs: made, to be built (asRecord) when the
/// triangles changed.
fn asPrepare(s: *Slot, ntri: u32) bool {
    const tv = &table[ipc.B_TV];
    const changed = tv.flags & ipc.GBF_IN != 0 and !(tv.flags & ipc.GBF_DELTA != 0 and tv.rn == 0);
    aswork.build = !s.asok or s.nt != ntri or changed;
    aswork.ntri = ntri;
    if (!aswork.build) return true;
    if (s.ibuf == 0) {
        if (!makeBuffer(64, vk.USAGE_ADDR | vk.USAGE_ASIN, .{ vk.MEM_HOST_VISIBLE | vk.MEM_HOST_COHERENT, vk.MEM_HOST_VISIBLE | vk.MEM_HOST_COHERENT }, true, &s.ibuf, &s.imem)) return false;
        var p: ?[*]u8 = null;
        if (f.MapMemory.?(device, s.imem, 0, ~@as(u64, 0), 0, &p) != 0) return false;
        s.iptr = @ptrCast(@alignCast(p));
    }
    const gb = triGeom(addrOf(s.dbuf) + table[ipc.B_VP].off, ntri);
    const gt = instGeom(addrOf(s.ibuf));
    aswork.gb = gb;
    aswork.gt = gt;
    var bb = vk.AsBuild{ .type = vk.AS_BOTTOM, .g = &aswork.gb };
    var bt = vk.AsBuild{ .type = vk.AS_TOP, .g = &aswork.gt };
    var sb = vk.AsSizes{};
    var st = vk.AsSizes{};
    f.GetAccelerationStructureBuildSizesKHR.?(device, vk.BUILD_DEVICE, &bb, &ntri, &sb);
    const one: u32 = 1;
    f.GetAccelerationStructureBuildSizesKHR.?(device, vk.BUILD_DEVICE, &bt, &one, &st);
    const a0 = up256(sb.size, 256);
    const a1 = up256(st.size, 256);
    const scr0 = up256(a0 + a1, @max(scratch_align, 256));
    const need = scr0 + up256(@max(sb.build, st.build), 256) + scratch_align;
    if (s.blas != 0) f.DestroyAccelerationStructureKHR.?(device, s.blas, null);
    if (s.tlas != 0) f.DestroyAccelerationStructureKHR.?(device, s.tlas, null);
    s.blas = 0;
    s.tlas = 0;
    s.asok = false;
    if (need > s.acap) {
        dropBuffer(&s.abuf, &s.amem);
        s.acap = 0;
        const cap = need + need / 8;
        if (!makeBuffer(cap, vk.USAGE_ASSTORE | vk.USAGE_ADDR | vk.USAGE_STORAGE, .{ vk.MEM_DEVICE_LOCAL, 0 }, true, &s.abuf, &s.amem)) return false;
        s.acap = cap;
    }
    const ci0 = vk.AsCI{ .buf = s.abuf, .off = 0, .size = sb.size, .type = vk.AS_BOTTOM };
    if (f.CreateAccelerationStructureKHR.?(device, &ci0, null, &s.blas) != 0) return false;
    const ci1 = vk.AsCI{ .buf = s.abuf, .off = a0, .size = st.size, .type = vk.AS_TOP };
    if (f.CreateAccelerationStructureKHR.?(device, &ci1, null, &s.tlas) != 0) return false;
    // every face seen, never opaque: each candidate comes to the shader
    s.iptr.?.* = .{ .xform = ident, .idx_mask = 0xff << 24, .sbt_flags = (1 | 8) << 24, .ref = asAddr(s.blas) };
    const base = addrOf(s.abuf);
    bb.dst = s.blas;
    bb.scratch = base + scr0;
    bt.dst = s.tlas;
    bt.scratch = base + scr0;
    aswork.blas = bb;
    aswork.tlas = bt;
    s.nt = ntri;
    return true;
}

/// asprep's descriptors (before the commands).
fn prepDescriptors(s: *Slot) void {
    const k = &kernels[ipc.K_PREP];
    const tab = [5]usize{ ipc.B_PARAMS, ipc.B_TV, ipc.B_SPH, ipc.B_VP, ipc.B_AB };
    var inf: [5]vk.BufInfo = undefined;
    var wr: [5]vk.Write = undefined;
    for (tab, 0..) |t, i| {
        inf[i] = .{ .buf = s.dbuf, .off = table[t].off, .range = table[t].bytes };
        wr[i] = .{ .set = k.set, .binding = @intCast(i), .buf = &inf[i] };
    }
    f.UpdateDescriptorSets.?(device, 5, &wr, 0, null);
}

fn bindRun(k: *const Kernel, gx: u32, gy: u32) void {
    f.CmdBindPipeline.?(cbuf, vk.BIND_COMPUTE, k.pipe);
    f.CmdBindDescriptorSets.?(cbuf, vk.BIND_COMPUTE, k.layout, 0, 1, &k.set, 0, null);
    f.CmdDispatch.?(cbuf, gx, gy, 1);
}

fn asRecord(s: *Slot) void {
    const k = &kernels[ipc.K_PREP];
    const groups = (aswork.ntri + 63) / 64;
    bindRun(k, @min(groups, 32768), (groups + 32767) / 32768);
    barrier(vk.PS_COMPUTE, vk.PS_ASBUILD, vk.AC_SHADER_WRITE, vk.AC_AS_READ | vk.AC_SHADER_READ);
    aswork.blas.g = &aswork.gb;
    aswork.tlas.g = &aswork.gt;
    const r0 = vk.AsRange{ .prims = aswork.ntri };
    const r1 = vk.AsRange{ .prims = 1 };
    const p0: *const vk.AsRange = &r0;
    const p1: *const vk.AsRange = &r1;
    f.CmdBuildAccelerationStructuresKHR.?(cbuf, 1, &aswork.blas, &p0);
    barrier(vk.PS_ASBUILD, vk.PS_ASBUILD, vk.AC_AS_WRITE, vk.AC_AS_READ | vk.AC_AS_WRITE);
    f.CmdBuildAccelerationStructuresKHR.?(cbuf, 1, &aswork.tlas, &p1);
    barrier(vk.PS_ASBUILD, vk.PS_COMPUTE, vk.AC_AS_WRITE, vk.AC_AS_READ | vk.AC_SHADER_READ);
    s.asok = true;
}

fn bad(where: u32) u32 {
    if (debug) std.debug.print("beemodel-gpu: run refused at check {d}\n", .{where});
    return 1;
}

fn doRun(m: *const ipc.Msg, ms: *u32) u32 {
    const t0 = nowMs();
    if (m.slot >= ipc.NSLOT) return bad(1);
    const s = &slots[m.slot];
    const ki: usize = if (m.d == 0) ipc.K_PT else m.d - 1;
    if (ki == ipc.K_VIEW) return viewRun(m, s, ms, t0);
    if (ki == ipc.K_RASTER) return rasterRun(m, s, ms, t0);
    if (ki != ipc.K_PT and ki != ipc.K_PTG and ki != ipc.K_PTR and ki != ipc.K_PTGR) return bad(2);
    const rtx_run = ki == ipc.K_PTR or ki == ipc.K_PTGR;
    if (rtx_run and !rtx) return bad(3);
    if (!makeKernel(ki)) return bad(4);
    if (rtx_run and !makeKernel(ipc.K_PREP)) return bad(5);
    const k = &kernels[ki];
    const base = s.base orelse return bad(6);
    const nbind = m.a;
    if (nbind != (if (rtx_run) @as(u32, ipc.PT_NTAB) else ipc.PT_NBIND)) return bad(7);
    const gx = m.b;
    const gy = m.c;
    // the table: a private copy, checked against the size
    @memcpy(std.mem.sliceAsBytes(table[0..nbind]), base[0 .. nbind * ipc.GB_SZ]);
    for (table[0..nbind]) |*b| {
        if (b.bytes == 0 or b.off % ipc.GPU_ALIGN != 0) return bad(8);
        const end = @addWithOverflow(b.off, b.bytes);
        if (end[1] != 0 or end[0] > s.size) return bad(9);
        if (b.off < ipc.GPU_DATA0) return bad(10);
        if (b.bytes > max_range) return bad(11);
    }
    nreg = 0;
    for (0..nbind) |i| {
        const b = &table[i];
        if (i < ipc.PT_NBIND) {
            infos[i] = .{ .buf = s.dbuf, .off = b.off, .range = b.bytes };
            writes[i] = .{ .set = k.set, .binding = @intCast(i), .buf = &infos[i] };
        }
        if (b.flags & ipc.GBF_IN == 0) continue;
        if (b.flags & ipc.GBF_DELTA == 0) {
            if (!upRange(s, b.off, b.bytes)) return bad(12);
            continue;
        }
        const r0: u64 = b.r0;
        const rn: u64 = b.rn;
        if (r0 + rn > ipc.GPU_MAXRANGE) return bad(13);
        const rt: [*]align(1) const [2]u64 = @ptrCast(base + ipc.GPU_RANGES);
        for (r0..r0 + rn) |ri| {
            const r = rt[ri]; // (read once)
            if (r[1] == 0 or r[0] < b.off) return bad(14);
            const e = @addWithOverflow(r[0], r[1]);
            if (e[1] != 0 or e[0] > b.off + b.bytes) return bad(15);
            if (!upRange(s, r[0], r[1])) return bad(16);
        }
    }
    const ntri = checkParams(s, rtx_run, gx, gy) orelse return bad(17);
    var nw: u32 = ipc.PT_NBIND;
    var aswr: vk.WriteAs = .{};
    if (rtx_run) {
        if (!asPrepare(s, ntri)) return bad(18);
        aswr.as = &s.tlas;
        writes[nw] = .{ .next = &aswr, .set = k.set, .binding = ipc.PT_NBIND, .type = vk.DESC_AS };
        nw += 1;
        if (aswork.build) prepDescriptors(s);
    }
    f.UpdateDescriptorSets.?(device, nw, &writes, 0, null);
    if (!begin()) return bad(19);
    if (nreg > 0) f.CmdCopyBuffer.?(cbuf, s.sbuf, s.dbuf, @intCast(nreg), &regions);
    barrier(vk.PS_TRANSFER, vk.PS_COMPUTE, vk.AC_TRANSFER_WRITE, vk.AC_SHADER_READ | vk.AC_SHADER_WRITE);
    if (rtx_run and aswork.build) asRecord(s);
    bindRun(k, gx, gy);
    barrier(vk.PS_COMPUTE, vk.PS_TRANSFER, vk.AC_SHADER_WRITE, vk.AC_TRANSFER_READ);
    nreg = 0;
    for (table[0..nbind]) |*b| {
        if (b.flags & ipc.GBF_OUT == 0) continue;
        regions[nreg] = .{ .src = b.off, .dst = b.off, .size = b.bytes };
        nreg += 1;
    }
    if (nreg > 0) f.CmdCopyBuffer.?(cbuf, s.dbuf, s.sbuf, @intCast(nreg), &regions);
    barrier(vk.PS_TRANSFER, vk.PS_HOST, vk.AC_TRANSFER_WRITE, vk.AC_HOST_READ);
    if (!submitWait()) return bad(20);
    if (!s.host) {
        for (regions[0..nreg]) |r| @memcpy(base[r.src..][0..r.size], s.sptr.?[r.src..][0..r.size]);
    }
    ms.* = @intCast(@max(nowMs() - t0, 0));
    return 0;
}

/// The table, copied and checked; the inputs up. False: refused.
fn takeTable(s: *Slot, base: [*]u8, nbind: u32) bool {
    @memcpy(std.mem.sliceAsBytes(table[0..nbind]), base[0 .. nbind * ipc.GB_SZ]);
    for (table[0..nbind]) |*b| {
        if (b.bytes == 0 or b.off % ipc.GPU_ALIGN != 0 or b.off < ipc.GPU_DATA0 or b.bytes > max_range) return false;
        const end = @addWithOverflow(b.off, b.bytes);
        if (end[1] != 0 or end[0] > s.size) return false;
    }
    nreg = 0;
    for (0..nbind) |i| {
        const b = &table[i];
        if (b.flags & ipc.GBF_IN == 0) continue;
        if (b.flags & ipc.GBF_DELTA != 0) return false; // (whole, for these kernels)
        if (!upRange(s, b.off, b.bytes)) return false;
    }
    return true;
}

fn storageWrites(s: *Slot, k: *const Kernel, nbind: u32) void {
    for (0..nbind) |i| {
        infos[i] = .{ .buf = s.dbuf, .off = table[i].off, .range = table[i].bytes };
        writes[i] = .{ .set = k.set, .binding = @intCast(i), .buf = &infos[i] };
    }
    f.UpdateDescriptorSets.?(device, nbind, &writes, 0, null);
}

fn finishCopies(s: *Slot, base: [*]u8, n: usize) void {
    if (s.host) return;
    for (regions[0..n]) |r| @memcpy(base[r.dst..][0..r.size], s.sptr.?[r.dst..][0..r.size]);
}

/// The tile stage: one workgroup a tile (raster.comp).
fn rasterRun(m: *const ipc.Msg, s: *Slot, ms: *u32, t0: i64) u32 {
    const base = s.base orelse return bad(30);
    if (m.slot != ipc.RS_SLOT or m.a != ipc.RS_NB) return bad(31);
    if (!makeKernel(ipc.K_RASTER)) return bad(32);
    const k = &kernels[ipc.K_RASTER];
    if (!takeTable(s, base, ipc.RS_NB)) return bad(33);
    const t = &table;
    if (t[0].bytes < 32 or t[0].flags & ipc.GBF_IN == 0) return bad(34);
    var head: [8]u32 = undefined;
    @memcpy(std.mem.sliceAsBytes(&head), (s.sptr.? + t[0].off)[0..32]);
    const pw: u64 = head[0];
    const ph: u64 = head[1];
    const ntx: u64 = head[2];
    if (pw == 0 or ph == 0 or pw > 16384 or ph > 16384 or ntx != (pw + 15) / 16) return bad(35);
    const nty = (ph + 15) / 16;
    if (m.b != ntx or m.c != nty) return bad(36);
    if (t[ipc.RS_TOFF].bytes < (ntx * nty + 1) * 4) return bad(37);
    for ([_]usize{ ipc.RS_DEPTH, ipc.RS_IDS, ipc.RS_VIS, ipc.RS_COL }) |i| {
        if (t[i].bytes < pw * ph * 4) return bad(38);
    }
    storageWrites(s, k, ipc.RS_NB);
    if (!begin()) return bad(39);
    if (nreg > 0) f.CmdCopyBuffer.?(cbuf, s.sbuf, s.dbuf, @intCast(nreg), &regions);
    barrier(vk.PS_TRANSFER, vk.PS_COMPUTE, vk.AC_TRANSFER_WRITE, vk.AC_SHADER_READ | vk.AC_SHADER_WRITE);
    bindRun(k, m.b, m.c);
    barrier(vk.PS_COMPUTE, vk.PS_TRANSFER, vk.AC_SHADER_WRITE, vk.AC_TRANSFER_READ);
    nreg = 0;
    for (table[0..ipc.RS_NB]) |*b| {
        if (b.flags & ipc.GBF_OUT == 0) continue;
        regions[nreg] = .{ .src = b.off, .dst = b.off, .size = b.bytes };
        nreg += 1;
    }
    if (nreg > 0) f.CmdCopyBuffer.?(cbuf, s.dbuf, s.sbuf, @intCast(nreg), &regions);
    barrier(vk.PS_TRANSFER, vk.PS_HOST, vk.AC_TRANSFER_WRITE, vk.AC_HOST_READ);
    if (!submitWait()) return bad(40);
    finishCopies(s, base, nreg);
    ms.* = @intCast(@max(nowMs() - t0, 0));
    return 0;
}

// --- the viewport (view.vert, view.frag) ---------------------------------------------------

var gv_rp: u64 = 0;
var gv_w: u32 = 0;
var gv_h: u32 = 0;
var gv_img: [4]u64 = @splat(0);
var gv_mem: [4]u64 = @splat(0);
var gv_view: [4]u64 = @splat(0);
var gv_fb: u64 = 0;
const gv_fmt = [4]u32{ vk.FMT_BGRA8, vk.FMT_R32F, vk.FMT_R32U, vk.FMT_D32F };

fn shaderOf(bytes: []const u8, mod: *u64) bool {
    const words = ca.alloc(u32, bytes.len / 4) catch return false;
    defer ca.free(words);
    @memcpy(std.mem.sliceAsBytes(words), bytes[0 .. words.len * 4]);
    const sci = vk.ShaderCI{ .size = words.len * 4, .code = words.ptr };
    return f.CreateShaderModule.?(device, &sci, null, mod) == 0;
}

fn makeView() bool {
    if (!gfx) return false;
    const k = &kernels[ipc.K_VIEW];
    var att: [4]vk.AttDesc = undefined;
    for (0..4) |i| {
        att[i] = .{ .fmt = gv_fmt[i], .store = if (i < 3) 0 else 1, .layout1 = if (i < 3) vk.LAYOUT_TSRC else vk.LAYOUT_DEPTH };
    }
    const cr = [3]vk.AttRef{ .{ .att = 0, .layout = vk.LAYOUT_COLOR }, .{ .att = 1, .layout = vk.LAYOUT_COLOR }, .{ .att = 2, .layout = vk.LAYOUT_COLOR } };
    const dr = vk.AttRef{ .att = 3, .layout = vk.LAYOUT_DEPTH };
    const sub = vk.Subpass{ .ncol = 3, .col = &cr, .depth = &dr };
    const rpci = vk.RpCI{ .natt = 4, .att = &att, .sub = &sub };
    if (gv_rp == 0 and f.CreateRenderPass.?(device, &rpci, null, &gv_rp) != 0) return false;
    var vert: u64 = 0;
    var frag: u64 = 0;
    if (!shaderOf(@embedFile("spv/viewv.spv"), &vert) or !shaderOf(@embedFile("spv/viewf.spv"), &frag)) return false;
    var b: [ipc.GV_NB]vk.DslBinding = undefined;
    for (0..ipc.GV_NB) |i| b[i] = .{ .binding = @intCast(i), .stage = vk.STAGE_VERTEX | vk.STAGE_FRAGMENT };
    const dci = vk.DslCI{ .n = ipc.GV_NB, .b = &b };
    if (f.CreateDescriptorSetLayout.?(device, &dci, null, &k.dsl) != 0) return false;
    const pci = vk.PlCI{ .dsl = &k.dsl };
    if (f.CreatePipelineLayout.?(device, &pci, null, &k.layout) != 0) return false;
    const st = [2]vk.StageCI{ .{ .stage = vk.STAGE_VERTEX, .module = vert }, .{ .stage = vk.STAGE_FRAGMENT, .module = frag } };
    const vi = vk.ViCI{};
    const ia = vk.IaCI{};
    const vps = vk.VpsCI{};
    const rs = vk.RsCI{};
    const ms = vk.MsCI{};
    const ds = vk.DsCI{};
    const ba = [3]vk.BlendAtt{ .{}, .{}, .{} };
    const cb = vk.CbsCI{ .n = 3, .att = &ba };
    const dy = [2]u32{ 0, 1 };
    const dyn = vk.DynCI{ .n = 2, .st = &dy };
    const gci = vk.GraphicsCI{ .st = &st, .vi = &vi, .ia = &ia, .vp = &vps, .rs = &rs, .ms = &ms, .ds = &ds, .cb = &cb, .dyn = &dyn, .layout = k.layout, .rp = gv_rp };
    if (f.CreateGraphicsPipelines.?(device, 0, 1, &gci, null, &k.pipe) != 0) {
        k.pipe = 0;
        return false;
    }
    const dsa = vk.DsAlloc{ .pool = dpool, .dsl = &k.dsl };
    if (f.AllocateDescriptorSets.?(device, &dsa, &k.set) != 0) {
        k.pipe = 0;
        return false;
    }
    return true;
}

/// Its images, at least this large (they only grow: viewports of two sizes share them).
fn gvImages(w: u32, h: u32) bool {
    if (w <= gv_w and h <= gv_h) return true;
    const nw = @max(w, gv_w);
    const nh = @max(h, gv_h);
    if (gv_fb != 0) f.DestroyFramebuffer.?(device, gv_fb, null);
    gv_fb = 0;
    for (0..4) |i| {
        if (gv_view[i] != 0) f.DestroyImageView.?(device, gv_view[i], null);
        if (gv_img[i] != 0) f.DestroyImage.?(device, gv_img[i], null);
        if (gv_mem[i] != 0) f.FreeMemory.?(device, gv_mem[i], null);
        gv_view[i] = 0;
        gv_img[i] = 0;
        gv_mem[i] = 0;
    }
    gv_w = 0;
    gv_h = 0;
    for (0..4) |i| {
        const usage: u32 = if (i < 3) vk.IMG_COLOR | vk.IMG_TSRC else vk.IMG_DEPTH;
        const ici = vk.ImageCI{ .fmt = gv_fmt[i], .w = nw, .h = nh, .usage = usage };
        if (f.CreateImage.?(device, &ici, null, &gv_img[i]) != 0) return false;
        var req: vk.MemReq = undefined;
        f.GetImageMemoryRequirements.?(device, gv_img[i], &req);
        const ty = memType(req.bits, vk.MEM_DEVICE_LOCAL) orelse return false;
        const ma = vk.MemAlloc{ .size = req.size, .type = ty };
        if (f.AllocateMemory.?(device, &ma, null, &gv_mem[i]) != 0) return false;
        if (f.BindImageMemory.?(device, gv_img[i], gv_mem[i], 0) != 0) return false;
        const vci = vk.ViewCI{ .img = gv_img[i], .fmt = gv_fmt[i], .aspect = if (i < 3) 1 else 2 };
        if (f.CreateImageView.?(device, &vci, null, &gv_view[i]) != 0) return false;
    }
    const fb = vk.FbCI{ .rp = gv_rp, .natt = 4, .att = &gv_view, .w = nw, .h = nh };
    if (f.CreateFramebuffer.?(device, &fb, null, &gv_fb) != 0) return false;
    gv_w = nw;
    gv_h = nh;
    return true;
}

/// One render pass, one indirect call; colour, 1/z and ids into their bindings.
fn viewRun(m: *const ipc.Msg, s: *Slot, ms: *u32, t0: i64) u32 {
    const base = s.base orelse return bad(50);
    if (!gfx or m.slot != ipc.GV_SLOT or m.a != ipc.GV_NB) return bad(51);
    const w = m.b;
    const h = m.c;
    const ndraw = m.rest[0];
    if (w == 0 or h == 0 or w > 16384 or h > 16384) return bad(52);
    if (!makeKernel(ipc.K_VIEW)) return bad(53);
    const k = &kernels[ipc.K_VIEW];
    if (!takeTable(s, base, ipc.GV_NB)) return bad(54);
    const t = &table;
    const px = @as(u64, w) * h * 4;
    if (t[ipc.GV_COL].bytes < px or t[ipc.GV_INVZ].bytes < px or t[ipc.GV_ID].bytes < px) return bad(55);
    if (t[ipc.GV_IND].bytes < @as(u64, ndraw) * 16) return bad(56);
    if (!gvImages(w, h)) return bad(57);
    storageWrites(s, k, ipc.GV_NB);
    if (!begin()) return bad(58);
    if (nreg > 0) f.CmdCopyBuffer.?(cbuf, s.sbuf, s.dbuf, @intCast(nreg), &regions);
    barrier(vk.PS_TRANSFER, vk.PS_INDIRECT | vk.PS_VERTEX | vk.PS_FRAGMENT, vk.AC_TRANSFER_WRITE, vk.AC_INDIRECT | vk.AC_SHADER_READ);
    const clear = [4]vk.ClearValue{ .{}, .{}, .{}, .{} };
    const rb = vk.RpBegin{ .rp = gv_rp, .fb = gv_fb, .w = w, .h = h, .nc = 4, .clear = &clear };
    f.CmdBeginRenderPass.?(cbuf, &rb, 0);
    f.CmdBindPipeline.?(cbuf, vk.BIND_GRAPHICS, k.pipe);
    f.CmdBindDescriptorSets.?(cbuf, vk.BIND_GRAPHICS, k.layout, 0, 1, &k.set, 0, null);
    const vp = vk.Viewport{ .w = @floatFromInt(w), .h = @floatFromInt(h) };
    const sc = vk.Rect2{ .w = w, .h = h };
    f.CmdSetViewport.?(cbuf, 0, 1, &vp);
    f.CmdSetScissor.?(cbuf, 0, 1, &sc);
    if (ndraw > 0) f.CmdDrawIndirect.?(cbuf, s.dbuf, t[ipc.GV_IND].off, ndraw, 16);
    f.CmdEndRenderPass.?(cbuf);
    const outs = [3]usize{ ipc.GV_COL, ipc.GV_INVZ, ipc.GV_ID };
    for (outs, 0..) |b, i| {
        const r = vk.BufImgCopy{ .off = t[b].off, .w = w, .h = h };
        f.CmdCopyImageToBuffer.?(cbuf, gv_img[i], vk.LAYOUT_TSRC, s.sbuf, 1, &r);
        regions[i] = .{ .dst = t[b].off, .size = px };
    }
    barrier(vk.PS_TRANSFER, vk.PS_HOST, vk.AC_TRANSFER_WRITE, vk.AC_HOST_READ);
    if (!submitWait()) return bad(59);
    finishCopies(s, base, 3);
    ms.* = @intCast(@max(nowMs() - t0, 0));
    return 0;
}

fn doWarm(rtx_taken: bool) u32 {
    // (a kernel that does not build is not fatal here: its render stays on the CPU)
    _ = makeKernel(ipc.K_PT);
    if (rtx) {
        _ = makeKernel(ipc.K_PTR);
        _ = makeKernel(ipc.K_PTGR);
        _ = makeKernel(ipc.K_PREP);
    }
    if (!rtx or !rtx_taken) _ = makeKernel(ipc.K_PTG);
    _ = makeKernel(ipc.K_RASTER);
    if (gfx) _ = makeKernel(ipc.K_VIEW);
    return 0;
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

pub fn main() void {
    // RADV's ACO instruction scheduler (Mesa 26.2) miscompiles ptg, the compute
    // path with graphs: textures come out wrong, on this kernel alone, and the
    // right image with this set (tests/gpu.py). Other drivers do not read it.
    _ = setenv("ACO_DEBUG", "nosched", 0);
    allow_cpu = envIs("BEEMODEL_GPU", "any");
    fail_at = envInt("BEEMODEL_GPU_FAIL");
    hang_at = envInt("BEEMODEL_GPU_HANG");
    slow_ms = envInt("BEEMODEL_GPU_SLOW");
    debug = env("BEEMODEL_GPU_DEBUG") != null;
    const st = setup();
    var hello = ipc.Msg{ .cmd = ipc.MSG_HELLO, .slot = st, .a = ipc.GPU_MAGIC };
    if (st == 0) {
        hello.b = pdType(&props) | ipc.GH_PORT | (if (rtx) @as(u32, ipc.GH_RTX) else 0) | (if (hostmem) @as(u32, ipc.GH_HOSTMEM) else 0) | (if (gfx) @as(u32, ipc.GH_GFX) else 0);
        const nm: [*]const u8 = @ptrCast(&props);
        const name = hello.name();
        @memcpy(name[0..47], nm[20..][0..47]);
        name[47] = 0;
    }
    send(&hello);
    if (st != 0) return;
    while (true) {
        var m: ipc.Msg = undefined;
        var fd: i32 = -1;
        if (!recv(&m, &fd)) return;
        var ms: u32 = 0;
        var status: u32 = 0;
        switch (m.cmd) {
            ipc.MSG_MAP => status = doMap(&m, fd),
            ipc.MSG_WARM => status = doWarm(m.slot == 1),
            ipc.MSG_RUN => {
                runs += 1;
                if (runs == fail_at) return; // (the tests' failure: as if killed)
                if (runs == hang_at) {
                    while (true) {
                        var ts = linux.timespec{ .sec = 3600, .nsec = 0 };
                        _ = linux.nanosleep(&ts, null);
                    }
                }
                if (slow_ms > 0) {
                    var ts = linux.timespec{ .sec = 0, .nsec = @as(isize, slow_ms) * 1_000_000 };
                    _ = linux.nanosleep(&ts, null);
                }
                status = doRun(&m, &ms);
            },
            else => return, // MSG_QUIT, or anything else
        }
        if (fd >= 0 and m.cmd != ipc.MSG_MAP) _ = linux.close(fd);
        var r = ipc.Msg{ .cmd = ipc.MSG_REPLY, .slot = status, .a = ms };
        send(&r);
        if (status != 0) return; // a failure ends the helper: the CPU goes on
    }
}
