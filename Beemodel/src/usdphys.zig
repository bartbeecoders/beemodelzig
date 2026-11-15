//! OpenUSD physics (UsdPhysics) on import, as usdphys.s does it: rigid
//! bodies and joints, made with BeeModel's own rigid.add and rigid.joint
//! (rbody.zig), so they behave as hand-made ones do.
//!
//! A prim with PhysicsRigidBodyAPI is a body; the objects imported under it
//! are its parts (more than one - one a material). The largest part (its
//! mesh's box) is the rigid body, the others its children: they follow it.
//! Its mass: physics:mass (MassAPI) on the body or summed over its meshes
//! (else BeeModel's density); no body lighter than 1/10 of the heaviest. Its
//! shape (that part's) from the meshes' physics:approximation: convexHull ->
//! hull, boundingCube -> box, boundingSphere -> sphere, the rest -> compound.
//! kinematicEnabled -> passive. Friction and bounce: the physics material
//! bound (material:binding:physics on a mesh or the body): dynamicFriction,
//! restitution. Joints (PhysicsRevoluteJoint -> hinge, PrismaticJoint ->
//! slider, FixedJoint -> fixed, SphericalJoint -> point): body0 / body1 (no
//! body: the world), the pivot localPos0 in body0's frame, the axis (X / Y /
//! Z through localRot0), limits (degrees for hinges, metres for sliders); a
//! joint with a drive (PhysicsDriveAPI), or a mimic joint following one, is
//! held where it starts (limits 0 0); disabled ones are left out. Bodies can
//! nest (a URDF's links): a joint's body is the nearest one above its target.
const std = @import("std");
const ul = @import("usdlayer.zig");
const usd = @import("usd.zig");
const m4 = @import("m4d.zig");
const scene = @import("scene.zig");
const Value = ul.Value;

const MAXB = 1024; // bodies an import
const MAXO = 4096; // objects in bodies
const MAXJ = 1024; // joints

const Body = struct {
    prim: u32 = 0,
    first: ?usize = null, // its first object (then its largest part)
    nobj: u32 = 0,
    shape: u32 = 0, // 0 compound 1 hull 2 box 3 sphere
    mass: f64 = 0, // 0: not given
    pmat: ?[*:0]const u8 = null, // its physics material (stage path)
    lastm: i64 = -1, // the last mesh prim counted
    pass: bool = false, // kinematic: passive
    w: m4.M = m4.ident, // its world matrix (stage)
};

var bodies: [MAXB]Body = undefined;
var nb: u32 = 0;
var cur: i32 = -1; // the body being walked
const Obj = struct { oi: usize, body: u32 };
var objs: [MAXO]Obj = undefined;
var no: u32 = 0;
var joints: [MAXJ]u32 = undefined;
var nj: u32 = 0;
/// made by the last import
pub var nbodies: u32 = 0;
pub var njoints: u32 = 0;
var group: u32 = 0; // the import's collision group (1 .. 15)
var ngrp: u32 = 0; // (the next one: imports take turns)

const shapes = [_][]const u8{ "compound", "hull", "box", "sphere" };
const jtypes = [_][]const u8{ "hinge", "slider", "fixed", "point" };
const jnames = [_][]const u8{ "PhysicsRevoluteJoint", "PhysicsPrismaticJoint", "PhysicsFixedJoint", "PhysicsSphericalJoint" };
const mimics = [_][]const u8{ "NewtonMimicAPI", "PhysxMimicJointAPI:rotX", "PhysxMimicJointAPI:rotY", "PhysxMimicJointAPI:rotZ", "PhysxMimicJointAPI:transX", "PhysxMimicJointAPI:transY", "PhysxMimicJointAPI:transZ" };

/// usdphys_reset: this import's group (its parts meet everything but each
/// other: they overlap where they join, as PhysX articulations let them)
pub fn reset() void {
    ngrp += 1;
    if (ngrp > 15) ngrp = 1;
    group = ngrp;
    nb = 0;
    no = 0;
    nj = 0;
    cur = -1;
    nbodies = 0;
    njoints = 0;
}

/// its apiSchemas (any opinion: they add up) list it
fn hasApi(pi: u32, schema: []const u8) bool {
    return usd.pany(pi, "apiSchemas", schema);
}

/// a mimic joint (Newton's, PhysX's): it follows a driven joint, which is
/// held where it starts - so is it
fn mimic(pi: u32) bool {
    for (mimics) |x| {
        if (hasApi(pi, x)) return true;
    }
    return false;
}

fn attr(pi: u32, a: [*:0]const u8) ?*Value {
    return usd.agetv(pi, a);
}

