// The part of Vulkan the helper uses, by hand: no headers are needed to build it.
pub const Handle = ?*opaque {};
pub const U64H = u64; // non-dispatchable handles
pub const Result = i32;
pub const SUCCESS: Result = 0;
pub const TIMEOUT: Result = 2;

pub const ST_APP = 0;
pub const ST_INSTANCE = 1;
pub const ST_DEVQ = 2;
pub const ST_DEVICE = 3;
pub const ST_SUBMIT = 4;
pub const ST_MEMALLOC = 5;
pub const ST_FENCE = 8;
pub const ST_BUFFER = 12;
pub const ST_SHADER = 16;
pub const ST_STAGE = 18;
pub const ST_COMPUTE = 29;
pub const ST_PLAYOUT = 30;
pub const ST_DSL = 32;
pub const ST_DPOOL = 33;
pub const ST_DSALLOC = 34;
pub const ST_WRITE = 35;
pub const ST_CPOOL = 39;
pub const ST_CBALLOC = 40;
pub const ST_CBBEGIN = 42;
pub const ST_MEMBARRIER = 46;
pub const ST_FEATS2 = 1000059000;
pub const ST_PROPS2 = 1000059001;
pub const ST_ALLOCFLAGS = 1000060000;
pub const ST_BDA_INFO = 1000244001;
pub const ST_BDA_FEATS = 1000257000;
pub const ST_AS_BUILD = 1000150000;
pub const ST_AS_ADDR = 1000150002;
pub const ST_AS_INST = 1000150004;
pub const ST_AS_TRIS = 1000150005;
pub const ST_AS_GEOM = 1000150006;
pub const ST_WRITE_AS = 1000150007;
pub const ST_AS_FEATS = 1000150013;
pub const ST_AS_PROPS = 1000150014;
pub const ST_AS_CREATE = 1000150017;
pub const ST_AS_SIZES = 1000150020;
pub const ST_RQ_FEATS = 1000348013;
pub const ST_EXTBUF = 1000072000;
pub const ST_IMPORTHOST = 1000178000;
pub const ST_HOSTPTRPROPS = 1000178001;
pub const ST_EXTHOSTPROPS = 1000178002;
pub const HT_HOST = 0x80;

pub const API_1_1: u32 = 1 << 22 | 1 << 12;
pub const API_1_2: u32 = 1 << 22 | 2 << 12;

pub const DESC_STORAGE = 7;
pub const DESC_AS = 1000150000;
pub const STAGE_COMPUTE = 32;
pub const BIND_COMPUTE = 1;
pub const QUEUE_COMPUTE = 2;
pub const USAGE_TSRC = 1;
pub const USAGE_TDST = 2;
pub const USAGE_STORAGE = 32;
pub const USAGE_ADDR = 0x20000;
pub const USAGE_ASIN = 0x80000;
pub const USAGE_ASSTORE = 0x100000;
pub const MEM_DEVICE_LOCAL = 1;
pub const MEM_HOST_VISIBLE = 2;
pub const MEM_HOST_COHERENT = 4;
pub const MEM_HOST_CACHED = 8;
pub const PS_TRANSFER = 4096;
pub const PS_COMPUTE = 2048;
pub const PS_HOST = 16384;
pub const PS_ASBUILD = 0x02000000;
pub const AC_TRANSFER_WRITE = 4096;
pub const AC_TRANSFER_READ = 2048;
pub const AC_SHADER_READ = 32;
pub const AC_SHADER_WRITE = 64;
pub const AC_HOST_READ = 8192;
pub const AC_AS_READ = 0x200000;
pub const AC_AS_WRITE = 0x400000;
pub const FMT_RGB32F = 106;
pub const INDEX_NONE = 1000165000;
pub const DT_INTEGRATED = 1;
pub const DT_DISCRETE = 2;
pub const DT_VIRTUAL = 3;
pub const DT_CPU = 4;
pub const AS_TOP = 0;
pub const AS_BOTTOM = 1;
pub const GEOM_TRIS = 0;
pub const GEOM_INST = 2;
pub const BUILD_DEVICE = 1;

