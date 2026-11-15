#!/usr/bin/env python3
"""BeeScript (src/bscript.zig, bs_*.zig) run by BeeModel alone (--eval and
--run, a temp HOME and XDG_RUNTIME_DIR each): every script ends cleanly (a
result or one error line, exit 0 or 1, no crash, panic or hang); the .bee
files they save read back, and open -> save gives the same file; every
limit stops a script at its edge with an error; every builtin not available
yet answers with one clear error; random valid programs and random garbage
run cleanly; the console, undo / redo of a run (a failing one too) and macro
recording in the window (the fake compositor).

    python3 tests/bscript.py BIN [fuzz-runs=150] [seed]

BEE_CPU (default 10) pins the window runs. BS_ONLY=lang,files,... runs some
sections (lang run files unported limits console leak fuzz garbage window).
Imported by other tests for PortWin, check, scene, same_scene, T, CPU, K_ESC:
importing parses nothing that could fail (BIN is argv[1] if given).
"""
import os, random, re, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 and sys.argv[1] else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
# the release build beside the debug one: a heavy random program the debug build times out on runs there
REL = os.environ.get('BS_REL') or os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(BIN))), 'zig-out/bin/beemodel')
RUNS, SEED = 150, random.randrange(1 << 30)   # (set from the command line in main())
CPU = int(os.environ.get('BEE_CPU', '10'))
ONLY = [x for x in os.environ.get('BS_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beebs-', dir='/tmp')
HELD = []


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def want(s):
    return not ONLY or s in ONLY


def run(binary, args, timeout=120, stdin=None):
    """One run with a HOME and XDG_RUNTIME_DIR of its own: (rc, stdout, stderr)."""
    h = tempfile.mkdtemp(dir=T)
    env = dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h, XDG_CACHE_HOME=os.path.join(h, 'cache'))
    try:
        r = subprocess.run([binary, *args], capture_output=True, timeout=timeout, env=env)
        out = (r.returncode, r.stdout.decode('utf-8', 'replace'), r.stderr.decode('utf-8', 'replace'))
    except subprocess.TimeoutExpired:
        out = (None, 'timeout', '')
    shutil.rmtree(h, True)
    return out


def clean(r, eval_=True):
    """A run that ended as a program should: exit 0, or exit 1 with an error
    line (for --eval / --run); no signal, panic, safety check or timeout."""
    rc, out, err = r
    if rc not in (0, 1) or any(w in out + err for w in ('panic', 'reached unreachable', 'integer overflow', 'Segmentation fault')):
        return False
    return rc == 0 or not eval_ or any(ln.startswith('error: ') for ln in out.splitlines())


def cleanly(code, what=None, timeout=120):
    """A clean run of the script: (ok, its result)."""
    r = run(BIN, ['--eval', code], timeout)
    ok = clean(r)
    check(ok, (what or repr(code[:70])) + ('' if ok else f'\n         {r!r:.400}'))
    return ok, r


# ---- the .bee files the scripts save: the same scene --------------------------------------

def scene(path):
    """A .bee file's scene as two saves can be compared: every chunk but the
    workspaces, the thumbnail and the view, meshes taken through the objects
    that use them (a writer may number them in another order), UVs and
    vertex colours by object too."""
    cs = beefile.chunks(path)
    meshes = [b for t, b in cs if t == b'MESH']
    objs = beefile.chunk(path, b'OBJS')
    n = struct.unpack_from('<I', objs)[0]
    recs = []
    for k in range(n):
        r = objs[4 + k * 84:4 + (k + 1) * 84]
        typ, mi = struct.unpack_from('<II', r, 72)[0], struct.unpack_from('<I', r, 80)[0]
        me = meshes[mi] if typ == 0 and mi < len(meshes) else None
        name = r[:32].split(b'\0')[0]
        recs.append((name.ljust(32, b'\0') + r[32:80], me))     # (bytes after a name's 0 do not count)
    rest = {}
    for t, b in cs:
        if t in (b'MESH', b'OBJS', b'THMB', b'WSPC', b'VIEW', b'MUVS', b'MVCL') or not b:
            continue
        rest.setdefault(t, []).append(b)
    return recs, rest


def same_scene(pa, pb, what, uid_next=True):
    """The same scene in both files. uid_next=False: the UIDS chunk's last
    word (the next id, which undo keeps counting on) does not count."""
    if not (os.path.exists(pa) and os.path.exists(pb)):
        check(False, f'{what}: a file is missing ({pa}: {os.path.exists(pa)}, {pb}: {os.path.exists(pb)})')
        return False
    (ra, xa), (rb, xb) = scene(pa), scene(pb)
    if not uid_next:
        for x in (xa, xb):
            if b'UIDS' in x:
                x[b'UIDS'] = [u[:-4] for u in x[b'UIDS']]
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
        if xa.get(t) != xb.get(t):
            why.append(f'{t.decode()} chunk')
    check(not why, f'{what}: the same scene' + ('' if not why else ': ' + '; '.join(why[:4])))
    return not why


def roundtrip(p, what, whole=True):
    """p read back by BeeModel (file.open) and saved again: the same file
    (whole=False, a file a window saved: the same scene; a run with no window
    keeps no workspaces or thumbnail)."""
    q = p[:-4] + '_rt.bee'
    r = run(BIN, ['--eval', f'op("file.open", "{p}")\nop("file.save", "{q}")'])
    if not whole and r[0] == 0 and os.path.exists(q):
        return same_scene(p, q, f'{what}: open -> save, the same scene')
    ok = r[0] == 0 and os.path.exists(q) and open(p, 'rb').read() == open(q, 'rb').read()
    check(ok, f'{what}: open -> save gives the same file' + ('' if ok else f' ({r[:2]!r:.200}, saved {os.path.exists(q)})'))
    return ok


def saved(code, tag, what):
    """The script saving @OUT: a clean run, exit 0, a file that reads back and
    that open -> save keeps as it is."""
    p = f'{T}/{tag}.bee'
    r = run(BIN, ['--eval', code.replace('@OUT', p)])
    ok, why = r[0] == 0 and clean(r), ''
    if not ok:
        why = f' ({r!r:.300})'
    elif not os.path.exists(p):
        ok, why = False, ': no file saved'
    else:
        try:
            scene(p)
        except Exception as e:  # noqa: BLE001 (any parse failure is the finding)
            ok, why = False, f': its .bee does not read back ({e})'
    check(ok, f'{what}: runs, saves a file that reads back' + why)
    return ok and roundtrip(p, what)


# ---- the language, case by case ------------------------------------------------------------

