#!/usr/bin/env python3
"""The feature tree, BeeModel on its own, done two ways in the same build and
compared: a BeeScript (--eval: the script functions pad(), pocket(), feature()
... the operators' templates call) and the console's lines (--op). Random
sketches and random feature chains (pad, pocket, revolve, hole, shell,
fillet, chamfer, patterns, infill) with parameter, unit and value changes,
suppressing and reordering: every body's MESH and the CADD chunk byte for
byte both ways; random and damaged feature records in files, opened and saved
(no crash); failing features and their statuses; the console's words for bad
arguments; undo and redo (each step's file as the operators alone give it);
the Product template; the CAD tab's feature list clicked (the file as the
console's operator gives it), its look; a window in the fake compositor
(tests/wl_fake.py): a sketch drawn, padded, dimensioned, undone.

    python3 tests/feature.py BIN [runs=40] [seed]

BEE_CPU (default 6) pins the runs; FT_ONLY=s_ops,s_files ... runs some.
"""
import math, os, random, re, struct, subprocess, sys, tempfile, time, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 40
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '6')
ONLY = [x for x in os.environ.get('FT_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beefeat-', dir='/tmp')
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def orig_eval(code, timeout=1800):
    """A BeeScript run by BeeModel (--eval): (exit code, its output). (The name
    from when another program ran it.)"""
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--eval', code], capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return None, 'timeout'


def port(*a, timeout=1800, binary=None):
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary or BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a],
                           capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode
    except subprocess.TimeoutExpired:
        return None


def plog():
    return open(f'{T}/log.txt', errors='replace').read() if os.path.exists(f'{T}/log.txt') else ''


def answers(lines):
    """The port's console: what each command said, in order ("> cmd" starts one)."""
    out, cur = [], None
    for ln in lines:
        if ln.startswith('> '):
            cur = []
            out.append(cur)
        elif cur is not None:
            cur.append(ln[:95])
    return out


def objmeshes(path):
    """{object name: its MESH chunk}."""
    try:
        ms = [c for t, c in beefile.chunks(path) if t == b'MESH']
        return {o['name']: (ms[o['mesh']] if 0 <= o['mesh'] < len(ms) else None) for o in beefile.objects(path)}
    except Exception:
        return None


def cadd(path):
    try:
        return beefile.chunk(path, b'CADD')
    except Exception:
        return None


def feats(c):
    """CADD's feature records: [(type, body, sketch, ref, flags, count, status, axis, slots)]."""
    if c is None or len(c) < 12:
        return None
    n = struct.unpack_from('<I', c, 8)[0]
    o = 12 + n * 128
    if o + 4 > len(c):
        return []
    nf = struct.unpack_from('<I', c, o)[0]
    out = []
    for k in range(nf):
        r = c[o + 4 + k * 128:o + 4 + (k + 1) * 128]
        if len(r) < 128:
            break
        out.append(struct.unpack_from('<8I', r) + (r[32:],))
    return out


def stats(c):
    f = feats(c)
    return None if f is None else [x[6] for x in f]


def build(chs):
    o = b'BEEM' + struct.pack('<I', 1)
    for t, c in chs:
        o += t + struct.pack('<I', len(c)) + c
    return o


def same_files(a, b, what):
    """Every object's mesh and the CADD chunk, byte for byte (object
    references are the objects' persistent uids in both): (ok, why)."""
    ma, mb = objmeshes(a), objmeshes(b)
    if ma is None or mb is None:
        return False, f'{what}: a file is missing ({ma is None}, {mb is None})'
    bad = [k for k in sorted(set(ma) | set(mb)) if ma.get(k) != mb.get(k)]
    ca, cb = cadd(a), cadd(b)
    why = []
    if bad:
        why.append('meshes of ' + ', '.join(f'{k} ({len(ma.get(k) or b"")}/{len(mb.get(k) or b"")} bytes)' for k in bad))
    if ca != cb:
        why.append(f'CADD (statuses {stats(ca)} / {stats(cb)})')
    return not why, f'{what}: ' + ('; '.join(why) if why else 'the same')


# ---- random sketches and feature chains ------------------------------------------------

PLANES = ['XY', 'XZ', 'YZ']


class Num(float):
    """A number that prints the way BeeScript reads it (no exponent)."""
    def __str__(self):
        t = f'{float(self):.6f}'.rstrip('0').rstrip('.')
        return '0' if t in ('-0', '') else t
    __repr__ = __str__
    __format__ = lambda self, spec: str(self) if not spec else float.__format__(self, spec)


def rnd(rng, a, b, nd=3):
    return Num(round(rng.uniform(a, b), nd))


def N(x):
    return Num(x)


def sketch_lines(rng, name):
    """BeeScript for a random sketch: closed profiles (rectangles, circles,
    polygons, half discs), sometimes nested, loose points for holes."""
    pl = rng.choice(PLANES)
    off = rng.choice([0, 0, 0, rnd(rng, -1, 1)])
    L = [f's = sketch("{name}", "{pl}", {off})']
    x0, y0 = rnd(rng, -2, 1), rnd(rng, -2, 1)
    w, h = rnd(rng, 1.5, 4), rnd(rng, 1, 3)
    kind = rng.choice(['rect', 'rect', 'circle', 'poly', 'halfdisc', 'two'])
    if kind in ('rect', 'two'):
        L.append(f'r = rect(s, {x0}, {y0}, {w}, {h})')
        if rng.random() < .3:
            L.append('_ = con(s, "length", r, "w")')
    if kind == 'circle':
        L.append(f'c = circle(s, {x0}, {y0}, {rnd(rng, 0.6, 2)})')
    if kind == 'poly':
        n = rng.randrange(3, 7)
        pts = [(N(round(x0 + math.cos(2 * math.pi * k / n) * w * .6, 3)), N(round(y0 + math.sin(2 * math.pi * k / n) * h * .6, 3))) for k in range(n)]
        for k in range(n):
            a, b = pts[k], pts[(k + 1) % n]
            L.append(f'_ = line(s, {a[0]}, {a[1]}, {b[0]}, {b[1]})')
    if kind == 'halfdisc':
        r = rnd(rng, 0.8, 2)
        L.append(f'_ = arc(s, {x0}, {y0}, {r}, 0, 3.14159265358979)')
        L.append(f'_ = line(s, {N(round(x0 - r, 6))}, {y0}, {N(round(x0 + r, 6))}, {y0})')
    if kind == 'two':
        L.append(f'r2 = rect(s, {N(round(x0 + w + 0.5, 3))}, {y0}, {rnd(rng, 0.5, 2)}, {h})')
    if rng.random() < .5 and kind in ('rect', 'two', 'circle'):
        cx, cy = (x0 + w / 2, y0 + h / 2) if kind != 'circle' else (x0, y0)
        L.append(f'_ = circle(s, {N(round(cx, 3))}, {N(round(cy, 3))}, {rnd(rng, 0.1, 0.45)})')
    for _ in range(rng.choice([0, 0, 1, 2, 3])):
        cx, cy = (x0 + w * rng.uniform(.2, .8), y0 + h * rng.uniform(.2, .8)) if kind != 'circle' else (x0 + rng.uniform(-.4, .4), y0)
        L.append(f'_ = point(s, {N(round(cx, 3))}, {N(round(cy, 3))})')
    if rng.random() < .3:
        L.append(f'move("{name}", {rnd(rng, -1, 1)}, {rnd(rng, -1, 1)}, {rnd(rng, -1, 1)})')
    if rng.random() < .2:
        L.append(f'rotate("{name}", {rng.choice([0, 15, 90, 30])}, {rng.choice([0, 45, 10])}, 0)')
    return L


def value(rng, lo, hi, params=True):
    r = rng.random()
    if params and r < .2:
        return rng.choice(['h', '2*w', 'h/2', 'w+0.5', 'h*1.5'])
    if r < .3:
        return rng.choice(['0', '-1', '1000mm', '50cm', '0.5+0.25'])
    return str(rnd(rng, lo, hi))