/// up_isdbl: a number as a double
fn isDbl(v0: ?*Value) ?f64 {
    const v = v0 orelse return null;
    if (v.t == ul.UT_DBL) return v.dbl();
    if (v.t == ul.UT_INT) return @floatFromInt(v.int());
    return null;
}

/// up_jointkind: 0 hinge, 1 slider, 2 fixed, 3 point; null
fn jointKind(pi: u32) ?u32 {
    const v = usd.pget(pi, "typeName") orelse return null;
    if (v.t != ul.UT_STR) return null;
    const t = ul.cstr(v.str());
    for (jnames, 0..) |n, k| {
        if (std.mem.eql(u8, t, n)) return @intCast(k);
    }
    return null;
}

/// usdphys_enter: a body or a joint noted; the body that was current (for
/// leave)
pub fn enter(pi: u32, w: *const m4.M) i32 {
    const prev = cur;
    if (jointKind(pi) != null) {
        if (nj < MAXJ) {
            joints[nj] = pi;
            nj += 1;
        }
        return prev;
    }
    if (!hasApi(pi, "PhysicsRigidBodyAPI")) return prev;
    if (attr(pi, "physics:rigidBodyEnabled")) |v| {
        if (v.t == ul.UT_INT and v.int() == 0) return prev;
    }
    if (nb >= MAXB) return prev;
    const b = &bodies[nb];
    b.* = .{ .prim = pi, .w = w.* };
    cur = @intCast(nb);
    nb += 1;
    if (isDbl(attr(pi, "physics:mass"))) |m| { // its own mass, kinematic, material
        b.mass = m;
        b.lastm = pi;
    }
    if (attr(pi, "physics:kinematicEnabled")) |v| {
        if (v.t == ul.UT_INT and v.int() != 0) b.pass = true;
    }
    b.pmat = usd.rel(pi, "material:binding:physics");
    return prev;
}

/// usdphys_leave: the body enter gave
pub fn leave(prev: i32) void {
    cur = prev;
}

/// usdphys_object: a part of the current body (if there is one): its mesh's
/// mass, approximation and physics material
pub fn object(pi: u32, oi: usize) void {
    if (cur < 0) return;
    const b = &bodies[@intCast(cur)];
    if (no >= MAXO) return;
    objs[no] = .{ .oi = oi, .body = @intCast(cur) };
    no += 1;
    b.nobj += 1;
    if (b.first == null) b.first = oi;
    if (b.lastm == pi) return; // (a mesh split by material: once)
    b.lastm = pi;
    if (isDbl(attr(pi, "physics:mass"))) |m| b.mass = m + b.mass; // its mass, added
    if (attr(pi, "physics:approximation")) |v| {
        if (v.t == ul.UT_STR) {
            const t = ul.cstr(v.str());
            b.shape = if (std.mem.eql(u8, t, "convexHull")) 1 else if (std.mem.eql(u8, t, "boundingCube")) 2 else if (std.mem.eql(u8, t, "boundingSphere")) 3 else 0;
        }
    }
    if (b.pmat == null) b.pmat = usd.rel(pi, "material:binding:physics"); // its physics material
}

// ---- making them ----------------------------------------------------------------------

/// up_main: a body's largest part: the longest diagonal of its mesh's box (not
/// its vertices: a screw head can have as many as a housing); its first when
/// none has a mesh
fn mainPart(bi: u32) ?usize {
    var best = bodies[bi].first;
    var size: f32 = -1.0;
    for (objs[0..no]) |o| {
        if (o.body != bi) continue;
        if (o.oi >= scene.count) continue;
        const mi = scene.objects[o.oi].mesh orelse continue;
        const me = scene.meshes[mi] orelse continue;
        const dx = me.hi[0] - me.lo[0];
        const dy = me.hi[1] - me.lo[1];
        const dz = me.hi[2] - me.lo[2];
        var d = dx * dx;
        d += dy * dy;
        d += dz * dz;
        if (d > size) {
            size = d;
            best = o.oi;
        }
    }
    return best;
}

const T = struct {
    b: [520]u8 = undefined,
    n: usize = 0,
    fn s(t: *T, x: []const u8) void {
        const k = @min(x.len, t.b.len - t.n);
        @memcpy(t.b[t.n..][0..k], x[0..k]);
        t.n += k;
    }
    /// up_f: " x" (6 decimals) of a double as a float
    fn f(t: *T, x: f64) void {
        var fb: [40]u8 = undefined;
        t.s(@import("json.zig").fmtFloat(&fb, @floatCast(x)));
    }
    fn int(t: *T, x: i64) void {
        var ib: [24]u8 = undefined;
        t.s(std.fmt.bufPrint(&ib, "{d}", .{x}) catch "0");
    }
    fn name(t: *T, oi: ?usize) void {
        const i = oi orelse return;
        if (i < scene.count) t.s(scene.objects[i].name());
    }
    fn vec3(t: *T, v: [3]f64) void {
        t.f(v[0]);
        t.s(" ");
        t.f(v[1]);
        t.s(" ");
        t.f(v[2]);
    }
    /// up_run: the operator with the text (when it fits), quietly, inside the
    /// import's undo step
    fn run(t: *T, id: []const u8) void {
        if (t.n > 500) return;
        @import("library.zig").runOp(id, t.b[0..t.n]);
    }
};