LANG = [
    # the first ones BeeScript had
    'print(1 + 2 * 3, (1 + 2) * 3, 7 % 3, -7 % 3, 10 / 4)',
    'print(2m + 50cm, 10mm, 1km, 180deg / pi, 1e3, 1.5e-2)',
    'print(0.1 + 0.2, 1 / 3, 2 / 3, 1e20, 0.00001234, -0.5)',
    'print("a" + 1, "x" == "x", 1 != 1, not nil, 3 > 2 and 2 > 3, 0 or "y")',
    'fn fib(n) { if n < 2 { return n }\n return fib(n - 1) + fib(n - 2) }\nprint(fib(20))',
    's = 0\nfor i in 0..10 { if i == 3 { continue }\n if i == 6 { break }\n s += i }\nprint(s)',
    'i = 0; while i < 5 { i += 2 }; print(i)',
    'if 0 { print(1) } else if 2 > 1 { print(2) } else { print(3) }',
    'print(pow(2, 10), pow(4, 0.5), round(2.5), floor(-0.5), abs(-2), min(3, 1), max(3, 1))',
    'print(sin(90deg), cos(180deg), atan2(1, 0) / 1deg, sqrt(16), len("four"), num("2.5"))',
    'seed(7); a = rand(); seed(7); print(a == rand(), a >= 0 and a < 1)',
    'print(count(), name(2), active())',
    'b = add("torus", "T", 1, 2, 3); move(b, 0, 5, 0); print(b, get(b, "y"), count())',
    'x = 1 + nil', '\n\nprint(y)', 'for i in 0..3 {', 'fn f(a) { return a }\nf()',
    # the REPL echo
    '1 + 1', '"text"', 'nil', 'x = 5', 'x = 5\nx', 'print(1)\n2', '2\nx = 1', 'return 7', 'return', 'return "a" + 1\nprint(9)',
    'if 1 { 3 }', 'fn f() { 4 }\nf()', 'true', 'false', 'pi', '-0', '0x10', "'single'", '"a\\"b\\\\c\\n\\td\\q"',
    # numbers, printed
    'print(1e15, 999999999999999, 1e-4, 0.0001, 0.00009999, 123456.7890123, -1234567.0000004)',
    'print(1e308, 1e309, -1e309, 1e-310, 5e-324, 0.9999995, 0.9999994, 2.5e-7, 1.0000005e20)',
    'print(9.9999999e-5, 9.9999999e20, 0.0001235, 2.0000005, 1.25e-6, 0.0001005, 0.0001025)',
    'print(1.5e308, -1.7e308, 1e308 * 1.0000001)',
    'print(1/0.0000001, 0.1 * 3, 1e15 + 0.5, 4503599627370497, 1e16 / 3, 7e22, 1.5e-5)',
    'print(0x, 1)', 'print(0xg)', 'print(0xfffffffffffffff)', 'print(0x1000000000000000)', 'print(1e, 2)', 'print(1e+5, 1E-5, 2.5e+2m)',
    'print(1e399, 1e400, 1e-399, 3e-400)', 'print(1.5.5)', 'print(.5, 5., 1..2)', 'print(2cm, 3 mm)', 'print(10deg, 1rad, 1km / 1m)',
    'print(12345678901234567890, 0.000000000000000000001, 100000000000000000000000000000000)',
    # texts
    'print("a" + 2 + 3, 2 + 3 + "a", "x" + nil + "y", "" == "", "a" < "b")',
    's = ""\nfor i in 0..50 { s = s + i + "," }\nprint(len(s), s)',
    'print(str(1.5) + str(nil) + str("q"), len(str(1/3)), num(" 12"), num("12 "), num("-"), num("-2mm"), num("0x1f"), num("1e3"), num(""), num(".5"), num("."))',
    'print(num(3), num(nil))', 'print(len(5))', 'print("unterminated)', 'print("bad\n")', 'print("end\\', "print('mixed\")",
    'print("' + 'x' * 1100 + '")', 'print("' + 'y' * 600 + '", "' + 'z' * 600 + '", 1, 2, 3)', '"' + 'w' * 1500 + '"',
    's = "ab"\nfor i in 0..19 { s = s + s }\nprint(len(s))', 's = "ab"\nfor i in 0..20 { s = s + s }\nprint(len(s))',
    'a = "keep"\nb = "' + 'k' * 1000 + '"\nprint(a, len(b))',
    # comparisons and NaN, as ucomisd answers
    'n = sqrt(-1)\nprint(n, n < 1, n <= 1, n > 1, n >= 1, n == n, n != n, -n, not n, n and 1, n or 2)',
    'n = sqrt(-1)\nprint(1 % n)', 'print(1 / 0)', 'print(5 % 0)', 'print(-0 == 0, 1 < 2 < 3)', 'print(1 < "a")', 'print(nil < 1)',
    'print(-"a")', 'print("a" - 1)', 'print(nil * 2)', 'print(nil + nil)', 'print(not "", not "a", not 0, not 0.1)',
    'print(min(1, sqrt(-1)), min(sqrt(-1), 1), max(-0, 0), min(0, -0), max(2), min(5, 4, 3, 9))',
    'print(pow(2, -2), pow(-8, 1/3), pow(0, 0.5), pow(sqrt(-1), 0), pow(10, 300), pow(2, 1048577), pow(1.0001, 2000000), pow(2, 0.5))',
    'print(sin(1e22), cos(1e19), tan(1e19), tan(pi / 2), sin(-0), atan2(0, -1), atan2(-0, -1), atan2(1, 0))',
    'print(floor(-2.5), round(-2.5), round(0.49999999999999994), abs(-0), sqrt(2), deg(pi), rad(180))',
    'seed(0); a = rand(); seed(-1); b = rand(); seed(1e30); c = rand(); seed(sqrt(-1)); d = rand()\nprint(a, b, c, d)',
    'seed(42)\nfor i in 0..5 { print(rand()) }',
    'print(expr("2mm + 1cm"), expr("sin(30deg)"), expr("2^10"))', 'print(expr("1 +"))', 'print(expr("nosuch"))', 'print(expr(5))',
    # control flow
    'x = 0\nwhile x < 3 {\n x += 1\n if x == 2 { continue }\n print(x)\n}',
    'for i in 0..3 { for j in 0..2 { if j == 1 { break } print(i, j) } }',
    'for i in 5..2 { print(i) }\nprint(i)', 'for i in 0..2.5 { print(i) }', 'for i in "a"..3 { }', 'for i in 0.."b" { }',
    'n = 3\nfor i in 0..n { n = 0\n print(i) }', 'if nil { print(1) }\nelse { print(2) }', 'if 1 { print(1) }\n\n\nelse { print(2) }',
    'if 1 { } else if 0 { } else if 1 { } else { }', 'x = 1 if x', 'if 1 print(1)', 'if 1 {', 'while 1', 'else { }', '}',
    'break', 'continue', 'for i in 0..1 { fn f() {} }', 'fn f() { fn g() {} }', 'fn print() {}', 'fn f(a, a) {}', 'fn f(a b) {}', 'fn 1() {}',
    'fn f(1) {}', 'fn f[', 'fn f() { return 1 }\nprint(f(), f)', 'fn f() { }\nprint(f())', 'fn f(x) { y = x * 2\n return y }\nprint(f(3), y)',
    'g = 10\nfn f() { return g + 1 }\nprint(f())', 'fn f() { g2 = 5 }\nf()\nprint(g2)', 'print(nofn(1))', 'fn f(a) {}\nf(1, 2)',
    'fn f(n) { if n == 0 { return 0 } return 1 + f(n - 1) }\nprint(f(2000))', 'fn f(n) { if n == 0 { return 0 } return 1 + f(n - 1) }\nprint(f(2047))',
    'fn f(n) { return f(n) }\nf(1)', 'for i 0..3 {}', 'for i in 0 3 {}', 'for 1 in 0..3 {}', 'x = ', 'x = (1 +', 'print(1', 'print(1,)', 'x = 1 2',
    'x += 1', 'x = 2\nx -= 5\nx *= 3\nx /= 4\nprint(x)', 'x = "a"\nx += 1\nprint(x)', 'x == 3', 'pi = 3', 'true = 1', 'nil()', '(1)(2)',
    'add("cube", "Wide",\n    1,\n    2,\n    3)\nprint(get("Wide", "z"), (1 +\n 2), (\n\n4)\n)', 'print(1\n)\nx = (1\n', 'x = 1; y = 2;; z = 3 ;\nprint(x + y + z)', 'print(1) # a comment\n# another\nprint(2) #', 'a=1\r\nprint(a)\r\n',
    'x = [1, 2]', 'x = a.b', 'x = 1 @ 2', 'x = 1 ! 2', 'print("é")', 'é = 1', 'x = \x01', 'x = \x7f', 'x = \x1b',
    'and', 'x = 1 and', 'not', 'print(-)', 'print(--1, - -1, ---1)',
    'print(' + ', '.join(str(i) for i in range(16)) + ')', 'print(' + ', '.join(str(i) for i in range(17)) + ')',
    'x = ' + 'a' * 31 + ' = 1', 'x' * 32 + ' = 1', 'print(' + 'n' * 32 + ')',
    'x = 1\n' + 'if 1 { ' * 199 + '}' * 199, 'x = 1\n' + 'if 1 { ' * 200 + '}' * 200,
    'print(' + '(' * 199 + '1' + ')' * 199 + ')', 'print(' + '(' * 200 + '1' + ')' * 200 + ')',
    'x = ' + '-' * 199 + '1', 'x = ' + '-' * 200 + '1', 'x = ' + 'not ' * 5000 + '1\nprint(x)',
    'x = 0\n' + 'for i in 0..1 {\n' * 16 + 'x += 1\n' + '}\n' * 16 + 'print(x)', 'for i in 0..1 {\n' * 17 + '}\n' * 17,
    'for i in 0..1 {\n' + 'break\n' * 16 + '}', 'for i in 0..1 {\n' + 'break\n' * 17 + '}', 'for i in 0..1 {\n' + 'continue\n' * 17 + '}',
    ''.join(f'v{i} = 1\n' for i in range(512)) + 'print(v511)', ''.join(f'v{i} = 1\n' for i in range(513)),
    ''.join(f'fn f{i}() {{}}\n' for i in range(128)) + 'print(1)', ''.join(f'fn f{i}() {{}}\n' for i in range(129)),
    'fn f() {\n' + ''.join(f'l{i} = {i}\n' for i in range(64)) + 'return l63 }\nprint(f())', 'fn f() {\n' + ''.join(f'l{i} = 1\n' for i in range(65)) + '}',
    'fn f(a) {\n' + ''.join(f'l{i} = {i}\n' for i in range(63)) + 'return f(a)\n}\nf(1)',
    'x = 1\n' * 20000, 'x=1;' * 16000, '1;' * 32767, '1;' * 32766,
    'print("' + 'q' * 65000 + '")',
    'x = 1\nwhile 1 { x += 1 }', 'while 1 { }',
    # the scene
    'print(add("cube"), add("cube", "A"), add("cube", nil), add("cube", "B", 1, 2, 3), add("cube", nil, 4, 5, 6))',
    'add("cube", "A", 1, 2)', 'add("blob")', 'add(1)', 'add("cube", 5)', 'add("cube", "A", "x", 0, 0)', 'add()',
    'print(add("light"), add("camera"), add("sphere"), add("cylinder"), add("plane"), add("cone"), add("torus"), add("grid"), add("armature"))',
    'add("' + 'n' * 100 + '")',
    'for i in 0..1003 { add("cube", "Z") }\nprint(count(), name(count() - 1), name(1002))',
    'print(add("cube", "' + 'L' * 40 + '"), add("cube", "' + 'L' * 40 + '"))', 'print(rename("Cube", ""), rename("Light", ""))',
    'print(rename("Cube", "Light"), rename("Light", "Light"), exists("Light.001"), exists("light"))',
    'move("Cube", 1, 2, 3)\nrotate("Cube", 0.5, 1deg, -2)\nscale("Cube", 2)\nprint(get("Cube", "x"), get("Cube", "rz"), get("Cube", "sy"))',
    'scale("Cube", 1, 2)', 'scale("Cube", 1, 2, 3)\nprint(get("Cube", "sz"))', 'move("Cube", 1)', 'move("Nope", 1, 2, 3)', 'move("Cube", "a", 1, 2)', 'move(1, 1, 2, 3)',
    'set("Cube", "x", 1.1)\nset("Cube", "rx", 0.3)\nset("Cube", "sz", -2)\nprint(get("Cube", "x"), get("Cube", "rx"), get("Cube", "sz"))',
    'set("Cube", "color", 0x123456)\nprint(get("Cube", "color"))\nset("Cube", "color", -1)\nprint(get("Cube", "color"))\nset("Cube", "color", 1e20)\nprint(get("Cube", "color"))',
    'set("Cube", "hidden", 2)\nprint(get("Cube", "hidden"))\nset("Cube", "hidden", 0.5)\nprint(get("Cube", "hidden"))\nset("Cube", "select", 1)\nprint(get("Cube", "select"), issel("Cube"))',
    'print(get("Camera", "lens"), get("Light", "power"), get("Light", "lr"), get("Cube", "lens"))\nset("Camera", "lens", 35)\nset("Light", "power", 3)\nset("Light", "lg", 0.25)\nprint(get("Camera", "lens"), get("Light", "power"), get("Light", "lg"))',
    'get("Cube", "' + 'p' * 1100 + '")', 'op("' + 'q' * 1030 + '")', 'get("Cube", "w")', 'get("Cube", "colour")', 'get("Cube", "verylong")', 'get("Cube", 1)', 'get(1, "x")', 'set("Cube", "x", "1")', 'set("Nope", "q", 1)',
    'print(prop("Cube:x"), prop("Cube:nope"), prop("Nope:x"), prop("Light:ry"))',
    'select("Cube", "Light")\nprint(issel("Cube"), issel("Camera"), active())\nselect()\nprint(issel("Cube"), active())',
    'select("Cube", "Nope")', 'select("Cube", 2)\nprint(issel("Cube"))', 'print(issel("Nope"), issel(""), exists(""))', 'issel(1)',
    'delete("Cube")\nprint(count(), exists("Cube"), active())', 'delete("Cube", "Light")\nprint(count(), name(0))', 'delete("Nope")', 'delete()',
    'print(name(0), name(2), name(2.9))', 'name(3)', 'name(-1)', 'name(sqrt(-1))', 'name("0")',
    'print(objtype("Cube"), objtype("Light"), objtype("Camera"))', 'objtype("Nope")',
    'print(parent("Cube"), parent("Nope"))\nadd("sphere", "Hub", 0, 3, 0)\nselect("Cube", "Hub")\nop("object.parent_set")\nprint(parent("Cube"), parent("Hub"))',
    'op("nope.op")', 'op("script.run")', 'op("transform.move")', 'op("edit.undo")', 'op("edit.redo")', 'op(5)',
    'op("create.cube")\nop("create.cube", 3)\nop("create.sphere", nil)\nprint(count(), active())',
    'print(verts("Cube"), edges("Cube"), faces("Cube"), everts("Cube"), efaces("Cube"), volume("Cube"), selected("Cube"))',
    'verts("Light")', 'faces("Nope")', 'volume(1)',
    'print(vpos("Cube", 0, "x"), vpos("Cube", 0, 1), vpos("Cube", 7, "z"), vpos("Cube", 3, 2.9))', 'vpos("Cube", 8, 0)', 'vpos("Cube", -1, 0)',
    'vpos("Cube", 0, 3)', 'vpos("Cube", 0, "w")', 'vpos("Cube", 0, "")', 'vpos("Cube", 0, -1)',
    'vselect("Cube", 0, 2, 5)\nprint(selected("Cube"), vsel("Cube", 2), vsel("Cube", 1))\nvsel("Cube", 1, "y")\nvsel("Cube", 2, 0)\nprint(selected("Cube"))\nvselect("Cube")\nprint(selected("Cube"))',
    'vselect("Cube", 0, 9)', 'vsel("Cube", 8)', 'vsel("Cube", 0, nil)\nprint(vsel("Cube", 0))',
    'vmove("Cube", 0, -1, -2, -1)\nvmove("Cube", 1, 5, 5, 5)\nprint(vpos("Cube", 0, "y"), vpos("Cube", 1, 0), volume("Cube"))',
    'add("cube", "C2")\nvmove("C2", 0, 3, 3, 3)\nprint(vpos("Cube", 0, 0), vpos("C2", 0, 0))', 'vmove("Cube", 8, 0, 0, 0)', 'vmove("Cube", 0, 0, 0, "z")',
    'edit("Cube")\nvselect("Cube")\nfor i in 0..verts("Cube") {\n if vpos("Cube", i, "y") > 0 { vsel("Cube", i, 1) }\n}\nop("mesh.extrude", 1)\nedit()\ntop = -9\nfor i in 0..verts("Cube") { top = max(top, vpos("Cube", i, "y")) }\nprint(verts("Cube"), faces("Cube"), top)',
    'edit("Light")', 'edit("Nope")', 'edit()\nedit()\nprint(1)',
    'print(frame(), frame(5), frame(), frame(-2.5))', 'print(frames(), frametime(0), frametime(3, 1), frametime(-1))',
    'print(viewinfo(0), viewinfo(1), viewinfo(2), viewinfo(3), viewinfo(6), viewinfo(-1))\nview(30, 20, 10, 1, 2, 3)\nprint(viewinfo(0), viewinfo(1), viewinfo(2), viewinfo(5))',
    'print(world(0), world(1), world(3), world(4), world(9), world(10), world(11), world(12), world(99))',
    'print(clock() > 0)', 'print(count(1))', 'print(get("Cube"))',
]