pub const QUEUE_GRAPHICS = 1;
pub const USAGE_INDIRECT = 256;
pub const IMG_TSRC = 1;
pub const IMG_COLOR = 16;
pub const IMG_DEPTH = 32;
pub const STAGE_VERTEX = 1;
pub const STAGE_FRAGMENT = 16;
pub const BIND_GRAPHICS = 0;
pub const PS_INDIRECT = 2;
pub const PS_VERTEX = 8;
pub const PS_FRAGMENT = 128;
pub const PS_EARLY_FRAG = 256;
pub const PS_LATE_FRAG = 512;
pub const PS_COLOR_OUT = 1024;
pub const AC_INDIRECT = 1;
pub const AC_COLOR_WRITE = 256;
pub const AC_DEPTH_WRITE = 1024;
pub const FMT_BGRA8 = 44;
pub const FMT_R32F = 100;
pub const FMT_R32U = 98;
pub const FMT_D32F = 126;
pub const LAYOUT_COLOR = 2;
pub const LAYOUT_DEPTH = 3;
pub const LAYOUT_TSRC = 6;
pub const ST_IMAGE = 14;
pub const ST_IMAGEVIEW = 15;
pub const ST_VI = 19;
pub const ST_IA = 20;
pub const ST_VPS = 22;
pub const ST_RS = 23;
pub const ST_MS = 24;
pub const ST_DS = 25;
pub const ST_CBS = 26;
pub const ST_DYN = 27;
pub const ST_GRAPHICS = 28;
pub const ST_FRAMEBUFFER = 37;
pub const ST_RENDERPASS = 38;
pub const ST_RPBEGIN = 43;

