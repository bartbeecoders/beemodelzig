// "Hive" light transport (hive_pt.s): unidirectional path tracing with
// next-event estimation and multiple importance sampling (power heuristic)
// over the lights - the studio sky (cosine sampled), its sun (a 0.5 degree
// disc), the light objects (point, sun, spot, area) and emissive triangles
// (by area times power). The principled BSDF: Lambert diffuse, GGX
// reflection (Schlick Fresnel, metallic workflow), a rough dielectric for
// transmission (Walter / pbrt: Fresnel, refraction, total internal
// reflection) and a clear coat layer. Russian roulette after three bounces,
// indirect light clamped against fireflies. Passes add one sample per pixel
// into float accumulators (beauty, albedo, normal, depth), rows on every
// core; resolve applies ACES and the sRGB curve.
const std = @import("std");
const m = @import("math.zig");
const scene = @import("scene.zig");
const material = @import("material.zig");
const hive = @import("hive.zig");
const jobs = @import("jobs.zig");
const env = @import("env.zig");
const sg = @import("shgraph.zig");
const surface = @import("surface.zig");

/// The world is an HDRI: no studio sky, no sun (set when the scene goes up).
pub var use_env = false;
const A = std.heap.page_allocator;

const pi = std.math.pi;
const inv_pi: f32 = 1.0 / pi;
const amin: f32 = 0.0004;
const clamp_ind: f32 = 40.0;
const far: f32 = 1e30;

// the studio sky (as the material preview) and its sun
const sky_zenith: m.V3 = .{ 0.34, 0.46, 0.74 };
const sky_horizon: m.V3 = .{ 0.72, 0.74, 0.78 };
const sky_ground: m.V3 = .{ 0.20, 0.19, 0.17 };
const sun_dir: m.V3 = .{ 0.5246, 0.7343, 0.4302 };
const sun_cos: f32 = 0.99996192; // cos(0.5 deg)
const sun_rad: m.V3 = .{ 4100.0, 3950.0, 3700.0 }; // E ~ 3 over the disc
const sun_pdf: f32 = 4181.5; // 1 / (2 pi (1 - cos))

/// light bounces (the render settings)
pub var bounces: u32 = 12;

// --- random numbers: xorshift64*, one state per path --------------------------------

pub const Rng = struct {
    s: u64,
    pub fn init(a: u64, b: u64) Rng {
        var x = a *% 0x9E3779B97F4A7C15 ^ (b +% 0x632BE59BD9B4E019) *% 0xBF58476D1CE4E5B9;
        x ^= x >> 31;
        x *%= 0x94D049BB133111EB;
        x ^= x >> 29;
        return .{ .s = x | 1 };
    }
    pub fn f(r: *Rng) f32 {
        r.s ^= r.s >> 12;
        r.s ^= r.s << 25;
        r.s ^= r.s >> 27;
        const v = r.s *% 0x2545F4914F6CDD1D;
        return @as(f32, @floatFromInt(v >> 40)) * (1.0 / 16777216.0);
    }
};

fn lum(c: m.V3) f32 {
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
}
fn mul(a: m.V3, b: m.V3) m.V3 {
    return .{ a[0] * b[0], a[1] * b[1], a[2] * b[2] };
}

/// An orthonormal frame about n (Duff et al.).
fn onb(n: m.V3) [2]m.V3 {
    const s: f32 = if (n[2] >= 0) 1 else -1;
    const a = -1 / (s + n[2]);
    const b = n[0] * n[1] * a;
    return .{ .{ 1 + s * n[0] * n[0] * a, s * b, -s * n[0] }, .{ b, s + n[1] * n[1] * a, -n[1] } };
}
fn local(f: [2]m.V3, n: m.V3, x: f32, y: f32, z: f32) m.V3 {
    return m.add(m.add(m.scale(f[0], x), m.scale(f[1], y)), m.scale(n, z));
}

// --- the sky ------------------------------------------------------------------------------

fn skyRad(d: m.V3) m.V3 {
    if (use_env) return env.rad(d);
    if (d[1] <= 0) return sky_ground;
    const t = @sqrt(d[1]);
    return m.add(sky_horizon, m.scale(m.sub(sky_zenith, sky_horizon), t));
}
/// The sky a camera ray sees, as a pixel (the Rendered viewport's backdrop).
pub fn skyPixel(d: m.V3) u32 {
    const c = skyRad(d);
    return (aces(c[0]) << 16) | (aces(c[1]) << 8) | aces(c[2]);
}
fn inSun(d: m.V3) bool {
    if (use_env) return false;
    return m.dot(d, sun_dir) > sun_cos;
}

// --- the BSDF -----------------------------------------------------------------------------

const Ctx = struct {
    n: m.V3, // shading normal, on the side of wo
    no: m.V3, // shading normal, outside
    wo: m.V3,
    base: m.V3,
    f0: m.V3,
    alpha: f32,
    metal: f32,
    te: f32, // transmission weight
    eta: f32,
    coat: f32,
    calpha: f32,
    abase: f32, // the base layer under the coat
    pd: f32,
    ps: f32,
    pt: f32,
    pc: f32,
    coso: f32,
};

fn schlickW(c: f32) f32 {
    const x = std.math.clamp(1 - c, 0, 1);
    const x2 = x * x;
    return x2 * x2 * x;
}

const tiny: f32 = 1e-8;