def s_lang():
    print('-- the language, the REPL echo, numbers, texts, limits, the scene builtins: each case ends cleanly --')
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor(4) as ex:
        res = list(ex.map(lambda c: run(BIN, ['--eval', c]), LANG))
    n = 0
    for code, r in zip(LANG, res):
        ok = clean(r)
        check(ok, repr(code[:70]) + ('' if ok else f'\n         {r!r:.400}'))
        n += ok
    print(f'  {n} of {len(LANG)} cases ended cleanly')
    # a few the language must get right whatever the numbers print as
    for code, want_, what in (('print(1 + 2 * 3, (1 + 2) * 3)', '7 9', 'precedence'),
                              ('s = 0\nfor i in 0..10 { if i == 3 { continue }\n if i == 6 { break }\n s += i }\nprint(s)', '12', 'for, continue, break'),
                              ('fn fib(n) { if n < 2 { return n }\n return fib(n - 1) + fib(n - 2) }\nprint(fib(20))', '6765', 'recursion'),
                              ('seed(7); a = rand(); seed(7); print(a == rand(), a >= 0 and a < 1)', '1 1', 'seed() repeats rand()')):
        r = run(BIN, ['--eval', code])
        check(r[0] == 0 and r[1].strip() == want_, f'{what}: {want_!r} ({r[:2]!r:.120})')