def chain(rng, nsk):
    """A random feature chain: (script lines, console steps)."""
    S, P = [], []
    bodies = ['Body', 'Part']
    n = 0
    kinds = []

    def emit(s, p):
        S.append(s)
        P.extend(p)

    made = []
    for _ in range(rng.randrange(1, 9)):
        r = rng.random()
        sk = f'S{rng.randrange(nsk)}'
        b = bodies[0] if rng.random() < .8 else bodies[1]
        if n == 0 or r < .35 or not made:
            t = rng.choice(['pad', 'pad', 'pocket', 'revolve', 'hole'])
            v = value(rng, 0.3, 3)
            if t == 'revolve':
                v = rng.choice(['360deg', '90deg', '270deg', str(rnd(rng, 0.5, 6.3)), '-180deg'])
                m = rng.choice(['u', 'v'])
            elif t == 'hole':
                v = str(rnd(rng, 0.1, 0.6))
                m = rng.choice(['', '0', str(rnd(rng, 0.2, 2))])
            elif t == 'pocket':
                m = rng.choice(['normal', 'through', 'symmetric', 'reverse'])
            else:
                m = rng.choice(['normal', 'symmetric', 'reverse'])
            if t == 'hole':
                d = f', "{m}"' if m not in ('', '0') else ''
                emit(f'_ = hole("{b}", "{sk}", "{v}"{d})', [('--select', sk), ('--op', f'cad.hole {b} {v} {m}')])
            else:
                emit(f'_ = {t}("{b}", "{sk}", "{v}", "{m}")', [('--select', sk), ('--op', f'cad.{t} {b} "{v}" {m}')])
            kinds.append(t)
            n += 1
            if b not in made:
                made.append(b)
        elif r < .45:
            b = rng.choice(made)
            ref = rng.randrange(n + 1)
            wall = rng.choice([str(rnd(rng, 0.05, 0.3)), '5', '0'])
            m = rng.choice(['normal', 'bottom'])
            emit(f'_ = shell("{b}", {ref}, "{wall}", "{m}")', [('--select', b), ('--op', f'cad.shell {ref} {wall} {m}')])
            kinds.append('shell')
            n += 1
        elif r < .6:
            b = rng.choice(made)
            t = rng.choice(['fillet', 'chamfer'])
            v = rng.choice([str(rnd(rng, 0.02, 0.3)), str(rnd(rng, 0.3, 3))])
            e = rng.choice(['all', 'vertical', 'horizontal', 'top', 'bottom'])
            emit(f'_ = {t}("{b}", "{v}", "{e}")', [('--select', b), ('--op', f'cad.{t} {v} {e}')])
            kinds.append(t)
            n += 1
        elif r < .7:
            b = rng.choice(made)
            ref = rng.randrange(n + 1)
            cnt = rng.randrange(2, 5)
            circ = rng.choice(['linear', 'circular'])
            st = str(rnd(rng, 0.5, 3)) if circ == 'linear' else rng.choice(['0', '90deg', '1.5'])
            ax = rng.choice('xyz')
            emit(f'_ = pattern("{b}", {ref}, {cnt}, "{st}", "{ax}", "{circ}")', [('--select', b), ('--op', f'cad.pattern {ref} {cnt} {st} {ax} {circ}')])
            kinds.append('pattern')
            n += 1
        elif r < .74 and 'shell' in kinds:
            b = rng.choice(made)
            ref = kinds.index('shell')
            emit(f'_ = infill("{b}", {ref}, "{rng.choice(["gyroid", "grid"])}", "{rnd(rng, 0.6, 1.5)}", "{rnd(rng, 0.08, 0.2)}")', [])
            # (the console line from the script line: same words)
            g = S[-1].split('"')
            P.extend([('--select', b), ('--op', f'cad.infill {ref} {g[3]} {g[5]} {g[7]}')])
            kinds.append('infill')
            n += 1
        elif r < .82:
            k = rng.randrange(n)
            v = value(rng, 0.1, 3)
            emit(f'_ = feature({k}, 0, "{v}")', [('--op', f'feature {k} 0 "{v}"')])
        elif r < .87:
            k = rng.randrange(n)
            on = rng.choice([0, 1])
            emit(f'_ = feature({k}, 3, {on})', [('--op', f'feature {k} 3 {on}')])
        elif r < .92:
            k = rng.randrange(n)
            d = rng.choice(['up', 'down'])
            emit(f'op("cad.feature_move", "{k} {d}")', [('--op', f'cad.feature_move {k} {d}')])
        elif r < .97:
            p = rng.choice(['h', 'w'])
            v = rng.choice(['1.5', '2', '0.7', '3*w', '2.5'] if p == 'h' else ['1', '2', '0.8'])
            emit(f'param("{p}", "{v}")', [('--op', f'param.set {p} {v}')])
        else:
            u = rng.choice(['mm', 'cm', 'm', 'in'])
            emit(f'op("scene.units", "{u}")', [('--op', f'scene.units {u}')])
    return S, P


def base_for(rng, k):
    """A base scene: parameters w and h, 1-3 random sketches."""
    nsk = rng.randrange(1, 4)
    L = ['param("w", "1.2")', 'param("h", "1.5")']
    for i in range(nsk):
        L += sketch_lines(rng, f'S{i}')
    return L, nsk