pub const ImageCI = extern struct { s: u32 = ST_IMAGE, next: ?*const anyopaque = null, flags: u32 = 0, ty: u32 = 1, fmt: u32 = 0, w: u32 = 0, h: u32 = 0, d: u32 = 1, mips: u32 = 1, layers: u32 = 1, samples: u32 = 1, tiling: u32 = 0, usage: u32 = 0, sharing: u32 = 0, nq: u32 = 0, q: ?*const u32 = null, layout: u32 = 0 };
pub const ViewCI = extern struct { s: u32 = ST_IMAGEVIEW, next: ?*const anyopaque = null, flags: u32 = 0, img: u64 = 0, ty: u32 = 1, fmt: u32 = 0, comps: [4]u32 = @splat(0), aspect: u32 = 1, mip0: u32 = 0, mips: u32 = 1, layer0: u32 = 0, layers: u32 = 1 };
pub const AttDesc = extern struct { flags: u32 = 0, fmt: u32 = 0, samples: u32 = 1, load: u32 = 1, store: u32 = 0, sload: u32 = 2, sstore: u32 = 1, layout0: u32 = 0, layout1: u32 = 0 };
pub const AttRef = extern struct { att: u32 = 0, layout: u32 = 0 };
pub const Subpass = extern struct { flags: u32 = 0, bind: u32 = 0, nin: u32 = 0, inp: ?*const AttRef = null, ncol: u32 = 0, col: ?[*]const AttRef = null, res: ?*const AttRef = null, depth: ?*const AttRef = null, npres: u32 = 0, pres: ?*const u32 = null };
pub const RpCI = extern struct { s: u32 = ST_RENDERPASS, next: ?*const anyopaque = null, flags: u32 = 0, natt: u32 = 0, att: ?[*]const AttDesc = null, nsub: u32 = 1, sub: ?*const Subpass = null, ndep: u32 = 0, dep: ?*const anyopaque = null };
pub const FbCI = extern struct { s: u32 = ST_FRAMEBUFFER, next: ?*const anyopaque = null, flags: u32 = 0, rp: u64 = 0, natt: u32 = 0, att: ?[*]const u64 = null, w: u32 = 0, h: u32 = 0, layers: u32 = 1 };
pub const ViCI = extern struct { s: u32 = ST_VI, next: ?*const anyopaque = null, flags: u32 = 0, nb: u32 = 0, b: ?*const anyopaque = null, na: u32 = 0, a: ?*const anyopaque = null };
pub const IaCI = extern struct { s: u32 = ST_IA, next: ?*const anyopaque = null, flags: u32 = 0, topo: u32 = 3, restart: u32 = 0 };
pub const VpsCI = extern struct { s: u32 = ST_VPS, next: ?*const anyopaque = null, flags: u32 = 0, nv: u32 = 1, v: ?*const anyopaque = null, ns: u32 = 1, sc: ?*const anyopaque = null };
pub const RsCI = extern struct { s: u32 = ST_RS, next: ?*const anyopaque = null, flags: u32 = 0, clamp: u32 = 0, discard: u32 = 0, poly: u32 = 0, cull: u32 = 0, front: u32 = 0, bias: u32 = 0, bc: f32 = 0, bcl: f32 = 0, bs: f32 = 0, line: f32 = 1 };
pub const MsCI = extern struct { s: u32 = ST_MS, next: ?*const anyopaque = null, flags: u32 = 0, samples: u32 = 1, shading: u32 = 0, mins: f32 = 0, mask: ?*const u32 = null, a2c: u32 = 0, a2o: u32 = 0 };
pub const DsCI = extern struct { s: u32 = ST_DS, next: ?*const anyopaque = null, flags: u32 = 0, test_: u32 = 1, write: u32 = 1, op: u32 = 4, bounds: u32 = 0, stencil: u32 = 0, front: [7]u32 = @splat(0), back: [7]u32 = @splat(0), min: f32 = 0, max: f32 = 1 };
pub const BlendAtt = extern struct { blend: u32 = 0, a: u32 = 0, b: u32 = 0, c: u32 = 0, d: u32 = 0, e: u32 = 0, f: u32 = 0, mask: u32 = 15 };
pub const CbsCI = extern struct { s: u32 = ST_CBS, next: ?*const anyopaque = null, flags: u32 = 0, logic: u32 = 0, op: u32 = 0, n: u32 = 0, att: ?[*]const BlendAtt = null, k: [4]f32 = @splat(0) };
pub const DynCI = extern struct { s: u32 = ST_DYN, next: ?*const anyopaque = null, flags: u32 = 0, n: u32 = 0, st: ?[*]const u32 = null };
pub const GraphicsCI = extern struct { s: u32 = ST_GRAPHICS, next: ?*const anyopaque = null, flags: u32 = 0, nst: u32 = 2, st: ?[*]const StageCI = null, vi: ?*const ViCI = null, ia: ?*const IaCI = null, ts: ?*const anyopaque = null, vp: ?*const VpsCI = null, rs: ?*const RsCI = null, ms: ?*const MsCI = null, ds: ?*const DsCI = null, cb: ?*const CbsCI = null, dyn: ?*const DynCI = null, layout: u64 = 0, rp: u64 = 0, sub: u32 = 0, base: u64 = 0, base_i: i32 = -1 };
pub const ClearValue = extern struct { v: [4]u32 = @splat(0) };
pub const RpBegin = extern struct { s: u32 = ST_RPBEGIN, next: ?*const anyopaque = null, rp: u64 = 0, fb: u64 = 0, x: i32 = 0, y: i32 = 0, w: u32 = 0, h: u32 = 0, nc: u32 = 0, clear: ?[*]const ClearValue = null };
pub const Viewport = extern struct { x: f32 = 0, y: f32 = 0, w: f32 = 0, h: f32 = 0, mn: f32 = 0, mx: f32 = 1 };
pub const Rect2 = extern struct { x: i32 = 0, y: i32 = 0, w: u32 = 0, h: u32 = 0 };
pub const BufImgCopy = extern struct { off: u64 = 0, row: u32 = 0, height: u32 = 0, aspect: u32 = 1, mip: u32 = 0, layer: u32 = 0, layers: u32 = 1, x: i32 = 0, y: i32 = 0, z: i32 = 0, w: u32 = 0, h: u32 = 0, d: u32 = 1 };