# ---- --run, --eval, the command line -------------------------------------------------------

def s_run():
    print('-- --run and --eval: files, exit codes, what goes where --')
    d = f'{T}/run'
    os.makedirs(d)
    files = {
        'ok.bees': 'print("hello")\nadd("cube", "R")\nprint(count())\ncount()\n',
        'err.bees': 'print(1)\nprint(2\n',
        'rt.bees': 'x = 1\nprint(x)\ny = x + nil\nprint(3)\n',
        'empty.bees': '',
        'big.bees': '#' * 65534,
        'toobig.bees': '#' * 65535,
        'nul.bees': 'print("ok")\0print(2)',
        'crlf.bees': 'a = 2\r\nprint(a * 3)\r\n',
        'utf8.bees': 'print("Grüße ✓")\n# «comment»\n',
    }
    for k, v in files.items():
        open(f'{d}/{k}', 'w', encoding='utf-8').write(v)
    os.makedirs(f'{d}/dir.bees')
    cases = [[f'--run', f'{d}/{k}'] for k in files] + [['--run', f'{d}/missing.bees'], ['--run', f'{d}/dir.bees'], ['--run'], ['--eval'],
                                                    ['--eval', ''], ['--eval', 'print(1)', 'extra'], ['--eval', 'x' * 70000], ['--eval', 'print("' + 'a' * 65530 + '")']]
    res = {}
    for a in cases:
        y = run(BIN, a)
        res[' '.join(a)] = y
        ok = y[0] in (0, 1, 2) and 'panic' not in y[1] + y[2] and (y[0] == 0 or (y[1] + y[2]).strip() != '')
        check(ok, f'{" ".join(a)[:60]!r}: exit {y[0]}, a result or one clear message' + ('' if ok else f'\n         {y!r:.300}'))
    r = res[f'--run {d}/ok.bees']
    check(r[0] == 0 and r[1].startswith('hello\n'), f'ok.bees runs: {r[:2]!r:.80}')
    r = res[f'--run {d}/rt.bees']
    check(r[0] == 1 and r[1].startswith('1\n') and r[1].splitlines()[-1].startswith('error: line 3') and '3\n' not in r[1][2:], f'rt.bees stops at its error on line 3: {r[:2]!r:.80}')
    r = res[f'--run {d}/err.bees']
    check(r[0] == 1 and r[1].startswith('error: '), f'err.bees: a compile error, nothing run: {r[:2]!r:.80}')
    for k in ('missing.bees', 'dir.bees', 'empty.bees', 'toobig.bees'):
        r = res[f'--run {d}/{k}']
        check(r[0] not in (0, None), f'{k}: refused (exit {r[0]}: {(r[1] + r[2]).strip()[:60]!r})')
    r = res[f'--run {d}/big.bees']
    check(r[0] == 0, f'big.bees (65534 bytes, comments): runs (exit {r[0]})')
    r2 = run(BIN, ['--eval', 'x = 1 + nil'])
    check(r2[0] == 1, f'--eval: exit 1 after a script error ({r2[:2]!r:.80})')


# ---- the files they save ---------------------------------------------------------------------