/// (as the original: the denominator kept from 1e-8, which caps D for the
/// smallest roughness - its MIS weights depend on that)
fn ggxD(nh: f32, alpha: f32) f32 {
    const a2 = alpha * alpha;
    const q = nh * nh * (a2 - 1) + 1;
    return a2 / @max(q * q * pi, tiny);
}

fn ggxG1(c0: f32, alpha: f32) f32 {
    const c = @abs(c0);
    const a2 = alpha * alpha;
    return 2 * c / @max(c + @sqrt(a2 + (1 - a2) * c * c), tiny);
}

/// Dielectric Fresnel reflectance for the cosine on the incident side.
fn fresnelD(cos_i0: f32, eta0: f32) f32 {
    var ci = cos_i0;
    var eta = eta0;
    if (ci < 0) {
        eta = 1 / eta;
        ci = -ci;
    }
    const s2 = (1 - ci * ci) / (eta * eta);
    if (s2 >= 1) return 1; // total internal reflection
    const ct = @sqrt(1 - s2);
    const rpar = (eta * ci - ct) / (eta * ci + ct);
    const rper = (ci - eta * ct) / (ci + eta * ct);
    return 0.5 * (rpar * rpar + rper * rper);
}

fn bsdfInit(ma: *const material.Material, ns_out: m.V3, wo: m.V3, outside: bool) Ctx {
    var c: Ctx = undefined;
    c.no = ns_out;
    c.n = if (outside) ns_out else m.scale(ns_out, -1);
    c.wo = wo;
    c.coso = @max(m.dot(c.n, wo), tiny);
    c.base = ma.base;
    c.alpha = @max(ma.roughness * ma.roughness, amin);
    c.metal = ma.metallic;
    c.te = ma.transmission * (1 - ma.metallic);
    c.eta = @max(ma.ior, 1.0001);
    const r = (ma.ior - 1) / (ma.ior + 1);
    const s0 = r * r * ma.specular * 2;
    for (0..3) |i| c.f0[i] = s0 * (1 - c.metal) + ma.base[i] * c.metal;
    c.coat = ma.coat;
    c.calpha = @max(ma.coat_rough * ma.coat_rough, amin);
    const fc = 0.04 + 0.96 * schlickW(c.coso);
    const wc = c.coat * fc;
    c.abase = 1 - wc;
    const wd = lum(c.base) * (1 - c.metal) * (1 - c.te) * c.abase;
    const sw = schlickW(c.coso);
    const fs: m.V3 = .{ c.f0[0] + (1 - c.f0[0]) * sw, c.f0[1] + (1 - c.f0[1]) * sw, c.f0[2] + (1 - c.f0[2]) * sw };
    const ws = lum(fs) * c.abase * (1 - c.te);
    const wg = c.abase * c.te;
    const sum = wd + ws + wg + wc;
    if (sum > 0) {
        c.pd = wd / sum;
        c.ps = ws / sum;
        c.pt = wg / sum;
        c.pc = wc / sum;
    } else {
        // nothing (a graph's base colour below zero): say diffuse, the other
        // weights as they are (hive_pt.s: only the diffuse weight is set to 1,
        // the sum taken as 1) - the specular lobe stays in the pdf
        c.pd = 1;
        c.ps = ws;
        c.pt = wg;
        c.pc = wc;
    }
    return c;
}

/// pbrt's rough dielectric about the outside normal: f (3) and the pdf of both lobes.
fn glassEval(c: *const Ctx, wi: m.V3, f: *m.V3) f32 {
    const co = m.dot(c.no, c.wo);
    const ci = m.dot(c.no, wi);
    if (co == 0 or ci == 0) return 0;
    const reflect = ci * co > 0;
    const etap: f32 = if (co > 0) c.eta else 1 / c.eta;
    var wm = if (reflect) m.add(wi, c.wo) else m.add(m.scale(wi, etap), c.wo);
    const l = m.len(wm);
    if (!(l > 1e-12)) return 0;
    wm = m.scale(wm, 1 / l);
    if (m.dot(wm, c.no) < 0) wm = m.scale(wm, -1);
    const wmo = m.dot(wm, c.wo);
    const wmi = m.dot(wm, wi);
    if (wmi * ci < 0 or wmo * co < 0) return 0;
    const nm = @abs(m.dot(c.no, wm));
    const d = ggxD(nm, c.alpha);
    const g = ggxG1(co, c.alpha) * ggxG1(ci, c.alpha);
    const R = fresnelD(wmo, c.eta);
    const T = 1 - R;
    if (reflect) {
        const v = d * g * R / @max(4 * @abs(ci * co), tiny);
        f.* = .{ v, v, v };
        return R * d * nm / @max(4 * @abs(wmo), tiny);
    }
    const den0 = wmi + wmo / etap;
    const den = @max(den0 * den0, tiny);
    const v = T * d * g * @abs(wmi * wmo / @max(@abs(ci * co * den), tiny)) / (etap * etap);
    f.* = .{ v, v, v };
    return T * d * nm * @abs(wmi) / den;
}

