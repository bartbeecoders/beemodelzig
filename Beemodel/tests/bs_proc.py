#!/usr/bin/env python3
"""BeeScript's curve, procedural, folder and text builtins (src/bs_proc.zig:
curve cpoints clength cpos lsystem wfc instances instpos folder infolder
folders refimage text text_set; src/wfc.zig: wave function collapse) run by
BeeModel through --eval, a temp HOME and XDG_RUNTIME_DIR each: normal calls,
errors, every argument count with junk values, wrong types, bad names and
edge values (NaN, infinities, huge, negative, empty text), random call
sequences each give a clean result or a clean script error (no crash, panic
or timeout); the .bee files they save read back (objects, meshes, curves and
texts by the object that holds them, folders), and opened and saved again
give the same scene; a run undone and redone as one step; random garbage (no
crash, no hang); memory over many runs.

    python3 tests/bs_proc.py BIN [random-runs=60] [seed]

BS_ONLY=scripts (curves lsys wfc inst fold reftext),edge,args,files,random,undo,garbage,leak
runs some.
"""
import os, random, shutil, struct, subprocess, sys, tempfile, zlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsboth as B
import beefile

A = sys.argv + [os.path.join(B.ROOT, 'zig-out-debug/bin/beemodel')] * (len(sys.argv) < 2)
B.setup(A[:2] + ['-'] + A[2:], 60)   # (bsboth: BIN ORIG RUNS SEED; no ORIG)
ONLY = [x for x in os.environ.get('BS_ONLY', '').split(',') if x]
MINE = ['curve', 'cpoints', 'clength', 'cpos', 'lsystem', 'wfc', 'instances', 'instpos', 'folder', 'infolder', 'folders', 'refimage', 'text', 'text_set']
NAMES = {k: v for k, v in B.table({'curves', 'organise', 'modeling', 'scene', 'render', 'nodes'}).items() if k in MINE}
CV_HDR, CP_SZ = 572, 48


def want(s):
    return not ONLY or s in ONLY or (s in GROUPS and 'scripts' in ONLY)


GROUPS = ('curves', 'lsys', 'wfc', 'inst', 'fold', 'reftext')


def png(path, w, h):
    raw = b''.join(b'\0' + b''.join(bytes([(x * 40) % 256, (y * 60) % 256, 128]) for x in range(w)) for y in range(h))
    ch = lambda t, d: struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))


REF = os.path.join(B.T, 'ref.png')
png(REF, 6, 4)
BADPNG = os.path.join(B.T, 'bad.png')
open(BADPNG, 'wb').write(open(REF, 'rb').read()[:30])

# ---- the .bee files: curves and texts by the object holding them ----------------------------

def by_object(path):
    """CURV and TEXT records keyed by the names of the objects whose mesh they
    belong to (the writers number meshes in their own orders)."""
    objs = beefile.objects(path)
    owner = {}
    for o in objs:
        owner.setdefault(o['mesh'], o['name'])
    out = {}
    c = beefile.chunk(path, b'CURV') or b''
    o = 0
    while len(c) - o >= 8:
        ix, n = struct.unpack_from('<II', c, o)
        sz = 8 + CV_HDR + n * CP_SZ
        out[('CURV', owner.get(ix, f'?{ix}'))] = c[o + 4:o + sz]
        o += sz
    if o != len(c):
        out[('CURV', 'tail')] = c[o:]
    c = beefile.chunk(path, b'TEXT') or b''
    o = 0
    while len(c) - o >= 8:
        ix, n = struct.unpack_from('<II', c, o)
        out[('TEXT', owner.get(ix, f'?{ix}'))] = c[o + 4:o + 8 + n]
        o += 8 + n
    return out