def s_files():
    print('-- what a script leaves: the .bee files it saves read back, open -> save keeps them --')
    saved('add("cube", "Box", 1, 2, 3)\nrotate("Box", 0.1, 45deg, 0)\nscale("Cube", 2)\nset("Light", "power", 2)\nset("Cube", "color", 0xff0000)\n'
          'set("Camera", "hidden", 1)\nvmove("Cube", 0, -1, -2, -1)\nop("file.save", "@OUT")', 'tf', 'transforms, properties, a vertex')
    saved('for i in 0..10 { add("cube", "Step" + i, i * 2m, 0, 0) }\nfn ring(n, r) {\n for i in 0..n {\n  a = i * 360deg / n\n'
          '  add("sphere", "R" + i, cos(a) * r, 1, sin(a) * r)\n }\n}\nring(12, 6m)\nop("file.save", "@OUT")', 'ring', 'rows and a ring of objects (loops, functions, units)')
    saved('add("light", "Key", 1, 2, 3)\nset("Key", "lr", 0.5)\nset("Key", "lens", 2)\nadd("camera", "Shot", 0, 2, 10)\nset("Shot", "lens", 35)\n'
          'set("Cube", "power", 9)\nop("file.save", "@OUT")', 'lc', 'lights and cameras (LCAM records)')
    saved('select("Cube", "Light")\ndelete("Cube")\nrename("Camera", "Eye")\nadd("cube")\nadd("cube", "Cube")\nselect("Eye")\nop("file.save", "@OUT")',
          'sel', 'selection, delete, rename, unique names')
    saved('edit("Cube")\nvselect("Cube")\nfor i in 0..verts("Cube") { if vpos("Cube", i, "y") > 0 { vsel("Cube", i, 1) } }\nop("mesh.extrude", 1)\nedit()\n'
          'op("file.save", "@OUT")', 'ext', 'edit mode: a selection, an extrude')
    saved('add("cube", "A")\nvmove("A", 3, 1, 1, 1.5)\nvmove("A", 3, 1, 1, 2)\nvmove("Cube", 0, 0, 0, 0)\nadd("plane", "P")\nscale("P", 3)\nop("file.save", "@OUT")',
          'vm', 'vertices moved twice, shared meshes left alone')
    saved('frame(12)\nview(10, 20, 30, 1, 2, 3)\nop("file.save", "@OUT")', 'fv', 'the frame and the view')
    # a failing run keeps what it did before the error
    b = run(BIN, ['--eval', f'add("cube", "Before", 1, 1, 1)\nop("file.save", "{T}/f.bee")\nx = 1 + nil\nop("file.save", "{T}/f2.bee")'])
    check(b[0] == 1 and os.path.exists(f'{T}/f.bee') and not os.path.exists(f'{T}/f2.bee'), f'a run stops at its error: {b[1].strip()!r}')
    if os.path.exists(f'{T}/f.bee'):
        check('Before' in [x['name'] for x in beefile.objects(f'{T}/f.bee')], 'a failing run, saved before its error: Before is in it')
    # objects the scripts made, by name, in their files
    for tag, names in (('tf', ['Box']), ('ring', ['Step9', 'R11']), ('lc', ['Key', 'Shot']), ('sel', ['Eye']), ('vm', ['A', 'P'])):
        if os.path.exists(f'{T}/{tag}.bee'):
            got = [x['name'] for x in beefile.objects(f'{T}/{tag}.bee')]
            check(all(n in got for n in names), f'{tag}.bee has {names}')
    if os.path.exists(f'{T}/sel.bee'):
        got = [x['name'] for x in beefile.objects(f'{T}/sel.bee')]
        check(len(got) == len(set(got)), f'sel.bee: every name once ({got})')
    # VIEW: finite numbers
    vb = beefile.chunk(f'{T}/fv.bee', b'VIEW') if os.path.exists(f'{T}/fv.bee') else None
    if vb:
        import math
        fb = struct.unpack_from('<6f', vb, 12)
        check(all(math.isfinite(x) for x in fb), f'view(10, 20, 30, 1, 2, 3) in VIEW: finite numbers {fb}')


# ---- the builtins not available yet ----------------------------------------------------------

def called(code):
    return set(re.findall(r'\b([a-z_][a-z0-9_]*)\s*\(', code))


def ported_set():
    """The builtins BeeModel has (from the sources: bs_*.zig's lists)."""
    names = set()
    for f in os.listdir(os.path.join(ROOT, 'src')):
        if f.startswith('bs_') and f.endswith('.zig') and f not in ('bs_table.zig', 'bs_areas.zig'):
            names |= set(re.findall(r'\.name = "([a-z_0-9]+)"', open(os.path.join(ROOT, 'src', f)).read()))
    return names


def all_builtins():
    return re.findall(r'\.name = "([a-z_0-9]+)", \.min = (\d+), \.max = (\d+), \.area = \.(\w+)', open(os.path.join(ROOT, 'src', 'bs_table.zig')).read())


def s_unported():
    print('-- every builtin not available yet: one clear error --')
    have = ported_set()
    rows = all_builtins()
    bad = []
    missing = [r for r in rows if r[0] not in have]
    for nm, mn, mx, area in missing:
        args = ', '.join(['1'] * int(mn))
        b = run(BIN, ['--eval', f'x = 1\n{nm}({args})'])
        if not (b[0] == 1 and b[1] == f'error: line 2: not available yet: {nm}\n'):
            bad.append((nm, b[:2]))
    check(not bad, f'{len(missing)} builtins not available yet, each one error "error: line 2: not available yet: <name>"' + (f': {bad[:4]}' if bad else ''))
    # their argument counts are still checked (when compiling): one too many is an error
    bad = []
    for nm, mn, mx, area in missing[:60]:
        code = f'{nm}({", ".join(["1"] * (int(mx) + 1))})'
        b = run(BIN, ['--eval', code])
        if not (b[0] == 1 and clean(b) and 'not available yet' not in b[1]):
            bad.append((nm, b[:2]))
    check(not bad, 'their argument counts are checked: one too many is an error before the run' + (f': {bad[:3]}' if bad else ''))
    by = {}
    for nm, mn, mx, area in missing:
        by.setdefault(area, []).append(nm)
    for a in sorted(by):
        print(f'     {a}: {" ".join(by[a])}')
    check(len(rows) == 211 and len(have) + len(missing) == 211, f'the table: 211 builtins, {len(have)} available')


# ---- random programs ---------------------------------------------------------------------------