/// f (without the cosine) and the mixture's pdf toward wi.
fn bsdfEval(c: *const Ctx, wi: m.V3, f: *m.V3) f32 {
    f.* = .{ 0, 0, 0 };
    var pdf: f32 = 0;
    const ci = m.dot(c.n, wi);
    if (ci > 0) {
        const hv = m.norm(m.add(wi, c.wo));
        const nh = @max(m.dot(c.n, hv), 0);
        const oh = @max(m.dot(c.wo, hv), 1e-6);
        // diffuse
        if (c.pd > 0) {
            pdf += c.pd * ci * inv_pi;
            const k = (1 - c.metal) * (1 - c.te) * c.abase * inv_pi;
            f.* = m.add(f.*, m.scale(c.base, k));
        }
        // specular (opaque): D G F / (4 co ci), weight a (1 - te)
        if (c.ps > 0 or c.f0[0] + c.f0[1] + c.f0[2] > 0) {
            const d = ggxD(nh, c.alpha);
            pdf += c.ps * d * nh / (4 * oh);
            const g = ggxG1(c.coso, c.alpha) * ggxG1(ci, c.alpha);
            const k = d * g / (4 * c.coso * ci) * c.abase * (1 - c.te);
            const w = schlickW(oh);
            for (0..3) |i| f[i] += k * (c.f0[i] + (1 - c.f0[i]) * w);
        }
        // clear coat: the same with F0 = 0.04, its alpha, weight coat
        if (c.coat > 0) {
            const d = ggxD(nh, c.calpha);
            pdf += c.pc * d * nh / (4 * oh);
            const g = ggxG1(c.coso, c.calpha) * ggxG1(ci, c.calpha);
            const v = d * g / (4 * c.coso * ci) * (0.04 + 0.96 * schlickW(oh)) * c.coat;
            f.* = m.add(f.*, .{ v, v, v });
        }
    }
    if (c.te > 0) {
        var fg: m.V3 = undefined;
        const pg = glassEval(c, wi, &fg);
        if (pg > 0) {
            pdf += c.pt * pg;
            const k = c.abase * c.te;
            for (0..3) |i| f[i] += fg[i] * c.base[i] * k; // (tinted by the base colour)
        }
    }
    return pdf;
}

/// A microfacet normal ~ D cos about n.
fn sampleH(n: m.V3, alpha: f32, r: *Rng) m.V3 {
    const ua = r.f();
    const ub = r.f();
    const t2 = alpha * alpha * ua / @max(1 - ua, 1e-7);
    const cz = 1 / @sqrt(1 + t2);
    const sz = @sqrt(@max(0, 1 - cz * cz));
    const ph = 2 * pi * ub;
    return local(onb(n), n, @cos(ph) * sz, @sin(ph) * sz, cz);
}

fn reflectAbout(wo: m.V3, hv: m.V3) m.V3 {
    return m.sub(m.scale(hv, 2 * m.dot(wo, hv)), wo);
}

/// A direction wi from the BSDF; null: none. The caller evaluates f and the pdf.
fn bsdfSample(c: *const Ctx, r: *Rng) ?m.V3 {
    const u = r.f();
    if (u < c.pd) {
        const r1 = r.f();
        const r2 = r.f();
        const rr = @sqrt(r1);
        const ph = 2 * pi * r2;
        return local(onb(c.n), c.n, rr * @cos(ph), rr * @sin(ph), @sqrt(@max(0, 1 - r1)));
    }
    if (u < c.pd + c.ps + c.pc) {
        // (a bent normal can face away: no facet there, the path ends)
        const hv = sampleH(c.n, if (u < c.pd + c.ps) c.alpha else c.calpha, r);
        return if (m.dot(hv, c.wo) > 0) reflectAbout(c.wo, hv) else null;
    }
    // glass: h ~ D about the outside normal, faced to wo
    var hv = sampleH(c.no, c.alpha, r);
    var oh = m.dot(c.wo, hv);
    if (oh < 0) {
        hv = m.scale(hv, -1);
        oh = -oh;
    }
    const outside = m.dot(c.no, c.wo) > 0;
    const etap: f32 = if (outside) c.eta else 1 / c.eta;
    const R = fresnelD(if (outside) oh else -oh, c.eta);
    if (r.f() < R) return reflectAbout(c.wo, hv);
    const s2 = (1 - oh * oh) / (etap * etap);
    if (s2 >= 1) return reflectAbout(c.wo, hv);
    const ct = @sqrt(1 - s2);
    return m.add(m.scale(c.wo, -1 / etap), m.scale(hv, oh / etap - ct));
}

// --- lights --------------------------------------------------------------------------------

const ObjLight = struct {
    pos: m.V3,
    I: m.V3, // colour x power (x the default's strength)
    kind: scene.LightType,
    size: f32,
    dir: m.V3, // the way it shines
    cos_out: f32, // a sun's half angle, a spot's outer
    u: m.V3, // an area's half-edge axis
    cos_in: f32, // a spot's inner
};

pub var lights: []ObjLight = &.{};
// emissive triangles: a CDF over area x power
pub var lcdf: []f32 = &.{};
pub var ltri: []u32 = &.{};
/// per triangle: its choice's probability over its area (0: not a light)
pub var lsel: []f32 = &.{};
pub var nslots: u32 = 2;

fn freeLights() void {
    if (lights.len > 0) A.free(lights);
    if (lcdf.len > 0) A.free(lcdf);
    if (ltri.len > 0) A.free(ltri);
    if (lsel.len > 0) A.free(lsel);
    lights = &.{};
    lcdf = &.{};
    ltri = &.{};
    lsel = &.{};
}

fn triArea(t: *const hive.Tri) f32 {
    return 0.5 * m.len(m.cross(t.e1, t.e2));
}

fn emission(ma: *const material.Material) m.V3 {
    // (a graph drives the emission: no light sampling, found by bounces)
    if (sg.pinsOf(ma)[sg.PIN_EMIT] != 0) return .{ 0, 0, 0 };
    return m.scale(ma.emission, ma.strength);
}

