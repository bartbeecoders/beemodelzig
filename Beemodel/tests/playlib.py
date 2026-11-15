"""Shared by tests/play.py, tests/logic.py and tests/playwin.py: sessions of play
mode run by BeeModel from the command line (--play step / look / key / dump).
Given a binary as `script` (BeeModel itself), the same session also runs as a
BeeScript (--run: playstep, playlook, playkey, playinfo, logic, logicvar) and
the two routes' numbers are compared bit for bit. Without one, a session must
end cleanly and give finite numbers.

A session is a list of actions:
    ('op', 'play.start', 'walk 0 4 0')      an operator with its words
    ('step', s[, fwd, right, up, run])      playstep: play on for s seconds
    ('look', yaw, pitch)                    playlook (degrees)
    ('key', code, down)                     playkey (evdev code, 1 / 0)
    ('dump', tag, items)                    a line of numbers: items are
        'p' (playinfo 0..18), 'l' (logic 0..8), 'o:Name' (x y z rx ry rz sx sy
        sz hidden), 'v:Name:k:c' (logicvar, nil when none runs on it)
    ('save', path)                          file.save there
The BeeScript prints each number twice (x 1e9 and x 1e14: print keeps 6
decimals), which gives back every bit of a float.
"""
import math, os, struct, subprocess, sys, tempfile, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401,E402 (a HOME of our own)

ROOT = os.path.dirname(HERE)
CPU = os.environ.get('BEE_CPU', '12')
T = tempfile.mkdtemp(prefix='beeplay-', dir=os.environ.get('BEEPLAY_TMP', '/tmp'))
ENV = dict(os.environ, HOME=T)
os.makedirs(os.path.join(T, 'BeeModel'), exist_ok=True)


def _pr(tag, exprs):
    """print lines of at most 6 numbers (x 1e9, x 1e14): the first with the tag, the rest '+'."""
    out = []
    for k in range(0, len(exprs), 6):
        out.append(f'print("{tag if k == 0 else "+"}", ' + ', '.join(f'{e} * 1000000000, {e} * 100000000000000' for e in exprs[k:k + 6]) + ')')
    return out


Q = 'fn dp(t) {\n' + '\n'.join(_pr('@T', [f'playinfo({k})' for k in range(19)])).replace('"@T"', 't') + '\n}\n'
Q += 'fn dl(t) {\n' + '\n'.join(_pr('@T', [f'logic({k})' for k in range(9)])).replace('"@T"', 't') + '\n}\n'
Q += 'fn dob(t, n) {\n' + '\n'.join(_pr('@T', [f'get(n, "{p}")' for p in ['x', 'y', 'z', 'rx', 'ry', 'rz', 'sx', 'sy', 'sz', 'hidden']])).replace('"@T"', 't') + '\n}\n'
Q += '''fn dv(t, n, k, c) {
 v = logicvar(n, k, c)
 if v == nil {
  print(t, "nil", "nil")
 } else {
  print(t, v * 1000000000, v * 100000000000000)
 }
}
'''

OBJ_PROPS = ['x', 'y', 'z', 'rx', 'ry', 'rz', 'sx', 'sy', 'sz', 'hidden']


def cleanup():
    shutil.rmtree(T, True)


def f32(x):
    return struct.unpack('<f', struct.pack('<f', x))[0]


def bits(x):
    return struct.unpack('<I', struct.pack('<f', x))[0]


def esc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')


def item_exprs(it):
    if it == 'p':
        return [f'playinfo({k})' for k in range(19)]
    if it == 'l':
        return [f'logic({k})' for k in range(9)]
    if it.startswith('o:'):
        return [f'get("{it[2:]}", "{p}")' for p in OBJ_PROPS]
    if it.startswith('v:'):
        nm, k, c = it[2:].split(':')
        return [f'logicvar("{nm}", {k}, {c})']
    raise ValueError(it)


def script_code(actions):
    out = [Q]
    for a in actions:
        if a[0] == 'op':
            out.append(f'op("{a[1]}", "{esc(a[2])}")' if a[2] else f'op("{a[1]}")')
        elif a[0] == 'step':
            v = list(a[1:]) + [0] * (5 - len(a[1:]))
            out.append(f'playstep({v[0]}, {v[1]}, {v[2]}, {v[3]}, {v[4]})')
        elif a[0] == 'look':
            out.append(f'playlook({a[1]}, {a[2]})')
        elif a[0] == 'key':
            out.append(f'playkey({a[1]}, {a[2]})')
        elif a[0] == 'dump':
            first = True
            for it in a[2]:
                t = f'"{a[1]}"' if first else '"+"'
                first = False
                if it == 'p':
                    out.append(f'dp({t})')
                elif it == 'l':
                    out.append(f'dl({t})')
                elif it.startswith('o:'):
                    out.append(f'dob({t}, "{it[2:]}")')
                elif it.startswith('v:'):
                    nm, k, c = it[2:].split(':')
                    out.append(f'dv({t}, "{nm}", {k}, {c})')
        elif a[0] == 'save':
            out.append(f'op("file.save", "{a[1]}")')
        elif a[0] == 'sel':
            out.append('select(' + ', '.join(f'"{x}"' for x in a[1].split(',')) + ')')
        elif a[0] == 'raw':
            out.append(a[1])
    return '\n'.join(out) + '\n'