pub const AppInfo = extern struct { s: u32 = ST_APP, next: ?*const anyopaque = null, name: ?[*:0]const u8 = null, ver: u32 = 0, engine: ?[*:0]const u8 = null, ever: u32 = 0, api: u32 = 0 };
pub const InstanceCI = extern struct { s: u32 = ST_INSTANCE, next: ?*const anyopaque = null, flags: u32 = 0, app: ?*const AppInfo = null, nlayer: u32 = 0, layers: ?*const anyopaque = null, next_: u32 = 0, exts: ?[*]const [*:0]const u8 = null };
pub const QueueFamily = extern struct { flags: u32, count: u32, ts: u32, gran: [3]u32 };
pub const DevQCI = extern struct { s: u32 = ST_DEVQ, next: ?*const anyopaque = null, flags: u32 = 0, family: u32 = 0, count: u32 = 1, prio: ?[*]const f32 = null };
pub const DeviceCI = extern struct { s: u32 = ST_DEVICE, next: ?*const anyopaque = null, flags: u32 = 0, nq: u32 = 1, q: ?*const DevQCI = null, nlayer: u32 = 0, layers: ?*const anyopaque = null, next_: u32 = 0, exts: ?[*]const [*:0]const u8 = null, feats: ?*const anyopaque = null };
pub const ExtProps = extern struct { name: [256]u8, ver: u32 };
pub const MemReq = extern struct { size: u64, alignment: u64, bits: u32 };
pub const MemType = extern struct { flags: u32, heap: u32 };
pub const MemHeap = extern struct { size: u64, flags: u32 };
pub const MemProps = extern struct { ntype: u32, types: [32]MemType, nheap: u32, heaps: [16]MemHeap };
pub const BufferCI = extern struct { s: u32 = ST_BUFFER, next: ?*const anyopaque = null, flags: u32 = 0, size: u64 = 0, usage: u32 = 0, sharing: u32 = 0, nq: u32 = 0, q: ?*const u32 = null };
pub const MemAlloc = extern struct { s: u32 = ST_MEMALLOC, next: ?*const anyopaque = null, size: u64 = 0, type: u32 = 0 };
pub const MemAllocFlags = extern struct { s: u32 = ST_ALLOCFLAGS, next: ?*const anyopaque = null, flags: u32 = 2, mask: u32 = 0 };
pub const ShaderCI = extern struct { s: u32 = ST_SHADER, next: ?*const anyopaque = null, flags: u32 = 0, size: usize = 0, code: ?[*]const u32 = null };
pub const DslBinding = extern struct { binding: u32 = 0, type: u32 = DESC_STORAGE, count: u32 = 1, stage: u32 = STAGE_COMPUTE, samplers: ?*const anyopaque = null };
pub const DslCI = extern struct { s: u32 = ST_DSL, next: ?*const anyopaque = null, flags: u32 = 0, n: u32 = 0, b: ?[*]const DslBinding = null };
pub const PlCI = extern struct { s: u32 = ST_PLAYOUT, next: ?*const anyopaque = null, flags: u32 = 0, n: u32 = 1, dsl: ?*const u64 = null, npc: u32 = 0, pc: ?*const anyopaque = null };
pub const StageCI = extern struct { s: u32 = ST_STAGE, next: ?*const anyopaque = null, flags: u32 = 0, stage: u32 = STAGE_COMPUTE, module: u64 = 0, name: [*:0]const u8 = "main", spec: ?*const anyopaque = null };
pub const ComputeCI = extern struct { s: u32 = ST_COMPUTE, next: ?*const anyopaque = null, flags: u32 = 0, stage: StageCI = .{}, layout: u64 = 0, base: u64 = 0, base_i: i32 = -1 };
pub const PoolSize = extern struct { type: u32, count: u32 };
pub const DPoolCI = extern struct { s: u32 = ST_DPOOL, next: ?*const anyopaque = null, flags: u32 = 0, max: u32 = 0, n: u32 = 0, sizes: ?[*]const PoolSize = null };
pub const DsAlloc = extern struct { s: u32 = ST_DSALLOC, next: ?*const anyopaque = null, pool: u64 = 0, n: u32 = 1, dsl: ?*const u64 = null };
pub const BufInfo = extern struct { buf: u64 = 0, off: u64 = 0, range: u64 = 0 };
pub const Write = extern struct { s: u32 = ST_WRITE, next: ?*const anyopaque = null, set: u64 = 0, binding: u32 = 0, elem: u32 = 0, n: u32 = 1, type: u32 = DESC_STORAGE, img: ?*const anyopaque = null, buf: ?*const BufInfo = null, view: ?*const anyopaque = null };
pub const CPoolCI = extern struct { s: u32 = ST_CPOOL, next: ?*const anyopaque = null, flags: u32 = 2, family: u32 = 0 };
pub const CbAlloc = extern struct { s: u32 = ST_CBALLOC, next: ?*const anyopaque = null, pool: u64 = 0, level: u32 = 0, n: u32 = 1 };
pub const CbBegin = extern struct { s: u32 = ST_CBBEGIN, next: ?*const anyopaque = null, flags: u32 = 1, inh: ?*const anyopaque = null };
pub const MemBarrier = extern struct { s: u32 = ST_MEMBARRIER, next: ?*const anyopaque = null, src: u32 = 0, dst: u32 = 0 };
pub const BufCopy = extern struct { src: u64 = 0, dst: u64 = 0, size: u64 = 0 };
pub const Submit = extern struct { s: u32 = ST_SUBMIT, next: ?*const anyopaque = null, nwait: u32 = 0, wait: ?*const anyopaque = null, stages: ?*const anyopaque = null, ncb: u32 = 1, cb: ?*const Handle = null, nsig: u32 = 0, sig: ?*const anyopaque = null };
pub const FenceCI = extern struct { s: u32 = ST_FENCE, next: ?*const anyopaque = null, flags: u32 = 0 };

