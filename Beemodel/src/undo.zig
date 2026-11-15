// Undo / redo: a ring of whole-scene snapshots. After every input event the
// app calls sync(): if the scene now differs from the current snapshot (and
// no drag, typed value or modal transform is in progress) that is one step.
// So a drag, a typed value or a toggle is one step, as in the original.
//
// The original records the scene just before an operator (run_op: undo_push,
// then the operator); here a step is the scene after one, and the snapshot the
// scene is at stands in for "just before the next one". So what evaluation does
// between edits (a frame, a driver, a constraint) has to reach that snapshot,
// or it would look like an edit. But only then: evaluation also runs while an
// edit is under way (a drag's frames, an operator's rig_eval), and folding that
// in would put the edit in the step before it. An evaluation pass therefore asks
// once, before its first write, whether the scene still is the snapshot (evalWrite):
// only then what it writes is evaluation and nothing else, and goes into the
// snapshot whole (absorb). Otherwise the snapshot stays and the next step takes it.
const std = @import("std");
const scene = @import("scene.zig");

pub const N = 128;

/// A step's changes in place (a sculpt stroke moves a mesh that older steps hold
/// too): what takes the scene from the step before to it and back. Every step that
/// holds the mesh sees it through the deltas between them; so a delta stays with
/// its step and is run, in order, wherever the history goes.
pub const Delta = struct {
    ctx: *anyopaque,
    bytes: usize,
    /// true: back to the step before.
    apply: *const fn (*anyopaque, bool) void,
    free: *const fn (*anyopaque) void,
};
var deltas: [N]?Delta = @splat(null);

fn dropDelta(s: usize) void {
    if (deltas[s]) |d| d.free(d.ctx);
    deltas[s] = null;
}

/// The steps after the one the scene is at go.
fn dropRedo() void {
    var k = cur + 1;
    while (k < len) : (k += 1) dropDelta(slot(k));
    len = cur + 1;
}

/// The oldest step goes; the delta that led out of it is no use now.
fn dropOldest() void {
    dropDelta(slot(1));
    base = (base + 1) % N;
    len -= 1;
    cur -= 1;
}

fn dropAll() void {
    for (0..N) |s| dropDelta(s);
}

var states: [N]scene.State = @splat(.{ .count = 0, .active = null, .cursor = .{ 0, 0, 0 }, .render_camera = null });
var labels: [N][112]u8 = undefined; // (an agent's "Agent: <tool>": the original's 112)
var label_len: [N]u8 = @splat(0);
var base: usize = 0; // ring index of the oldest snapshot
var len: usize = 0; // snapshots kept
var cur: usize = 0; // the snapshot the scene is at (0 .. len-1)

/// Changes with the steps; known_at[m] == generation: only the step the scene
/// is at can hold mesh m.
var generation: u32 = 1;
/// Moves whenever undo, redo or a jump restores a step (what is derived from
/// the scene and not kept in the steps - bfeat.zig's solids - follows it).
pub var restores: u32 = 0;
var known_at: [scene.max_meshes]u32 = @splat(0);

var pending: [112]u8 = undefined;
var pending_len: usize = 0;

fn slot(k: usize) usize {
    return (base + k) % N;
}

pub fn init() void {
    base = 0;
    len = 1;
    cur = 0;
    scene.save(&states[0]);
    label_len[0] = 0;
}

/// The history starts again: the scene was replaced. Images, the world and
/// lightmaps are not in steps, so a step from before would be another scene
/// with this one's images, and saving it would lose them (undo_clear).
pub fn restart() void {
    generation +%= 1;
    @import("sculpt.zig").sceneReplaced();
    @import("paint.zig").sceneReplaced();
    dropAll();
    held.drop();
    held_step = false;
    base = 0;
    len = 1;
    cur = 0;
    scene.save(&states[0]);
    label_len[0] = 0;
    pending_len = 0;
    gc_at = scene.meshes_made -% 1;
    collect();
}

/// Names the step the next change makes ("Move", "Delete" ...).
pub fn label(s: []const u8) void {
    const n = @min(s.len, pending.len);
    @memcpy(pending[0..n], s[0..n]);
    pending_len = n;
}