fn prepLights() bool {
    freeLights();
    var n: usize = 0;
    for (scene.objects[0..scene.count]) |*o| {
        if (o.kind == .light and o.visible and o.render) n += 1;
    }
    lights = A.alloc(ObjLight, n) catch return false;
    var k: usize = 0;
    for (scene.objects[0..scene.count], 0..) |*o, oi| {
        if (!(o.kind == .light and o.visible and o.render)) continue;
        const mtx = scene.world(oi);
        const R = m.rotationOf(mtx);
        const col = material.toLinear(o.light_color);
        const strength: f32 = (o.power / 1000.0) * (if (o.light_type == .sun) @as(f32, 3.0) else 80.0);
        var l = ObjLight{
            .pos = .{ mtx[3], mtx[7], mtx[11] },
            .I = m.scale(col, strength),
            .kind = o.light_type,
            .size = @max(0, o.size),
            .dir = m.norm(.{ -R[2], -R[5], -R[8] }),
            .cos_out = 1,
            .u = m.norm(.{ R[0], R[3], R[6] }),
            .cos_in = 1,
        };
        const half_edge = (if (l.size > 0) l.size else 1.0) * 0.5;
        l.u = m.scale(l.u, half_edge);
        switch (l.kind) {
            .sun => l.cos_out = @cos(l.size * 0.5 * m.deg),
            .spot => {
                const cone = if (o.cone > 0) o.cone else 45;
                l.cos_out = @cos(cone * 0.5 * m.deg);
                l.cos_in = @cos(cone * 0.5 * 0.8 * m.deg);
            },
            else => {},
        }
        lights[k] = l;
        k += 1;
    }
    // emissive triangles
    lsel = A.alloc(f32, hive.tris.len) catch return false;
    @memset(lsel, 0);
    var ne: usize = 0;
    for (hive.tris, 0..) |*t, i| {
        if (lum(emission(hive.materialOf(i))) > 0 and triArea(t) > 0) ne += 1;
    }
    nslots = 2 + @as(u32, @intCast(lights.len));
    if (ne > 0) {
        lcdf = A.alloc(f32, ne) catch return false;
        ltri = A.alloc(u32, ne) catch return false;
        var acc: f32 = 0;
        var j: usize = 0;
        for (hive.tris, 0..) |*t, i| {
            const p = lum(emission(hive.materialOf(i))) * triArea(t);
            if (!(p > 0)) continue;
            acc += p;
            lcdf[j] = acc;
            ltri[j] = @intCast(i);
            j += 1;
        }
        for (lcdf, ltri) |*c, ti| {
            const a = triArea(&hive.tris[ti]);
            _ = c;
            lsel[ti] = lum(emission(hive.materialOf(ti))) * a / acc / a;
        }
        for (lcdf) |*c| c.* /= acc;
        nslots += 1;
    }
    return true;
}

const LSample = struct { wi: m.V3, li: m.V3, dist: f32, pdf: f32, delta: bool };

fn coneSample(axis: m.V3, cos_max: f32, r: *Rng) m.V3 {
    const c = 1 - r.f() * (1 - cos_max);
    const s = @sqrt(@max(0, 1 - c * c));
    const ph = 2 * pi * r.f();
    return local(onb(axis), axis, @cos(ph) * s, @sin(ph) * s, c);
}

/// A light object toward p: pdf in solid angle (the choice not in it).
fn objLight(l: *const ObjLight, p: m.V3, r: *Rng) ?LSample {
    switch (l.kind) {
        .sun => {
            const axis = m.scale(l.dir, -1);
            if (l.cos_out >= 0.9999999) return .{ .wi = axis, .li = l.I, .dist = far, .pdf = 1, .delta = true };
            const solid = 2 * pi * (1 - l.cos_out);
            return .{ .wi = coneSample(axis, l.cos_out, r), .li = m.scale(l.I, 1 / solid), .dist = far, .pdf = 1 / solid, .delta = true };
        },
        .area => {
            const v = m.cross(l.dir, l.u);
            const s = m.add(l.pos, m.add(m.scale(l.u, 2 * r.f() - 1), m.scale(v, 2 * r.f() - 1)));
            const d = m.sub(s, p);
            const dist = m.len(d);
            if (!(dist > 1e-6)) return null;
            const wi = m.scale(d, 1 / dist);
            const cl = -m.dot(wi, l.dir);
            if (cl <= 0) return null;
            const area = 4 * m.dot(l.u, l.u);
            return .{ .wi = wi, .li = m.scale(l.I, 4 / area), .dist = dist, .pdf = dist * dist / (cl * area), .delta = true };
        },
        else => {
            const d = m.sub(l.pos, p);
            const dist = m.len(d);
            if (!(dist > 1e-6)) return null;
            var wi = m.scale(d, 1 / dist);
            var fade: f32 = 1;
            if (l.kind == .spot) {
                const c = -m.dot(wi, l.dir);
                const t = std.math.clamp((c - l.cos_out) / @max(l.cos_in - l.cos_out, 1e-6), 0, 1);
                fade = t * t * (3 - 2 * t);
                if (fade <= 0) return null;
            }
            const rad = l.size;
            if (rad <= 0 or dist <= rad) {
                return .{ .wi = wi, .li = m.scale(l.I, fade / (dist * dist)), .dist = dist, .pdf = 1, .delta = true };
            }
            // a sphere of the radius: the cone of it seen from p
            const cmax = @sqrt(@max(0, 1 - rad * rad / (dist * dist)));
            wi = coneSample(wi, cmax, r);
            return .{ .wi = wi, .li = m.scale(l.I, fade / (pi * rad * rad)), .dist = dist - rad, .pdf = 1 / (2 * pi * (1 - cmax)), .delta = true };
        },
    }
}