def s_ops():
    print('-- random sketches and feature chains: every body\'s MESH and CADD byte for byte, by a script and by the console --')
    rng = random.Random(SEED)
    cases = []
    for k in range(RUNS):
        bl, nsk = base_for(rng, k)
        base = f'{T}/b{k}.bee'
        S, P = chain(rng, nsk)
        cases.append((base, bl, S, P))
    # the bases (a script makes them), then each chain both ways
    # (in batches: a script of 64 KiB at most)
    for lo in range(0, len(cases), 20):
        code = []
        for base, bl, S, P in cases[lo:lo + 20]:
            code += ['op("file.new")'] + bl + [f'op("file.save_as", "{base}")']
        rc, out = orig_eval('\n'.join(code))
    check(all(os.path.exists(c[0]) for c in cases), f'a script made the {len(cases)} base scenes')
    def run_orig(ks):
        code = []
        for k in ks:
            base, bl, S, P = cases[k]
            code += [f'op("file.open", "{base}")'] + S + [f'op("file.save_as", "{T}/o{k}.bee")']
        return orig_eval('\n'.join(code))
    lost = []
    for lo in range(0, len(cases), 10):
        ks = list(range(lo, min(lo + 10, len(cases))))
        run_orig(ks)
        for k in ks:
            if not os.path.exists(f'{T}/o{k}.bee'):
                rc, out = run_orig([k])   # (one that stops the script: alone)
                if not os.path.exists(f'{T}/o{k}.bee'):
                    lost.append((k, rc, out.strip()[-200:]))
    good = 0
    for lo in range(0, len(cases), 8):
        args = []
        for k in range(lo, min(lo + 8, len(cases))):
            base, bl, S, P = cases[k]
            args += ['--op', f'file.open {base}']
            for a, b in P:
                args += [a, b]
            args += ['--op', f'file.save_as {T}/p{k}.bee']
        port(*args)
    worked = 0
    for k, rc, out in lost:
        print(f'  info chain {k}: the script did not finish it (exit {rc}: {out!r}):\n      ' + ' | '.join(cases[k][2]))
    check(len(lost) <= len(cases) // 20, f'the script finished {len(cases) - len(lost)} of {len(cases)} chains')
    for k, (base, bl, S, P) in enumerate(cases):
        if any(x[0] == k for x in lost):
            continue
        ok, why = same_files(f'{T}/o{k}.bee', f'{T}/p{k}.bee', f'chain {k}')
        if ok:
            good += 1
            st = stats(cadd(f'{T}/o{k}.bee')) or []
            worked += sum(1 for x in st if x == 0)
        else:
            check(False, why + '\n      ' + ' | '.join(S))
    check(good == len(cases) - len(lost) and worked > len(cases), f'{good} of {len(cases) - len(lost)} random chains the same both ways ({worked} features built, the rest failing alike)')


# ---- files: random and damaged feature records ------------------------------------------

def rec(rng, nobj, uids, damaged=False):
    t = rng.randrange(1, 11) if not (damaged and rng.random() < .2) else rng.randrange(0, 40)
    body = rng.choice(uids['mesh'] + [0, 99] if damaged else uids['mesh'])
    skt = rng.choice(uids['sketch'] + ([0, 77, uids['mesh'][0]] if damaged else []))
    ref = rng.randrange(0, 6) if not damaged else rng.choice([0, 1, 2, -1 & 0xffffffff, 64, 1 << 31])
    if t in (6, 7):
        ref = rng.randrange(0, 5) if not damaged else rng.randrange(0, 9)
    flags = rng.choice([0, 0, 1, 2, 4, 8]) | (rng.choice([0, 8]) if rng.random() < .1 else 0)
    if damaged and rng.random() < .3:
        flags = rng.randrange(1 << 32)
    count = rng.randrange(2, 5) if t in (8, 9) else rng.choice([0, 0, 1, 2, 3])
    if damaged and rng.random() < .2:
        count = rng.choice([-5 & 0xffffffff, 0, 1, 40])
    stat = 99 if not damaged else rng.randrange(9, 1 << 32)   # (a rebuild sets 0 .. 8)
    axis = rng.randrange(0, 3) if not damaged else rng.choice([0, 1, 2, 3, 7, 1 << 31])
    r = bytearray(struct.pack('<8I', t, body, skt, ref, flags, count, stat, axis))
    for k in range(3):
        sl = bytearray(32)
        c = rng.random()
        if c < .4:
            sl[0] = 1
            struct.pack_into('<d', sl, 8, rng.choice([rnd(rng, 0.05, 3), 0.0, -1.0, rnd(rng, 0.05, 0.4)]))
        elif c < .8:
            txt = rng.choice([str(rnd(rng, 0.05, 3)), 'h', '2*w', 'h/3', '15cm', '0.2', 'nosuch', '1/0', '', '0.1*h'])
            sl[:len(txt)] = txt.encode()
            if damaged and rng.random() < .2:
                sl[len(txt):] = bytes(rng.randrange(32, 127) for _ in range(32 - len(txt)))   # no terminator
        if damaged and rng.random() < .1:
            sl = bytearray(rng.randrange(256) for _ in range(32))
            if sl[0] > 1:
                sl[31] = 0
        r += sl
    # infill: lattice cells not too small (the run time)
    if t == 10:
        struct.pack_into('<B', r, 32, 1)
        struct.pack_into('<d', r, 40, rnd(rng, 0.6, 1.5))
        r[64:96] = bytes(32)
        r[64] = 1
        struct.pack_into('<d', r, 72, rnd(rng, 0.08, 0.2))
    return bytes(r)


def cadd_chunk(rng, nf, uids, damaged):
    params = []
    for name, ex in (('w', '1.2'), ('h', '1.5')):
        p = bytearray(128)
        p[:len(name)] = name.encode()
        p[24:24 + len(ex)] = ex.encode()
        struct.pack_into('<d', p, 120, float(ex))
        params.append(bytes(p))
    unit = rng.choice([1000.0, 1000.0, 1.0, 10.0])
    c = struct.pack('<dI', unit, len(params)) + b''.join(params)
    c += struct.pack('<I', nf) + b''.join(rec(rng, 4, uids, damaged) for _ in range(nf))
    c += struct.pack('<I', 0)
    if damaged and rng.random() < .3:
        c = c[:rng.randrange(8, len(c))]   # truncated
    if damaged and rng.random() < .1:
        c = c[:12 + 2 * 128] + struct.pack('<I', rng.choice([65, 1000, 1 << 31])) + c[12 + 2 * 128 + 4:]
    return c


def resave_both(names, one_by_one=False):
    if one_by_one:
        for p in names:
            orig_eval(f'op("file.open", "{p}")\nop("file.save_as", "{p}.o.bee")', timeout=300)
    else:
        orig_eval('\n'.join(f'op("file.open", "{p}")\nop("file.save_as", "{p}.o.bee")' for p in names))
    for lo in range(0, len(names), 1 if one_by_one else 10):
        args = []
        for p in names[lo:lo + (1 if one_by_one else 10)]:
            args += ['--op', f'file.open {p}', '--op', f'file.save_as {p}.p.bee']
        port(*args)
    return [(p + '.o.bee', p + '.p.bee') for p in names]


def s_files():
    print('-- files: random and damaged feature records, opened (the parts rebuild) and saved, by a script and by the console --')
    rng = random.Random(SEED + 1)
    base = f'{T}/fbase.bee'
    L = ['op("file.new")', 'param("w", "1.2")', 'param("h", "1.5")']
    L += sketch_lines(random.Random(5), 'S0') + sketch_lines(random.Random(9), 'S1')
    L += ['_ = pad("Body", "S0", "1", "normal")', f'op("file.save_as", "{base}")']
    orig_eval('\n'.join(L))
    chs = beefile.chunks(base)
    objs = beefile.objects(base)
    uids = {'mesh': [i + 1 for i, o in enumerate(objs) if o['type'] == 0], 'sketch': [i + 1 for i, o in enumerate(objs) if o['type'] == 3]}
    for kind in ('ok', 'bad'):
        names = []
        for k in range(RUNS):
            c = cadd_chunk(rng, rng.randrange(1, 7), uids, kind == 'bad')
            p = f'{T}/f_{kind}{k}.bee'
            open(p, 'wb').write(build([(t, c if t == b'CADD' else x) for t, x in chs]))
            names.append(p)
        same = 0
        lost = 0
        built = rebuilt = recs = 0
        for a, b in resave_both(names, one_by_one=kind == 'bad'):
            if not os.path.exists(a) and kind == 'bad':
                lost += 1
                continue
            ok, why = same_files(a, b, os.path.basename(a))
            if ok:
                same += 1
                st = stats(cadd(a)) or []
                built += sum(1 for x in st if x == 0)
                rebuilt += sum(1 for x in st if x <= 8)
                recs += len(st)
            else:
                check(False, why)
        check(same + lost == len(names) and lost < len(names) // 4 and rebuilt > recs // 2, f'{kind}: {same} of {len(names)} files the same both ways after the rebuild ({rebuilt} of {recs} records rebuilt, {built} built; the script lost {lost})')


# ---- failing features ------------------------------------------------------------------------

FAIL_CASES = [
    # (what, the chain, the statuses it must end with)
    ('a pocket through nothing', ['pocket Body S 1 normal'], [5]),
    ('a pad, then a shell too thick', ['pad Body S 1 normal', 'shell Body 0 3 normal'], [0, None]),
    ('a fillet too big', ['pad Body S 1 normal', 'fillet Body 5 all'], [0, None]),
    ('a chamfer too big', ['pad Body S 1 normal', 'chamfer Body 3 vertical'], [0, None]),
    ('a pattern of a failed feature', ['pocket Body S 1 normal', 'pattern Body 0 3 1 x linear'], [5, 5]),
    ('a pattern of itself', ['pad Body S 1 normal', 'pattern Body 1 3 1 x linear'], [0, 6]),
    ('a pattern of a fillet', ['pad Body S 1 normal', 'fillet Body 0.1 all', 'pattern Body 1 3 1 x linear'], [0, 0, 6]),
    ('a pattern of a pattern', ['pad Body S 1 normal', 'pattern Body 0 2 3 x linear', 'pattern Body 1 2 3 y linear'], [0, 0, 6]),
    ('a shell of a pocket', ['pad Body S 1 normal', 'pocket Body S 0.5 normal', 'shell Body 1 0.1 normal'], [0, 0, 6]),
    ('infill of a pad', ['pad Body S 1 normal', 'infill Body 0 gyroid 1 0.1'], [0, 6]),
    ('a revolve of 0', ['revolve Body S 0 u'], [4]),
    ('a pad of 0', ['pad Body S 0 normal'], [4]),
    ('a hole without loose points', ['pad Body T 1 normal', 'hole Body T 0.5'], [0, 2]),
    ('a hole of no diameter', ['pad Body S 1 normal', 'hole Body S 0'], [0, 4]),
    ('an open profile', ['pad Body O 1 normal'], [2]),
    ('a value that fails later', ['pad Body S h normal', 'param.remove h'], [4]),
    ('a body that is gone', ['pad Body S 1 normal', 'pad Part S 2 normal', 'delete Body', 'param.set q 1'], [8, 0]),
    ('a sketch that is gone', ['pad Body S 1 normal', 'delete S', 'param.set q 1'], [1]),
    ('suppressed, then the pattern', ['pad Body S 1 normal', 'feature 0 3 1', 'pattern Body 0 2 3 x linear'], [7, 0]),
    ('a fillet on nothing (a body starts empty)', ['fillet Cube 0.1 all', 'pad Cube S 1 normal'], [5, 0]),
    ('a circular pattern of a hole', ['pad Body S 1 normal', 'hole Body S 0.3', 'pattern Body 1 4 0 y circular'], [0, 0, 0]),
    ('a shell of a spike (the offset kept at its hairpin)', ['pad Body A 1 normal', 'shell Body 0 0.05 normal'], [0, 0]),
    ('a shell open at the bottom, a grid infill', ['pad Body S 1 normal', 'shell Body 0 0.1 bottom', 'infill Body 1 grid 1 0.15'], [0, 0, 0]),
]


def fail_steps(chain):
    """(script lines, port args) of a FAIL_CASES chain."""
    S, P = [], []
    for c in chain:
        w = c.split()
        t = w[0]
        if t in ('pad', 'pocket', 'revolve'):
            S.append(f'_ = {t}("{w[1]}", "{w[2]}", "{w[3]}", "{w[4]}")')
            P += ['--select', w[2], '--op', f'cad.{t} {w[1]} {w[3]} {w[4]}']
        elif t == 'hole':
            S.append(f'_ = hole("{w[1]}", "{w[2]}", "{w[3]}")')
            P += ['--select', w[2], '--op', f'cad.hole {w[1]} {w[3]}']
        elif t == 'shell':
            S.append(f'_ = shell("{w[1]}", {w[2]}, "{w[3]}", "{w[4]}")')
            P += ['--select', w[1], '--op', f'cad.shell {w[2]} {w[3]} {w[4]}']
        elif t in ('fillet', 'chamfer'):
            S.append(f'_ = {t}("{w[1]}", "{w[2]}", "{w[3]}")')
            P += ['--select', w[1], '--op', f'cad.{t} {w[2]} {w[3]}']
        elif t == 'pattern':
            S.append(f'_ = pattern("{w[1]}", {w[2]}, {w[3]}, "{w[4]}", "{w[5]}", "{w[6]}")')
            P += ['--select', w[1], '--op', f'cad.pattern {" ".join(w[2:])}']
        elif t == 'infill':
            S.append(f'_ = infill("{w[1]}", {w[2]}, "{w[3]}", "{w[4]}", "{w[5]}")')
            P += ['--select', w[1], '--op', f'cad.infill {" ".join(w[2:])}']
        elif t == 'feature':
            S.append(f'_ = feature({w[1]}, {w[2]}, {w[3]})')
            P += ['--op', c]
        elif t == 'delete':
            S.append(f'delete("{w[1]}")')
            P += ['--select', w[1], '--op', 'object.delete']
        elif t == 'param.set':
            S.append(f'param("{w[1]}", "{w[2]}")')
            P += ['--op', c]
        elif t == 'param.remove':
            S.append(f'op("param.remove", "{w[1]}")')
            P += ['--op', c]
    return S, P


def s_fail():
    print('-- failing features: their statuses, and the bodies they leave, both ways --')
    base = f'{T}/xbase.bee'
    L = ['param("h", "1.5")', 's = sketch("S", "XY")', 'r = rect(s, 0, 0, 4, 2)', '_ = point(s, 1, 1)', '_ = point(s, 3, 1)',
         't = sketch("T", "XZ")', 'r = rect(t, -1, -1, 2, 2)', 'o = sketch("O", "XY")', '_ = line(o, 0, 0, 1, 0)', '_ = line(o, 1, 0, 1, 1)',
         'a = sketch("A", "XY", 2)', '_ = line(a, 0, 0, 3, 0)', '_ = line(a, 3, 0, 0, 0.3)', '_ = line(a, 0, 0.3, 0, 0)',
         f'op("file.save_as", "{base}")']
    orig_eval('\n'.join(L))
    code = []
    args = []
    for k, (what, chain, want) in enumerate(FAIL_CASES):
        S, P = fail_steps(chain)
        code += [f'op("file.open", "{base}")'] + S + [f'op("file.save_as", "{T}/xo{k}.bee")']
        args += ['--op', f'file.open {base}'] + P + ['--op', f'file.save_as {T}/xp{k}.bee']
    orig_eval('\n'.join(code))
    port(*args)
    for k, (what, chain, want) in enumerate(FAIL_CASES):
        a, b = f'{T}/xo{k}.bee', f'{T}/xp{k}.bee'
        ok, why = same_files(a, b, what)
        st = stats(cadd(a))
        meant = st is not None and len(st) == len(want) and all(w is None or w == x for w, x in zip(want, st))
        check(ok and meant, f'{why}, statuses {st} (meant {want})')


# ---- booleans as bool.s gives them ------------------------------------------------------------

def s_exact():
    print('-- booleans: a revolve that cuts through its own axis, joined to another; a turned pattern --')
    base = f'{T}/bbase.bee'
    orig_eval('\n'.join(['s = sketch("S0", "YZ", 0)', 'r = rect(s, 0.366, -0.129, 3.653, 1.206)', 'r2 = rect(s, 4.519, -0.129, 1.889, 1.206)',
                         'move("S0", 0.808, -0.798, 0.016)', 't = sketch("S1", "XY", 0)', 'r = rect(t, -1.231, -0.777, 3.075, 2.807)',
                         f'op("file.save_as", "{base}")']))
    orig_eval('\n'.join([f'op("file.open", "{base}")', '_ = revolve("Body", "S1", "1.633", "u")', '_ = revolve("Body", "S0", "270deg", "u")',
                         f'op("file.save_as", "{T}/bo.bee")']))
    port('--op', f'file.open {base}', '--select', 'S1', '--op', 'cad.revolve Body 1.633 u', '--select', 'S0', '--op', 'cad.revolve Body 270deg u',
         '--op', f'file.save_as {T}/bp.bee')
    ok, why = same_files(f'{T}/bo.bee', f'{T}/bp.bee', 'the union')
    m = objmeshes(f'{T}/bo.bee')
    nv = struct.unpack_from('<3I', m['Body']) if m and m.get('Body') else None
    check(ok and nv is not None and nv[1] > 0 and stats(cadd(f'{T}/bp.bee')) == [0, 0], f'{why}: {nv}, statuses {stats(cadd(f"{T}/bp.bee"))}')
    # a pattern of a revolve, turned: a region on a triangle of no area
    base = f'{T}/bbase2.bee'
    orig_eval('\n'.join(['s = sketch("S0", "XY", -0.375)', 'c = circle(s, -0.564, 0.082, 1.616)', f'op("file.save_as", "{base}")']))
    S = ['_ = pocket("Body", "S0", "0.449", "symmetric")', '_ = pad("Body", "S0", "1.604", "normal")', '_ = pattern("Body", 0, 4, "0", "y", "circular")',
         '_ = revolve("Body", "S0", "90deg", "u")', '_ = pattern("Body", 3, 2, "1.5", "y", "circular")']
    orig_eval('\n'.join([f'op("file.open", "{base}")'] + S + [f'op("file.save_as", "{T}/bo2.bee")']))
    port('--op', f'file.open {base}', '--select', 'S0', '--op', 'cad.pocket Body 0.449 symmetric', '--select', 'S0', '--op', 'cad.pad Body 1.604 normal',
         '--select', 'Body', '--op', 'cad.pattern 0 4 0 y circular', '--select', 'S0', '--op', 'cad.revolve Body 90deg u',
         '--select', 'Body', '--op', 'cad.pattern 3 2 1.5 y circular', '--op', f'file.save_as {T}/bp2.bee')
    ok, why = same_files(f'{T}/bo2.bee', f'{T}/bp2.bee', 'the turned copy, joined')
    m = objmeshes(f'{T}/bo2.bee')
    nv = struct.unpack_from('<3I', m['Body']) if m and m.get('Body') else None
    check(ok and nv is not None and nv[1] > 0, f'{why}: {nv} (statuses {stats(cadd(f"{T}/bo2.bee"))})')


# ---- the console's words ---------------------------------------------------------------------

ERROR_CASES = [
    ('S', 'cad.pad', 'Body 3 bogus'), ('S', 'cad.pad', 'Body nosuch normal'), ('S', 'cad.pad', 'Body 3'), ('S', 'cad.pad', 'Body'),
    ('S', 'cad.pad', 'Body "" normal'), ('S', 'cad.pad', 'Light 3 normal'), ('S', 'cad.pad', 'S 3 normal'),
    ('S', 'cad.pad', 'Body 012345678901234567890123456789012 symmetric'), ('S', 'cad.pad', 'Body 1/0 normal'),
    ('S', 'cad.pad', 'Body 3 normal'), ('S', 'cad.pad', '"My Body" 3 normal'), ('Cube', 'cad.pad', 'Body 3 normal'),
    ('S', 'cad.pocket', 'Body 1 up'), ('S', 'cad.pocket', 'Body 1 through'), ('S', 'cad.revolve', 'Body 1 w'),
    ('S', 'cad.revolve', 'Body 90deg u'), ('S', 'cad.hole', 'Body 2'), ('S', 'cad.hole', 'Body 2 x'), ('S', 'cad.hole', 'Body 2 0'),
    ('Cube', 'cad.shell', '0 0.1 normal'), ('Cube', 'cad.shell', ''), ('Cube', 'cad.shell', 'x 0.1'), ('Cube', 'cad.shell', '0 0.1'),
    ('Cube', 'cad.shell', '1.7 0.1 bottom'), ('Cube', 'cad.fillet', '0.1'), ('Cube', 'cad.fillet', '0.1 diagonal'),
    ('Cube', 'cad.fillet', ''), ('Cube', 'cad.fillet', 'x all'), ('Cube', 'cad.chamfer', '0.1 top'), ('Cube', 'cad.pattern', '0 3 1 x linear'),
    ('Cube', 'cad.pattern', '0 3 1 x'), ('Cube', 'cad.pattern', '0'), ('Cube', 'cad.pattern', 'a b c d e'), ('Cube', 'cad.pattern', '0 3 1 q linear'),
    ('Cube', 'cad.infill', '3 gyroid 1 0.1'), ('Cube', 'cad.infill', '3 lattice 1 0.1'), ('Cube', 'cad.infill', '3'),
    ('Cube', 'cad.feature_move', '1 up'), ('Cube', 'cad.feature_move', '1 sideways'), ('Cube', 'cad.feature_move', ''), ('Cube', 'cad.feature_move', 'x up'),
    ('Light', 'cad.fillet', '0.1 all'), ('S', 'cad.fillet', '0.1 all'),
]


def s_errors():
    print('-- the console\'s words: every feature operator\'s errors and answers --')
    base = f'{T}/ebase.bee'
    orig_eval(f's = sketch("S", "XY")\nr = rect(s, 0, 0, 4, 2)\n_ = point(s, 1, 1)\nop("file.save_as", "{base}")')
    args = []
    for act, op, arg in ERROR_CASES:
        args += ['--op', f'file.open {base}', '--select', act, '--op', f'{op} {arg}']
    rc = port(*args)
    got = [a for k, a in enumerate(answers(plog().splitlines())) if k % 2 == 1]
    check(rc == 0 and len(got) == len(ERROR_CASES), f'{len(ERROR_CASES)} operators with odd arguments: BeeModel ran them all ({rc}, {len(got)} answers)')


# ---- undo and redo ---------------------------------------------------------------------------

UNDO_SEQ = ['cad.pad Body h normal', 'cad.fillet 0.1 vertical', 'cad.pattern 0 2 5 x linear', 'param.set h 2', 'cad.feature_move 1 down',
            'scene.units cm', 'cad.shell 0 0.1 normal', '#save', 'edit.undo', 'edit.undo', 'edit.undo', '#save', 'edit.redo', 'edit.redo', '#save',
            'edit.undo', 'edit.undo', 'edit.undo', 'edit.undo', '#save', 'cad.chamfer 0.05 top', 'edit.redo', '#save', 'edit.undo', 'edit.undo', '#save',
            'edit.redo', '#save']


def s_undo():
    print('-- undo and redo through features, parameters, units and moves: each step\'s file as the operators alone give it --')
    base = f'{T}/ubase.bee'
    orig_eval('\n'.join(['param("h", "1.5")', 's = sketch("S", "XY")', 'r = rect(s, 0, 0, 4, 2)', 'select("S")', f'op("file.save_as", "{base}")']))
    # each operator alone: the file after it, to compare the undone ones with
    args = ['--op', f'file.open {base}', '--select', 'S']
    for k, c in enumerate(UNDO_SEQ[:7]):
        args += ['--op', c, '--op', f'file.save_as {T}/us{k}.bee']
    port(*args)
    want_steps = [(objmeshes(f'{T}/us{k}.bee'), cadd(f'{T}/us{k}.bee')) for k in range(7)]
    check(all(w[1] is not None for w in want_steps) and len({w[1] for w in want_steps}) == 7, 'each of the seven operators changed the tree')
    args = ['--op', f'file.open {base}', '--select', 'S']
    n = 0
    for c in UNDO_SEQ:
        if c == '#save':
            args += ['--op', f'file.save_as {T}/pu{n}.bee']
            n += 1
        else:
            args += ['--op', c]
    port(*args)
    # save 0 is after all seven; undone and redone: save 1 (3 undone) is after operator 3, save 2
    # after 5, save 3 after 1; a new operator drops the redo steps: two undone after it is
    # operator 0, one redone operator 1
    for k, st in ((0, 6), (1, 3), (2, 5), (3, 1), (5, 0), (6, 1)):
        b = f'{T}/pu{k}.bee'
        got = (objmeshes(b), cadd(b)) if os.path.exists(b) else None
        check(got == want_steps[st], f'save {k}: as after operator {st} ({UNDO_SEQ[st]})')
    b = f'{T}/pu4.bee'
    got = cadd(b) if os.path.exists(b) else None
    check(got is not None and got != want_steps[1][1] and len(feats(got)) == len(feats(want_steps[1][1])) + 1, 'save 4: the chamfer on top of operator 1, redo had nothing left')


# ---- the CAD tab: the feature list and the dialogs, in both programs ------------------------

UI_BASE = ['param("h", "1.5")', 's = sketch("S", "XY")', 'r = rect(s, 0, 0, 4, 2)', 'c = circle(s, 2, 1, 0.5)', '_ = point(s, 0.5, 0.5)',
           '_ = pad("Body", "S", "3", "normal")', '_ = pocket("Body", "S", "1", "reverse")', '_ = fillet("Body", "0.2", "vertical")',
           '_ = shell("Body", 1, "0.1", "normal")']

UI_STEPS = [
    ('a value typed', 'Body', ('value', 1, '0.5')),
    ('an expression typed', 'Body', ('value', 0, '2*h')),
    ('a value that does not evaluate', 'Body', ('value', 2, 'nosuch')),
    ('On off', 'Body', ('on', 0)),
    ('On off, the failing one', 'Body', ('on', 3)),
    ('up', 'Body', ('up', 2)),
    ('down', 'Body', ('down', 0)),
    ('up at the top: nothing', 'Body', ('up', 0)),
    ('down at the bottom: nothing', 'Body', ('down', 3)),
    ('Pad: its dialog, OK', 'S', ('form', 'Pad')),
    ('Hole: its dialog, OK', 'S', ('form', 'Hole')),
    ('Revolve: its dialog, OK', 'S', ('form', 'Revolve')),
    ('Fillet: its dialog, OK', 'Body', ('form', 'Fillet')),
    ('Chamfer: its dialog, OK', 'Body', ('form', 'Chamfer')),
    ('Shell: its dialog, OK', 'Body', ('form', 'Shell')),
    ('Pattern: its dialog, OK', 'Body', ('form', 'Pattern')),
    ('Infill: its dialog, OK', 'Body', ('form', 'Infill')),
    ('Pocket: its dialog, OK', 'S', ('form', 'Pocket')),
    ('Pattern with a sketch active: nothing (it says why)', 'S', ('form', 'Pattern')),
    ('Pad with the part active: nothing (it says why)', 'Body', ('form', 'Pad')),
]
FORM_WIDGET = {'Pad': 'cad.add.pad', 'Pocket': 'cad.add.pocket', 'Revolve': 'cad.add.revolve', 'Hole': 'cad.add.hole', 'Shell': 'cad.add.shell',
               'Fillet': 'cad.add.fillet', 'Chamfer': 'cad.add.chamfer', 'Pattern': 'cad.add.pattern', 'Infill': 'cad.add.infill'}


def port_rows(path):
    """The port's feature rows in its --dump-ui: [(label, up, down, value, on)] as rects."""
    rows = []
    lines = [ln.split('\t') for ln in open(path).read().splitlines()]
    for i, ln in enumerate(lines):
        if ln[0] == 'info' and re.match(r'^\d+ [A-Z]', ln[1]) and i + 4 < len(lines) and lines[i + 1][1] == 'cad.feature.up':
            rect = lambda q: [int(v) for v in q[2].split()]
            rows.append((ln[1], rect(lines[i + 1]), rect(lines[i + 2]), rect(lines[i + 3]), rect(lines[i + 4])))
    return rows


def centre(r):
    return f'{r[0] + r[2] // 2},{r[1] + r[3] // 2}'


def s_ui():
    print('-- the CAD tab: values typed, On, up and down, the feature dialogs; the file after each, as the console\'s operator gives it --')
    base = f'{T}/uibase.bee'
    orig_eval('\n'.join(UI_BASE + [f'op("file.save_as", "{base}")']))
    for what, act, step in UI_STEPS:
        port('--op', f'file.open {base}', '--select', act, '--click-label', 'tab:CAD', '--move', '600,300')
        rows = port_rows(f'{T}/u.txt')
        kind = step[0]
        if kind == 'form':
            act_args = ['--click-label', f'button:{step[1]}', '--key', 'enter']
            same_as = None
        else:
            if step[1] >= len(rows):
                check(False, f'{what}: BeeModel shows {len(rows)} rows')
                continue
            r = rows[step[1]]
            box = {'up': r[1], 'down': r[2], 'value': r[3], 'on': r[4]}[kind]
            act_args = ['--click', centre(box)]
            if kind == 'value':
                act_args += ['--key', 'ctrl+a', '--type', step[2], '--key', 'enter']
            same_as = {'value': f'feature {step[1]} 0 "{step[2] if kind == "value" else ""}"', 'on': f'feature {step[1]} 3 1',
                       'up': f'cad.feature_move {step[1]} up', 'down': f'cad.feature_move {step[1]} down'}[kind]
        b = f'{T}/ui.bee'
        if os.path.exists(b):
            os.remove(b)
        rc = port('--op', f'file.open {base}', '--select', act, '--click-label', 'tab:CAD', '--move', '600,300', *act_args, '--move', '600,300', '--op', f'file.save_as {b}')
        got = (objmeshes(b), cadd(b)) if os.path.exists(b) else None
        changed = got is not None and got[1] != cadd(base)
        quiet = 'nothing' in what
        check(rc == 0 and got is not None and (changed or quiet or 'evaluate' in what), f'{what}: {"changed" if changed else "unchanged"} (statuses {stats(got[1]) if got else None})')
        if same_as and not quiet:
            c = f'{T}/uic.bee'
            if os.path.exists(c):
                os.remove(c)
            port('--op', f'file.open {base}', '--select', act, '--op', same_as, '--op', f'file.save_as {c}')
            want = (objmeshes(c), cadd(c)) if os.path.exists(c) else None
            check(want is not None and got == want, f'{what}: the same file as "{same_as}" on the console')


# ---- the rebuild's time on a long tree ---------------------------------------------------------

PERF_BASE = ['param("h", "1")', 's = sketch("S", "XZ")', 'r = rect(s, 0, 0, 8, 6)', 'q = sketch("Q", "XZ")', 'c = circle(q, 4, 3, 1)',
             't = sketch("T", "XZ", 1)'] + [f'_ = point(t, {x}, {y})' for x in (1, 2, 3, 5, 6, 7) for y in (1, 5)] + [
             'u = sketch("U", "XY")', 'r = rect(u, 1, -1, 6, 0.6)', 'v = sketch("V", "XY", 3)', 'c = circle(v, 4, 0.5, 0.3)']
# (sketch, the operator, the script function's line)
PERF_FEATS = [('S', 'cad.pad Body h normal', '_ = pad("Body", "S", "h", "normal")'),
              ('Body', 'cad.fillet 0.3 vertical', '_ = fillet("Body", "0.3", "vertical")'),
              ('Body', 'cad.chamfer 0.05 top', '_ = chamfer("Body", "0.05", "top")'),
              ('T', 'cad.hole Body 0.4 0.8', '_ = hole("Body", "T", "0.4", "0.8")'),
              ('Q', 'cad.pocket Body 0.5 reverse', '_ = pocket("Body", "Q", "0.5", "reverse")'),
              ('U', 'cad.pocket Body 0.3 symmetric', '_ = pocket("Body", "U", "0.3", "symmetric")'),
              ('V', 'cad.pad Body 0.5 normal', '_ = pad("Body", "V", "0.5", "normal")'),
              ('Body', 'cad.pattern 6 4 1.5 x linear', '_ = pattern("Body", 6, 4, "1.5", "x", "linear")'),
              ('Body', 'cad.pattern 3 2 0.5 x linear', '_ = pattern("Body", 3, 2, "0.5", "x", "linear")')]


def s_perf():
    print('-- the rebuild\'s time on a long tree (whole runs, one CPU): said, and the tree both ways --')
    base = f'{T}/pbase.bee'
    orig_eval('\n'.join(PERF_BASE + [f'op("file.save_as", "{base}")']))
    K = 10

    def otime(k):
        code = [f'op("file.open", "{base}")'] + [x[2] for x in PERF_FEATS] + [f'param("h", "{1 + 0.1 * (i + 1):.1f}")' for i in range(k)] + [f'op("file.save_as", "{T}/perf_o{k}.bee")']
        t0 = time.time()
        orig_eval('\n'.join(code))
        return time.time() - t0

    def ptime(k):
        args = ['--op', f'file.open {base}']
        for act, c, _ in PERF_FEATS:
            args += ['--select', act, '--op', c]
        for i in range(k):
            args += ['--op', f'param.set h {1 + 0.1 * (i + 1):.1f}']
        args += ['--op', f'file.save_as {T}/perf_p{k}.bee']
        t0 = time.time()
        port(*args)
        return time.time() - t0

    def best(f, k):
        return min(f(k) for _ in range(3))
    otime(K)
    p0, pK = best(ptime, 0), best(ptime, K)
    ok, why = same_files(f'{T}/perf_o{K}.bee', f'{T}/perf_p{K}.bee', f'the tree after {K} changes of h, by a script and by the console')
    st = stats(cadd(f'{T}/perf_p{K}.bee'))
    check(ok and st == [0] * len(PERF_FEATS), f'{why} (statuses {st})')
    rp = (pK - p0) / K * 1000
    print(f'  info  a rebuild of the {len(PERF_FEATS)} features: {rp:.1f} ms', flush=True)


# ---- the Product (CAD) template ---------------------------------------------------------------

def objs_of(path):
    return [(o['name'], o['type'], o['loc'], o['rot'], o['scl'], o['color']) for o in beefile.objects(path)]


def s_template():
    print('-- the Product (CAD) template: millimetres, w d h, a sketch padded h and filleted --')
    b = f'{T}/tpl.bee'
    rc = port('--op', 'help.template product', '--op', f'file.save_as {b}', '--op', 'param.list')
    got = (objmeshes(b), cadd(b), beefile.chunk(b, b'SKCH'), objs_of(b)) if os.path.exists(b) else None
    ans = [[ln for ln in a if ln.startswith('  ')] for a in answers(plog().splitlines())]
    check(rc == 0 and got is not None, f'the template saved ({rc})')
    if got is None:
        return
    check(got[0].get('Part') is not None and len(got[0]['Part']) > 1000, f'a part with a mesh (Part: {len(got[0].get("Part") or b"")} bytes)')
    check(stats(got[1]) == [0, 0], f'CADD: a pad and a fillet, both built ({stats(got[1])})')
    check(got[2] is not None and len(got[2]) > 0, 'a sketch (SKCH)')
    pl = ans[2] if len(ans) > 2 else []
    check(all(any(ln.split()[:1] == [n] or f' {n} ' in f' {ln} ' for ln in pl) for n in ('w', 'd', 'h')), f'param.list says w, d and h: {pl}')
    b3 = f'{T}/tpl3.bee'
    port('--op', f'file.open {b}', '--op', f'file.save_as {b3}')
    got3 = (objmeshes(b3), cadd(b3), beefile.chunk(b3, b'SKCH'), objs_of(b3)) if os.path.exists(b3) else None
    check(got3 == got, 'opened and saved again: the same meshes, CADD, sketch and objects')
    # the welcome screen: Product (CAD) is a button that works
    b2 = f'{T}/tpl2.bee'
    # (after the first: the scene goes, the CAD document stays - its features fail on the bodies that went)
    rc = port('--op', 'help.template product', '--key', 'f3', '--type', 'Welcome', '--key', 'enter', '--click-label', 'button:Product (CAD)', '--op', f'file.save_as {b2}')
    got2 = (objmeshes(b2), cadd(b2), objs_of(b2)) if os.path.exists(b2) else None
    check(rc == 0 and got2 is not None and any(o[0] == 'Part' for o in got2[2]), f'the welcome screen\'s Product (CAD), a second time: a scene with the part (statuses {stats(got2[1]) if got2 else None})')


# ---- the look: the feature list ----------------------------------------------------------------

def ppm_pixel(path, x, y):
    d = open(path, 'rb').read()
    hdr = d.split(b'\n', 3)
    w = int(hdr[1].split()[0])
    k = (y * w + x) * 3
    return tuple(hdr[3][k:k + 3])


def s_look():
    print('-- the look: the feature rows (health dots, values, up / down, On) --')
    base = f'{T}/lbase.bee'
    orig_eval('\n'.join(UI_BASE + ['_ = feature(2, 3, 1)', f'op("file.save_as", "{base}")']))
    rc = port('--op', f'file.open {base}', '--select', 'Body', '--click-label', 'tab:CAD', '--move', '600,300')
    prows = port_rows(f'{T}/u.txt')
    ui = open(f'{T}/u.txt').read().splitlines()
    check(rc == 0 and len(prows) == 4, f'four rows ({len(prows)})')
    if len(prows) != 4:
        return
    px = next(int(ln.split('\t')[2].split()[0]) for ln in ui if ln.startswith('button\tNew Sketch...'))
    pdots = [ppm_pixel(f'{T}/u.ppm', px + 4, r[1][1] + 9) for r in prows]
    pvals = [next((ln.split('\t')[1] for ln in ui if ln.startswith('text\t') and ln.split('\t')[2].split()[:2] == [str(r[3][0]), str(r[3][1])]), None) for r in prows]
    py = [r[1][1] for r in prows]
    check(all(b > a for a, b in zip(py, py[1:])), f'the rows one under another: {py}')
    for k, r in enumerate(prows):
        boxes = r[1:]
        check(all(b[2] > 0 and b[3] > 0 for b in boxes) and all(boxes[i][0] + boxes[i][2] <= boxes[i + 1][0] for i in range(3)), f'row {k}: up, down, value, On side by side ({[b[:2] for b in boxes]})')
    check(pvals == ['3', '1', '0.2', '0.1'], f'the values shown: {pvals}')
    near = lambda c, d: max(abs(p - q) for p, q in zip(c, d)) <= 24
    check(not near(pdots[2], pdots[0]) and near(pdots[0], pdots[1]), f'the suppressed feature\'s health dot is not the built ones\' ({pdots})')


# ---- both windows: a sketch drawn, padded, edited in sketch mode, undone ---------------------

ROW = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
ROW.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12})
ROW.update({str(i): i + 1 for i in range(1, 10)})