pub const Feats2 = extern struct { s: u32 = ST_FEATS2, next: ?*anyopaque = null, f: [55]u32 = @splat(0) };
pub const BdaFeats = extern struct { s: u32 = ST_BDA_FEATS, next: ?*anyopaque = null, bda: u32 = 0, replay: u32 = 0, multi: u32 = 0 };
pub const AsFeats = extern struct { s: u32 = ST_AS_FEATS, next: ?*anyopaque = null, as: u32 = 0, replay: u32 = 0, indirect: u32 = 0, host: u32 = 0, uab: u32 = 0 };
pub const RqFeats = extern struct { s: u32 = ST_RQ_FEATS, next: ?*anyopaque = null, rq: u32 = 0 };
pub const Props2 = extern struct { s: u32 = ST_PROPS2, next: ?*anyopaque = null, p: [824 / 8]u64 = @splat(0) };
pub const AsProps = extern struct { s: u32 = ST_AS_PROPS, next: ?*anyopaque = null, geoms: u64 = 0, insts: u64 = 0, prims: u64 = 0, a: u32 = 0, b: u32 = 0, c: u32 = 0, d: u32 = 0, scratch: u32 = 0 };
pub const BdaInfo = extern struct { s: u32 = ST_BDA_INFO, next: ?*const anyopaque = null, buf: u64 = 0 };
pub const AsCI = extern struct { s: u32 = ST_AS_CREATE, next: ?*const anyopaque = null, flags: u32 = 0, buf: u64 = 0, off: u64 = 0, size: u64 = 0, type: u32 = 0, addr: u64 = 0 };
pub const AsSizes = extern struct { s: u32 = ST_AS_SIZES, next: ?*const anyopaque = null, size: u64 = 0, update: u64 = 0, build: u64 = 0 };
pub const AsTris = extern struct { s: u32 = ST_AS_TRIS, next: ?*const anyopaque = null, fmt: u32 = FMT_RGB32F, vdata: u64 = 0, stride: u64 = 12, maxv: u32 = 0, itype: u32 = INDEX_NONE, idata: u64 = 0, xform: u64 = 0 };
pub const AsInst = extern struct { s: u32 = ST_AS_INST, next: ?*const anyopaque = null, ptrs: u32 = 0, data: u64 = 0 };
pub const AsGeomData = extern union { tris: AsTris, inst: AsInst };
pub const AsGeom = extern struct { s: u32 = ST_AS_GEOM, next: ?*const anyopaque = null, type: u32 = 0, g: AsGeomData, flags: u32 = 0 };
pub const AsBuild = extern struct { s: u32 = ST_AS_BUILD, next: ?*const anyopaque = null, type: u32 = 0, flags: u32 = 4, mode: u32 = 0, src: u64 = 0, dst: u64 = 0, n: u32 = 1, g: ?*const AsGeom = null, pg: ?*const anyopaque = null, scratch: u64 = 0 };
pub const AsRange = extern struct { prims: u32 = 0, off: u32 = 0, first: u32 = 0, xform: u32 = 0 };
pub const AsAddrInfo = extern struct { s: u32 = ST_AS_ADDR, next: ?*const anyopaque = null, as: u64 = 0 };
pub const WriteAs = extern struct { s: u32 = ST_WRITE_AS, next: ?*const anyopaque = null, n: u32 = 1, as: ?*const u64 = null };
pub const AsInstance = extern struct { xform: [12]f32, idx_mask: u32, sbt_flags: u32, ref: u64 };
pub const ExtBufCI = extern struct { s: u32 = ST_EXTBUF, next: ?*const anyopaque = null, types: u32 = HT_HOST };
pub const ImportHost = extern struct { s: u32 = ST_IMPORTHOST, next: ?*const anyopaque = null, type: u32 = HT_HOST, ptr: ?*anyopaque = null };
pub const HostPtrProps = extern struct { s: u32 = ST_HOSTPTRPROPS, next: ?*anyopaque = null, bits: u32 = 0 };
pub const ExtHostProps = extern struct { s: u32 = ST_EXTHOSTPROPS, next: ?*anyopaque = null, alignment: u64 = 0 };