/// One light, chosen uniformly among the slots (sky, sun, objects, emissive
/// triangles); the pdf includes the choice.
fn lightSample(p: m.V3, n: m.V3, r: *Rng) ?LSample {
    const ns: f32 = @floatFromInt(nslots);
    var k: u32 = @intFromFloat(r.f() * ns);
    if (k >= nslots) k = nslots - 1;
    const pc = 1 / ns;
    if (k == 0 and use_env) {
        // the HDRI by its CDF
        const s = env.sample(r.f(), r.f(), r.f(), r.f()) orelse return null;
        return .{ .wi = s.wi, .li = env.rad(s.wi), .dist = far, .pdf = pc * s.pdf, .delta = false };
    }
    if (k == 1 and use_env) return null;
    if (k == 0) {
        // the sky: cosine about n
        const r1 = r.f();
        const r2 = r.f();
        const rr = @sqrt(r1);
        const ph = 2 * pi * r2;
        const c = @sqrt(@max(0, 1 - r1));
        if (c <= 0) return null;
        const wi = local(onb(n), n, rr * @cos(ph), rr * @sin(ph), c);
        return .{ .wi = wi, .li = skyRad(wi), .dist = far, .pdf = pc * c * inv_pi, .delta = false };
    }
    if (k == 1) {
        return .{ .wi = coneSample(sun_dir, sun_cos, r), .li = sun_rad, .dist = far, .pdf = pc * sun_pdf, .delta = false };
    }
    if (k - 2 < lights.len) {
        var s = objLight(&lights[k - 2], p, r) orelse return null;
        s.pdf *= pc;
        return s;
    }
    // an emissive triangle by the CDF, a uniform point on it
    const u = r.f();
    var lo: usize = 0;
    var hi: usize = lcdf.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (lcdf[mid] <= u) lo = mid + 1 else hi = mid;
    }
    const ti = ltri[@min(lo, ltri.len - 1)];
    const t = &hive.tris[ti];
    const su = @sqrt(r.f());
    const b = r.f() * su;
    const a = 1 - su;
    const q = m.add(t.v0, m.add(m.scale(t.e1, a), m.scale(t.e2, b)));
    const d = m.sub(q, p);
    const dist = m.len(d);
    if (!(dist > 1e-6)) return null;
    const wi = m.scale(d, 1 / dist);
    const gn = m.norm(m.cross(t.e1, t.e2));
    const cl = @abs(m.dot(gn, wi)); // (two-sided)
    if (cl <= 1e-6) return null;
    return .{ .wi = wi, .li = emission(hive.materialOf(ti)), .dist = dist, .pdf = pc * lsel[ti] * dist * dist / cl, .delta = false };
}

fn mis(a: f32, b: f32) f32 {
    const a2 = a * a;
    const b2 = b * b;
    return if (a2 + b2 > 0) a2 / (a2 + b2) else 0;
}

// --- the camera ----------------------------------------------------------------------------

pub const Camera = struct { o: m.V3, right: m.V3, up: m.V3, fwd: m.V3, tan_h: f32 };
pub var cam: Camera = undefined;

// --- a path -----------------------------------------------------------------------------------

pub const Aux = struct { albedo: m.V3 = .{ 0, 0, 0 }, normal: m.V3 = .{ 0, 0, 0 }, depth: f32 = 0 };

/// From the hit point, nudged along the geometric normal to the direction's side.
fn offsetRay(p: m.V3, ng: m.V3, dir: m.V3) m.V3 {
    const e: f32 = 1e-4;
    return m.add(p, m.scale(ng, if (m.dot(ng, dir) >= 0) e else -e));
}

/// L += beta * radiance, clamped (fireflies) after the first bounce.
fn addL(L: *m.V3, beta: m.V3, rad: m.V3, depth: u32) void {
    for (0..3) |i| {
        var v = rad[i] * beta[i];
        if (depth > 0) v = @min(v, clamp_ind);
        if (std.math.isFinite(v)) L[i] += v;
    }
}

/// The radiance along a camera ray through screen (sx, sy) in -1 .. 1.
fn tracePath(sx: f32, sy: f32, aux: *Aux, r: *Rng) m.V3 {
    return traceRay(cam.o, m.norm(m.add(cam.fwd, m.add(m.scale(cam.right, sx * cam.tan_h), m.scale(cam.up, sy * cam.tan_h)))), aux, r);
}