class Gen:
    """Valid programs (a few may stop with a runtime error, one clean error
    line), deterministic, small loops."""

    def __init__(self, rng):
        self.r = rng
        self.vars = ['a', 'b', 'c']
        self.fns = []
        self.depth = 0

    def num(self):
        r = self.r
        k = r.randrange(10)
        if k == 0:
            return f'{r.randrange(0, 4096):#x}'
        if k == 1:
            return f'{r.uniform(-100, 100):.{r.randrange(0, 8)}f}{r.choice(["m", "cm", "mm", "km", "deg", "rad", ""])}'
        if k == 2:
            return f'{r.randrange(1, 99)}e{r.randrange(-12, 25)}'
        if k == 3:
            return r.choice(['pi', 'true', 'false', '0', '1e15', '0.0001', '1e-5'])
        return str(r.randrange(-20, 100)) if r.random() < 0.5 else f'{r.uniform(-50, 50):.3f}'

    def text(self):
        return '"' + ''.join(self.r.choice('abcxyz _-0123') for _ in range(self.r.randrange(0, 6))) + '"'

    def expr(self, d=0):
        """A number mostly, a text now and then (both kinds stay apart, so
        that most programs run to their end; a few still stop)."""
        r = self.r
        if r.random() < 0.15:
            return self.texpr(d)
        return self.nexpr(d)

    def texpr(self, d=0):
        r = self.r
        k = r.randrange(6)
        if d > 3 or k == 0:
            return self.text()
        if k == 1:
            return f'({self.texpr(d + 1)} + {self.nexpr(d + 1)})'
        if k == 2:
            return f'str({self.nexpr(d + 1)})'
        if k == 3:
            return r.choice(['name(0)', 'name(2)', 'active()', 'c', '"Cube"'])
        return f'({self.texpr(d + 1)} + {self.texpr(d + 1)})'

    def nvar(self):
        return self.r.choice([v for v in self.vars if v not in ('c',)] or ['a'])

    def nexpr(self, d=0):
        r = self.r
        if d > 3 or r.random() < 0.3:
            return self.nvar() if r.random() < 0.4 else self.num()
        k = r.randrange(14)
        if k < 5:
            op = r.choice(['+', '-', '*', '/', '%', '+', '*', '-'])
            rhs = self.nexpr(d + 1)
            if op in '/%':
                rhs = f'({rhs} + 0.5)'
            return f'({self.nexpr(d + 1)} {op} {rhs})'
        if k == 5:
            return f'({self.nexpr(d + 1)} {r.choice(["==", "!=", "<", "<=", ">", ">="])} {self.nexpr(d + 1)})'
        if k == 6:
            return f'({self.nexpr(d + 1)} {r.choice(["and", "or"])} {self.nexpr(d + 1)})'
        if k == 7:
            return f'(not {self.nexpr(d + 1)})' if r.random() < 0.5 else f'(-{self.nexpr(d + 1)})'
        if k == 8:
            f = r.choice(['sin', 'cos', 'tan', 'sqrt', 'abs', 'floor', 'round', 'deg', 'rad', 'sqrt', 'abs'])
            return f'{f}({self.nexpr(d + 1)})'
        if k == 9:
            return f'{r.choice(["min", "max", "pow", "atan2"])}({self.nexpr(d + 1)}, {self.nexpr(d + 1)})'
        if k == 10 and self.fns:
            f, n = r.choice(self.fns)
            return f'{f}({", ".join(self.nexpr(d + 1) for _ in range(n))})'
        if k == 11:
            return r.choice(['count()', 'rand()', 'exists("Cube")', 'verts("Cube")', 'get("Cube", "x")', 'get("Light", "power")',
                             'len(name(1))', 'num("2cm")', 'issel("Cube")', 'frame()', 'volume("Cube")', 'get("Cube", "rz")'])
        if k == 12:
            return f'len({self.texpr(d + 1)})'
        return self.num()

    def stmt(self, d=0):
        r = self.r
        k = r.randrange(12)
        v = r.choice([x for x in self.vars if x != 'c'] + ['d', 'e'])
        if v not in self.vars:      # (a new variable: made by =, known after it)
            e = self.nexpr()
            self.vars.append(v)
            return f'{v} = {e}'
        if k < 3 or d > 2:
            return f'{v} {r.choice(["=", "=", "+=", "-=", "*="])} {self.nexpr()}'
        if k == 3:
            return f'print({", ".join(self.expr() for _ in range(r.randrange(0, 4)))})'
        if k == 4:
            return f'if {self.expr()} {{\n{self.block(d)}\n}}' + (f' else if {self.nexpr()} {{\n{self.block(d)}\n}}' if r.random() < 0.3 else '') + (f' else {{\n{self.block(d)}\n}}' if r.random() < 0.5 else '')
        if k == 5:
            i = f'i{d}'
            self.vars.append(i)
            return f'for {i} in {r.randrange(-2, 3)}..{r.randrange(0, 6)} {{\n{self.block(d)}\n}}'
        if k == 6:
            w = f'w{d}'
            return f'{w} = 0\nwhile {w} < {r.randrange(0, 5)} {{\n{w} += 1\n{self.block(d)}\n{"break" if r.random() < 0.2 else ""}\n}}'
        if k == 7:
            return f'{r.choice(["move", "rotate", "scale"])}("Cube", {self.nexpr()}, {self.nexpr()}, {self.nexpr()})'
        if k == 8:
            return f'set("{r.choice(["Cube", "Light", "Camera"])}", "{r.choice(["x", "y", "rz", "sx", "color", "hidden", "select", "power", "lens"])}", {self.nexpr()})'
        if k == 9:
            return f'add("{r.choice(["cube", "sphere", "light", "plane", "camera", "cone"])}", {self.texpr()}, {self.nexpr()}, {self.nexpr()}, {self.nexpr()})'
        if k == 10:
            return self.expr()
        return f'print({self.expr()})'

    def block(self, d):
        return '\n'.join(self.stmt(d + 1) for _ in range(self.r.randrange(1, 4)))

    def program(self):
        out = []
        for k in range(self.r.randrange(0, 3)):
            n = self.r.randrange(0, 3)
            ps = [f'p{j}' for j in range(n)]
            keep = self.vars
            self.vars = ps + ['a', 'b']
            body = self.block(1)
            self.vars = keep
            out.append(f'fn f{k}({", ".join(ps)}) {{\n{body}\nreturn {self.r.choice(ps + ["a", "1"])}\n}}')
            self.fns.append((f'f{k}', n))
        out.append('a = 1\nb = 2\nc = "c"')
        out += [self.stmt() for _ in range(self.r.randrange(3, 12))]
        out.append('print(a, b, c, count())')
        return '\n'.join(out)


def s_fuzz():
    print(f'-- {RUNS} random valid programs (seed {SEED}): each ends cleanly, the same output run twice --')
    rng = random.Random(SEED)
    bad, slow = [], []
    errs = 0
    for k in range(RUNS):
        code = Gen(rng).program()
        a = run(BIN, ['--eval', code], 300)  # (the debug build: a few thousand add()s take a minute)
        if a[0] is None and os.path.exists(REL):
            a = run(REL, ['--eval', code], 900)  # (too slow for the debug build: the release build)
            slow.append(k)
        errs += a[0] == 1
        why = '' if clean(a) else 'not clean'
        # (rand() is seeded by nothing but seed(): a program prints the same twice, unless it reads the clock)
        if not why and k % 5 == 0 and k not in slow:
            b = run(BIN, ['--eval', code], 300)
            if b[:2] != a[:2]:
                why = f'another output the second time {b[:2]!r:.200}'
        if why:
            bad.append((code, a[:2], why))
    for code, a, why in bad[:3]:
        print(f'     {code!r:.6000}\n       {a!r:.300}: {why}')
    if slow:
        print(f'     (programs {slow}: too slow for the debug build in 300 s, run on the release build)')
    check(not bad, f'{RUNS - len(bad)} of {RUNS} programs: a result or one error line, every fifth the same run twice ({errs} stopped with an error)')


TOKENS = ['x', 'y', 'f', 'fn', 'if', 'else', 'while', 'for', 'in', 'return', 'break', 'continue', 'and', 'or', 'not', 'nil', 'true', 'pi',
          '(', ')', '{', '}', ',', '=', '==', '!=', '<', '<=', '>', '>=', '+', '-', '*', '/', '%', '..', '+=', ';', '\n', '1', '2.5', '0xff',
          '3cm', '"t"', "'u'", '#c\n', 'print', 'add', 'move', 'get', 'set', 'select', 'delete', 'op', 'vmove', 'edit', 'frame', 'view',
          'sin', 'pow', 'str', 'num', 'len', '"Cube"', '"cube"', 'name', 'count', '[', '@', '\\', '"', 'é', '1e999', '9' * 30]


def s_garbage():
    print('-- garbage: no crash, no hang, only its words --')
    rng = random.Random(SEED ^ 0x5eed)
    bad = []
    t0 = time.time()
    n = max(RUNS, 40)
    for k in range(n):
        m = rng.randrange(6)
        if m == 0:
            code = ''.join(chr(rng.randrange(1, 256)) for _ in range(rng.randrange(1, 300)))
        elif m == 1:
            code = ' '.join(rng.choice(TOKENS) for _ in range(rng.randrange(1, 400)))
        elif m == 2:
            d = rng.randrange(150, 260)
            code = 'x = ' + rng.choice(['(', '-', 'not ', 'f(']) * d + '1' + rng.choice([')', '']) * d
        elif m == 3:
            code = 's = "' + 'z' * rng.randrange(1, 60000) + '"\nwhile len(s) < 4000000 { s = s + s }'
        elif m == 4:
            code = 'fn r(n) { ' + rng.choice(['return r(n + 1)', 'x = r(n)', 'return 1 + r(n - 1)']) + ' }\nr(1)'
        else:
            code = Gen(rng).program()
            code = code[:rng.randrange(len(code) + 1)] + rng.choice(TOKENS) + code[rng.randrange(len(code) + 1):]
        r = run(BIN, ['--eval', code], 120)
        lines = r[1].splitlines()
        ok = r[0] in (0, 1) and (r[0] == 0 or (lines and lines[-1].startswith('error: '))) and 'panic' not in r[2] and 'thread' not in r[2]
        if not ok:
            bad.append((code[:200], r[0], r[2][-300:]))
    for c, rc, e in bad[:3]:
        print(f'     {c!r}\n       exit {rc}: {e}')
    check(not bad, f'{n} garbage scripts: exit 0 or 1, an error line, no panic ({time.time() - t0:.0f} s)')
    # the endless loop stops after 500 million steps
    t0 = time.time()
    r = run(BIN, ['--eval', 'while 1 { }'], 600)
    check(r[1] == 'error: line 1: stopped after 500 million steps (endless loop?)\n', f'an endless loop stops after 500 million steps ({time.time() - t0:.1f} s on this build)')


