#!/usr/bin/env python3
"""Features as B-rep solids (bfeat.zig, bfillet.zig: cad.kernel on).

  * s_random: random sketches and feature chains (tests/feature.py's) with the
    kernel on - pads, pockets, revolves, holes, shells, fillets, chamfers,
    patterns, infill, values, parameters, units, suppressing, reordering,
    the switch turned off and on mid-way: each chain run as a BeeScript
    script and as console operators gives the same bodies' MESH (the solids'
    tessellations), CADD chunk with its statuses, file.export_step bytes and
    brep() values; enough solids built, their values finite; the switch off
    at the end leaves no solids.
  * s_fillet: B-rep fillets and chamfers on boxes, L shapes (a concave
    edge), plates with holes, turned parts: each selector, radii up to
    failing, chamfers; the same checks; the kernel rounds and chamfers
    edges, and a chamfer on straight sides makes no round faces.
  * s_words: the console's words (cad.kernel, the export, the features with
    the kernel on): no crash, the export with a solid written, without one
    refused with a word.
  * s_undo: the switch and features undone and redone: each undo gives the
    file saved at that state before, each redo the one after; the export
    after an undo is a fresh build of that state.
  * s_files: scenes saved with the kernel on and opened again (the switch
    kept, the meshes; the solids rebuilt), damaged and odd kernel switches,
    records whose references point anywhere: opened, rebuilt and saved the
    same by a script and by the console.
  * s_window: a window (the fake compositor): the CAD tab's "Exact B-rep
    solids" switch clicked, a sketch drawn, padded, dimensioned in sketch
    mode, undone and redone with the kernel on: the files and the viewport
    after each step.
  * s_perf: the kernel's rebuild of a long tree timed (release builds, one
    CPU; BF_PERF=1 checks it stays interactive), and the view open.
  * s_fuzz: random kernel-on sessions with odd arguments and damaged files:
    no crash, no hang.

    python3 tests/bfeat.py BIN [runs=30] [seed]

BEE_CPU (default 10) pins the window and timing runs; BF_ONLY=s_random,...
runs some sections.
"""
import math, os, random, re, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
os.environ.setdefault('BEE_CPU', '10')
import temphome  # noqa: F401 (a HOME of our own)
import beefile
import feature as F   # (its random sketches and chains)

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 30
SEED = int(sys.argv[3]) if len(sys.argv) > 3 else random.randrange(1 << 30)
CPU = os.environ.get('BEE_CPU', '10')
ONLY = [x for x in os.environ.get('BF_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beebfeat-', dir='/tmp')
ENV = dict(os.environ, HOME=T)


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def bee_eval(code, timeout=1800):
    """A BeeScript script (--eval): (exit code, its output)."""
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--eval', code], capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired:
        return None, 'timeout'


def port(*a, timeout=1800):
    """Console operators, headless (--op, --dump-log, --dump-ui): the exit code."""
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', '--dump-ui', f'{T}/u.txt', *a],
                           capture_output=True, text=True, timeout=timeout, env=ENV)
        return r.returncode
    except subprocess.TimeoutExpired:
        return None


def plog():
    return open(f'{T}/log.txt', errors='replace').read() if os.path.exists(f'{T}/log.txt') else ''


def answers(lines):
    """The console: what each command said, in order ("> cmd" starts one)."""
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
    """Every object's mesh and the CADD chunk, byte for byte: (ok, why)."""
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


QUERIES = ['volume', 'area', 'faces', 'edges', 'vertices', 'loops', 'valid', 'kernel', 'error', 'triangles', 'tessvolume', 'watertight',
           'planes', 'cylinders', 'cones', 'spheres', 'tori', 'nurbs']


# ---- a case is a base scene, steps (as a script and as console operators), then the export, brep() and the file ------

def oprint_brep():
    """BeeScript: every object's brep() values (print takes 16 arguments at most)."""
    return ('for i in 0..count() {\n n = name(i)\n print("N", n)\n'
            '  print("Q", ' + ', '.join(f'brep(n, "{q}")' for q in QUERIES[:9]) + ')\n'
            '  print("R", ' + ', '.join(f'brep(n, "{q}")' for q in QUERIES[9:]) + ')\n}')


def parse_obrep(text):
    """{case: {object: [values as printed]}} from lines "K k", "N name", "Q ...", "R ..."."""
    out, k, cur = {}, None, None
    for ln in text.splitlines():
        if ln.startswith('K '):
            k = int(ln[2:])
            out[k] = {}
        elif ln.startswith('N ') and k is not None:
            cur = ln[2:]
            out[k][cur] = []
        elif ln[:2] in ('Q ', 'R ') and k is not None and cur is not None:
            out[k][cur] += ln.split()[1:]
    return out


def brep_diff(ov_list, got):
    """The largest difference, in units of the last digit the script printed
    (6 decimals, or 7 digits with an exponent), and where."""
    worst, where = 0.0, ''
    for q, ov in zip(QUERIES, ov_list):
        pv = got.get(q, '?')
        if ov == 'nil' or pv in ('nil', '?'):
            e = 0 if ov == pv else 1e9
        else:
            a, b = float(ov), float(pv)
            unit = abs(a) * 1e-6 if 'e' in ov else max(abs(a) * 1e-6, 1e-6)
            e = abs(a - b) / unit * 1e-7
        if e > worst:
            worst, where = e, f'{q} {ov} vs {pv}'
    return worst, where


_names = {}


def F_names(k, tag='f'):
    return _names.get((tag, k), [])


def run_cases(cases, tag):
    """cases: [(base, script lines, console args)]. Each runs from its base as a
    script and as console operators; then the export, brep() of every object,
    the file. -> [(k, why)] differences, the lost ones, counts."""
    for k in range(len(cases)):
        for s in 'op':
            os.makedirs(f'{T}/{tag}{k}{s}', exist_ok=True)
    # each case in a process of its own (brep(.., "error") is the last failed
    # boolean's, whatever case it was in)
    text = ''
    lost = []

    def ocode(k):
        base, S, P = cases[k]
        code = [f'print("K {k}")', f'op("file.open", "{base}")'] + S
        code += [f'op("file.export_step", "{T}/{tag}{k}o/x.step")', oprint_brep(), f'op("file.save_as", "{T}/{tag}{k}o/f.bee")']
        return '\n'.join(code)
    for k in range(len(cases)):
        rc, out = bee_eval(ocode(k), timeout=600)
        text += out + '\n'
        if rc not in (0, 1) or not os.path.exists(f'{T}/{tag}{k}o/f.bee'):
            lost.append((k, rc, out.strip()[-200:]))
    ob = parse_obrep(text)
    for k in ob:
        _names[(tag, k)] = list(ob[k])
    # the console; brep() for the objects the script's file has
    t0 = time.time()
    for k in range(len(cases)):
        base, S, P = cases[k]
        args = ['--op', f'file.open {base}']
        for a, b in P:
            args += [a, b]
        args += ['--op', f'file.export_step {T}/{tag}{k}p/x.step']
        for j, n in enumerate(ob.get(k, {})):
            args += ['--dump-brep', f'{T}/{tag}{k}p/q{j}.txt;{n}']
        args += ['--op', f'file.save_as {T}/{tag}{k}p/f.bee']
        rc = port(*args, timeout=600)
        if rc != 0:
            check(False, f'{tag}: the console run stopped ({rc}) in case {k}')
    tp = time.time() - t0
    bad, nsolid, nstep, nfaces = [], 0, 0, 0
    for k in range(len(cases)):
        if any(x[0] == k for x in lost):
            continue
        why = []
        fo, fp = f'{T}/{tag}{k}o/f.bee', f'{T}/{tag}{k}p/f.bee'
        ok, w = same_files(fo, fp, f'case {k}')
        if not ok:
            why.append(w)
        so = f'{T}/{tag}{k}o/x.step'
        sp = f'{T}/{tag}{k}p/x.step'
        a = open(so, 'rb').read() if os.path.exists(so) else None
        b = open(sp, 'rb').read() if os.path.exists(sp) else None
        if a != b:
            why.append(f'STEP export ({len(a or b"")} / {len(b or b"")} bytes)')
        elif a:
            nstep += 1
        for j, n in enumerate(ob.get(k, {})):
            q = f'{T}/{tag}{k}p/q{j}.txt'
            got = dict(ln.split(' ', 1) for ln in open(q).read().splitlines()) if os.path.exists(q) else {}
            got = {x: y.strip() for x, y in got.items()}
            worst, where = brep_diff(ob[k][n], got)
            if worst > 0.5e-7:
                why.append(f'brep({n}): {where}')
            if got.get('kernel') == '1e0':
                nsolid += 1
                nfaces += int(float(got.get('faces', '0')))
                bad_v = [x for x in ('volume', 'area', 'faces') if not (math.isfinite(float(got.get(x, 'nan'))) and float(got.get(x, 'nan')) > 0)]
                if bad_v:
                    why.append(f'brep({n}): a solid with {", ".join(f"{x} {got.get(x)}" for x in bad_v)}')
        # the switch off at the end: no solids
        sw = [x for x in S_of(cases[k]) if x.startswith('op("cad.kernel"')]
        if sw and sw[-1].endswith('"off")') and any(_kern(f'{T}/{tag}{k}p/q{j}.txt') for j in range(len(ob.get(k, {})))):
            why.append('the switch off at the end, yet a solid')
        if why:
            bad.append((k, '; '.join(why)))
    for k, rc, out in lost:
        print(f'  info  {tag} case {k}: the script did not finish it (exit {rc}: {out!r})')
    crashed = [(k, rc) for k, rc, _ in lost if rc not in (0, 1)]
    check(not crashed, f'{tag}: every script ends cleanly (a result or a script error){": not " + str(crashed) if crashed else ""}')
    return bad, lost, nsolid, nstep, nfaces, tp