class Win:
    """BeeModel in the fake compositor (tests/wl_fake.py), pinned; the keys
    typed as US codes (no keymap is sent)."""

    def __init__(self, binary):
        import wl_fake

        class F(wl_fake.Fake):
            def move(self, x, y):
                self.motion(x, y)

            def type(self, text):
                for c in text:
                    if c == '_':
                        self.key(12, 1)
                    elif c.isupper():
                        self.key(ROW[c.lower()], 1)
                    else:
                        self.key(ROW[c])

            def click(self, x, y, b=0x110):
                wl_fake.Fake.click(self, x, y, b)
        self.home = tempfile.mkdtemp(dir=T, prefix='h')
        self.f = F(binary, size=(1280, 800), env={'HOME': self.home})
        os.sched_setaffinity(self.f.proc.pid, {int(CPU)})
        self.f.until(lambda: self.f.frames > 0 and self.f.keyboard is not None and self.f.pointer is not None, 20)
        self.f.pump(1.0)
        self.f.enter(600, 350)
        self.f.move(600, 350)
        self.f.pump(0.3)
        self.n = 0

    def line(self, c):
        f = self.f
        f.key(28); f.pump(0.1); f.type(c); f.key(28); f.pump(0.5); f.key(1); f.pump(0.1)

    def maxi(self):
        f = self.f
        f.move(600, 350); f.pump(0.2)
        f.key(57, 4); f.pump(0.4)

    def save(self):
        p = f'{self.home}/s{self.n}.bee'
        self.n += 1
        self.line(f'file.save {p}')
        t0 = time.time()
        while not os.path.exists(p) and time.time() - t0 < 60:
            self.f.pump(0.1)
        self.f.pump(0.2)
        return p

    def frame(self):
        s = self.f.surfaces[self.f.main().surface]
        bf = self.f.buffers[s['last']]
        return bf['stride'] // 4, bf['h'], bytes(s['pixels'])

    def close(self):
        self.f.proc.kill()
        self.f.proc.wait()