# ---- limits counted exactly ------------------------------------------------------------------

def s_limits():
    print('-- the budgets: a script just inside runs to its end, one just past stops with an error --')

    def edge(code_in, code_out, what, timeout=120):
        a = run(BIN, ['--eval', code_in], timeout)
        b = run(BIN, ['--eval', code_out], timeout)
        ok = a[0] == 0 and clean(a) and b[0] == 1 and clean(b)
        check(ok, f'{what}: inside exit {a[0]}, past it exit {b[0]} {b[1].strip()[-70:]!r}' + ('' if ok else f'\n         {a!r:.200}\n         {b!r:.200}'))
    # i = 0 / while i < N { i += 1 }: 10 N + 11 operations; 499 999 999 may run
    edge('i = 0\nwhile i < 49999998 { i += 1 }\nprint(i)', 'i = 0\nwhile i < 49999999 { i += 1 }\nprint(i)', '500 million steps', 900)
    # the text heap: two halves of 1 MiB, texts kept by the variables copied at the start of a run
    edge('s = "' + 'h' * 1000 + '"\nfor i in 0..1046 { t = s + "" }\nprint(1)', 's = "' + 'h' * 1000 + '"\nfor i in 0..1048 { t = s + "" }\nprint(1)', 'the text heap')
    # recursion: 2047 calls deep at most
    edge('fn f(n) { if n == 0 { return 0 }\n return f(n - 1) }\nprint(f(2046))', 'fn f(n) { if n == 0 { return 0 }\n return f(n - 1) }\nprint(f(2047))', '2047 calls deep')
    # the value stack: 16384; a call that recurses for ever stops cleanly whatever comes first
    cleanly('fn f(a, b, c, d, e, g, h) {\n' + ''.join(f'l{i} = 1\n' for i in range(57)) + 'return f(a, b, c, d, e, g, h) }\nf(1, 2, 3, 4, 5, 6, 7)', 'the value stack: 64 locals a call, endless: stops cleanly')
    for k in (7, 8):
        ok, r = cleanly('fn f(n) {\n' + ''.join(f'l{i} = 1\n' for i in range(k)) + 'return f(n) }\nf(1)', f'{k} locals a call, endless: stops cleanly')
        check(r[0] == 1, f'{k} locals a call: an error ({r[1].strip()!r:.70})')


# ---- the console: its lines, what they say -----------------------------------------------

def s_console():
    print('-- the console (headless): BeeScript, operators, its own words, the REPL --')
    log = f'{T}/con.txt'
    lines = ['x = 3', 'print(x * 2, "objects:", count())', 'x', 'nosuch.op arg', 'fn tw(n) { return n * 2 }', 'tw(4)', 'y = (1 +', 'print(y)',
             'add("cube", "F" + tw(4), 1, 2, 3)', 'list', 'add sphere', 'help', 'print(exists("F8"), exists("Sphere"))', 'new = 55', 'new', 'count()', 'print(new + 1)',
             's = "keep" + 1', 't = ""; for i in 0..2000 { t = t + "zz" }', 'print(s)', 'script.reset', 'print(x)', 'edit.undo arg']
    a = []
    for ln in lines:
        a += ['--op', ln]
    r = run(BIN, ['--shot', f'{T}/con.ppm', '--dump-log', log, *a])
    got = open(log).read().split('\n') if os.path.exists(log) else []
    want_in = ['  6 objects: 3', '  = 3', '  unknown command: nosuch.op',
               '  Tab completes operator ids - console.list_ops lists them all; other lines run as BeeScript',
               '  = 8', '  error: line 1: expected a value', '  error: line 1: not defined: y', '  1 1', '  = 3',
               '  keep1', '  script variables and functions cleared', '  error: line 1: not defined: x', '  56']
    miss = [w for w in want_in if w not in got]
    check(r[0] == 0 and not miss, f'the console\'s lines, its words ({len(got)} lines){": missing " + repr(miss) if miss else ""}')
    check('"F8"' not in got and any('F8' in g for g in got if g.startswith('  *') or g.startswith('   ')), 'its own words still work: list, add sphere, help')
    # Tab: the operator ids that start with what was typed, in order
    r = run(BIN, ['--shot', f'{T}/tab.ppm', '--dump-log', f'{T}/tab.txt', '--key', 'enter', '--type', 'scr', '--key', 'tab', '--key', 'tab', '--key', 'tab',
                  '--key', 'enter', '--type', 'zzq', '--key', 'tab', '--key', 'enter'])
    tl = open(f'{T}/tab.txt').read().split('\n') if os.path.exists(f'{T}/tab.txt') else []
    check('> script.reset' in tl and '> zzq' in tl, f'Tab: scr -> script.record, script.run, script.reset; zzq matches none and stays ({tl[-4:]})')
    k = [i for i, g in enumerate(got) if g == '> new']
    check(k and got[k[0] + 1:k[0] + 2] != ['  = 55'], 'new = 55 is BeeScript (print(new + 1) says 56), new alone the console\'s word (a new scene)')


# ---- memory: many runs in one process ------------------------------------------------------------