def S_of(case):
    return case[1]


def _kern(q):
    try:
        return dict(ln.split(' ', 1) for ln in open(q).read().splitlines()).get('kernel', '').strip() == '1e0'
    except OSError:
        return False


# ---- random chains with the kernel on -----------------------------------------------------------

def kchain(rng, nsk):
    """A random chain the kernel can mostly build: a pad first, then pockets,
    holes, pads, revolves, shells, fillets and chamfers by selector, patterns,
    values and parameters changed; now and then a feature it cannot do."""
    S, P = [], []
    n = 0
    kinds = []

    def emit(s, p):
        S.append(s)
        P.extend(p)
    made = []
    for step in range(rng.randrange(2, 8)):
        b = rng.choice(made) if made else 'Body'
        r = rng.random()
        sk = f'S{rng.randrange(nsk)}'
        if n == 0 or r < .4:
            t = 'pad' if n == 0 else rng.choice(['pad', 'pocket', 'pocket', 'hole', 'revolve'])
            if t == 'revolve':
                v, m = rng.choice(['360deg', '90deg', '180deg', '-90deg']), rng.choice(['u', 'v'])
            elif t == 'hole':
                v, m = str(F.rnd(rng, 0.1, 0.5)), rng.choice(['', str(F.rnd(rng, 0.2, 2))])
            elif t == 'pocket':
                v, m = rng.choice([str(F.rnd(rng, 0.2, 1.5)), 'h/2']), rng.choice(['normal', 'through', 'symmetric', 'reverse'])
            else:
                v, m = rng.choice([str(F.rnd(rng, 0.3, 2.5)), 'h', 'w+0.5']), rng.choice(['normal', 'symmetric', 'reverse'])
            bb = b if rng.random() < .85 else 'Part'
            if t == 'hole':
                d = f', "{m}"' if m else ''
                emit(f'_ = hole("{bb}", "{sk}", "{v}"{d})', [('--select', sk), ('--op', f'cad.hole {bb} {v} {m}'.rstrip())])
            else:
                emit(f'_ = {t}("{bb}", "{sk}", "{v}", "{m}")', [('--select', sk), ('--op', f'cad.{t} {bb} "{v}" {m}')])
            kinds.append(t)
            n += 1
            if bb not in made:
                made.append(bb)
        elif r < .55:
            t = rng.choice(['fillet', 'chamfer'])
            v = rng.choice(['0.05', '0.1', str(F.rnd(rng, 0.02, 0.3)), '0.8'])
            e = rng.choice(['vertical', 'vertical', 'top', 'bottom', 'horizontal', 'all'])
            emit(f'_ = {t}("{b}", "{v}", "{e}")', [('--select', b), ('--op', f'cad.{t} {v} {e}')])
            kinds.append(t)
            n += 1
        elif r < .63 and 'pad' in kinds and b == 'Body':
            ref = kinds.index('pad')
            wall = rng.choice([str(F.rnd(rng, 0.05, 0.3)), '0.1'])
            m = rng.choice(['normal', 'bottom'])
            emit(f'_ = shell("{b}", {ref}, "{wall}", "{m}")', [('--select', b), ('--op', f'cad.shell {ref} {wall} {m}')])
            kinds.append('shell')
            n += 1
        elif r < .73:
            ref = rng.randrange(n)
            cnt = rng.randrange(2, 4)
            circ = rng.choice(['linear', 'circular'])
            st = str(F.rnd(rng, 0.5, 3)) if circ == 'linear' else rng.choice(['0', '90deg', '1.5'])
            ax = rng.choice('xyz')
            emit(f'_ = pattern("{b}", {ref}, {cnt}, "{st}", "{ax}", "{circ}")', [('--select', b), ('--op', f'cad.pattern {ref} {cnt} {st} {ax} {circ}')])
            kinds.append('pattern')
            n += 1
        elif r < .83:
            k = rng.randrange(n)
            v = F.value(rng, 0.1, 2)
            emit(f'_ = feature({k}, 0, "{v}")', [('--op', f'feature {k} 0 "{v}"')])
        elif r < .87:
            k, on = rng.randrange(n), rng.choice([0, 1])
            emit(f'_ = feature({k}, 3, {on})', [('--op', f'feature {k} 3 {on}')])
        elif r < .9:
            k = rng.randrange(n)
            d = rng.choice(['up', 'down'])
            emit(f'op("cad.feature_move", "{k} {d}")', [('--op', f'cad.feature_move {k} {d}')])
        elif r < .97:
            p = rng.choice(['h', 'w'])
            v = rng.choice(['1.5', '2', '0.7', '1', '0.8'])
            emit(f'param("{p}", "{v}")', [('--op', f'param.set {p} {v}')])
        else:
            u = rng.choice(['mm', 'cm', 'm', 'in'])
            emit(f'op("scene.units", "{u}")', [('--op', f'scene.units {u}')])
    return S, P


FX_BASE = ['param("w", "1.2")', 'param("h", "1.5")',
           'a = sketch("A", "XZ")', 'r = rect(a, -1, -1, 2, 1.6)', '_ = circle(a, 0, -0.2, 0.25)', '_ = point(a, -0.6, -0.6)', '_ = point(a, 0.6, 0.3)',
           'b = sketch("B", "XZ", 1)', 'r = rect(b, -0.5, -0.7, 0.8, 0.8)',
           'c = sketch("C", "XY")', 'r = rect(c, 0.5, 0, 0.6, 0.8)',
           'd = sketch("D", "XZ")', 'r = rect(d, -0.3, -0.3, 0.6, 0.6)', 'move("D", 0.3, 0.2, -0.1)', 'rotate("D", 0, 30, 0)']