/// The radiance arriving at o along -d (d unit), a path traced as from the
/// camera: light probes and lightmaps. Workers may call it.
pub fn traceRay(o0: m.V3, d0: m.V3, aux: *Aux, r: *Rng) m.V3 {
    var o = o0;
    var d = d0;
    var L: m.V3 = .{ 0, 0, 0 };
    var beta: m.V3 = .{ 1, 1, 1 };
    var spec = true; // the camera ray: no MIS
    var pdf_b: f32 = 0;
    var prev_n: m.V3 = .{ 0, 1, 0 }; // the shading normal at the last point (the sky's MIS)
    const pc = 1 / @as(f32, @floatFromInt(nslots));
    var depth: u32 = 0;
    var gm: material.Material = undefined; // a graph's results at the hit
    while (true) {
        const hit = surface.walk(o, d, far, r) orelse {
            // the sky (+ the sun), MIS against the light choices
            const lp: f32 = if (use_env) env.pdf(d) else @max(m.dot(prev_n, d), 0) * inv_pi;
            const w: f32 = if (spec) 1 else mis(pdf_b, pc * lp);
            var tmp = m.scale(skyRad(d), w);
            if (inSun(d)) {
                const ws: f32 = if (spec) 1 else mis(pdf_b, pc * sun_pdf);
                tmp = m.add(tmp, m.scale(sun_rad, ws));
            }
            addL(&L, beta, tmp, depth);
            break;
        };
        const t = &hive.tris[hit.tri];
        const p = m.add(o, m.scale(d, hit.t));
        const ng = m.norm(m.cross(t.e1, t.e2));
        const cn = hive.norms[hit.tri];
        const w0 = 1 - hit.u - hit.v;
        var ns = m.add(m.add(m.scale(cn[0], w0), m.scale(cn[1], hit.u)), m.scale(cn[2], hit.v));
        const nl = m.len(ns);
        ns = if (nl > 1e-12) m.scale(ns, 1 / nl) else ng;
        if (m.dot(ns, ng) < 0) ns = ng; // the smooth one on the face's side
        const wo = m.scale(d, -1);
        const outside = m.dot(ng, wo) > 0; // the ray met the front
        var ma = hive.materialOf(hit.tri);
        ma = if (ma.nodes() != 0) surface.hitGraph(ma, hit, p, &ns, wo, &gm) else surface.hitTint(ma, hit, &gm);
        // emission, MIS against NEE of this triangle
        if (ma.strength > 0) {
            var w: f32 = 1;
            if (!spec) {
                const cl = @abs(m.dot(ng, wo));
                const pl = if (cl > 1e-6) pc * lsel[hit.tri] * hit.t * hit.t / cl else 0;
                w = mis(pdf_b, pl);
            }
            addL(&L, beta, m.scale(ma.emission, ma.strength * w), depth);
        }
        const c = bsdfInit(ma, ns, wo, outside);
        if (depth == 0) {
            aux.albedo = ma.base;
            aux.normal = ns;
            aux.depth = hit.t;
        }
        // next-event estimation
        if (lightSample(p, c.n, r)) |ls| {
            var f: m.V3 = undefined;
            const pb = bsdfEval(&c, ls.wi, &f);
            if (lum(f) > 1e-8 and ls.pdf > 0) {
                const so = offsetRay(p, ng, ls.wi);
                const tmax = ls.dist * 0.99999994 - 1e-4;
                const blocked = if (hive.cut) surface.walk(so, ls.wi, tmax, r) != null else hive.occluded(so, ls.wi, tmax);
                if (!blocked) {
                    const w: f32 = if (ls.delta) 1 else mis(ls.pdf, pb);
                    const k = @abs(m.dot(c.n, ls.wi)) * w / ls.pdf;
                    addL(&L, beta, m.scale(mul(f, ls.li), k), depth);
                }
            }
        }
        // on along a BSDF sample
        const wi = bsdfSample(&c, r) orelse break;
        var f: m.V3 = undefined;
        const pb = bsdfEval(&c, wi, &f);
        if (!(pb > 1e-8) or !std.math.isFinite(pb)) break;
        beta = m.scale(mul(beta, f), @abs(m.dot(c.n, wi)) / pb);
        if (!(lum(beta) > 1e-8) or !std.math.isFinite(lum(beta))) break;
        spec = false;
        pdf_b = pb;
        prev_n = c.n;
        o = offsetRay(p, ng, wi);
        d = wi;
        depth += 1;
        if (depth >= bounces) break;
        // Russian roulette
        if (depth >= 3) {
            const q = std.math.clamp(@max(beta[0], @max(beta[1], beta[2])), 0.05, 0.95);
            if (r.f() >= q) break;
            beta = m.scale(beta, 1 / q);
        }
    }
    return L;
}

// --- the film ---------------------------------------------------------------------------------

pub var fw: u32 = 0;
pub var fh: u32 = 0;
pub var accum: [][3]f32 = &.{};
pub var alb: [][3]f32 = &.{};
pub var nrm: [][3]f32 = &.{};
pub var dep: []f32 = &.{};
/// per pixel: the sum of the samples' squared luminance (the denoiser's variance)
pub var m2: []f32 = &.{};
/// samples per row so far (rows run in bands within a time budget)
pub var row_spp: []u32 = &.{};
pub var target: u32 = 128;
pub var seed: u64 = 1;
/// The next row that needs a sample (rows go round).
var cursor_row: u32 = 0;

pub fn freeFilm() void {
    if (accum.len > 0) A.free(accum);
    if (alb.len > 0) A.free(alb);
    if (nrm.len > 0) A.free(nrm);
    if (dep.len > 0) A.free(dep);
    if (m2.len > 0) A.free(m2);
    if (row_spp.len > 0) A.free(row_spp);
    accum = &.{};
    alb = &.{};
    nrm = &.{};
    dep = &.{};
    m2 = &.{};
    row_spp = &.{};
    fw = 0;
    fh = 0;
}

/// The scene goes up to Hive: false when out of memory.
pub fn buildScene() bool {
    scene_gen +%= 1;
    use_env = env.prep();
    sg.scene_time = @import("graphops.zig").sceneTime();
    scene_ok = hive.build() and prepLights();
    return scene_ok;
}