def s_leak():
    print('-- memory: console runs that make and drop objects, again and again --')
    line = ('for i in 0..60 { add("cube", "L" + i, i, 0, 0); vmove("L" + i, 0, 1, 1, 1); edit("L" + i); vsel("L" + i, 1, 1); edit()\n'
            ' s = "t" + i + str(rand()) }\nfor i in 0..60 { delete("L" + i) }')

    def rss(k):
        h = tempfile.mkdtemp(dir=T)
        a = ['--shot', f'{h}/x.ppm']
        for _ in range(k):
            a += ['--op', line]
        p = subprocess.Popen([BIN, *a], env=dict(os.environ, HOME=h, XDG_RUNTIME_DIR=h), stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        _, st, ru = os.wait4(p.pid, 0)
        return st, ru.ru_maxrss
    (s4, r4), (s40, r40) = rss(4), rss(40)
    check(s4 == 0 and s40 == 0 and r40 - r4 < 8192, f'4 runs {r4} KiB, 40 runs {r40} KiB at most: no growth past 8 MiB')


# ---- the window: the console, undo / redo, macros ----------------------------------------------

K_ENTER, K_ESC = 28, 1
US = {**{c: k for k, c in enumerate('1234567890', 2)}, **{c: k for k, c in enumerate('qwertyuiop', 16)},
      **{c: k for k, c in enumerate('asdfghjkl', 30)}, **{c: k for k, c in enumerate('zxcvbnm', 44)},
      '.': 52, '-': 12, ' ': 57, '/': 53, '=': 13, ',': 51, ';': 39, "'": 40, '[': 26, ']': 27, '\\': 43}
US_SHIFT = {'_': 12, '(': 10, ')': 11, '"': 40, '+': 13, '{': 26, '}': 27, '*': 9, '<': 51, '>': 52, '#': 4, '%': 6, '!': 2, ':': 39}


class PortWin:
    def __init__(self):
        import wl_fake
        self.home = tempfile.mkdtemp(prefix='p', dir=T)
        self.f = wl_fake.Fake(BIN, size=(1280, 800), env={'BEE_CPU': str(CPU), 'HOME': self.home})
        HELD.append(self.f.proc)
        os.sched_setaffinity(self.f.proc.pid, {CPU})
        self.f.until(lambda: self.f.frames > 0 and self.f.keyboard is not None and self.f.pointer is not None)
        self.f.enter(600, 300)
        self.f.motion(600, 300)
        self.f.pump(0.3)

    def key(self, code, mods=0):
        self.f.key(code, mods)
        self.f.pump(0.1)

    def type(self, text):
        for ch in text:
            if ch in US_SHIFT or ch.isupper():
                self.f.key(US_SHIFT[ch] if ch in US_SHIFT else US[ch.lower()], 1)
            else:
                self.f.key(US[ch])

    def line(self, text):
        self.f.key(K_ENTER)
        self.type(text)
        self.f.key(K_ENTER)
        self.f.pump(0.4)

    def image(self):
        from PIL import Image
        self.f.pump(0.4)
        s = self.f.surfaces[self.f.main().surface]
        bf = self.f.buffers[s['last']]
        return Image.frombuffer('RGBX', (bf['w'], bf['h']), s['pixels'], 'raw', 'BGRX', bf['stride'], 1).convert('RGB')

    def close(self):
        self.f.proc.kill()
        self.f.proc.wait()


def s_window():
    print('-- the console in the window: BeeScript lines, one undo step a run, a failing run, macros --')
    try:
        p = PortWin()
    except Exception as e:
        check(False, f'the window did not start: {e}')
        return
    try:
        steps = [
            ('line', 'x = 3'),
            ('line', 'add("cube", "Tower" + x, 4, 0, 0)'),
            ('save', 'w0'),
            ('line', 'for i in 0..3 { add("sphere", "B" + i, -4, i * 2, 0) }'),
            ('save', 'w1'),
            ('key', K_ESC), ('undo',), ('save', 'w2'),        # the loop's run: one step
            ('redo',), ('save', 'w3'),
            ('line', 'move("Tower3", 1, 1, 1); y = 1 + nil; move("Tower3", 9, 9, 9)'),   # stops at its error
            ('save', 'w4'),
            ('key', K_ESC), ('undo',), ('save', 'w5'),        # the failing run is one step too
            ('line', 'print(x * 2, "objects:", count())'),
            ('line', 'fn tw(n) { return n * 2 }'),
            ('line', 's = "keep" + tw(1)'),
            ('line', 't = ""; for i in 0..2000 { t = t + "zz" }'),
            ('line', 'add("cube", s + "F" + tw(4), 1, 2, 3)'),
            ('save', 'w6'),
            ('line', 'add("cube", "S1"); op("file.save_as", "@T/inrun.bee"); add("cube", "S2")'),
            ('save', 'w6b'),
            ('key', K_ESC), ('undo',), ('save', 'w7'),        # a save inside a run: still one step
            ('line', 'nosuch.op'),
            ('line', 'create.cone'),
            ('shot', 'console'),
        ]
        for s in steps:
            if s[0] == 'line':
                p.line(s[1].replace('@T/', T + '/'))
            elif s[0] == 'key':
                p.key(s[1])
            elif s[0] == 'undo':
                p.key(44, 4)
                p.f.pump(0.3)
            elif s[0] == 'redo':
                p.key(44, 5)
                p.f.pump(0.3)
            elif s[0] == 'save':
                p.line(f'file.save_as {T}/{s[1]}.bee')
                p.key(K_ESC)
            elif s[0] == 'shot':
                p.image().save(f'{T}/{s[1]}.png')
        check(p.f.proc.poll() is None, 'the window still runs after the console lines')
        # undo / redo put the scene back as it was
        for a, b, what in (('w0', 'w2', 'Ctrl+Z: the loop\'s run undone, one step'), ('w1', 'w3', 'Ctrl+Shift+Z: redone'),
                           ('w3', 'w5', 'Ctrl+Z: the failing run undone as one step'), ('w6', 'w7', 'a run that saves on its way: one step all the same')):
            same_scene(f'{T}/{a}.bee', f'{T}/{b}.bee', f'{what} ({b} = {a})', uid_next=False)
        names = lambda t: [x['name'] for x in beefile.objects(f'{T}/{t}.bee')] if os.path.exists(f'{T}/{t}.bee') else []
        n1, n2 = names('w1'), names('w2')
        check('B2' in n1 and 'B0' not in n2 and 'Tower3' in n2, f'B0..B2 then gone, Tower3 kept ({n1} / {n2})')
        t4 = [x for x in beefile.objects(f'{T}/w4.bee') if x['name'] == 'Tower3'] if n1 else []
        t5 = [x for x in beefile.objects(f'{T}/w5.bee') if x['name'] == 'Tower3'] if n1 else []
        check(t4 and t4[0]['loc'] == (1.0, 1.0, 1.0) and t5 and t5[0]['loc'] == (4.0, 0.0, 0.0), f'the failing run moved Tower3 once; undone it is back ({t4[:1]} / {t5[:1]})')
        check('keep2F8' in names('w6'), 'keep2F8 made from a function and a text of earlier runs')
        check('S2' in names('w6b') and os.path.exists(f'{T}/inrun.bee') and 'S1' in [x['name'] for x in beefile.objects(f'{T}/inrun.bee')],
              'a save inside a run: the file has S1, the scene S2 after it')
        print(f'     (screenshot: {T}/console.png)')
        # macros: record an operator, a typed move; play it back in a new scene
        p.line('script.record')
        im = p.image()
        im.save(f'{T}/rec.png')
        px = im.load()
        red = sum(1 for y in range(im.size[1] - 22, im.size[1]) for x in range(0, 200) if px[x, y][0] > 180 and px[x, y][1] < 110 and px[x, y][2] < 110)
        p.line('create.cone')
        p.key(K_ESC)
        p.f.motion(640, 400)
        p.key(34)
        p.key(45)
        p.key(3)
        p.key(K_ENTER)
        p.line('script.record')
        check(red > 20, f'recording: the status bar says so in red, a dot and "Recording macro" ({red} red pixels)')
        mp = open(f'{p.home}/BeeModel/scripts/macro.bees').read() if os.path.exists(f'{p.home}/BeeModel/scripts/macro.bees') else ''
        check('op("create.cone")' in mp and 'move(' in mp, f'the macro file: the operator and the typed move (G X 2) {mp!r}')
        p.line('file.new')
        p.key(K_ESC)
        p.line(f'file.save_as {T}/m0.bee')
        p.key(K_ESC)
        p.line('script.run')
        p.key(K_ESC)
        p.line(f'file.save_as {T}/m1.bee')
        p.key(K_ESC)
        p.key(44, 4)
        p.f.pump(0.3)
        p.line(f'file.save_as {T}/m2.bee')
        p.key(K_ESC)
        n0, n1 = names('m0'), names('m1')
        check(len(n1) == len(n0) + 1 and any(n.startswith('Cone') for n in n1), f'script.run plays the macro back in a new scene: a cone ({n0} -> {n1})')
        same_scene(f'{T}/m0.bee', f'{T}/m2.bee', 'Ctrl+Z after it: the replay is one step (m2 = m0)', uid_next=False)
        for t in ('w1', 'w6', 'm1'):
            if os.path.exists(f'{T}/{t}.bee'):
                roundtrip(f'{T}/{t}.bee', f'the window\'s {t}.bee', whole=False)
        check(p.f.proc.poll() is None, 'the window still runs at the end')
    finally:
        p.close()


def main():
    global RUNS, SEED
    a = sys.argv
    RUNS = int(a[2]) if len(a) > 2 else 150
    SEED = int(a[3]) if len(a) > 3 else SEED
    print(f'BeeScript: {BIN}, seed {SEED}')
    try:
        for name in ('lang', 'run', 'files', 'unported', 'limits', 'console', 'leak', 'fuzz', 'garbage', 'window'):
            if want(name):
                globals()['s_' + name]()
    finally:
        for p in HELD:
            try:
                p.kill()
            except Exception:
                pass
        if not os.environ.get('BS_KEEP'):
            shutil.rmtree(T, True)
    print(f'bscript: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


if __name__ == '__main__':
    main()
