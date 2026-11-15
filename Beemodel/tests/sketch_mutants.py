#!/usr/bin/env python3
"""Each guard of tests/sketch.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

(The solver's own numbers were guarded by comparing them with the assembly
original, which is gone: those mutants went with that comparison.)

    python3 tests/sketch_mutants.py WORKDIR [jobs=8] [name...]

The window mutants (s_window) run one at a time at the end, on BEE_CPU.
"""
import concurrent.futures, os, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# the project's zig by its full path, asked before the HOME of our own (mise
# looks in the real one; its shim finds no version in the copies: no mise.toml there)
try:
    _z = subprocess.run(['mise', 'which', 'zig'], capture_output=True, text=True, cwd=ROOT).stdout.strip()
except OSError:
    _z = ''
ZIG = _z or 'zig'
import temphome  # noqa: F401,E402 (a HOME of its own: the user's ~/.config stays as it is)
W = os.path.abspath(sys.argv[1])
JOBS = int(sys.argv[2]) if len(sys.argv) > 2 else 8
M = [  # name, file, old, new, the scenarios that must fail
    # --- the review's fixes (each one the current sources minus that fix)
    ('x87: on a page made executable at run time', 'src/sketch.zig', 'const use_x87 = builtin.cpu.arch == .x86_64;\n\n// fld qword [rdi]; fsincos; fstp qword [rdi+8] (cos); fstp qword [rdi] (sin); ret\nexport const bee_sk_x87_sincos: [10]u8 linksection(".text") = .{ 0xdd, 0x07, 0xd9, 0xfb, 0xdd, 0x5f, 0x08, 0xdd, 0x1f, 0xc3 };\n\n/// atan2 as fld y; fld x; fpatan; fstp qword.\npub fn fpatan(y: f64, x: f64) f64 {\n    return @import("animexpr.zig").atan2x87(y, x);\n}\n\n/// fld a; fsincos; fstp cos; fstp sin -> .{ sin, cos }\npub fn fsincos(a: f64) [2]f64 {\n    if (!use_x87) return .{ @sin(a), @cos(a) };\n    return run87(&bee_sk_x87_sincos, a);\n}\n', 'const use_x87 = builtin.cpu.arch == .x86_64;\nconst x87_code = [_]u8{\n    0xf2, 0x0f, 0x11, 0x44, 0x24, 0xf8, 0xf2, 0x0f, 0x11, 0x4c, 0x24, 0xf0, 0xdd, 0x44, 0x24, 0xf8,\n    0xdd, 0x44, 0x24, 0xf0, 0xd9, 0xf3, 0xdd, 0x5c, 0x24, 0xf8, 0xf2, 0x0f, 0x10, 0x44, 0x24, 0xf8, 0xc3,\n    0xf2, 0x0f, 0x11, 0x44, 0x24, 0xf8, 0xdd, 0x44, 0x24, 0xf8, 0xd9, 0xfb, 0xdd, 0x1e, 0xdd, 0x1f, 0xc3,\n};\nvar x87_page: ?[*]const u8 = null;\nfn x87() ?[*]const u8 {\n    if (x87_page) |p| return p;\n    const linux = std.os.linux;\n    const r = linux.mmap(null, 4096, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);\n    if (linux.errno(r) != .SUCCESS) return null;\n    const p: [*]u8 = @ptrFromInt(r);\n    @memcpy(p[0..x87_code.len], &x87_code);\n    if (linux.errno(linux.mprotect(p, 4096, .{ .READ = true, .EXEC = true })) != .SUCCESS) return null;\n    x87_page = p;\n    return p;\n}\npub fn fpatan(y: f64, x: f64) f64 {\n    const p = x87() orelse return std.math.atan2(y, x);\n    const f: *const fn (f64, f64) callconv(.c) f64 = @ptrCast(p);\n    return f(y, x);\n}\npub fn fsincos(a: f64) [2]f64 {\n    const p = x87() orelse return .{ @sin(a), @cos(a) };\n    var s: f64 = 0;\n    var c: f64 = 0;\n    const f: *const fn (*f64, *f64, f64) callconv(.c) void = @ptrCast(p + 33);\n    f(&s, &c, a);\n    return .{ s, c };\n}\n', 's_review'),
    # --- the object, the file
    ('file: refs always 1', 'src/skobj.zig', 'const n = sceneHolds(b) + undo.sketchHolds(b, true);', 'const n = sceneHolds(b) * 0 + 1;', 's_window,s_modes'),
    ('file: not solved when read', 'src/skobj.zig', '_ = end(i); // solved and shown again', '_ = displayMesh(b);', 's_solver'),
    ('own: changed in place', 'src/skobj.zig', 'if (sceneHolds(b) + undo.sketchHolds(b, false) <= 1) return b;', 'if (true) return b;', 's_modes'),
    # --- DXF, SVG
    ('dxf: construction on layer 0', 'src/fab2d.zig', 'o.str(if (e.flags & sk.F_CONSTR != 0) "CONSTRUCTION\\n" else "0\\n"); // the layer', 'o.str("0\\n");', 's_dxfsvg'),
    ('units ignored', 'src/fab2d.zig', 'const data = (if (kind == .dxf) dxf(b, cad.unitMm()) else svg(b, cad.unitMm()))', 'const data = (if (kind == .dxf) dxf(b, 1000) else svg(b, 1000))', 's_dxfsvg'),
    # --- sketch mode
    ('Tab does not toggle sketch mode', 'src/ops.zig', 'if (@import("sketchui.zig").tab()) return; // (sketch mode)', '', 's_modes'),
    ('Esc not sketch mode\'s', 'src/app.zig', 'if (@import("sketchui.zig").escape()) return; // (sketch mode first)', '', 's_modes'),
    ('dimension: angles not in degrees', 'src/sketchui.zig', 'if (d.t == sk.C_ANGLE and !hasUnit(arg)) {', 'if (false) {', 's_ops'),
    ('dimension: the expression dropped', 'src/sketchui.zig', 'var text: ?[]const u8 = arg;', 'var text: ?[]const u8 = null;', 's_ops'),
    ('level lines not horizontal', 'src/sketchui.zig', 'if (dy < dx * md_tan) {', 'if (dy < dx * 0.0) {', 's_window'),
    ('Shift does not add', 'src/sketchui.zig', '        if (!shift) nsel = 0;\n        selToggle(key);', '        nsel = 0;\n        selToggle(key);', 's_window'),
    ('line tool: draws nothing', 'src/sketchui.zig', "        T_LINE => {\n            var a = prev; // the start: the chain's point", "        T_LINE => {\n            if (true) return;\n            var a = prev; // the start: the chain's point", 's_fuzz'),
    ('drag: the old display mesh kept', 'src/skobj.zig', '        if (old) |om| release(om);', '        _ = old;', 's_review'),
    ('a point click does not select', 'src/sketchui.zig', '    } else click(v, r, x, y, shift);', '    } else _ = .{ v, r, x, y, shift };', 's_point_click'),
]
want = sys.argv[3:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
if not os.path.exists(f'{W}/BeeZigUi'):
    os.symlink(os.path.join(os.path.dirname(ROOT), 'BeeZigUi'), f'{W}/BeeZigUi')


def one(k):
    name, fn, old, new, scen = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', d)   # (its ../BeeZigUi: WORKDIR/BeeZigUi, a link)
        if os.path.isdir(f'{ROOT}/zig-pkg'):
            os.symlink(f'{ROOT}/zig-pkg', f'{d}/zig-pkg')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            return name, '?', 'the code is not there'
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run([ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, SK_ONLY=scen)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/sketch.py', f'{d}/out/bin/beemodel', '40', '4242'], env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {scen}: {fails[0].strip()[:90]}' if fails else f'nothing in {scen} failed')
    finally:
        shutil.rmtree(d, ignore_errors=True)


bad = []
win = [k for k in range(len(M)) if 's_window' in M[k][4] or 's_point_click' in M[k][4]]
rest = [k for k in range(len(M)) if k not in win]
with concurrent.futures.ThreadPoolExecutor(JOBS) as ex:
    for name, st, msg in ex.map(one, rest):
        print(f'  {st:4} {name}: {msg}', flush=True)
        if st != 'ok':
            bad.append(name)
for k in win:
    name, st, msg = one(k)
    print(f'  {st:4} {name}: {msg}', flush=True)
    if st != 'ok':
        bad.append(name)
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