/// up_primof: the composed prim of a stage path, null
fn primOf(p: [*:0]const u8) ?u32 {
    const k = ul.find(usd.st.?, p) orelse return null;
    return if (usd.done(k)) k else null;
}

/// usdphys_finish: the bodies and joints of the import made
pub fn finish() void {
    var heavy: f64 = 0.0; // the heaviest body
    for (bodies[0..nb]) |*b| {
        if (b.nobj == 0) continue;
        heavy = if (heavy > b.mass) heavy else b.mass; // (maxsd)
    }
    const least = heavy * 0.1; // the lightest a body may be
    for (bodies[0..nb], 0..) |*b, bi| {
        if (b.nobj == 0) continue;
        b.first = mainPart(@intCast(bi)); // its largest part: the rigid body
        var t: T = .{}; // "active compound mass m friction f bounce b"
        t.s(if (b.pass) "passive " else "active ");
        t.s(shapes[b.shape]);
        if (b.mass > 0) { // (all of it: one rigid body)
            t.s(" mass ");
            t.f(if (b.mass > least) b.mass else least);
        }
        if (b.pmat) |pm| { // its physics material
            if (primOf(pm)) |p| {
                if (isDbl(attr(p, "physics:dynamicFriction"))) |x| {
                    t.s(" friction ");
                    t.f(x);
                }
                if (isDbl(attr(p, "physics:restitution"))) |x| {
                    t.s(" bounce ");
                    t.f(x);
                }
            }
        }
        if (nb > 1) { // (several bodies: a group)
            t.s(" group ");
            t.int(group);
            t.s(" collide ");
            t.int(~(@as(u32, 1) << @intCast(group)) & 0xffff);
        }
        const first = b.first orelse continue;
        selectNone(); // exactly its rigid part selected, active
        if (first < scene.count) {
            scene.objects[first].selected = true;
            scene.active = first;
        }
        if (t.n > 500) continue;
        t.run("rigid.add");
        nbodies += 1;
        if (first >= scene.count) continue;
        for (objs[0..no]) |o| { // its other parts: its children (they follow it)
            if (o.body != bi or o.oi == first) continue;
            if (o.oi >= scene.count) continue;
            _ = scene.setParent(o.oi, first);
        }
    }
    for (joints[0..nj]) |j| joint(j);
    selectNone();
}

/// select_none: no object selected (the active one stays active)
fn selectNone() void {
    for (scene.objects[0..scene.count]) |*o| o.selected = false;
}

/// up_under: path is root or below it
fn under(p: [*:0]const u8, root: [*:0]const u8) bool {
    var i: usize = 0;
    while (root[i] != 0) : (i += 1) {
        if (root[i] != p[i]) return false;
    }
    return p[i] == 0 or p[i] == '/';
}

/// up_bodyof: the body a joint's target is (or is inside: the nearest body
/// above - the longest path; bodies can nest, as a URDF's links do), null
/// the world
fn bodyOf(j: u32, r: [*:0]const u8) ?u32 {
    const t = usd.rel(j, r) orelse return null;
    var best: ?u32 = null;
    var blen: usize = 0;
    for (bodies[0..nb], 0..) |*b, i| {
        const p = usd.primPath(b.prim);
        if (!under(t, p)) continue;
        const l = ul.cstr(p).len;
        if (l > blen) {
            blen = l;
            best = @intCast(i);
        }
    }
    const k = best orelse return null;
    if (bodies[k].nobj == 0) return null; // (a body without objects: the world)
    return k;
}

/// up_xvec: a point (translated) or a direction through a matrix
fn xvec(m: *const m4.M, v: [3]f64, point: bool) [3]f64 {
    var o: [3]f64 = undefined;
    for (0..3) |r| {
        var s = m[r * 4] * v[0];
        s += m[r * 4 + 1] * v[1];
        s += m[r * 4 + 2] * v[2];
        if (point) s += m[r * 4 + 3];
        o[r] = s;
    }
    return o;
}