def scene_diff(pa, pb, skip=()):
    """What differs between two saved scenes ('' when nothing)."""
    if not (os.path.exists(pa) and os.path.exists(pb)):
        return f'a file is missing ({os.path.basename(pa)} {os.path.exists(pa)}, {os.path.basename(pb)} {os.path.exists(pb)})'
    (ra, xa), (rb, xb) = B.scene(pa), B.scene(pb)
    why = []
    if len(ra) != len(rb):
        why.append(f'{len(ra)} / {len(rb)} objects')
    for k, (a, b) in enumerate(zip(ra, rb)):
        if a[0] != b[0]:
            fa, fb = beefile.objects(pa)[k], beefile.objects(pb)[k]
            why.append(f'object {k} {fa["name"]!r}: {[(x, fa[x], fb[x]) for x in fa if x != "mesh" and fa[x] != fb[x]]}')
        elif a[1] != b[1]:
            why.append(f'object {k}: its mesh ({len(a[1] or b"")} / {len(b[1] or b"")} bytes)')
    for t in sorted(set(xa) | set(xb)):
        if t in (b'CURV', b'TEXT') or t in skip:
            continue
        if xa.get(t) != xb.get(t):
            why.append(f'{t.decode()} chunk')
    oa, ob = by_object(pa), by_object(pb)
    for k in sorted(set(oa) | set(ob)):
        if oa.get(k) != ob.get(k):
            why.append(f'{k[0]} of {k[1]}')
    return '; '.join(why[:4])


def files(code, tag, what, quiet=False, again=False):
    """A clean run; the scene it saves (if it gets that far) reads back - and,
    with again, opened and saved by a second run is the same scene."""
    pa, pb = f'{B.T}/{tag}.bee', f'{B.T}/{tag}_again.bee'
    for p in (pa, pb):
        if os.path.exists(p):
            os.remove(p)
    b = B.run(B.BIN, ['--eval', code.replace('@OUT', pa)], 600)
    d = '' if B.clean(b) else 'not a clean run'
    if not d and os.path.exists(pa):
        try:
            B.scene(pa)
            by_object(pa)
        except Exception as e:  # noqa: BLE001 (any parse failure is the finding)
            d = f'its .bee does not read back ({e!r})'
        if not d and again:
            c = B.run(B.BIN, ['--eval', f'op("file.open", "{pa}")\nop("file.save", "{pb}")'], 600)
            d = scene_diff(pa, pb) if c[0] == 0 else f'opened and saved again: {c!r}'
            d = d and 'opened and saved again: ' + d
    elif not d and b[0] == 0 and '@OUT' in code:
        d = 'no file saved'
    ok = not d
    if not quiet or not ok:
        B.check(ok, f'{what}: a clean run, its scene reads back' + (', opened and saved again: the same' if again else '') + ('' if ok else f': {d}\n         {b!r}'))
    return ok


TREE = ('t = gtree("T")\no = gnode(t, "output")\ni = gnode(t, "input")\nd = gnode(t, "distribute", 2, 3, 0)\nc = gnode(t, "cube", 0.2)\n'
        'n = gnode(t, "instance", 1, 0, 0)\nglink(t, i, d, 1)\nglink(t, d, n, 1)\nglink(t, c, n, 2)\nglink(t, n, o, 1)\n'
        'm = modifier("Cube", "geometry")\nmodset("Cube", m, "tree", t)\n')
TILES = ('scale("Cube", 0.5)\np = add("plane", "Pl")\nscale(p, 0.5)\nw = add("cone", "Co")\nscale(w, 0.5, 0.5, 0.25)\nrotate(w, 0, 30, 0)\n'
         'g = add("cylinder", "Cy")\nscale(g, 0.5, 0.5, 0.5)\nrotate(g, 90, 0, 0)\n')
TXT = 'op("text.add", "Hello")\n'

# ---- scripts: normal calls, errors -------------------------------------------------------------