def fx(*steps):
    """A fixed chain from (script line, console steps) pairs."""
    return [x[0] for x in steps], [y for x in steps for y in x[1]]


def f_(kind, body, sk, v, m=''):
    q = f', "{m}"' if m else ''
    return (f'_ = {kind}("{body}", "{sk}", "{v}"{q})', [('--select', sk), ('--op', f'cad.{kind} {body} "{v}" {m}'.rstrip())])


def g_(kind, body, *args):
    sa = ', '.join(f'"{a}"' if isinstance(a, str) else str(a) for a in args)
    return (f'_ = {kind}("{body}", {sa})', [('--select', body), ('--op', f'cad.{kind} ' + ' '.join(str(a) for a in args))])


FIXED_CHAINS = [
    fx(f_('pad', 'Body', 'A', 'h', 'normal'), f_('pocket', 'Body', 'B', '0.4', 'normal')),
    fx(f_('pad', 'Body', 'A', 'h', 'symmetric'), ('_ = hole("Body", "A", "0.2")', [('--select', 'A'), ('--op', 'cad.hole Body 0.2')])),
    fx(f_('pad', 'Body', 'A', '1', 'normal'), g_('shell', 'Body', 0, '0.1', 'normal')),
    fx(f_('pad', 'Body', 'A', '1', 'reverse'), g_('shell', 'Body', 0, '0.1', 'bottom')),
    fx(f_('revolve', 'Part', 'C', '60deg', 'v'), g_('pattern', 'Part', 0, 4, '0', 'y', 'circular')),
    fx(f_('pad', 'Body', 'A', '0.5', 'normal'), f_('pocket', 'Body', 'D', '0.2', 'through'), g_('pattern', 'Body', 1, 3, '0.5', 'x', 'linear')),
    fx(f_('pad', 'Body', 'A', '0.5', 'normal'), f_('revolve', 'Part', 'C', '360deg', 'v'), g_('pattern', 'Body', 1, 2, '0.5', 'x', 'linear')),
    fx(f_('pad', 'Body', 'D', '0.8', 'symmetric'), f_('revolve', 'Part', 'C', '270deg', 'v'), g_('chamfer', 'Body', '0.05', 'vertical')),
    fx(('op("file.import_step", "#STEP")', [('--op', 'file.import_step #STEP')]), f_('pad', 'Body', 'D', '0.8', 'normal'),
       f_('pocket', 'Body', 'B', '0.3', 'reverse')),
]


def kernel_chain(rng, nsk):
    S, P = (kchain if rng.random() < .75 else F.chain)(rng, nsk)
    # the switch: on first, or after the tree (the rebuild then makes the solids); now and then off and on
    where = 0 if rng.random() < .7 else len(S)
    S.insert(where, 'op("cad.kernel", "on")')
    # (the console's steps: find where that is in P: each S line is one --op, with a --select before features)
    Pi = port_index(P, where)
    P[Pi:Pi] = [('--op', 'cad.kernel on')]
    if rng.random() < .2 and len(S) > 2:
        w = rng.randrange(1, len(S))
        S.insert(w, 'op("cad.kernel", "off")')
        Pi = port_index(P, w)
        P[Pi:Pi] = [('--op', 'cad.kernel off')]
        if rng.random() < .6:
            S.append('op("cad.kernel", "on")')
            P.append(('--op', 'cad.kernel on'))
    return S, P


def port_index(P, n):
    """The index in the console's steps where the n-th script line's steps start
    (each line is one --op, maybe after one --select)."""
    k, i = 0, 0
    while i < len(P) and k < n:
        if P[i][0] == '--select':
            i += 1
        i += 1
        k += 1
    return i


def make_bases(lines_list):
    paths = []
    for lo in range(0, len(lines_list), 20):
        code = []
        for k in range(lo, min(lo + 20, len(lines_list))):
            p, bl = lines_list[k]
            code += ['op("file.new")'] + bl + [f'op("file.save_as", "{p}")']
            paths.append(p)
        bee_eval('\n'.join(code))
    return all(os.path.exists(p) for p in paths)