/// Record a step if the scene changed since the current snapshot.
var gc_at: u32 = 0;

/// The meshes only older steps keep may take this much; past it the oldest
/// steps go (the original caps its history at 64 MiB too; a mesh copy of a
/// big scan is 100+ MB, so the budget is larger here).
const max_bytes: usize = 512 << 20;

/// Free the meshes neither the scene nor any step uses (edits make new ones).
fn collect() void {
    @import("skobj.zig").collect(); // (sketch blocks no step holds)
    if (gc_at == scene.meshes_made) return;
    gc_at = scene.meshes_made;
    generation +%= 1;
    trim();
    var used: [scene.max_meshes]bool = @splat(false);
    markMeshes(&used);
    scene.collectMeshes(&used);
}

/// Drop the oldest steps while the meshes only the history holds pass the budget.
fn trim() void {
    while (cur > 0) {
        var live: [scene.max_meshes]bool = @splat(false);
        for (scene.objects[0..scene.count]) |*o| {
            if (o.mesh) |mi| live[mi] = true;
            if (o.mres) |mi| live[mi] = true;
        }
        var counted: [scene.max_meshes]bool = @splat(false);
        var bytes: usize = 0;
        for (0..len) |k| {
            const st = &states[slot(k)];
            for (st.objects[0..st.count]) |*o| {
                for ([2]?u16{ o.mesh, o.mres }) |h| {
                    const mi = h orelse continue;
                    if (live[mi] or counted[mi]) continue;
                    counted[mi] = true;
                    bytes += scene.meshBytes(mi);
                }
            }
            if (deltas[slot(k)]) |d| bytes += d.bytes;
        }
        if (bytes <= max_bytes) return;
        // the oldest step goes
        dropOldest();
    }
}

/// Strokes made inside a script run or an agent's request (strokeStep while
/// frozen or grouped): the one step the run makes when it ends carries their
/// deltas, applied in order (back: the last first).
var held_step = false;
const Chain = struct {
    d: std.ArrayList(Delta) = .empty,

    fn add(c: *Chain, x: Delta) void {
        c.d.append(std.heap.page_allocator, x) catch {
            // no room to keep it: the stroke stays, as the original's
            // undo_attach_delta does with nowhere to keep it
            x.free(x.ctx);
        };
    }

    /// The deltas as one (null: none), the list empty again.
    fn take(c: *Chain) ?Delta {
        if (c.d.items.len == 0) return null;
        if (c.d.items.len == 1) {
            const x = c.d.items[0];
            c.d.clearRetainingCapacity();
            return x;
        }
        const h = std.heap.page_allocator.create(Chain) catch {
            c.drop();
            return null;
        };
        h.* = .{ .d = c.d };
        c.d = .empty;
        var bytes: usize = 0;
        for (h.d.items) |x| bytes += x.bytes;
        return .{ .ctx = h, .bytes = bytes, .apply = applyChain, .free = freeChain };
    }

    fn drop(c: *Chain) void {
        for (c.d.items) |x| x.free(x.ctx);
        c.d.clearRetainingCapacity();
    }

    fn applyChain(p: *anyopaque, back: bool) void {
        const h: *Chain = @ptrCast(@alignCast(p));
        if (back) {
            var k = h.d.items.len;
            while (k > 0) {
                k -= 1;
                h.d.items[k].apply(h.d.items[k].ctx, true);
            }
        } else for (h.d.items) |x| x.apply(x.ctx, false);
    }

    fn freeChain(p: *anyopaque) void {
        const h: *Chain = @ptrCast(@alignCast(p));
        h.drop();
        h.d.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(h);
    }
};
var held: Chain = .{};

/// Play mode (play.zig): what the scene does is play, not edits; it keeps or
/// discards it as one step when it ends.
pub var frozen = false;

/// One step for a whole request (an agent's MCP call, a script run): the
/// syncs inside it do nothing, groupEnd makes the step and names it (the
/// original's undo_group_begin / undo_group_end).
var group_depth: u32 = 0;
/// Steps made so far (a step pushed: it moves).
pub var pushes: u32 = 0;