if want('curves'):
    print('-- curves --')
    for code in [
        'c = curve("bezier")\nprint(c, cpoints(c), clength(c), cpos(c, 0, "x"), cpos(c, 1, "y"), cpos(c, 1, "z"), cpos(c, 2, "x"))',
        'print(curve("circle"), curve("path"), curve("empty"), curve("bezier"), curve("circle"), active(), count())',
        'print(curve("circle", "Ring"), cpoints("Ring"), clength("Ring"), cpos("Ring", 3, "z"), cpos("Ring", 3, "zebra"), cpos("Ring", 3, "w"))',
        'print(curve("path", "P"), cpoints("P"), clength("P"))\nfor i in 0..5 { print(cpos("P", i, "x"), cpos("P", i, "y"), cpos("P", i, "z")) }',
        'print(curve("empty", "E"), cpoints("E"), clength("E"), cpos("E", 0, "x"))',
        'print(curve("empty", ""), curve("empty", ""), curve("bezier", "Cube"), curve("path", "abcdefghijklmnopqrstuvwxyz0123456789"))',
        'b = curve("empty", "Bridge")\nop("curve.spline", "bezier")\nop("curve.point", "-16 8 -6")\nop("curve.point", "0 6.5 0")\nop("curve.point", "16 8 6")\nop("curve.set", "resolution 24")\nprint(cpoints(b), clength(b), cpos(b, 1, "y"))',
        'c = curve("circle")\nop("curve.set", "bevel 0.2")\nprint(cpoints(c), clength(c), verts(c), faces(c), issel(c), issel("Cube"))',
        'print(cpoints("Cube"), clength("Cube"), cpos("Cube", 0, "x"))', 'print(cpoints("Light"))', 'print(clength("Nope"))', 'print(cpos("Camera", 0, "x"))',
        'print(curve("spiral"))', 'print(curve("Bezier"))', 'print(curve(""))', 'print(curve(1))', 'print(curve("bezier", 1))', 'print(curve("bezier", nil))',
        'c = curve("path")\nprint(cpos(c, 0, "{"), cpos(c, 0, "|"), cpos(c, 0, "y"), cpos(c, 4, "x"), cpos(c, 5, "x"))',
        'print(cpoints(1))', 'print(cpos(curve("path"), "1", "x"))', 'print(cpos(curve("path"), 1, 0))', 'print(cpos(curve("path"), 1, nil))',
    ]:
        B.same(code)

if want('lsys'):
    print('-- L-systems --')
    for code in [
        'print(lsystem("P", "F", "F=F+F-F", 2, 90), verts("P"), faces("P"), edges("P"), active())',
        'print(lsystem("T", "X", "X=F[+X]F[-X]+X; F=FF", 3, 25, 0.3, 0.02), verts("T"), faces("T"), volume("T"))',
        'print(lsystem("K", "F-F-F-F", "F=F-F+F+FF-F-F+F", 2, 90, 0.5), verts("K"), everts("K"))',
        'print(lsystem("B", "A", "A=[&FA]/////[&FA]///////[&FA]; F=S/////F; S=F", 3, 22.5, 0.2, 0.01), verts("B"), faces("B"))',
        'print(lsystem("Q", "F", "", 0, 0), verts("Q"), vpos("Q", 1, "y"))',
        'print(lsystem("N", "X", "X=+-", 3, 90))', 'print(lsystem("N", "", "", 3, 90))', 'print(lsystem("N", "F", "F=FF", 40, 90), verts("N"))',
        'print(lsystem("N", "F", "F=F[+F]", -3, 90), verts("N"))', 'print(lsystem("Cube", "F", "", 1, 0), lsystem("Cube", "F", "", 1, 0), count())',
        'print(lsystem("abcdefghijklmnopqrstuvwxyz0123456789", "F", "", 1, 0))', 'print(lsystem("", "F", "", 1, 0))',
        'print(lsystem(1, "F", "", 1, 0))', 'print(lsystem("L", 1, "", 1, 0))', 'print(lsystem("L", "F", 1, 1, 0))', 'print(lsystem("L", "F", "", "1", 0))',
        'print(lsystem("L", "F", "", 1, "90"))', 'print(lsystem("L", "F", "", 1, 90, "1"))', 'print(lsystem("L", "F", "", 1, 90, 1, "0.1"))',
        'print(lsystem(1, "", "", 1, 0))', 'print(lsystem("L", "F", "F=F+F", 2, 60, -1, -0.1), verts("L"), faces("L"))',
        'print(lsystem("L", "F[+F][-F]", "F=F[&F][^F]\\\\F/F|F", 2, 30, 1, 0.05), verts("L"), faces("L"))',
    ]:
        B.same(code)