def port_args(actions, dump):
    out = []
    for a in actions:
        if a[0] == 'op':
            out += ['--op', (a[1] + ' ' + a[2]).strip()]
        elif a[0] == 'step':
            out += ['--play', 'step ' + ' '.join(str(x) for x in a[1:])]
        elif a[0] == 'look':
            out += ['--play', f'look {a[1]} {a[2]}']
        elif a[0] == 'key':
            out += ['--play', f'key {a[1]} {a[2]}']
        elif a[0] == 'dump':
            out += ['--play', f'dump {dump} {a[1]} ' + ' '.join(a[2])]
        elif a[0] == 'save':
            out += ['--op', f'file.save {a[1]}']
        elif a[0] == 'sel':
            out += ['--select', a[1]]
        elif a[0] == 'port':
            out += list(a[1:])
    return out


def run_script(binary, code, timeout=600):
    """A BeeScript run by `binary` (--run): (stdout, stderr), ('timeout', '') when it hangs."""
    p = f'{T}/s.bees'
    open(p, 'w').write(code)
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary, '--run', p], capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        return 'timeout', ''
    return r.stdout, r.stderr


def run_port(binary, args, timeout=900, shot=None):
    try:
        r = subprocess.run(['taskset', '-c', CPU, binary, '--shot', shot or f'{T}/u.ppm', '--dump-log', f'{T}/log.txt', *args],
                           capture_output=True, text=True, timeout=timeout, env=ENV)
    except subprocess.TimeoutExpired:
        return None
    return r


def plog():
    return open(f'{T}/log.txt', errors='replace').read() if os.path.exists(f'{T}/log.txt') else ''


def parse_script(text):
    """{tag: [values]} (the last line of a tag wins; lists of lines in 'all')."""
    res, allv = {}, []
    for ln in text.splitlines():
        w = ln.split()
        if len(w) < 1 or (len(w) - 1) % 2:
            continue
        vals = []
        ok = True
        for i in range(1, len(w), 2):
            if w[i] == 'nil':
                vals.append(None)
                continue
            try:
                lo, hi = float(w[i]), float(w[i + 1])
            except ValueError:
                ok = False
                break
            x = lo / 1e9 if abs(lo) >= 1e3 else hi / 1e14
            vals.append(f32(x))
        if ok:
            if w[0] == '+' and allv:
                allv[-1][1].extend(vals)
                continue
            res[w[0]] = vals
            allv.append((w[0], vals))
    return res, allv


def parse_port(path):
    res, allv = {}, []
    if not os.path.exists(path):
        return res, allv
    for ln in open(path):
        w = ln.split()
        if not w:
            continue
        vals = [None if x == 'nil' else struct.unpack('<f', bytes.fromhex(x)[::-1])[0] for x in w[1:]]
        res[w[0]] = vals
        allv.append((w[0], vals))
    return res, allv


def same_val(a, b):
    if a is None or b is None:
        return a is None and b is None
    if math.isnan(a) or math.isnan(b):
        return math.isnan(a) and math.isnan(b)
    if a == 0 and b == 0:
        return True
    if abs(a) < 1e-11 and abs(b) < 1e-11:
        return abs(a - b) < 1e-15        # (below the printed digits)
    return bits(a) == bits(b)


def first_diff(oa, pa):
    for k, ((ta, va), (tb, vb)) in enumerate(zip(oa, pa)):
        if ta != tb or len(va) != len(vb):
            return f'line {k}: {ta} / {tb} ({len(va)} / {len(vb)} numbers)'
        for i, (x, y) in enumerate(zip(va, vb)):
            if not same_val(x, y):
                return f'line {k} ({ta}) number {i}: {x!r} / {y!r}'
    if len(oa) != len(pa):
        return f'{len(oa)} / {len(pa)} lines'
    return None


def not_finite(lines):
    """The first number that is not finite (None, a 'nil', is fine): a message or None."""
    for k, (t, vs) in enumerate(lines):
        for i, x in enumerate(vs):
            if x is not None and not math.isfinite(x):
                return f'line {k} ({t}) number {i}: {x!r}'
    return None


def session(binary, script, actions, prefix=None, timeout=900):
    """BeeModel plays the session from the command line (--play). With a binary
    as `script`, it plays it again as a BeeScript (--run) and the two routes must
    give the same bits. (the script's lines, or the --play lines when there is no
    script; the --play lines; the first problem or None; the --play process)."""
    pre = prefix or []
    dump = f'{T}/dump.txt'
    if os.path.exists(dump):
        os.remove(dump)
    r = run_port(binary, port_args(pre + actions, dump), timeout)
    _, pa = parse_port(dump)
    want = sum(1 for a in pre + actions if a[0] == 'dump')
    if script:
        out, err = run_script(script, script_code(pre + actions), timeout)
        _, oa = parse_script(out)
        d = first_diff(oa, pa)
    else:
        out, err, oa = '', '', pa
        d = not_finite(pa)
        if d is None and len(pa) != want:
            d = f'{len(pa)} of {want} dumps'
    if r is None:
        d = 'BeeModel hung (--play)'
    elif r.returncode != 0:
        d = f'BeeModel stopped ({r.returncode}): {r.stderr[-600:]}'
    elif script and out == 'timeout':
        d = 'the BeeScript hung'
    elif script and not oa:
        d = f'the BeeScript printed nothing: {err[-300:]}'
    elif script and len(out) >= 65000:
        d = 'the BeeScript\'s output was cut at 64 KiB: a shorter session'
    return oa, pa, d, r


# the old names (before 2026-11-14 the BeeScript ran in the assembly original)
orig_code = script_code
run_orig = run_script
parse_orig = parse_script