/// up_unit: made unit length (left when ~0)
fn unit(v: *[3]f64) void {
    var l = v[0] * v[0];
    l += v[1] * v[1];
    l += v[2] * v[2];
    l = @sqrt(l);
    if (!(l > 0)) return;
    const inv = 1.0 / l;
    for (v) |*x| x.* *= inv;
}

/// up_jaxis: the axis turned by q (x y z w): v + 2 (w (q x v) + q x (q x v))
fn jaxis(ax: [3]f64, q: [4]f64) [3]f64 {
    const t = [3]f64{ q[1] * ax[2] - q[2] * ax[1], q[2] * ax[0] - q[0] * ax[2], q[0] * ax[1] - q[1] * ax[0] };
    const u = [3]f64{ q[1] * t[2] - q[2] * t[1], q[2] * t[0] - q[0] * t[2], q[0] * t[1] - q[1] * t[0] };
    var o: [3]f64 = undefined;
    for (0..3) |c| {
        var x = t[c] * q[3];
        x += u[c];
        x += x;
        o[c] = x + ax[c];
    }
    return o;
}

/// up_joint: rigid.joint <type> <a> <b|world> pivot .. axis .. [limits ..]
fn joint(j: u32) void {
    if (attr(j, "physics:jointEnabled")) |v| { // disabled: out
        if (v.t == ul.UT_INT and v.int() == 0) return;
    }
    const kind = jointKind(j) orelse return;
    var b0 = bodyOf(j, "physics:body0");
    var b1 = bodyOf(j, "physics:body1");
    if (b0 == null) { // (body0 the world: body1 alone)
        b0 = b1;
        b1 = null;
    }
    const a = b0 orelse return;
    if (b1 != null and b1.? == a) return;
    const B = &bodies[a];
    // the pivot and axis in the stage: body0's matrix x localPos0 / localRot0
    var p: [3]f64 = .{ 0, 0, 0 };
    if (attr(j, "physics:localPos0")) |v| {
        if (v.t == ul.UT_VEC and v.n >= 3) {
            const d = v.vec();
            p = .{ d[0], d[1], d[2] };
        }
    }
    var piv = xvec(&usd.cm, xvec(&B.w, p, true), true);
    for (0..3) |c| piv[c] += usd.off[c]; // (and where the asset lands)
    var ax: [3]f64 = .{ 0, 0, 0 }; // its axis token X / Y / Z (else X)
    var c: usize = 0;
    if (attr(j, "physics:axis")) |v| {
        if (v.t == ul.UT_STR) {
            const k = v.str()[0] -% 'X';
            if (k <= 2) c = k;
        }
    }
    ax[c] = 1.0;
    var q: [4]f64 = .{ 0, 0, 0, 1 }; // localRot0: identity unless given
    if (attr(j, "physics:localRot0")) |v| {
        if (v.t == ul.UT_VEC and v.n >= 4) {
            const d = v.vec();
            q = .{ d[0], d[1], d[2], d[3] };
        }
    }
    var axis = xvec(&usd.cm, xvec(&B.w, jaxis(ax, q), false), false); // then W's rotation, then C's
    unit(&axis);
    var t: T = .{}; // the text: body1 first (BeeModel measures the first from the second, USD body1 from body0)
    t.s(jtypes[kind]);
    t.s(" ");
    if (b1) |o| {
        t.name(bodies[o].first);
        t.s(" ");
        t.name(B.first);
    } else { // (one body: it, to the world)
        t.name(B.first);
        t.s(" world");
    }
    t.s(" pivot ");
    t.vec3(piv);
    if (kind < 2) { // (fixed and point: no axis)
        t.s(" axis ");
        t.vec3(axis);
        var lo: f64 = 0;
        var hi: f64 = 0;
        var lim = true;
        if (hasApi(j, "PhysicsDriveAPI:linear") or hasApi(j, "PhysicsDriveAPI:angular") or mimic(j)) {
            // a drive: held where it is (as a stiff drive holds it): limits 0 0
        } else limits: { // limits, when both are finite
            lo = isDbl(attr(j, "physics:lowerLimit")) orelse {
                lim = false;
                break :limits;
            };
            hi = isDbl(attr(j, "physics:upperLimit")) orelse {
                lim = false;
                break :limits;
            };
            if (@abs(lo) >= 1.0e30 or @abs(hi) >= 1.0e30) {
                lim = false;
                break :limits;
            }
            if (kind == 1) { // a slider's: stage units to metres (C's scale: its first row's x)
                const s = @abs(usd.cm[0]);
                lo *= s;
                hi *= s;
            }
        }
        if (lim) {
            t.s(" limits ");
            t.f(lo);
            t.s(" ");
            t.f(hi);
        }
    }
    t.run("rigid.joint");
    njoints += 1;
}