pub fn groupBegin() void {
    if (group_depth == 0) sync(); // (what came before is a step of its own)
    group_depth += 1;
}

/// The group ends: true when it made a step.
pub fn groupEnd(l: []const u8) bool {
    if (group_depth == 0) return false;
    group_depth -= 1;
    if (group_depth > 0) return false;
    const p = pushes;
    label(l);
    sync();
    return pushes != p;
}

/// Inside a group, before an operator: while nothing has changed yet, the
/// step before keeps the selection as it is now (the original records the
/// scene at the group's first undo_push, the operator's, after a selection).
pub fn keepSelection() void {
    if (group_depth == 0) return;
    const now = &states[slot(cur)];
    if (!scene.differs(now)) scene.save(now);
}

pub fn grouped() bool {
    return group_depth > 0;
}

pub fn sync() void {
    if (frozen or group_depth > 0) return;
    defer collect();
    @import("lcam.zig").sync(); // (a light's or camera's field set: its record)
    @import("graphops.zig").syncCheck(); // (instances follow in the same step)
    const now = &states[slot(cur)];
    if (held_step) {
        // strokes inside a run or a request: their step, now the run is over
        held_step = false;
        pushStep(if (pending_len > 0) pending[0..pending_len] else "Edit");
        pending_len = 0;
        if (held.take()) |d| {
            deltas[slot(cur)] = d;
            generation +%= 1;
            trim();
        }
        return;
    }
    if (!scene.differs(now)) {
        // keep the newest selection with this step
        scene.save(now);
        pending_len = 0;
        @import("redo.zig").noStep();
        return;
    }
    pushStep(if (pending_len > 0) pending[0..pending_len] else "Edit");
    pending_len = 0;
}

/// A new step: the scene as it is. A new change drops the redo steps.
fn pushStep(l: []const u8) void {
    generation +%= 1;
    pushes +%= 1;
    dropRedo();
    if (len == N) dropOldest();
    cur += 1;
    len += 1;
    const s = slot(cur);
    scene.save(&states[s]);
    @memcpy(labels[s][0..l.len], l);
    label_len[s] = @intCast(l.len);
    @import("redo.zig").onStep();
    @import("autosave.zig").note(); // (every 25 changes)
}

/// A step that changed a mesh in place (nothing `differs` sees): one, whether or
/// not anything moved, as the original pushes one for every stroke.
pub fn strokeStep(l: []const u8, d: ?Delta) void {
    if (frozen or group_depth > 0) {
        // a script run, an agent's request: one step for all of it, made when
        // it ends (sync), carrying its strokes' deltas in order
        held_step = true;
        if (d) |x| held.add(x);
        return;
    }
    pushStep(l);
    deltas[slot(cur)] = d;
    pending_len = 0;
    if (d != null) {
        generation +%= 1;
        trim();
    }
}

/// What the step the scene is at carries, bytes (tests).
pub fn deltaBytes() usize {
    return if (deltas[slot(cur)]) |d| d.bytes else 0;
}

/// Object i changed mesh for a copy of it, with nothing else to tell (sculpt mode
/// takes its own): what the step the scene is at shows follows.
pub fn absorbMesh(i: usize) void {
    generation +%= 1;
    const st = &states[slot(cur)];
    const o = &scene.objects[i];
    for (st.objects[0..st.count]) |*s| {
        if (s.oid == o.oid) s.mesh = o.mesh;
    }
}

const Eval = enum { off, unknown, clean, under_edit };
var eval_state: Eval = .off;

/// An evaluation pass begins: nothing asked yet.
pub fn evalBegin() void {
    eval_state = .unknown;
}

pub fn evalEnd() void {
    eval_state = .off;
}

/// Before an evaluation's first write: is the scene still the snapshot?
pub fn evalWrite() void {
    if (frozen) eval_state = .under_edit;
    if (eval_state == .unknown) eval_state = if (scene.differs(&states[slot(cur)])) .under_edit else .clean;
}