if want('wfc'):
    print('-- wave function collapse --')
    for code in [
        TILES + 'print(wfc("W", 4, 3, 2, 7, "Cube Pl Co"), verts("W"), faces("W"), active())',
        TILES + 'print(wfc("W", 5, 5, 1, 1, "Co Pl"), verts("W"), vpos("W", 0, 0), vpos("W", 5, 2))',
        TILES + 'for s in 0..6 { print(s, wfc("W", 3, 3, 2, s, "Cube Co Cy Pl"), verts("W"), faces("W")) }',
        TILES + 'print(wfc("W", 6, 6, 1, 3, "Cy Co"), verts("W"))',
        'print(wfc("W3", 3, 3, 1, 1, "Light"), wfc("W4", -2, -2, 1, 1, "Cube"), wfc("W5", 2, 2, 1, 1, "Camera"))\nprint(verts("W3"), faces("W3"), verts("W4"), faces("W4"), verts("W5"))\nprint(vpos("W4", 0, 0), vpos("W4", 0, 1), vpos("W4", 0, 2), vpos("W4", 31, 0), vpos("W4", 31, 2))',
        'print(wfc("W", 65536, 65536, 1, 1, "Cube"), wfc("W", -1, -1, 1, 1, "Cube"), wfc("W", 0, 1, 1, 1, "Cube"), wfc("W", 32768, 1, 1, 1, "Cube"), wfc("W", 32769, 1, 1, 1, "Cube"))',
        'print(wfc("W", 1, 1, 1, 1, "Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube"), verts("W"))',
        'print(wfc("W", 1, 1, 1, 1, "Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube Cube"))',
        'print(wfc("W", 2, 2, 1, 1, "   Cube    Light  "), wfc("W", 2, 2, 1, 1, "Cube Nope"))', 'print(wfc("W", 2, 2, 1, 1, ""))', 'print(wfc("W", 2, 2, 1, 1, "   "))',
        'print(wfc("W", 2, 2, 1, 1, "cube"))', 'print(wfc(1, 2, 2, 1, 1, "Cube"))', 'print(wfc("W", "2", 2, 1, 1, "Cube"))', 'print(wfc("W", 2, 2, 1, 1, 5))',
        'print(wfc(nil, 2, 2, 1, 1, "Nope"))', 'print(wfc("", 2, 2, 1, -5, "Cube"), wfc("", 2, 2, 1, -5, "Cube"))',
        'c = curve("circle", "R")\nprint(wfc("W", 3, 3, 1, 2, "R Cube"), verts("W"))',
        'e = curve("empty", "E")\nprint(wfc("W", 3, 3, 1, 2, "E"), wfc("W", 3, 3, 1, 2, "E Cube"), verts("W"))',
        # (sides told apart at 1/64: a cube 0.49 high does not fit beside one 0.5 high)
        'scale("Cube", 0.5)\nadd("cube", "Cb2")\nscale("Cb2", 0.5, 0.49, 0.5)\nadd("cube", "Cb3")\nscale("Cb3", 0.5, 0.5, 0.494)\nfor s in 0..4 { w = wfc("W", 4, 4, 1, s, "Cube Cb2 Cb3")\n print(w, verts(w), vpos(w, 0, 1), vpos(w, 9, 1), vpos(w, 40, 1), vpos(w, 77, 2)) }',
        'add("sphere", "S")\nscale("S", 0.5)\nprint(wfc("W", 4, 4, 4, 9, "S Cube"), verts("W"), faces("W"))',
        # (every kind of object as a tile: lights, cameras and force fields their gizmo, armatures their bones, sketches their lines)
        'a = armature("Arm")\ns = sketch("Sk", "XY")\nrect(s, -0.5, -0.5, 1, 1)\ns2 = sketch("Sk2", "XY")\nf = field("wind", "Fi")\nop("text.add", "Hi")\n'
        'for t in 0..1 { print(wfc("W1", 1, 1, 1, 1, "Arm"), verts("W1"), faces("W1"), wfc("W2", 1, 1, 1, 1, "Sk"), verts("W2"), wfc("W3", 1, 1, 1, 1, "Fi"), verts("W3"), wfc("W4", 1, 1, 1, 1, "Sk2"), verts("W4")) }\n'
        'w = wfc("W5", 3, 3, 2, 1, "Arm Cube Sk Fi Text Camera")\nprint(w, verts(w), faces(w))\nfor i in 0..verts(w) { if i % 37 == 0 { print(vpos(w, i, 0), vpos(w, i, 1), vpos(w, i, 2)) } }',
        TILES + 'move("Co", 5, 5, 5)\nprint(wfc("W", 4, 4, 1, 3, "Co Cy"), verts("W"), vpos("W", 0, 0), vpos("W", 0, 1))',
    ]:
        B.same(code, timeout=600)