def frame_diff(a, b, box, tol=12):
    wd, h, pa = a
    _, _, pb = b
    n = 0
    for y in range(box[1], box[3], 2):
        for x in range(box[0], box[2], 2):
            o = (y * wd + x) * 4
            if max(abs(pa[o + i] - pb[o + i]) for i in range(3)) > tol:
                n += 1
    return n


def s_window():
    print('-- the window: a sketch drawn, padded from the console, a line dimensioned in sketch mode (the part follows), undo, redo --')
    steps = ['drawn and padded', 'a line dimensioned in sketch mode', 'Ctrl+Z', 'Ctrl+Shift+Z']

    def run(binary):
        w = Win(binary)
        snaps, frames = [], []
        try:
            f = w.f
            w.line('cad.sketch S XY 0')
            w.maxi()
            f.key(79); f.pump(1.2)                 # Numpad 1: the front
            f.key(19); f.pump(0.2)                 # R
            f.click(400, 250); f.pump(0.3)
            f.click(560, 380); f.pump(0.4)
            f.key(1); f.pump(0.2)                  # Esc: the tool
            f.key(38); f.pump(0.2)                 # L: a line on its own (to pick the sketch by)
            f.click(700, 250); f.pump(0.3); f.click(820, 250); f.pump(0.3)
            f.key(1); f.pump(0.2); f.key(1); f.pump(0.3)   # Esc: the tool, then sketch mode
            w.maxi()
            w.line('cad.pad Body 1 reverse')
            snaps.append(w.save())
            w.maxi()
            f.click(760, 250); f.pump(0.3)         # the sketch, by its line
            f.move(600, 350); f.pump(0.5)
            frames.append(w.frame())               # (the view before, the sketch selected)
            f.key(15); f.pump(0.3)                 # Tab: sketch mode on S
            f.click(480, 250); f.pump(0.3)         # its top line
            w.maxi()
            f.key(32); f.pump(0.4)                 # D: the command line, prefilled
            f.type('3'); f.key(28); f.pump(0.6); f.key(1); f.pump(0.2)
            w.maxi()
            f.key(1); f.pump(0.2); f.key(1); f.pump(0.2)   # Esc: the selection, then sketch mode
            f.move(600, 350); f.pump(0.5)
            frames.append(w.frame())
            w.maxi()
            snaps.append(w.save())
            w.maxi()
            f.move(600, 350); f.pump(0.2)
            f.key(44, 4); f.pump(0.6)
            f.move(601, 350); f.pump(0.5)
            frames.append(w.frame())
            w.maxi()
            snaps.append(w.save())
            w.maxi()
            f.move(600, 350); f.pump(0.2)
            f.key(44, 5); f.pump(0.6)
            f.move(601, 350); f.pump(0.5)
            frames.append(w.frame())
            w.maxi()
            snaps.append(w.save())
            return snaps, frames
        finally:
            w.close()
    pa, pf = run(BIN)
    if os.environ.get('FT_KEEP'):
        from PIL import Image
        for k, (wd, h, px) in enumerate(pf):
            Image.frombytes('RGBA', (wd, h), px, 'raw', 'BGRA').convert('RGB').save(f'{os.environ["FT_KEEP"]}/win_p{k}.png')
    ok = len(pa) == 4 and all(os.path.exists(a) for a in pa)
    check(ok, f'the four scenes saved from the window ({len(pa)})')
    if not ok:
        return
    for k, a in enumerate(pa):
        st = stats(cadd(a))
        check(st is not None and st == [0], f'{steps[k]}: the pad built (statuses {st})')
    ma = [objmeshes(a) for a in pa]
    check(ma[0].get('Body') is not None and ma[0]['Body'] != ma[1]['Body'] and ma[2]['Body'] == ma[0]['Body'] and ma[3]['Body'] == ma[1]['Body'],
          'the dimension changed the part; Ctrl+Z gave it back, Ctrl+Shift+Z the changed one again')
    # the view follows: after Ctrl+Z the viewport shows what it showed before the change
    box = (200, 120, 900, 600)
    if len(pf) == 4:
        d1, d2, d3 = frame_diff(pf[0], pf[1], box), frame_diff(pf[0], pf[2], box), frame_diff(pf[1], pf[3], box)
        check(d1 > 50 and d2 < d1 // 10 and d3 < d1 // 10, f'the viewport after the edit differs ({d1} px), after Ctrl+Z it is as before ({d2} px), after Ctrl+Shift+Z as after ({d3} px)')


# ---- random sessions, no crash, no hang -----------------------------------------

def s_fuzz():
    print('-- random sessions of feature operators with odd arguments, undo, redo, files (no crash, no hang) --')
    rng = random.Random(SEED + 7)
    base = f'{T}/zbase.bee'
    L = ['op("file.new")', 'param("w", "1.2")', 'param("h", "1.5")'] + sketch_lines(random.Random(3), 'S0') + sketch_lines(random.Random(4), 'S1')
    orig_eval('\n'.join(L + [f'op("file.save_as", "{base}")']))
    words = ['Body', 'Part', 'S0', 'S1', 'Cube', 'Light', '"a b"', '', 'x' * 40]
    vals = ['1', '0', '-1', 'h', '2*w', 'nosuch', '1/0', '1e300', 'nan', '"1 + 1"', '0.001', '360deg', '-1e9', '', '"' + 'x' * 33 + '"']
    modes = ['normal', 'symmetric', 'reverse', 'through', 'bottom', 'u', 'v', 'x', 'q', '']
    sels = ['all', 'vertical', 'horizontal', 'top', 'bottom', 'zz', '']
    crashed = []
    for run in range(max(4, RUNS // 4)):
        args = ['--op', f'file.open {base}']
        for _ in range(30):
            r = rng.random()
            if r < .08:
                args += ['--select', rng.choice(['S0', 'S1', 'Body', 'Cube', 'Light'])]
            elif r < .3:
                t = rng.choice(['pad', 'pocket', 'revolve', 'hole'])
                args += ['--select', rng.choice(['S0', 'S1']), '--op', f'cad.{t} {rng.choice(words)} {rng.choice(vals)} {rng.choice(modes + vals)}']
            elif r < .4:
                args += ['--op', f'cad.{rng.choice(["fillet", "chamfer"])} {rng.choice(vals)} {rng.choice(sels)}']
            elif r < .5:
                args += ['--op', f'cad.shell {rng.choice(["0", "1", "-1", "99", "x", ""])} {rng.choice(vals)} {rng.choice(modes)}']
            elif r < .58:
                args += ['--op', f'cad.pattern {rng.randrange(-1, 6)} {rng.choice([0, 1, 2, 3, 7, -2])} {rng.choice(vals)} {rng.choice("xyzuvq")} {rng.choice(["linear", "circular", "x"])}']
            elif r < .62:
                args += ['--op', f'cad.infill {rng.randrange(-1, 6)} {rng.choice(["gyroid", "grid", "x"])} {rng.choice(["0.8", "1", "0", "-1"])} {rng.choice(["0.1", "0.2", "0"])}']
            elif r < .72:
                args += ['--op', f'feature {rng.randrange(-1, 9)} {rng.randrange(-1, 5)} {rng.choice(vals + ["0", "1"])}']
            elif r < .78:
                args += ['--op', f'cad.feature_move {rng.randrange(-1, 9)} {rng.choice(["up", "down", "x"])}']
            elif r < .84:
                args += ['--op', rng.choice(['edit.undo', 'edit.redo'])]
            elif r < .88:
                args += ['--op', f'param.set {rng.choice(["h", "w"])} {rng.choice(vals)}']
            elif r < .9:
                args += ['--op', f'scene.units {rng.choice(["mm", "cm", "m", "in"])}']
            elif r < .92:
                args += ['--op', f'cad.kernel {rng.choice(["on", "off"])}']
            elif r < .95:
                args += ['--select', rng.choice(['S0', 'S1', 'Body']), '--op', 'object.delete']
            elif r < .97:
                args += ['--op', f'file.save_as {T}/z.bee', '--op', f'file.open {T}/z.bee']
            else:
                args += ['--select', rng.choice(['Body', 'S0']), '--click-label', 'tab:CAD', '--move', '600,300']
        rc = port(*args, timeout=600)
        if rc != 0:
            crashed.append((run, rc, args))
    for run, rc, args in crashed[:3]:
        print(f'      run {run}: exit {rc}: ' + ' '.join(args)[-600:])
    check(not crashed, f'{max(4, RUNS // 4)} random sessions of 30 steps: no crash, no hang ({len(crashed)} not)')


# ---- main ---------------------------------------------------------------------------------

SECTIONS = [s_ops, s_files, s_fail, s_exact, s_errors, s_undo, s_ui, s_template, s_look, s_window, s_perf, s_fuzz]

if __name__ == '__main__':
    print(f'feature: seed {SEED}, runs {RUNS}, binary {BIN}')
    t0 = time.time()
    try:
        for f in SECTIONS:
            if ONLY and f.__name__ not in ONLY:
                continue
            f()
    finally:
        shutil.rmtree(T, ignore_errors=True)
    print(f'feature: {time.time() - t0:.0f} s, fails {len(FAILS)}')
