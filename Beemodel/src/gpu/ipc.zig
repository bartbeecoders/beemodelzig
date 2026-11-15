// The beemodel-gpu helper's protocol (gpuipc.inc), shared by src/gpu.zig and
// src/gpu/helper.zig. The helper runs as a child with a SOCK_SEQPACKET socket
// on fd 3. Every message is GM_SZ bytes. Bulk data goes through shared memory:
// one memfd per slot, sent with MSG_MAP as SCM_RIGHTS. A slot's memory starts
// with a table of bindings (GB_SZ each): where each storage buffer of the
// kernel lies in it, whether to copy it to the GPU before the dispatch (in)
// and back after (out). A binding can instead go up in pieces (delta): the
// ranges of the slot that changed, listed after the table. The helper treats
// all of it as untrusted.
pub const GM_SZ = 64;
pub const Msg = extern struct {
    cmd: u32 = 0,
    /// MSG_MAP, MSG_RUN: the slot; MSG_WARM: 1 when RTX would be taken; replies, hello: status
    slot: u32 = 0,
    /// MSG_MAP: bytes; MSG_RUN: nbind, gx; replies: ms, hello: magic, type
    a: u32 = 0,
    b: u32 = 0,
    /// MSG_RUN: gy, the kernel + 1 (0: the slot's); hello: the device's name from here on
    c: u32 = 0,
    d: u32 = 0,
    rest: [10]u32 = @splat(0),

    pub fn size(m: *const Msg) u64 {
        return @as(u64, m.a) | @as(u64, m.b) << 32;
    }
    pub fn setSize(m: *Msg, s: u64) void {
        m.a = @truncate(s);
        m.b = @truncate(s >> 32);
    }
    pub fn name(m: *Msg) *[48]u8 {
        return @ptrCast(&m.c);
    }
    pub fn nameC(m: *const Msg) *const [48]u8 {
        return @ptrCast(&m.c);
    }
};

comptime {
    if (@sizeOf(Msg) != GM_SZ) @compileError("Msg");
}

pub const MSG_HELLO = 1; // helper -> main, first
pub const MSG_MAP = 2;
pub const MSG_RUN = 3;
pub const MSG_QUIT = 4;
pub const MSG_REPLY = 5;
pub const MSG_WARM = 6; // main -> helper: make every kernel now (a reply)

pub const GPU_MAGIC: u32 = 0x55504742; // 'BGPU'
pub const GH_OK = 0;
pub const GH_NOLOADER = 1; // no Vulkan instance
pub const GH_NODEVICE = 2; // no usable device (int64 compute)
pub const GH_NOPIPE = 3; // the shaders did not build
// MSG_HELLO's type: the device type, then
pub const GH_RTX = 0x100; // ray queries
pub const GH_GFX = 0x200; // the viewport kernel works
pub const GH_HOSTMEM = 0x400;
/// The port's kernels (this file's Params, the port's streams): the original's
/// helper speaks the same messages but runs other shaders.
pub const GH_PORT = 0x800;

pub const Binding = extern struct {
    off: u64 = 0,
    bytes: u64 = 0,
    flags: u32 = 0,
    pad: u32 = 0,
    r0: u32 = 0, // delta: its ranges, the first and how many
    rn: u32 = 0,
};
pub const GB_SZ = 32;
pub const GBF_IN = 1;
pub const GBF_OUT = 2;
pub const GBF_DELTA = 4; // with GBF_IN: only its ranges go up
pub const GPU_RANGES = 1024; // the ranges: slot offset, bytes (u64s)
pub const GPU_RANGE_SZ = 16;
pub const GPU_MAXRANGE = 192;
pub const GPU_DATA0 = 4096; // the first binding's offset
pub const GPU_ALIGN = 256; // bindings' alignment
pub const GPU_MAXBIND = 24;

pub const SLOT_PT = 0; // renders
pub const SLOT_LIVE = 2; // Rendered shading
pub const NSLOT = 5; // (1 raster, 3 viewport, 4 liquid: the original's, not here)

// kernels (GM_KERN is one more; 2 of them were the rasterizer's)
pub const K_PT = 0;
pub const K_PTG = 2;
pub const K_PTR = 3;
pub const K_PTGR = 4;
pub const K_RASTER = 1;
pub const K_PREP = 5;
pub const K_VIEW = 6;
pub const NKERN = 7;

// the rasterizer's tile stage (raster.comp): slot 1
pub const RS_SLOT = 1;
pub const RS_NB = 8;
pub const RS_TRIS = 1;
pub const RS_TOFF = 2;
pub const RS_ENTS = 3;
pub const RS_DEPTH = 4;
pub const RS_IDS = 5;
pub const RS_VIS = 6;
pub const RS_COL = 7;

// the 3D viewport drawn by the GPU: slot 3, a graphics kernel; MSG_RUN's rest[0]
// the draws, gx and gy the image's size
pub const GV_SLOT = 3;
pub const GV_NB = 16;
pub const GV_PAR = 0;
pub const GV_DRAW = 1;
pub const GV_IND = 2;
pub const GV_POS = 3;
pub const GV_NRM = 4;
pub const GV_UV = 5;
pub const GV_VC = 6;
pub const GV_MAT = 7;
pub const GV_IMG = 8;
pub const GV_ENV = 9;
pub const GV_COL = 10;
pub const GV_INVZ = 11;
pub const GV_ID = 12;
pub const GV_INST = 13;
pub const GV_PART = 14;
pub const GV_FLD = 15;

// pt.comp's bindings
pub const PT_NBIND = 20; // 0-15, the film, the HDRI, its CDF, spheres
pub const PT_NTAB = 22; // RTX: positions, boxes for its builds (the device's alone)
pub const B_PARAMS = 0;
pub const B_TV = 1;
pub const B_TN = 2;
pub const B_TM = 3;
pub const B_TC = 4;
pub const B_MA = 5;
pub const B_ND = 6;
pub const B_LCDF = 7;
pub const B_LTRI = 8;
pub const B_LSEL = 9;
pub const B_ACCUM = 10;
pub const B_AUX = 11;
pub const B_M2 = 12;
pub const B_TO = 13;
pub const B_TUV = 14;
pub const B_IMG = 15;
pub const B_FILM = 16;
pub const B_ENVIMG = 17;
pub const B_ENVCDF = 18;
pub const B_SPH = 19;
pub const B_VP = 20;
pub const B_AB = 21;

/// pt.comp's Params, as the helper checks it.
pub const P_W = 0;
pub const P_H = 1;
pub const P_NTRI = 8;
pub const P_CAM = 12; // float cam[16]
pub const P_HEAD = 28; // words before the lights