/// False after a build that failed: Hive holds no scene to trace.
pub var scene_ok = false;

/// Moves at each build: who holds a fingerprint of Hive's scene checks it is still the one up.
pub var scene_gen: u32 = 0;

/// Set up a render of the scene now: false when out of memory.
pub fn start(width: u32, height: u32, spp: u32, c: Camera) bool {
    freeFilm();
    return buildScene() and startFilm(width, height, spp, c);
}

/// A film held aside (the live view keeps its own: the F12 result stays whole).
pub const Film = struct {
    fw: u32 = 0,
    fh: u32 = 0,
    accum: [][3]f32 = &.{},
    alb: [][3]f32 = &.{},
    nrm: [][3]f32 = &.{},
    dep: []f32 = &.{},
    m2: []f32 = &.{},
    row_spp: []u32 = &.{},
    target: u32 = 128,
    cursor_row: u32 = 0,
    cam: Camera = undefined,
};

/// Swap the current film with `f`.
pub fn swapFilm(f: *Film) void {
    const t = f.*;
    f.* = .{ .fw = fw, .fh = fh, .accum = accum, .alb = alb, .nrm = nrm, .dep = dep, .m2 = m2, .row_spp = row_spp, .target = target, .cursor_row = cursor_row, .cam = cam };
    fw = t.fw;
    fh = t.fh;
    accum = t.accum;
    alb = t.alb;
    nrm = t.nrm;
    dep = t.dep;
    m2 = t.m2;
    row_spp = t.row_spp;
    target = t.target;
    cursor_row = t.cursor_row;
    cam = t.cam;
}

/// A new film for the scene in Hive: false when out of memory.
pub fn startFilm(width: u32, height: u32, spp: u32, c: Camera) bool {
    freeFilm();
    cursor_row = 0;
    const n = @as(usize, width) * height;
    accum = A.alloc([3]f32, n) catch return false;
    alb = A.alloc([3]f32, n) catch return false;
    nrm = A.alloc([3]f32, n) catch return false;
    dep = A.alloc(f32, n) catch return false;
    m2 = A.alloc(f32, n) catch return false;
    row_spp = A.alloc(u32, height) catch return false;
    @memset(accum, .{ 0, 0, 0 });
    @memset(alb, .{ 0, 0, 0 });
    @memset(nrm, .{ 0, 0, 0 });
    @memset(dep, 0);
    @memset(m2, 0);
    @memset(row_spp, 0);
    fw = width;
    fh = height;
    target = @max(spp, 1);
    cam = c;
    seed +%= 0x9E3779B97F4A7C15;
    return true;
}

const Band = struct { y0: u32 };

fn rowJob(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const b: *const Band = @ptrCast(@alignCast(ctx));
    for (lo..hi) |k| {
        const y: u32 = b.y0 + @as(u32, @intCast(k));
        if (y >= fh) continue;
        const s = row_spp[y];
        if (s >= target) continue;
        const aspect = @as(f32, @floatFromInt(fh)) / @as(f32, @floatFromInt(fw));
        for (0..fw) |x| {
            var r = Rng.init(seed ^ (@as(u64, y) * fw + x), s);
            const sx = 2 * (@as(f32, @floatFromInt(x)) + r.f()) / @as(f32, @floatFromInt(fw)) - 1;
            const sy = (1 - 2 * (@as(f32, @floatFromInt(y)) + r.f()) / @as(f32, @floatFromInt(fh))) * aspect;
            var aux = Aux{};
            const L = tracePath(sx, sy, &aux, &r);
            const i = @as(usize, y) * fw + x;
            for (0..3) |c| {
                accum[i][c] += L[c];
                alb[i][c] += aux.albedo[c];
                nrm[i][c] += aux.normal[c];
            }
            dep[i] += aux.depth;
            const l = lum(L);
            if (std.math.isFinite(l)) m2[i] += l * l;
        }
        row_spp[y] = s + 1;
    }
}


pub fn minSpp() u32 {
    var mn: u32 = std.math.maxInt(u32);
    for (row_spp) |s| mn = @min(mn, s);
    return if (row_spp.len == 0) 0 else mn;
}

/// Work for about `budget_ms`: bands of rows on every core. True while
/// samples remain.
pub fn tick(budget_ms: i64, now: *const fn () i64) bool {
    if (fw == 0) return false;
    const t0 = now();
    var band: u32 = @intCast(@max(1, @min(fh, jobs.count() * 2)));
    while (true) {
        const mn = minSpp();
        if (mn >= target) return false;
        // the band: from the first row with the fewest samples
        var y0: u32 = cursor_row;
        var k: u32 = 0;
        while (k < fh and row_spp[y0] != mn) : (k += 1) y0 = (y0 + 1) % fh;
        const n = @min(band, fh - y0);
        var b = Band{ .y0 = y0 };
        const tb = now();
        jobs.parallelFor(n, 1, &b, rowJob);
        cursor_row = (y0 + n) % fh;
        const took = now() - tb;
        // grow the band while it is fast
        if (took * 4 < budget_ms and band < fh) band = @min(fh, band * 2);
        if (now() - t0 >= budget_ms) return minSpp() < target;
    }
}

// --- resolve ---------------------------------------------------------------------------------

pub const Pass = enum(u8) { beauty, albedo, normal, depth };