if want('inst'):
    print('-- instances --')
    for code in [
        TREE + 'print(instances("Cube"))\nmove("Cube", 1, 2, 3)\nrotate("Cube", 10, 20, 30)\nscale("Cube", 1, 2, 0.5)\nfor i in 0..4 { print(instpos("Cube", i, 0), instpos("Cube", i, 1), instpos("Cube", i, 2)) }',
        TREE + 'print(instpos("Cube", -1, 0), instpos("Cube", 0, 3), instpos("Cube", 0, -1), instpos("Cube", 999999, 0), instpos("Cube", instances("Cube") - 1, 1), instpos("Cube", sqrt(-1), 0), instpos("Cube", 0, sqrt(-1)))',
        TREE + 'rotate("Cube", 74, 33.3, 9.1)\nprint(instpos("Cube", 0, 0) * 1e6, instpos("Cube", 1, 1) * 1e6, instpos("Cube", 2, 2) * 1e6)',
        TREE + 'p = add("plane", "Pa")\nmove("Cube", 0, 1, 0)\nop("object.parent", "")\nprint(instances("Cube"), instpos("Cube", 1, 1))',
        'print(instances("Cube"), instpos("Cube", 0, 0))', 'print(instances("Light"))', 'print(instpos("Camera", 0, 0))', 'print(instances("Nope"))',
        'print(instances(1))', 'print(instpos("Cube", "0", 0))', 'print(instpos("Cube", 0, "x"))',
    ]:
        B.same(code, timeout=600)

if want('fold'):
    print('-- folders --')
    for code in [
        'print(folder("A"), folder("B", "A"), folders(), infolder("Cube"), infolder("Cube", "B"), infolder("Cube", ""), infolder("Cube", "Z"), folders())',
        'print(folder("A", "Z"), folder("A", "Q"), folders(), folder(""), folders(), folder(""), folders(), infolder("Light", ""))',
        'print(folder("abcdefghijklmnopqrstuvwxyz0123456789"), folder("abcdefghijklmnopqrstuvwxyz01234"), folders())',
        'for i in 0..300 { f = folder("F" + i) }\nprint(f, folders(), infolder("Cube", "F299"), infolder("Cube", "F3"))',
        'folder("H")\nop("folder.select", "H")\nprint(infolder("Cube", "H"), get("Cube", "hidden"))',
        'print(folder(1))', 'print(folder("A", 1))', 'print(infolder("Nope", "A"))', 'print(infolder("Cube", 1))', 'print(infolder("Cube", nil))', 'print(folders(1))',
    ]:
        B.same(code)

if want('reftext'):
    print('-- reference images, text --')
    for code in [
        f'print(refimage("{REF}"), refimage("{REF}", "Board"), refimage("{B.T}/nope.png"), refimage("{REF}", ""), active(), count())',
        f'print(refimage("{BADPNG}"), refimage(""), refimage("{B.T}"), count())', f'print(refimage("{REF}", "abcdefghijklmnopqrstuvwxyz0123456789"))',
        f'print(refimage("{REF}", "Cube"), refimage("{REF}", "Cube"))', 'print(refimage(1))', f'print(refimage("{REF}", 1))',
        TXT + 't = active()\nprint(t, text(t), text("Cube"), text_set(t, "Bye\\nnow"), text(t), text_set("Cube", "x"), text_set(t, ""), text(t))',
        TXT + 't = active()\nprint(text_set(t, "{frame} and \\"q\\""), text(t), verts(t), faces(t))',
        TXT + 't = active()\ns = ""\nfor i in 0..300 { s = s + "0123456789" }\nprint(text_set(t, s), len(text(t)), verts(t))',
        TXT + 't = active()\nprint(text_set(t, "\xc3\xa9t\xc3\xa9 \xe2\x82\xac"), text(t), verts(t))',
        'print(text("Light"), text_set("Camera", "x"))', 'print(text("Nope"))', 'print(text_set("Nope", "x"))', 'print(text(1))', TXT + 'print(text_set(active(), 1))',
    ]:
        B.same(code)