/// An evaluation moved object i (a frame, a driver), with no edit under way:
/// not an edit, so the step the scene is at follows it. (`clean` is why the
/// whole of it is safe: all of the object but what this pass wrote is still
/// what the snapshot holds, mods and mesh too.)
pub fn absorb(i: usize) void {
    if (eval_state != .clean) return;
    const st = &states[slot(cur)];
    if (i >= st.count or i >= scene.count) return;
    const o = &scene.objects[i];
    const s = &st.objects[i];
    if (o.oid != s.oid) return;
    s.loc = o.loc;
    s.rot = o.rot;
    s.rad = o.rad;
    s.rad_deg = o.rad_deg;
    s.scl = o.scl;
    s.mods = o.mods;
    s.mesh = o.mesh;
    // (shown or hidden, deselected: a shattering one's pieces taking its place)
    s.visible = o.visible;
    s.selected = o.selected;
    s.wp = o.wp;
    s.wp_own = o.wp_own;
    s.wp_par = o.wp_par;
    s.wp_ok = o.wp_ok;
}

/// The same for a material's values.
pub fn absorbMat(k: usize) void {
    if (eval_state != .clean) return;
    const st = &states[slot(cur)];
    const material = @import("material.zig");
    if (k < st.mats.len and k < material.count) st.mats[k] = material.list[k];
}

/// The same for the force fields' records (a keyed strength).
pub fn absorbFields() void {
    if (eval_state != .clean) return;
    @import("fields.zig").keep(&states[slot(cur)].flds);
}

/// Does the step the scene is at hold this mesh? (an in-place change would reach it)
pub fn holdsMesh(mi: u16) bool {
    const st = &states[slot(cur)];
    for (st.objects[0..st.count]) |*o| {
        if (o.mesh == mi) return true;
    }
    return false;
}

/// A step other than the one the scene is at holds this mesh. (That one is the
/// scene itself until the next edit: absorb moves it along. Asked per written
/// channel, so the answer stays until the steps change.)
fn heldByOthers(mi: u16) bool {
    if (known_at[mi] == generation) return false;
    for (0..len) |k| {
        if (k == cur) continue;
        const st = &states[slot(k)];
        for (st.objects[0..st.count]) |*o| {
            if (o.mesh == mi) return true;
        }
    }
    known_at[mi] = generation;
    return false;
}

/// May an evaluation write in this mesh? No when a step would see it, as the
/// original's ME_REFS counts snapshots: it copies first, once, and the copy
/// is the scene's alone until the next step.
pub fn evalHolds(mi: u16) bool {
    if (heldByOthers(mi)) return true;
    return eval_state != .clean and holdsMesh(mi); // (the step before an edit stays as it is)
}

/// The redo panel ran the last tool again: the same step, a new result.
/// An evaluation changed what is made from the scene (a keyed CAD parameter: the
/// document and the features rebuilt), with no edit under way: the step the
/// scene is at follows all of it (`clean`: nothing else differs).
pub fn absorbAll() void {
    if (eval_state != .clean) return;
    generation +%= 1;
    scene.save(&states[slot(cur)]);
}

/// Nothing changed since the step the scene is at (co-editing: what others do
/// then goes into it, as the original pushes no step for it).
pub fn isClean() bool {
    return !scene.differs(&states[slot(cur)]);
}

pub fn replaceCurrent() void {
    generation +%= 1;
    scene.save(&states[slot(cur)]);
    collect();
}

pub fn canUndo() bool {
    return cur > 0 or @import("sculpt.zig").stroking or @import("paint.zig").stroking; // (a stroke under way is a step first)
}

pub fn canRedo() bool {
    return cur + 1 < len;
}

/// Undo one step; returns its name.
pub fn undo() ?[]const u8 {
    @import("sculpt.zig").finishStroke(); // (a stroke under way is a step first)
    @import("paint.zig").finishStroke();
    if (cur == 0) return null;
    @import("redo.zig").cancel();
    generation +%= 1;
    restores +%= 1;
    const s = slot(cur);
    if (deltas[s]) |d| d.apply(d.ctx, true);
    cur -= 1;
    scene.load(&states[slot(cur)]);
    return labels[s][0..label_len[s]];
}