def s_random():
    print('-- random sketches and feature chains with the kernel on, by a script and by the console: meshes, CADD, STEP, brep() --')
    rng = random.Random(SEED)
    cases, bl = [], []
    for k in range(RUNS):
        b, nsk = F.base_for(rng, k)
        base = f'{T}/rb{k}.bee'
        bl.append((base, b))
        S, P = kernel_chain(rng, nsk)
        cases.append((base, S, P))
    # and fixed ones: each feature kind the kernel builds, placed sketches, two bodies, an
    # imported part beside them; the switch turned off again, never turned on
    fx = f'{T}/rfx.bee'
    bl.append((fx, FX_BASE))
    bee_eval('\n'.join(['op("file.new")', 's = sketch("A", "XZ")', 'r = rect(s, -1, -1, 2, 1.6)', 'op("cad.kernel", "on")',
                          '_ = pad("Imp", "A", "0.4", "normal")', f'op("file.export_step", "{T}/rfx.step")']))
    for S, P in FIXED_CHAINS:
        S = [x.replace('#STEP', f'{T}/rfx.step') for x in S]
        P = [(a, b.replace('#STEP', f'{T}/rfx.step')) for a, b in P]
        cases.append((fx, ['op("cad.kernel", "on")'] + S, [('--op', 'cad.kernel on')] + P))
    b0 = bl[0][0]
    cases.append((b0, ['op("cad.kernel", "on")', '_ = pad("Body", "S0", "1", "normal")', 'op("cad.kernel", "off")'],
                  [('--op', 'cad.kernel on'), ('--select', 'S0'), ('--op', 'cad.pad Body "1" normal'), ('--op', 'cad.kernel off')]))
    cases.append((b0, ['_ = pad("Body", "S0", "1", "normal")', '_ = pocket("Body", "S0", "0.3", "through")'],
                  [('--select', 'S0'), ('--op', 'cad.pad Body "1" normal'), ('--select', 'S0'), ('--op', 'cad.pocket Body "0.3" through')]))
    check(make_bases(bl), f'a script made the {len(bl)} base scenes')
    bad, lost, nsolid, nstep, nfaces, tp = run_cases(cases, 'r')
    for k, why in bad:
        check(False, f'chain {k}: {why}\n      ' + ' | '.join(cases[k][1]))
    check(len(lost) <= max(1, len(cases) // 10), f'the script finished {len(cases) - len(lost)} of {len(cases)} chains')
    check(not bad and nsolid >= len(cases) // 4 and nstep >= len(cases) // 5,
          f'{len(cases) - len(lost) - len(bad)} of {len(cases) - len(lost)} chains the same from a script and the console: {nsolid} solids ({nfaces} faces), {nstep} STEP exports byte for byte (console {tp:.0f} s)')


# ---- fillets and chamfers ------------------------------------------------------------------------

FILLET_BASES = {
    'box': ['s = sketch("S", "XZ")', 'r = rect(s, -1, -0.5, 2, 1)'],
    'ell': ['s = sketch("S", "XZ")', '_ = line(s, 0, 0, 2, 0)', '_ = line(s, 2, 0, 2, 1)', '_ = line(s, 2, 1, 1, 1)', '_ = line(s, 1, 1, 1, 2)',
            '_ = line(s, 1, 2, 0, 2)', '_ = line(s, 0, 2, 0, 0)'],
    'plate': ['s = sketch("S", "XY")', 'r = rect(s, 0, 0, 3, 2)', '_ = circle(s, 1.5, 1, 0.4)', '_ = point(s, 0.5, 0.5)'],
    'tilt': ['s = sketch("S", "YZ", 0.3)', '_ = line(s, 0, 0, 2, 0.3)', '_ = line(s, 2, 0.3, 1.5, 1.8)', '_ = line(s, 1.5, 1.8, -0.2, 1.2)',
             '_ = line(s, -0.2, 1.2, 0, 0)', 'rotate("S", 15, 30, 0)', 'move("S", 0.2, -0.1, 0.4)'],
    'blunt': ['s = sketch("S", "XZ")', '_ = line(s, 0, 0, 2, 0)', '_ = line(s, 2, 0, 2, 1)', '_ = line(s, 2, 1, 1, 1.05)', '_ = line(s, 1, 1.05, 0, 1)',
              '_ = line(s, 0, 1, 0, 0)'],
    'disc': ['s = sketch("S", "XZ")', '_ = circle(s, 0, 0, 1)', 't = sketch("T", "XZ", 0.5)', 'r = rect(t, -0.3, -0.3, 0.6, 0.6)'],
}


FIXED_FILLETS = [  # (cases the kernel rounds: a box's vertical edges, with a pocket, a tilted prism's)
    ('box', ['op("cad.kernel", "on")', '_ = pad("Body", "S", "1", "normal")', '_ = fillet("Body", "0.1", "vertical")'],
     [('--op', 'cad.kernel on'), ('--select', 'S'), ('--op', 'cad.pad Body 1 normal'), ('--select', 'Body'), ('--op', 'cad.fillet 0.1 vertical')]),
    ('box', ['op("cad.kernel", "on")', '_ = pad("Body", "S", "0.6", "symmetric")', '_ = fillet("Body", "0.3", "vertical")', '_ = chamfer("Body", "0.05", "top")'],
     [('--op', 'cad.kernel on'), ('--select', 'S'), ('--op', 'cad.pad Body 0.6 symmetric'), ('--select', 'Body'), ('--op', 'cad.fillet 0.3 vertical'),
      ('--select', 'Body'), ('--op', 'cad.chamfer 0.05 top')]),
    ('tilt', ['op("cad.kernel", "on")', '_ = pad("Body", "S", "1", "normal")', '_ = fillet("Body", "0.1", "all")'],
     [('--op', 'cad.kernel on'), ('--select', 'S'), ('--op', 'cad.pad Body 1 normal'), ('--select', 'Body'), ('--op', 'cad.fillet 0.1 all')]),
    ('blunt', ['op("cad.kernel", "on")', '_ = pad("Body", "S", "1", "normal")', '_ = fillet("Body", "0.1", "vertical")'],
     [('--op', 'cad.kernel on'), ('--select', 'S'), ('--op', 'cad.pad Body 1 normal'), ('--select', 'Body'), ('--op', 'cad.fillet 0.1 vertical')]),
    ('disc', ['op("cad.kernel", "on")', '_ = pad("Body", "T", "1", "normal")', '_ = fillet("Body", "0.1", "vertical")', '_ = feature(1, 0, "w")'],
     [('--op', 'cad.kernel on'), ('--select', 'T'), ('--op', 'cad.pad Body 1 normal'), ('--select', 'Body'), ('--op', 'cad.fillet 0.1 vertical'),
      ('--op', 'feature 1 0 "w"')]),
]


def fillet_cases(rng):
    out = list(FIXED_FILLETS)
    for name, base in FILLET_BASES.items():
        for _ in range(max(3, RUNS // 4)):
            S, P = [], []

            def feat(s, p, act):
                S.append(s)
                P.extend([('--select', act), ('--op', p)])
            S.append('op("cad.kernel", "on")')
            P.append(('--op', 'cad.kernel on'))
            d = rng.choice(['1', '0.6', '2'])
            md = rng.choice(['normal', 'reverse', 'symmetric'])
            feat(f'_ = pad("Body", "S", "{d}", "{md}")', f'cad.pad Body {d} {md}', 'S')
            nf = 1
            if name == 'disc' and rng.random() < .7:
                feat('_ = pocket("Body", "T", "0.4", "normal")', 'cad.pocket Body 0.4 normal', 'T')
                nf += 1
            if name == 'plate' and rng.random() < .5:
                feat('_ = hole("Body", "S", "0.2")', 'cad.hole Body 0.2', 'S')
                nf += 1
            for _ in range(rng.choice([1, 1, 2])):
                t = rng.choice(['fillet', 'chamfer'])
                # (the kernel rounds edges that do not meet: vertical ones of an upright
                # prism; a rim's edges meet at its corners and fall back to the mesh)
                v = rng.choice(['0.05', '0.1', '0.2', '0.12', '0.3', 'w', '0.45', '0.7', '1.5', '0', '-0.1'][:9 if rng.random() < .8 else 11])
                e = rng.choice(['vertical'] * 5 + ['all', 'horizontal', 'top', 'bottom'])
                feat(f'_ = {t}("Body", "{v}", "{e}")', f'cad.{t} {v} {e}', 'Body')
                nf += 1
            if rng.random() < .3:
                v = rng.choice(['0.3', '0.08', '2*w'])
                S.append(f'_ = feature({nf - 1}, 0, "{v}")')
                P.append(('--op', f'feature {nf - 1} 0 "{v}"'))
            out.append((name, S, P))
    return out


def s_fillet():
    print('-- B-rep fillets and chamfers: boxes, an L (a concave edge), a plate with holes, a tilted prism, a disc: every selector --')
    rng = random.Random(SEED + 1)
    fc = fillet_cases(rng)
    bl = []
    cases = []
    for k, (name, S, P) in enumerate(fc):
        base = f'{T}/fb_{name}.bee'
        if not any(b[0] == base for b in bl):
            bl.append((base, ['param("w", "0.15")'] + FILLET_BASES[name]))
        cases.append((base, S, P))
    check(make_bases(bl), f'a script made the {len(bl)} base scenes')
    bad, lost, nsolid, nstep, nfaces, tp = run_cases(cases, 'f')
    for k, why in bad:
        check(False, f'{fc[k][0]} {k}: {why}\n      ' + ' | '.join(fc[k][1]))
    # how many bodies the kernel rounded (cylinders on a solid from a box, an L, a plate's sides);
    # a chamfer alone on straight sides (no hole, pocket or fillet) makes no round face
    rounded = cut = 0
    roundcham = []
    for k in range(len(cases)):
        for j, n in enumerate(F_names(k)):
            if n != 'Body':
                continue
            q = f'{T}/f{k}p/q{j}.txt'
            got = dict(l.split() for l in open(q)) if os.path.exists(q) else {}
            if got.get('kernel') != '1e0':
                continue
            S = fc[k][1]
            if any('fillet(' in x for x in S) and fc[k][0] in ('box', 'ell', 'tilt', 'blunt') and float(got['cylinders']) > 0:
                rounded += 1
            if any('chamfer(' in x for x in S) and float(got['faces']) > 6 and fc[k][0] in ('box', 'ell', 'tilt'):
                cut += 1
            if fc[k][0] in ('box', 'ell', 'tilt', 'blunt') and any('chamfer(' in x for x in S) and not any(w in x for x in S for w in ('fillet(', 'hole(', 'pocket(', 'revolve(')) \
                    and float(got['cylinders']) + float(got['cones']) + float(got['tori']) + float(got['nurbs']) > 0:
                roundcham.append(k)
    check(not bad and not lost and nsolid > len(cases) // 3,
          f'{len(cases) - len(bad)} of {len(cases)} fillet / chamfer cases the same from a script and the console: {nsolid} solids, {nstep} exports; the kernel rounded {rounded}, chamfered {cut} (console {tp:.0f} s)')
    check(rounded > 0 and cut > 0, f'the kernel rounded ({rounded}) and chamfered ({cut}) edges (not every case fell back to the mesh)')
    check(not roundcham, f'chamfers on straight sides: flat faces only (round ones in cases {roundcham})')


# ---- the console's words ---------------------------------------------------------------------------

WORDS = [('S', 'cad.kernel', 'on'), ('S', 'cad.kernel', 'off'), ('S', 'cad.kernel', 'maybe'), ('S', 'cad.kernel', ''), ('S', 'cad.kernel', 'ON'),
         ('S', 'file.export_step', '#/none.step'), ('S', 'cad.kernel', 'on'), ('S', 'file.export_step', '#/empty.step'),
         ('S', 'cad.pad', 'Body 1 normal'), ('S', 'file.export_step', '#/one.step'), ('Body', 'cad.fillet', '0.1 all'), ('Body', 'cad.fillet', '0.1 vertical'),
         ('Body', 'cad.chamfer', '0.05 top'), ('Body', 'cad.shell', '0 0.1 normal'), ('S', 'cad.hole', 'Body 0.2'), ('S', 'cad.pocket', 'Body 0.5 through'),
         ('S', 'cad.revolve', 'Body 90deg u'), ('Body', 'cad.pattern', '4 3 1 x linear'), ('Body', 'cad.infill', '3 grid 1 0.1'),
         ('Body', 'file.export_step', '#/two.step'), ('S', 'cad.kernel', 'off'), ('S', 'file.export_step', '#/off.step'), ('S', 'cad.kernel', 'on'),
         ('S', 'file.export_step', '#/again.step')]


def s_words():
    print('-- the console\'s words with the kernel on: no crash, the export with a solid written, without one refused --')
    base = f'{T}/wbase.bee'
    bee_eval(f'param("w", "1")\ns = sketch("S", "XY")\nr = rect(s, 0, 0, 4, 2)\n_ = point(s, 1, 1)\nop("file.save_as", "{base}")')
    d = tempfile.mkdtemp(dir=T)
    args = ['--op', f'file.open {base}']
    for act, op, arg in WORDS:
        args += ['--select', act, '--op', f'{op} {arg.replace("#", d)}'.rstrip()]
    rc = port(*args)
    got = answers_after(plog().splitlines(), len(WORDS))
    for c, g in zip(WORDS, got):
        print(f'      {c}: {g}')
    check(rc == 0 and len(got) == len(WORDS), f'{len(got)} of {len(WORDS)} commands run, no crash (exit {rc})')
    step = lambda n: open(f'{d}/{n}', 'rb').read(64) if os.path.exists(f'{d}/{n}') else b''
    check(step('one.step').startswith(b'ISO-10303-21'), 'the export after a pad with the kernel on is a STEP file')
    said = [g for c, g in zip(WORDS, got) if c[1] == 'file.export_step' and c[2] in ('#/none.step', '#/empty.step')]
    check(len(said) == 2 and all(g for g in said) and not step('none.step') and not step('empty.step'), f'with no solid, the export says so and writes nothing ({said})')


def answers_after(lines, n):
    a = answers(lines)
    return a[-n:] if len(a) >= n else a


# ---- undo and redo -----------------------------------------------------------------------------------

UNDO_SEQ = ['cad.kernel on', 'cad.pad Body h normal', 'cad.fillet 0.1 vertical', '#save', 'param.set h 2', '#save', 'cad.kernel off', '#save',
            'edit.undo', '#save', 'edit.undo', '#save', 'edit.undo', '#save', 'edit.redo', 'edit.redo', '#save', 'cad.chamfer 0.05 top', '#save',
            'edit.undo', 'edit.undo', '#save', 'edit.undo', 'edit.undo', 'edit.undo', '#save', 'edit.redo', 'edit.redo', 'edit.redo', '#save']


def s_undo():
    print('-- undo and redo through the switch and features: each step\'s file as the state\'s before; the export after undo --')
    base = f'{T}/ubase.bee'
    bee_eval('\n'.join(['param("h", "1.5")', 's = sketch("S", "XZ")', 'r = rect(s, 0, 0, 4, 2)', '_ = circle(s, 1, 1, 0.3)', 'select("S")',
                        f'op("file.save_as", "{base}")']))
    d = tempfile.mkdtemp(dir=T)
    args = ['--op', f'file.open {base}', '--select', 'S', '--op', f'file.save_as {d}/start.bee']
    n = 0
    for c in UNDO_SEQ:
        if c == '#save':
            args += ['--op', f'file.save_as {d}/u{n}.bee', '--op', f'file.export_step {d}/u{n}.step']
            n += 1
        else:
            args += ['--op', c]
    rc = port(*args)
    check(rc == 0, f'the session runs (exit {rc})')
    got = [(objmeshes(f'{d}/u{k}.bee'), cadd(f'{d}/u{k}.bee')) if os.path.exists(f'{d}/u{k}.bee') else None for k in range(n)]
    start = (objmeshes(f'{d}/start.bee'), cadd(f'{d}/start.bee'))
    kern = lambda g: g and g[1] and g[1][-4] & 1
    # saves: 0 fillet, 1 h=2, 2 kernel off, 3 undo, 4 undo, 5 undo (the pad alone), 6 redo x2,
    # 7 a chamfer, 8 undo x2, 9 undo x3 (as opened), 10 redo x3
    for k, w, what in ((3, 1, 'an undo of the switch: h=2 with the kernel on'), (4, 0, 'an undo of h=2'), (6, 1, 'two redos'),
                       (8, 0, 'the chamfer and h=2 undone'), (10, 0, 'three redos')):
        check(got[k] is not None and got[k] == got[w], f'save {k}: {what}: as save {w} (statuses {stats(got[k][1]) if got[k] else None})')
    check(got[9] is not None and got[9][0] == start[0] and not feats(got[9][1]), f'save 9: everything undone: the scene as opened (features {stats(got[9][1]) if got[9] else None})')
    check(kern(got[0]) and kern(got[1]) and not kern(got[2]) and kern(got[3]), 'the switch on, off, on again after the undo')
    check(got[5] is not None and got[5] != got[4] and got[7] != got[6], 'the fillet undone and the chamfer each change the body')
    # the export: after an undo too, a fresh build of the state shown
    pstep = [open(f'{d}/u{k}.step', 'rb').read() if os.path.exists(f'{d}/u{k}.step') else None for k in range(n)]
    fr = []
    for k in range(n):
        os.makedirs(f'{d}/f{k}', exist_ok=True)
        args = ['--op', f'file.open {d}/u{k}.bee', '--op', 'cad.kernel ' + ('on' if kern(got[k]) else 'off'),
                '--op', f'file.export_step {d}/f{k}/u{k}.step']
        port(*args)
        fr.append(open(f'{d}/f{k}/u{k}.step', 'rb').read() if os.path.exists(f'{d}/f{k}/u{k}.step') else None)
    fresh = [k for k in range(n) if pstep[k] == fr[k]]
    nsol = sum(1 for x in pstep if x)
    print(f'  info  the export as a fresh build of the state at saves {fresh}')
    check(len(fresh) == n and nsol >= 4, f'every export ({nsol} with solids) is what the shown state builds, after undo and redo too')


# ---- files -----------------------------------------------------------------------------------------

def s_files():
    print('-- files with the kernel on: saved, opened again, damaged switches and records --')
    base = f'{T}/fbase.bee'
    bee_eval('\n'.join(['param("h", "1.5")', 's = sketch("S", "XZ")', 'r = rect(s, 0, 0, 3, 2)', '_ = circle(s, 1, 1, 0.3)', 'op("cad.kernel", "on")',
                         '_ = pad("Body", "S", "h", "normal")', '_ = fillet("Body", "0.1", "vertical")', f'op("file.save_as", "{base}")']))
    c = cadd(base)
    check(c is not None and struct.unpack_from('<I', c, len(c) - 4)[0] == 1, 'the file keeps the switch at the end of CADD (1: on)')
    # opened: the meshes as saved; a rebuild makes the solids again (a script and the console)
    d = tempfile.mkdtemp(dir=T)
    code = (f'op("file.open", "{base}")\nprint("A", brep("Body", "kernel"))\nop("file.export_step", "{d}/o0.step")\n'
            f'op("file.save_as", "{d}/o0.bee")\nparam("h", "1.5")\nprint("B", brep("Body", "kernel"), brep("Body", "faces"))\n'
            f'op("file.export_step", "{d}/o1.step")\nop("file.save_as", "{d}/o1.bee")')
    rc, out = bee_eval(code)
    os.makedirs(f'{d}/p', exist_ok=True)
    port('--op', f'file.open {base}', '--dump-brep', f'{d}/qa.txt;Body', '--op', f'file.export_step {d}/p/o0.step', '--op', f'file.save_as {d}/p/o0.bee',
         '--op', 'param.set h 1.5', '--dump-brep', f'{d}/qb.txt;Body', '--op', f'file.export_step {d}/p/o1.step', '--op', f'file.save_as {d}/p/o1.bee')
    lg = plog()
    oa = re.search(r'^A (\S+)', out, re.M)
    ob = re.search(r'^B (\S+) (\S+)', out, re.M)
    qa = dict(l.split() for l in open(f'{d}/qa.txt')) if os.path.exists(f'{d}/qa.txt') else {}
    qb = dict(l.split() for l in open(f'{d}/qb.txt')) if os.path.exists(f'{d}/qb.txt') else {}
    # (opening solves the sketches, and a sketch features use rebuilds the tree: the solids are back)
    s0a = open(f'{d}/o0.step', 'rb').read() if os.path.exists(f'{d}/o0.step') else None
    s0b = open(f'{d}/p/o0.step', 'rb').read() if os.path.exists(f'{d}/p/o0.step') else None
    check(oa and oa.group(1) == '1' and qa.get('kernel') == '1e0' and s0a and s0a == s0b,
          f'opened: the sketches solved rebuild the solid, the export the same from a script and the console ({oa and oa.group(1)} / {qa.get("kernel")}, {len(s0a or b"")} bytes)')
    for k in (0, 1):
        ok, why = same_files(f'{d}/o{k}.bee', f'{d}/p/o{k}.bee', f'opened{" and rebuilt" if k else ""}, by a script and the console')
        check(ok, why)
    sa = open(f'{d}/o1.step', 'rb').read() if os.path.exists(f'{d}/o1.step') else None
    sb = open(f'{d}/p/o1.step', 'rb').read() if os.path.exists(f'{d}/p/o1.step') else None
    check(ob and ob.group(1) == '1' and qb.get('kernel') == '1e0' and float(qb.get('faces', 0)) == float(ob.group(2)) and sa and sa == sb,
          f'a rebuild after opening: the solid again ({ob and ob.groups()}), the export the same ({len(sa or b"")} bytes)')
    # the console's file (kernel on) opened by both, rebuilt, saved
    pf = f'{d}/p/o1.bee'
    rc, out = bee_eval(f'op("file.open", "{pf}")\nprint("K", brep("Body", "kernel"))\nparam("h", "1.2")\nop("file.save_as", "{d}/o2.bee")')
    port('--op', f'file.open {pf}', '--op', 'param.set h 1.2', '--op', f'file.save_as {d}/p/o2.bee')
    ok, why = same_files(f'{d}/o2.bee', f'{d}/p/o2.bee', 'the console\'s file opened by a script and the console and rebuilt')
    check(ok and re.search(r'^K 1', out, re.M) is not None, why + f' (the script\'s solid from it: {re.findall(r"^K (\S+)", out, re.M)})')
    # the meshes kept in the file are the solid's tessellation, not the mesh replay's
    off = f'{T}/fbase_off.bee'
    bee_eval(f'op("file.open", "{base}")\nop("cad.kernel", "off")\nop("file.save_as", "{off}")')
    check(objmeshes(base)['Body'] != objmeshes(off)['Body'], 'the file keeps the tessellation (it differs from the mesh replay\'s)')
    # damaged and odd switches, damaged records: a script and the console open them, rebuild (a parameter), save
    rng = random.Random(SEED + 3)
    chs = list(beefile.chunks(base))
    cases = []
    for k in range(max(8, RUNS // 2)):
        out = []
        for t, ch in chs:
            if t == b'CADD':
                ch = bytearray(ch)
                r = rng.random()
                if r < .25:
                    struct.pack_into('<I', ch, len(ch) - 4, rng.choice([0, 1, 2, 3, 0xffffffff, 0x80000001]))
                elif r < .4:
                    ch = ch[:rng.randrange(8, len(ch))]
                elif r < .55:
                    ch = ch[:-4]   # (an older file: no switch)
                elif r < .8:
                    # a record's fields: type, body, sketch, reference (the selector), count
                    np_ = struct.unpack_from('<I', ch, 8)[0]
                    o = 12 + np_ * 128
                    nf = struct.unpack_from('<I', ch, o)[0]
                    if nf:
                        f = o + 4 + rng.randrange(nf) * 128
                        fld = rng.choice([0, 4, 8, 12, 12, 16, 20, 28])
                        struct.pack_into('<I', ch, f + fld, rng.choice([0, 1, 2, 3, 5, 6, 7, 9, 64, 0xffffffff, rng.randrange(1 << 32)]))
                else:
                    for _ in range(rng.randrange(1, 6)):
                        i = rng.randrange(12, len(ch))
                        ch[i] = rng.randrange(256)
                ch = bytes(ch)
            out.append((t, ch))
        p = f'{T}/fd{k}.bee'
        open(p, 'wb').write(build(out))
        cases.append((p, ['param("h", "1.5")'], [('--op', 'param.set h 1.5')]))
    # every record's body the sketch's uid: the sketch object's own display is left alone
    out = []
    uids = list(struct.unpack_from(f'<{struct.unpack_from("<I", beefile.chunk(base, b"UIDS"), 0)[0]}I', beefile.chunk(base, b'UIDS'), 4))
    su = uids[[o['name'] for o in beefile.objects(base)].index('S')]
    for t, ch in chs:
        if t == b'CADD':
            ch = bytearray(ch)
            np_ = struct.unpack_from('<I', ch, 8)[0]
            o = 12 + np_ * 128
            for r in range(struct.unpack_from('<I', ch, o)[0]):
                struct.pack_into('<I', ch, o + 4 + r * 128 + 4, su)
            ch = bytes(ch)
        out.append((t, ch))
    open(f'{T}/fdsk.bee', 'wb').write(build(out))
    cases.append((f'{T}/fdsk.bee', ['param("h", "1.5")'], [('--op', 'param.set h 1.5')]))
    bad, lost, nsolid, nstep, nfaces, tp = run_cases(cases, 'd')
    k = len(cases) - 1
    ms, mo = objmeshes(f'{T}/fdsk.bee'), objmeshes(f'{T}/d{k}p/f.bee')
    check(ms is not None and mo is not None and ms.get('S') == mo.get('S'), 'a sketch named as the body: the sketch\'s own display kept')
    for k, why in bad:
        check(False, f'damaged file {k}: {why}')
    check(not bad and len(lost) <= max(1, len(cases) // 10), f'{len(cases) - len(bad) - len(lost)} of {len(cases) - len(lost)} damaged files opened and rebuilt the same by a script and the console ({nsolid} solids)')


# ---- the window ---------------------------------------------------------------------------------------

def checkbox_rect():
    """The CAD tab's switch, from --dump-ui (a window at the same size lays out the same)."""
    port('--op', 'cad.sketch S XY 0', '--key', 'esc', '--click-label', 'tab:CAD', '--move', '600,300')
    for ln in open(f'{T}/u.txt', errors='replace').read().splitlines():
        p = ln.split('\t')
        if len(p) >= 3 and p[0] == 'checkbox' and p[1] == 'Exact B-rep solids':
            x, y, w, h = map(int, p[2].split())
            return x, y, w, h
    return None


KEYS = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
KEYS.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12, '=': 13})
KEYS.update({str(i): i + 1 for i in range(1, 10)})


class Win:
    """BeeModel in the fake compositor (tests/wl_fake.py), at the size of a --shot run."""

    def __init__(self, binary):
        from wl_fake import Fake
        self.home = tempfile.mkdtemp(dir=T)
        self.f = Fake(binary, size=(1280, 800), env={'HOME': self.home})
        os.sched_setaffinity(self.f.proc.pid, {int(CPU)})
        self.f.until(lambda: self.f.frames > 0 and self.f.keyboard is not None and self.f.pointer is not None, 10)
        self.f.enter(600, 350)
        self.move(600, 350)
        self.f.pump(0.3)
        self.n = 0

    def move(self, x, y):
        self.f.motion(x, y)

    def type(self, text):
        for c in text:
            if c == '_':
                self.f.key(12, 1)
            elif c == ':':
                self.f.key(39, 1)
            elif c.isupper():
                self.f.key(KEYS[c.lower()], 1)
            else:
                self.f.key(KEYS[c])

    def line(self, c):
        f = self.f
        f.key(28); f.pump(0.1); self.type(c); f.key(28); f.pump(0.5); f.key(1); f.pump(0.1)

    def maxi(self):
        f = self.f
        self.move(600, 350); f.pump(0.2)
        f.mods(4); f.key(57); f.mods(0); f.pump(0.4)

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
        sf = self.f.main().surface
        w, h = [(cw, ch) for s_, cw, ch, _ in self.f.commits if s_ == sf][-1]
        px = self.f.surfaces[sf]['pixels']
        st = len(px) // h
        return w, h, b''.join(px[y * st:y * st + w * 4] for y in range(h))

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
    print('-- a window: the CAD tab\'s switch clicked; a sketch drawn, padded, dimensioned with the kernel on; undo, redo --')
    cb = checkbox_rect()
    check(cb is not None, f'the CAD tab has "Exact B-rep solids" ({cb})')
    if not cb:
        return
    w = Win(BIN)
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
        tab, box = tab_point(BIN), cb
        f.click(*tab); f.pump(0.6)
        w.move(box[0] + 8, box[1] + box[3] // 2); f.pump(0.3)
        f.click(box[0] + 8, box[1] + box[3] // 2); f.pump(0.8)
        w.move(600, 350); f.pump(0.3)
        w.line('cad.pad Body 1 reverse')
        snaps.append(w.save())
        w.maxi()
        f.click(760, 250); f.pump(0.3)         # the sketch, by its line
        w.move(600, 350); f.pump(0.5)
        frames.append(w.frame())
        f.key(15); f.pump(0.3)                 # Tab: sketch mode on S
        f.click(480, 250); f.pump(0.3)         # its top line
        w.maxi()
        f.key(32); f.pump(0.4)                 # D: the command line, prefilled
        w.type('3'); f.key(28); f.pump(0.8); f.key(1); f.pump(0.2)
        w.maxi()
        f.key(1); f.pump(0.2); f.key(1); f.pump(0.2)
        w.move(600, 350); f.pump(0.6)
        frames.append(w.frame())
        w.maxi()
        snaps.append(w.save())
        w.maxi()
        w.move(600, 350); f.pump(0.2)
        f.mods(4); f.key(44); f.mods(0); f.pump(0.8)
        w.move(601, 350); f.pump(0.6)
        frames.append(w.frame())
        w.maxi()
        snaps.append(w.save())
        w.maxi()
        w.move(600, 350); f.pump(0.2)
        f.mods(5); f.key(44); f.mods(0); f.pump(0.8)
        w.move(601, 350); f.pump(0.6)
        frames.append(w.frame())
        w.maxi()
        snaps.append(w.save())
        w.maxi()
        w.move(600, 350); f.pump(0.2)
        for _ in range(3):
            f.mods(4); f.key(44); f.mods(0); f.pump(0.8)
        w.move(601, 350); f.pump(0.6)
        w.maxi()
        snaps.append(w.save())
    finally:
        w.close()
    pa, pf = snaps, frames
    keep = os.environ.get('BF_KEEP')
    if keep:
        from PIL import Image
        for k, (wd, h, px) in enumerate(pf):
            Image.frombytes('RGBA', (wd, h), px, 'raw', 'BGRA').convert('RGB').save(f'{keep}/win_p{k}.png')
    kern = lambda p: (cadd(p) or b'\0\0\0\0')[-4]
    ma = [objmeshes(a) for a in pa]
    ok = len(pa) == 5 and all(ma) and all('Body' in m for m in ma[:4])
    check(ok and kern(pa[0]) == 1 and kern(pa[4]) == 0 and ma[0]['Body'] != ma[1]['Body'] and ma[2]['Body'] == ma[0]['Body'] and ma[3]['Body'] == ma[1]['Body'],
          f'the switch went on; the dimension changed the solid; Ctrl+Z gave it back, Ctrl+Shift+Z the changed one again; undoing the switch turned it off ({len(pa)} saves, kernel {[kern(p) for p in pa]})')
    box = (200, 120, 900, 600)
    if len(pf) == 4:
        d1, d2, d3 = frame_diff(pf[0], pf[1], box), frame_diff(pf[0], pf[2], box), frame_diff(pf[1], pf[3], box)
        check(d1 > 50 and d2 < d1 // 10 and d3 < d1 // 10, f'the viewport after the edit differs ({d1} px), after Ctrl+Z it is as before ({d2} px), after Ctrl+Shift+Z as after ({d3} px)')
    else:
        check(False, f'the viewport: {len(pf)} frames')


_tab = {}


def tab_point(binary):
    """The CAD tab's centre (from --dump-ui)."""
    if 'p' not in _tab:
        port('--op', 'cad.sketch S XY 0', '--key', 'esc', '--move', '600,300')
        for ln in open(f'{T}/u.txt', errors='replace').read().splitlines():
            p = ln.split('\t')
            if len(p) >= 3 and p[1] in ('tab:CAD', 'CAD') and p[0] in ('tab', 'button', 'editor'):
                x, y, w, h = map(int, p[2].split())
                _tab['p'] = (x + w // 2, y + h // 2)
                break
    return _tab.get('p', (0, 0))


# ---- speed ------------------------------------------------------------------------------------------

PERF_BASE = ['param("w", "1.2")', 'param("h", "1.5")', 's = sketch("S", "XZ")', 'r = rect(s, -2, -1, 4, 2)', '_ = circle(s, 0, 0, 0.4)',
             '_ = point(s, -1.2, -0.5)', '_ = point(s, 1.2, 0.5)', 't = sketch("T", "XZ", 1)', 'r2 = rect(t, -1, -0.6, 1.2, 1.2)',
             'u = sketch("U", "XY")', '_ = line(u, 0.5, 0, 1.5, 0)', '_ = line(u, 1.5, 0, 1.5, 0.8)', '_ = line(u, 1.5, 0.8, 0.5, 0)']
PERF_FEATS = [('S', 'cad.pad Body h normal', '_ = pad("Body", "S", "h", "normal")'),
              ('S', 'cad.hole Body 0.2', '_ = hole("Body", "S", "0.2")'),
              ('T', 'cad.pocket Body 0.5 normal', '_ = pocket("Body", "T", "0.5", "normal")'),
              ('Body', 'cad.pattern 2 3 1.3 x linear', '_ = pattern("Body", 2, 3, "1.3", "x", "linear")'),
              ('Body', 'cad.chamfer 0.05 vertical', '_ = chamfer("Body", "0.05", "vertical")'),
              ('U', 'cad.revolve Part 360deg u', '_ = revolve("Part", "U", "360deg", "u")'),
              ('S', 'cad.pad Part 0.3 symmetric', '_ = pad("Part", "S", "0.3", "symmetric")')]


def s_perf():
    print('-- speed: the kernel\'s rebuild of a long tree (whole runs, one CPU; BF_PERF=1 checks it) --')
    base = f'{T}/pbase.bee'
    bee_eval('\n'.join(PERF_BASE + [f'op("file.save_as", "{base}")']))
    K = 8

    def stime(k, on):
        code = [f'op("file.open", "{base}")'] + (['op("cad.kernel", "on")'] if on else []) + [x[2] for x in PERF_FEATS]
        code += [f'param("h", "{1 + 0.1 * (i + 1):.1f}")' for i in range(k)] + [f'op("file.save_as", "{T}/perf_o{k}{on}.bee")']
        t0 = time.time()
        bee_eval('\n'.join(code))
        return time.time() - t0

    def ptime(k, on):
        args = ['--op', f'file.open {base}'] + (['--op', 'cad.kernel on'] if on else [])
        for act, c, _ in PERF_FEATS:
            args += ['--select', act, '--op', c]
        for i in range(k):
            args += ['--op', f'param.set h {1 + 0.1 * (i + 1):.1f}']
        args += ['--op', f'file.save_as {T}/perf_p{k}{on}.bee']
        t0 = time.time()
        port(*args)
        return time.time() - t0

    def best(f, k, on):
        return min(f(k, on) for _ in range(3))
    res = {}
    for on in (0, 1):
        res[on] = (best(ptime, K, on) - best(ptime, 0, on)) / K * 1000
    stime(K, 1)
    ok, why = same_files(f'{T}/perf_o{K}1.bee', f'{T}/perf_p{K}1.bee', f'the long tree with the kernel on, after {K} changes of h, by a script and the console')
    st = stats(cadd(f'{T}/perf_p{K}1.bee'))
    check(ok and st and st.count(0) >= len(PERF_FEATS) - 1, f'{why} (statuses {st})')
    p0, p1 = res[0], res[1]
    print(f'  info  a rebuild of the {len(PERF_FEATS)} features: kernel off {p0:.1f} ms, on {p1:.1f} ms (the kernel: {p1 - p0:.1f} ms)', flush=True)
    # the view open: the long tree's solids drawn (frames as when orbiting), the kernel on and off
    fr = {}
    for on in (0, 1):
        args = ['--op', f'file.open {base}'] + (['--op', 'cad.kernel on'] if on else [])
        for act, c, _ in PERF_FEATS:
            args += ['--select', act, '--op', c]
        args += ['--select', 'Body', '--bench', '60']
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', f'{T}/u.ppm', *args], capture_output=True, text=True, timeout=900, env=ENV)
        m = re.search(r'bench: \d+ frames at \S+: ([\d.]+) ms avg, ([\d.]+) ms worst', r.stderr)
        fr[on] = (float(m.group(1)), float(m.group(2))) if m else None
    print(f'  info  the view of the long tree: a frame {fr[0]} ms (avg, worst) with the kernel off, {fr[1]} ms with it on', flush=True)
    check(fr[1] is not None and fr[0] is not None, 'the view draws the long tree\'s solids')
    if os.environ.get('BF_PERF') and fr[1] and fr[0]:
        check(fr[1][0] + p1 < 250, f'with the view open a change of the long tree (rebuild {p1:.0f} ms + a frame {fr[1][0]:.0f} ms) stays interactive')


# ---- random sessions ------------------------------------------------------------------

def s_fuzz():
    print('-- random kernel-on sessions with odd arguments, undo, redo, files (no crash, no hang) --')
    base = f'{T}/zbase.bee'
    bee_eval('\n'.join(PERF_BASE + [f'op("file.save_as", "{base}")']))
    rng = random.Random(SEED + 9)
    crashed = []
    vals = ['1', '0.3', '-1', '0', '1e300', '-1e300', 'nan', '1/0', 'h', '2*w', '0.0000001', '50', '360deg', '7']
    for run in range(max(4, RUNS // 4)):
        args = ['--op', f'file.open {base}', '--op', 'cad.kernel on']
        for _ in range(25):
            r = rng.random()
            if r < .3:
                t = rng.choice(['pad', 'pocket', 'revolve', 'hole'])
                args += ['--select', rng.choice(['S', 'T', 'U']), '--op', f'cad.{t} {rng.choice(["Body", "Part"])} {rng.choice(vals)} {rng.choice(["normal", "symmetric", "reverse", "through", "u", "v", ""])}']
            elif r < .45:
                t = rng.choice(['fillet', 'chamfer'])
                args += ['--select', rng.choice(['Body', 'Part']), '--op', f'cad.{t} {rng.choice(vals)} {rng.choice(["all", "vertical", "horizontal", "top", "bottom"])}']
            elif r < .52:
                args += ['--select', 'Body', '--op', f'cad.shell {rng.randrange(-1, 6)} {rng.choice(vals)} {rng.choice(["normal", "bottom"])}']
            elif r < .6:
                args += ['--select', 'Body', '--op', f'cad.pattern {rng.randrange(-1, 6)} {rng.choice([2, 3, 9, 0, -2])} {rng.choice(vals)} {rng.choice("xyz")} {rng.choice(["linear", "circular"])}']
            elif r < .68:
                args += ['--op', f'feature {rng.randrange(-1, 9)} {rng.randrange(-1, 5)} {rng.choice(vals)}']
            elif r < .74:
                args += ['--op', rng.choice(['edit.undo', 'edit.redo'])]
            elif r < .8:
                args += ['--op', f'param.set {rng.choice(["h", "w"])} {rng.choice(vals)}']
            elif r < .84:
                args += ['--op', f'cad.kernel {rng.choice(["on", "off"])}']
            elif r < .88:
                args += ['--op', f'file.export_step {T}/z.step']
            elif r < .91:
                args += ['--select', rng.choice(['S', 'Body']), '--op', 'object.delete']
            elif r < .94:
                args += ['--op', f'file.save_as {T}/z.bee', '--op', f'file.open {T}/z.bee']
            elif r < .97:
                args += ['--dump-brep', f'{T}/zq.txt;Body']
            else:
                args += ['--op', f'cad.feature_move {rng.randrange(-1, 9)} {rng.choice(["up", "down"])}']
        rc = port(*args, timeout=900)
        if rc != 0:
            crashed.append((run, rc, args))
    for run, rc, args in crashed[:3]:
        print(f'      run {run}: exit {rc}: ' + ' '.join(args)[-600:])
    check(not crashed, f'{max(4, RUNS // 4)} random kernel-on sessions of 25 steps: no crash, no hang ({len(crashed)} not)')


SECTIONS = [s_random, s_fillet, s_words, s_undo, s_files, s_window, s_perf, s_fuzz]

if __name__ == '__main__':
    print(f'bfeat: seed {SEED}, runs {RUNS}, binary {BIN}')
    t0 = time.time()
    try:
        for f in SECTIONS:
            if ONLY and f.__name__ not in ONLY:
                continue
            f()
    finally:
        shutil.rmtree(T, ignore_errors=True)
    print(f'bfeat: {time.time() - t0:.0f} s, fails {len(FAILS)}')