# ---- edge values -------------------------------------------------------------------------------

if want('edge'):
    print('-- edge values --')
    for v in ['0', '-0', '1e30', '-1e30', 'sqrt(-1)', '1e308*10', '-1e308*10', '1e-30', '-1', '2147483648', '-2147483649', '4294967297', '"0mm"', '""', 'nil']:
        B.same(f'x = {v}\nprint(cpos(curve("path"), x, "x"))\nprint(instpos("Cube", x, x))', f'curves, instances: {v}')
        B.same(f'x = {v}\nprint(lsystem("L", "F", "F=F+F", x, x), verts("L"))\nprint(lsystem("M", "F[+F]F", "F=F[-F]", 2, 30, x, x), verts("M"), faces("M"))', f'lsystem: {v}', timeout=600)
        B.same(TILES + f'x = {v}\nprint(wfc("W", x, 3, 1, 1, "Cube Co"), wfc("V", 3, x, x, 2, "Cy Pl"), wfc("U", 3, 3, 1, x, "Cube Co Pl"))\nprint(count(), verts(name(count() - 1)))', f'wfc: {v}', timeout=600)

# ---- every argument count -----------------------------------------------------------------------

if want('args'):
    print('-- every argument count, junk values --')
    B.check(len(NAMES) == len(MINE), f'the table: {len(NAMES)} of these builtins')
    B.argcounts(NAMES, 'curve("path", "S")\n')

# ---- the .bee files ------------------------------------------------------------------------------

if want('files'):
    print('-- the .bee files they save --')
    files('c = curve("bezier")\nr = curve("circle", "Ring")\np = curve("path", "abcdefghijklmnopqrstuvwxyz0123456789")\ne = curve("empty", "")\nop("file.save", "@OUT")', 'cv', 'curves of each kind', again=True)
    files('x = lsystem("P", "F", "F=F+F-F", 2, 90)\ny = lsystem("T", "X", "X=F[+X]F[-X]+X; F=FF", 3, 25, 0.3, 0.02)\nz = lsystem("P", "F-F", "F=FF", 3, 45, 0.5, 0.1)\nop("file.save", "@OUT")', 'ls', 'L-systems (lines, tubes)', again=True)
    files(TILES + 'w = wfc("W", 4, 3, 2, 7, "Cube Light Co")\nv = wfc("W", 5, 5, 1, 2, "Cy Pl")\nop("file.save", "@OUT")', 'wf', 'wave function collapse', again=True)
    files('print(folder("A"), folder("B", "A"), infolder("Cube", "B"), infolder("Light", "Z"), infolder("Camera", "Q"), infolder("Camera", ""))\nop("file.save", "@OUT")', 'fd', 'folders', again=True)
    files(TXT + 'text_set(active(), "Two\\nlines {frame}")\nop("text.add", "Other")\ntext_set("Text.001", "")\nop("file.save", "@OUT")', 'tx', 'texts set', again=True)
    files(f'r = refimage("{REF}", "Board")\nmove(r, 1, 2, 3)\nop("file.save", "@OUT")', 'rf', 'a reference image', again=True)
    files(TREE + 'print(instances("Cube"))\nop("file.save", "@OUT")', 'in', 'instances (geometry nodes)', again=True)
    # (tiles turned by rotate(): the radians it was given, not degrees and back)
    files(TILES + 'rotate("Pl", 74, 0, 9)\nrotate("Co", 33.3, 12.1, 7)\nw = wfc("W", 3, 2, 1, 34, "Pl Cube Co")\nprint(w, vpos(w, 0, 0), vpos(w, 1, 1))\nop("file.save", "@OUT")', 'wr', 'wfc: turned tiles', again=True)

# ---- random call sequences ------------------------------------------------------------------------