pub fn redo() ?[]const u8 {
    @import("sculpt.zig").finishStroke();
    @import("paint.zig").finishStroke();
    if (cur + 1 >= len) return null;
    @import("redo.zig").cancel();
    generation +%= 1;
    restores +%= 1;
    cur += 1;
    const s = slot(cur);
    scene.load(&states[s]);
    if (deltas[s]) |d| d.apply(d.ctx, false);
    return labels[s][0..label_len[s]];
}

/// Mark the meshes the history's snapshots use (they must not be freed).
pub fn markMeshes(used: []bool) void {
    for (0..len) |k| {
        const st = &states[slot(k)];
        for (st.objects[0..st.count]) |*o| {
            if (o.mesh) |mi| used[mi] = true;
            if (o.mres) |mi| used[mi] = true;
        }
    }
}

/// Does any step hold this mesh? (A mesh none holds and no object shows can
/// go at once, as the original's unref.)
pub fn anyStepHolds(mi: u16) bool {
    for (0..len) |k| {
        const st = &states[slot(k)];
        for (st.objects[0..st.count]) |*o| {
            if (o.mesh == mi or o.mres == mi) return true;
        }
    }
    return false;
}

/// How many times the steps hold this sketch block (skobj.zig: copy before
/// changing it); but_cur: not the current step's (the scene itself holds what that one does):
/// the original's undo and redo stacks, whose snapshots each keep a reference
/// (SK_REFS) until they are dropped; an undo moves one from the undo stack to
/// the scene and the scene's to the redo stack, so the count stays.
pub fn sketchHolds(b: *const anyopaque, but_cur: bool) usize {
    var n: usize = 0;
    for (0..len) |k| {
        if (but_cur and k == cur) continue;
        const st = &states[slot(k)];
        for (st.objects[0..st.count]) |*o| {
            if (o.sk) |p| {
                if (@as(*const anyopaque, p) == b) n += 1;
            }
        }
    }
    return n;
}

/// Every sketch block the history's snapshots hold (they must not be freed).
pub fn markSketches(f: *const fn (*@import("sketch.zig").Block) void) void {
    for (0..len) |k| {
        const st = &states[slot(k)];
        for (st.objects[0..st.count]) |*o| {
            if (o.sk) |p| f(p);
        }
    }
}

/// Steps for the history list: index 1 .. count-1 have names; `current` is where the scene is.
pub fn count() usize {
    return len;
}
pub fn current() usize {
    return cur;
}
pub fn nameOf(k: usize) []const u8 {
    if (k == 0) return "Original";
    const s = slot(k);
    return labels[s][0..label_len[s]];
}

/// Jump to step k of the history.
pub fn goto(k: usize) void {
    @import("sculpt.zig").finishStroke();
    @import("paint.zig").finishStroke();
    if (k >= len) return;
    @import("redo.zig").cancel();
    generation +%= 1;
    restores +%= 1;
    // (the deltas between, in order)
    while (cur > k) : (cur -= 1) {
        if (deltas[slot(cur)]) |d| d.apply(d.ctx, true);
    }
    while (cur < k) {
        cur += 1;
        if (deltas[slot(cur)]) |d| d.apply(d.ctx, false);
    }
    scene.load(&states[slot(cur)]);
}

test "a run's strokes as one delta: back last to first, forward first to last" {
    const Rec = struct {
        var log: [8]u8 = undefined;
        var n: usize = 0;
        var freed: usize = 0;
        fn apply(p: *anyopaque, back: bool) void {
            const id: *const u8 = @ptrCast(p);
            log[n] = if (back) id.* + 'a' - '1' else id.*;
            n += 1;
        }
        fn free(_: *anyopaque) void {
            freed += 1;
        }
    };
    var ids = [3]u8{ '1', '2', '3' };
    var c: Chain = .{};
    for (&ids) |*id| c.add(.{ .ctx = id, .bytes = 10, .apply = Rec.apply, .free = Rec.free });
    const d = c.take().?;
    try std.testing.expectEqual(@as(usize, 30), d.bytes);
    d.apply(d.ctx, true);
    d.apply(d.ctx, false);
    try std.testing.expectEqualStrings("cba123", Rec.log[0..Rec.n]);
    d.free(d.ctx);
    try std.testing.expectEqual(@as(usize, 3), Rec.freed);
    try std.testing.expect(c.take() == null); // (empty again)
}