const Cc = @import("std").builtin.CallingConvention;
fn F(comptime T: type) type {
    return ?T;
}
const H = Handle;
const P = ?*const anyopaque;
pub const Fns = struct {
    CreateInstance: ?*const fn (*const InstanceCI, P, *H) callconv(.c) Result = null,
    EnumerateInstanceVersion: ?*const fn (*u32) callconv(.c) Result = null,
    EnumeratePhysicalDevices: ?*const fn (H, *u32, ?[*]H) callconv(.c) Result = null,
    GetPhysicalDeviceProperties: ?*const fn (H, *[824 / 8]u64) callconv(.c) void = null,
    GetPhysicalDeviceFeatures: ?*const fn (H, *[55]u32) callconv(.c) void = null,
    GetPhysicalDeviceQueueFamilyProperties: ?*const fn (H, *u32, ?[*]QueueFamily) callconv(.c) void = null,
    GetPhysicalDeviceMemoryProperties: ?*const fn (H, *MemProps) callconv(.c) void = null,
    EnumerateDeviceExtensionProperties: ?*const fn (H, ?[*:0]const u8, *u32, ?[*]ExtProps) callconv(.c) Result = null,
    GetPhysicalDeviceFeatures2: ?*const fn (H, *Feats2) callconv(.c) void = null,
    GetPhysicalDeviceProperties2: ?*const fn (H, *Props2) callconv(.c) void = null,
    CreateDevice: ?*const fn (H, *const DeviceCI, P, *H) callconv(.c) Result = null,
    GetDeviceQueue: ?*const fn (H, u32, u32, *H) callconv(.c) void = null,
    CreateBuffer: ?*const fn (H, *const BufferCI, P, *u64) callconv(.c) Result = null,
    DestroyBuffer: ?*const fn (H, u64, P) callconv(.c) void = null,
    GetBufferMemoryRequirements: ?*const fn (H, u64, *MemReq) callconv(.c) void = null,
    AllocateMemory: ?*const fn (H, *const MemAlloc, P, *u64) callconv(.c) Result = null,
    FreeMemory: ?*const fn (H, u64, P) callconv(.c) void = null,
    BindBufferMemory: ?*const fn (H, u64, u64, u64) callconv(.c) Result = null,
    MapMemory: ?*const fn (H, u64, u64, u64, u32, *?[*]u8) callconv(.c) Result = null,
    UnmapMemory: ?*const fn (H, u64) callconv(.c) void = null,
    InvalidateMappedMemoryRanges: ?*const fn (H, u32, *const MappedRange) callconv(.c) Result = null,
    FlushMappedMemoryRanges: ?*const fn (H, u32, *const MappedRange) callconv(.c) Result = null,
    CreateShaderModule: ?*const fn (H, *const ShaderCI, P, *u64) callconv(.c) Result = null,
    CreateDescriptorSetLayout: ?*const fn (H, *const DslCI, P, *u64) callconv(.c) Result = null,
    CreatePipelineLayout: ?*const fn (H, *const PlCI, P, *u64) callconv(.c) Result = null,
    CreateComputePipelines: ?*const fn (H, u64, u32, *const ComputeCI, P, *u64) callconv(.c) Result = null,
    CreateDescriptorPool: ?*const fn (H, *const DPoolCI, P, *u64) callconv(.c) Result = null,
    AllocateDescriptorSets: ?*const fn (H, *const DsAlloc, *u64) callconv(.c) Result = null,
    UpdateDescriptorSets: ?*const fn (H, u32, [*]const Write, u32, P) callconv(.c) void = null,
    CreateCommandPool: ?*const fn (H, *const CPoolCI, P, *u64) callconv(.c) Result = null,
    AllocateCommandBuffers: ?*const fn (H, *const CbAlloc, *H) callconv(.c) Result = null,
    ResetCommandBuffer: ?*const fn (H, u32) callconv(.c) Result = null,
    BeginCommandBuffer: ?*const fn (H, *const CbBegin) callconv(.c) Result = null,
    EndCommandBuffer: ?*const fn (H) callconv(.c) Result = null,
    CmdBindPipeline: ?*const fn (H, u32, u64) callconv(.c) void = null,
    CmdBindDescriptorSets: ?*const fn (H, u32, u64, u32, u32, *const u64, u32, P) callconv(.c) void = null,
    CmdDispatch: ?*const fn (H, u32, u32, u32) callconv(.c) void = null,
    CmdCopyBuffer: ?*const fn (H, u64, u64, u32, [*]const BufCopy) callconv(.c) void = null,
    CmdFillBuffer: ?*const fn (H, u64, u64, u64, u32) callconv(.c) void = null,
    CmdPipelineBarrier: ?*const fn (H, u32, u32, u32, u32, *const MemBarrier, u32, P, u32, P) callconv(.c) void = null,
    QueueSubmit: ?*const fn (H, u32, *const Submit, u64) callconv(.c) Result = null,
    CreateFence: ?*const fn (H, *const FenceCI, P, *u64) callconv(.c) Result = null,
    WaitForFences: ?*const fn (H, u32, *const u64, u32, u64) callconv(.c) Result = null,
    ResetFences: ?*const fn (H, u32, *const u64) callconv(.c) Result = null,
    CreateImage: ?*const fn (H, *const ImageCI, P, *u64) callconv(.c) Result = null,
    DestroyImage: ?*const fn (H, u64, P) callconv(.c) void = null,
    GetImageMemoryRequirements: ?*const fn (H, u64, *MemReq) callconv(.c) void = null,
    BindImageMemory: ?*const fn (H, u64, u64, u64) callconv(.c) Result = null,
    CreateImageView: ?*const fn (H, *const ViewCI, P, *u64) callconv(.c) Result = null,
    DestroyImageView: ?*const fn (H, u64, P) callconv(.c) void = null,
    CreateRenderPass: ?*const fn (H, *const RpCI, P, *u64) callconv(.c) Result = null,
    CreateFramebuffer: ?*const fn (H, *const FbCI, P, *u64) callconv(.c) Result = null,
    DestroyFramebuffer: ?*const fn (H, u64, P) callconv(.c) void = null,
    CreateGraphicsPipelines: ?*const fn (H, u64, u32, *const GraphicsCI, P, *u64) callconv(.c) Result = null,
    CmdBeginRenderPass: ?*const fn (H, *const RpBegin, u32) callconv(.c) void = null,
    CmdEndRenderPass: ?*const fn (H) callconv(.c) void = null,
    CmdDrawIndirect: ?*const fn (H, u64, u64, u32, u32) callconv(.c) void = null,
    CmdSetViewport: ?*const fn (H, u32, u32, *const Viewport) callconv(.c) void = null,
    CmdSetScissor: ?*const fn (H, u32, u32, *const Rect2) callconv(.c) void = null,
    CmdCopyImageToBuffer: ?*const fn (H, u64, u32, u64, u32, *const BufImgCopy) callconv(.c) void = null,
    GetBufferDeviceAddress: ?*const fn (H, *const BdaInfo) callconv(.c) u64 = null,
    CreateAccelerationStructureKHR: ?*const fn (H, *const AsCI, P, *u64) callconv(.c) Result = null,
    DestroyAccelerationStructureKHR: ?*const fn (H, u64, P) callconv(.c) void = null,
    GetAccelerationStructureBuildSizesKHR: ?*const fn (H, u32, *const AsBuild, *const u32, *AsSizes) callconv(.c) void = null,
    GetAccelerationStructureDeviceAddressKHR: ?*const fn (H, *const AsAddrInfo) callconv(.c) u64 = null,
    CmdBuildAccelerationStructuresKHR: ?*const fn (H, u32, *const AsBuild, *const *const AsRange) callconv(.c) void = null,
    GetMemoryHostPointerPropertiesEXT: ?*const fn (H, u32, *const anyopaque, *HostPtrProps) callconv(.c) Result = null,
};
pub const MappedRange = extern struct { s: u32 = 6, next: ?*const anyopaque = null, mem: u64 = 0, off: u64 = 0, size: u64 = ~@as(u64, 0) };