def rand_prog(rnd):
    L = [TILES]
    objs = ['"Cube"', '"Pl"', '"Co"', '"Cy"']
    nums = ['0', '1', '2', '3', '-1', '0.5', '7', '25', '90', 'sqrt(-1)', '1e9']
    for _ in range(rnd.randint(2, 9)):
        w = rnd.random()
        if w < 0.15:
            nm = f'C{rnd.randint(0, 3)}'
            L.append(f'print(curve("{rnd.choice(["bezier", "circle", "path", "empty", "x"])}", "{nm}"))')
            objs.append(f'"{nm}"')
        elif w < 0.3:
            o = rnd.choice(objs)
            L.append(f'print(cpoints({o}), clength({o}), cpos({o}, {rnd.choice(nums)}, "{rnd.choice("xyzw")}"))')
        elif w < 0.45:
            nm = f'L{rnd.randint(0, 3)}'
            ax = rnd.choice(['F', 'X', 'F-F-F', 'F[+F]F'])
            ru = rnd.choice(['F=F+F-F', 'X=F[+X]F[-X]+X; F=FF', 'F=F[&F]F[^F]', ''])
            extra = rnd.choice(['', f', {rnd.choice(nums)}', f', {rnd.choice(nums)}, {rnd.choice(["0", "0.02", "0.1"])}'])
            L.append(f'print(lsystem("{nm}", "{ax}", "{ru}", {rnd.randint(0, 4)}, {rnd.choice(["90", "25", "22.5", "60"])}{extra}))')
            objs.append(f'"{nm}"')
        elif w < 0.6:
            tiles = ' '.join(rnd.sample(['Cube', 'Pl', 'Co', 'Cy'], rnd.randint(1, 4)))
            L.append(f'print(wfc("W", {rnd.randint(1, 5)}, {rnd.randint(1, 5)}, {rnd.randint(1, 3)}, {rnd.randint(-5, 50)}, "{tiles}"))')
            objs.append('"W"')
        elif w < 0.72:
            L.append(f'print(folder("{rnd.choice("ABC")}"{rnd.choice(["", ", " + repr(rnd.choice("ABD")).replace(chr(39), chr(34))])}), folders())')
        elif w < 0.84:
            L.append(f'print(infolder({rnd.choice(objs)}{rnd.choice(["", ", \"\"", ", \"A\"", ", \"E\""])}))')
        elif w < 0.92:
            o = rnd.choice(objs)
            L.append(f'move({o}, {rnd.randint(-3, 3)}, {rnd.randint(-3, 3)}, 0)\nrotate({o}, {rnd.randint(0, 90)}, 0, {rnd.randint(0, 90)})')
        else:
            L.append(f'print(text({rnd.choice(objs)}), text_set({rnd.choice(objs)}, "x"))')
    L.append('print(count(), active())\nop("file.save", "@OUT")')
    return '\n'.join(L)


if want('random'):
    print('-- random call sequences --')
    rnd = random.Random(B.SEED)
    bad = 0
    for k in range(B.RUNS):
        if not files(rand_prog(rnd), f'r{k}', f'random sequence {k}', quiet=True):
            bad += 1
            if bad > 3:
                break
    B.check(bad == 0, f'{B.RUNS} random call sequences: clean runs, scenes read back')

# ---- undo: a run is one step (the console's line, then edit.undo / redo) ----------------------