pub fn aces(x0: f32) u32 {
    const x = @max(x0, 0);
    const t = std.math.clamp(x * (2.51 * x + 0.03) / (x * (2.43 * x + 0.59) + 0.14), 0, 1);
    return @intFromFloat(@sqrt(t) * 255 + 0.5);
}

/// The chosen pass as 0xRRGGBB pixels (out: w * h): beauty (ACES + sRGB),
/// albedo, normal (0.5 + 0.5 n), depth (exp(-d / 12)). `den`: a denoised
/// beauty to show instead (linear), or null.
pub fn resolve(out: []u32, pass: Pass, den: ?[][4]f32) void {
    var job = Resolve{ .out = out, .pass = pass, .den = den };
    jobs.parallelFor(fh, 8, &job, resolveRows);
}

/// The chosen pass as linear floats (out: w * h): for EXR.
pub fn linear(out: [][3]f32, pass: Pass, den: ?[][4]f32) void {
    for (0..fh) |y| {
        const s = row_spp[y];
        const k: f32 = if (s > 0) 1 / @as(f32, @floatFromInt(s)) else 0;
        for (0..fw) |x| {
            const i = y * fw + x;
            out[i] = switch (pass) {
                .beauty => if (den) |dn| .{ dn[i][0], dn[i][1], dn[i][2] } else .{ accum[i][0] * k, accum[i][1] * k, accum[i][2] * k },
                .albedo => .{ alb[i][0] * k, alb[i][1] * k, alb[i][2] * k },
                .normal => .{ nrm[i][0] * k, nrm[i][1] * k, nrm[i][2] * k },
                .depth => .{ dep[i] * k, dep[i] * k, dep[i] * k },
            };
        }
    }
}

const Resolve = struct { out: []u32, pass: Pass, den: ?[][4]f32 };

fn resolveRows(ctx: *anyopaque, lo: usize, hi: usize, _: usize) void {
    const job: *const Resolve = @ptrCast(@alignCast(ctx));
    const out = job.out;
    const pass = job.pass;
    const den = job.den;
    for (lo..hi) |y| {
        const s = row_spp[y];
        const k: f32 = if (s > 0) 1 / @as(f32, @floatFromInt(s)) else 0;
        for (0..fw) |x| {
            const i = y * fw + x;
            var px: u32 = 0;
            switch (pass) {
                .beauty => {
                    const c: [3]f32 = if (den) |dn| .{ dn[i][0], dn[i][1], dn[i][2] } else .{ accum[i][0] * k, accum[i][1] * k, accum[i][2] * k };
                    px = (aces(c[0]) << 16) | (aces(c[1]) << 8) | aces(c[2]);
                },
                .albedo => {
                    for (0..3) |c| px = (px << 8) | @as(u32, @intFromFloat(@sqrt(std.math.clamp(alb[i][c] * k, 0, 1)) * 255 + 0.5));
                },
                .normal => {
                    for (0..3) |c| px = (px << 8) | @as(u32, @intFromFloat(std.math.clamp(0.5 + 0.5 * nrm[i][c] * k, 0, 1) * 255 + 0.5));
                },
                .depth => {
                    const dd = dep[i] * k;
                    const v: u32 = if (dd > 0) @intFromFloat(@exp(-dd / 12) * 255 + 0.5) else 0;
                    px = (v << 16) | (v << 8) | v;
                },
            }
            out[i] = px;
        }
    }
}

test "a second film leaves the first whole" {
    scene.init();
    const c = Camera{ .o = .{ 7.4, 5.3, 6.9 }, .right = .{ 0.68, 0, -0.73 }, .up = .{ -0.34, 0.88, -0.32 }, .fwd = m.norm(.{ -0.64, -0.46, -0.6 }), .tan_h = 0.36 };
    const now = struct {
        fn f() i64 {
            return 0;
        }
    }.f;
    try std.testing.expect(start(16, 9, 2, c));
    defer freeFilm();
    while (tick(1000, now)) {}
    const kept = accum[40];
    const ptr = accum.ptr;
    var other = Film{};
    swapFilm(&other);
    try std.testing.expectEqual(@as(u32, 0), fw);
    try std.testing.expect(startFilm(8, 4, 1, c));
    while (tick(1000, now)) {}
    try std.testing.expectEqual(@as(u32, 1), minSpp());
    freeFilm();
    swapFilm(&other);
    try std.testing.expectEqual(ptr, accum.ptr);
    try std.testing.expectEqual(@as(u32, 16), fw);
    try std.testing.expectEqual(kept, accum[40]);
    try std.testing.expectEqual(@as(u32, 2), minSpp());
}

test "a white furnace stays finite and lit" {
    scene.init();
    try std.testing.expect(start(32, 18, 4, .{ .o = .{ 7.4, 5.3, 6.9 }, .right = .{ 0.68, 0, -0.73 }, .up = .{ -0.34, 0.88, -0.32 }, .fwd = m.norm(.{ -0.64, -0.46, -0.6 }), .tan_h = 0.36 }));
    defer freeFilm();
    const now = struct {
        fn f() i64 {
            return 0;
        }
    }.f;
    var guard: usize = 0;
    while (minSpp() < 4 and guard < 1000) : (guard += 1) _ = tick(1000, now);
    try std.testing.expectEqual(@as(u32, 4), minSpp());
    var sum: f32 = 0;
    for (accum) |c| {
        for (c) |v| {
            try std.testing.expect(std.math.isFinite(v));
            sum += v;
        }
    }
    try std.testing.expect(sum > 0);
}