if want('undo'):
    print('-- undo / redo of a run: one step --')
    body = ('c = curve("circle", "Ring"); x = lsystem("P", "F", "F=F+F-F", 2, 90); w = wfc("W", 3, 3, 1, 2, "Cube"); folder("A"); infolder("Cube", "A"); '
            f'r = refimage("{REF}", "Board"); rotate(r, 180, 0, 0); op("text.add", "Hi"); text_set("Text", "Bye")')
    p, p0, p1, p2 = f'{B.T}/u_p.bee', f'{B.T}/u_p0.bee', f'{B.T}/u_p1.bee', f'{B.T}/u_p2.bee'
    h = tempfile.mkdtemp(dir=B.T)
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h)
    env.pop('WAYLAND_DISPLAY', None)
    r = subprocess.run([B.BIN, '--shot', f'{h}/s.ppm', '--op', f'file.save {p}', '--op', body, '--op', f'file.save {p1}', '--op', 'edit.undo', '--op', f'file.save {p0}',
                        '--op', 'edit.redo', '--op', f'file.save {p2}'], env=env, capture_output=True, timeout=300)
    B.check(r.returncode == 0, f'it ran (rc {r.returncode})')
    names = [o['name'] for o in beefile.objects(p1)] if os.path.exists(p1) else []
    B.check(all(n in names for n in ('Ring', 'P', 'W', 'Board', 'Text')), f'the run made its objects ({names})')
    # (undone: the image refimage loaded stays - images are not in undo steps -
    # and the next uid stays where it was)
    for pa, pb, what in ((p, p0, 'undone: as before the run'), (p1, p2, 'redone: as after the run')):
        d = scene_diff(pa, pb, (b'IMGS', b'UIDS') if pb == p0 else ())
        B.check(not d, f'{what}' + ('' if not d else ': ' + d))
    for f in (p, p0, p1, p2):
        if os.path.exists(f):
            os.remove(f)
    r = subprocess.run([B.BIN, '--shot', f'{h}/s.ppm', '--op', f'file.save {p}', '--op', 'c = curve("path", "Q"); folder("A"); infolder("Cube", "A"); lsystem(1, "F", "", 1, 0)',
                        '--op', f'file.save {p1}', '--op', 'edit.undo', '--op', f'file.save {p0}'], env=env, capture_output=True, timeout=300)
    names = [o['name'] for o in beefile.objects(p1)] if os.path.exists(p1) else []
    d0 = scene_diff(p, p0, (b'UIDS',))
    B.check(r.returncode == 0 and 'Q' in names and scene_diff(p, p1) and not d0,
            f'a failing run: what it did before the error kept (the curve Q, a folder), then undone in one step (rc {r.returncode}, {names}, {d0!r})')
    shutil.rmtree(h, True)

# ---- garbage --------------------------------------------------------------------------------------

if want('garbage'):
    print('-- random garbage: no crash, no hang, nothing but its words --')
    rnd = random.Random(B.SEED + 1)
    vals = ['""', '" "', '"Cube"', '"Light"', '"Camera"', '"bezier"', '"F"', '"F=FF"', '0', '-1', '1e300', '-1e300', 'sqrt(-1)', '1e308*10', 'nil', '"x" + "y"', '65536', '4294967296',
            '"' + 'F' * 200 + '"', '"' + 'Cube ' * 20 + '"', '"[[[[++"', f'"{REF}"']
    bad = []
    for k in range(B.RUNS * 4):
        L = [rnd.choice(['', TILES, TREE, TXT])]
        for _ in range(rnd.randint(1, 8)):
            nm = rnd.choice(MINE)
            mn, mx = NAMES[nm]
            n = rnd.randint(mn, mx)
            L.append(f'print({nm}({", ".join(rnd.choice(vals) for _ in range(n))}))')
        r = B.run(B.BIN, ['--eval', '\n'.join(L)], 300)
        if r[0] not in (0, 1) or any(not (l.startswith('error: line') or l) for l in r[1].splitlines() if 'panic' in l or 'Segmentation' in l):
            bad.append(('\n'.join(L), r))
    B.check(not bad, f'{B.RUNS * 4} garbage programs: exit 0 or 1, no panic' + (f': {bad[:2]}' if bad else ''))

if want('leak'):
    print('-- memory: console runs with these builtins again and again --')
    line = ('for q in 0..10 { c = curve("bezier"); l = lsystem("L", "F", "F=F[+F]F", 3, 25, 1, 0.05); w = wfc("W", 4, 4, 2, q, "Cube"); f = folder("F" + q); '
            'infolder(c, f); delete(c); delete(l); delete(w) }')

    def rss(k):
        h = tempfile.mkdtemp(dir=B.T)
        a = ['--shot', f'{h}/x.ppm']
        for _ in range(k):
            a += ['--op', line, '--op', 'file.new']
        env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h)
        env.pop('WAYLAND_DISPLAY', None)
        p = subprocess.Popen([B.BIN, *a], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _, st, ru = os.wait4(p.pid, 0)
        shutil.rmtree(h, True)
        return st, ru.ru_maxrss
    (s4, r4), (s40, r40) = rss(4), rss(40)
    B.check(s4 == 0 and s40 == 0 and r40 - r4 < 8192, f'4 runs {r4} KiB, 40 runs {r40} KiB at most: no growth past 8 MiB')

B.finish('bs_proc')
