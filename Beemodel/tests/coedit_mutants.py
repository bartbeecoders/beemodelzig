#!/usr/bin/env python3
"""Each guard of tests/coedit.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that part of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/coedit_mutants.py WORKDIR [name...]
    (WORKDIR: a copy of the project goes there, its build cache too; it is
    removed at the end)

Builds run one after another into WORKDIR/out with a cache in WORKDIR; each
mutant runs only the sections named with it (COEDIT_ONLY). (The guards that
compared bytes with the original's went with it, and their mutants too.)
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
PICK = sys.argv[2:]
C = 'src/cosync.zig'
M = [  # name, file, old, new, the sections that must fail
    ('a timestamp without the author\'s bit', C, '    if (author != 0) p |= 0x8000;\n    return (clock << 16) | p;', '    if (author == 99) p |= 0x8000;\n    return (clock << 16) | p;', 'agent'),
    ('the clock does not follow what it sees', C, '    if (c > clock) clock = c;', '    _ = c;', 'chain'),
    ('a register taken when not newer', C, '            if (at <= s.t.*) return;\n            s.t.* = at;', '            s.t.* = at;', 'join,chain'),
    ('no relay', C, '        apply(whole);\n        toAll(whole, k);', '        apply(whole);\n        _ = k;', 'chain'),
    ('relayed back to its sender too', C, '        toAll(whole, k);', '        toAll(whole, if (k > 99) k else null);', 'fuzz'),
    ('a new topology as vertex moves', C, '        if (sameTopo(s, me)) return opVerts(e, me.verts);', '        _ = sameTopo(s, me);\n        return opVerts(e, me.verts);', 'two'),
    ('undo: the user\'s log for the agent too', C, '    const li = author * 2 + r;', '    const li = r;', 'agent'),
    ('undo: inverses into the same log (no redo)', C, '    mode = if (redo) 0 else 1;\n    defer mode = 0;', '    mode = if (redo) 1 else 0;\n    defer mode = 0;', 'undo'),
    ('hosting: the starting scene in the undo log', C, '        ul[0].clearRetainingCapacity();\n    }\n    app.log("  co-editing: hosting', '    }\n    app.log("  co-editing: hosting', 'two'),
    ('keyed: the direction bit the other way', C, '    if (a < b) r |= 1 << 63;', '    if (a > b) r |= 1 << 63;', 'key'),
    ('keyed: the document before the AUTH', C, '    if (keyset) return;\n    c.state = 2;', '    c.state = 2;', 'key'),
    ('keyed: a bad tag let through', C, '            if (tag != rd64(msg, n - 4)) return refuse(c);', '            _ = tag;', 'key'),
    ('presence: the camera in degrees', C, '    const c = [6]f32{ v.yaw * m.deg, v.pitch * m.deg, v.dist', '    const c = [6]f32{ v.yaw, v.pitch, v.dist', 'pres'),
    ('follow: the view not taken', C, '    if (x.peer == follow and follow != 0) {', '    if (false) {', 'pres'),
    ('presence: not in the viewport\'s key', 'src/viewport.zig', '    h.update(std.mem.asBytes(&@import("cosync.zig").stateWord())); // (the other peers drawn)\n', '', 'pres'),
    ('damaged: a short message applied', C, '        if (p.len < need) return; // (damaged: passed over)', '        _ = need;', 'fuzz'),
    ('output buffers of 64 bytes', C, '    if (c.out.items.len + msg.len + 8 > BUF_CAP) return;', '    if (c.out.items.len + msg.len + 8 > 64) return;', 'two'),
    ('the status chip not drawn', C, '    if (!on) return right;\n    const ui', '    if (true) return right;\n    const ui', 'ui'),
    ('co.follow: numbers from 0', C, '            const n = @import("ntree.zig").cvtt(f) -% 1;', '            const n = @import("ntree.zig").cvtt(f);', 'pres'),
    ('grab cancel: every object back (a peer\'s edit too)', 'src/xform.zig', '        if (!moves[i] or orig_oid[i] != o.oid) continue;\n', '', 'undo'),
]


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def main():
    os.makedirs(W, exist_ok=True)
    # the copy builds as the sources do: the UI library next to it (build.zig.zon:
    # ../BeeZigUi), and the project's zig (mise.toml) found from the project
    zui = os.path.join(os.path.dirname(ROOT), 'BeeZigUi')
    if os.path.isdir(zui) and not os.path.exists(os.path.join(W, 'BeeZigUi')):
        os.symlink(zui, os.path.join(W, 'BeeZigUi'))
    mz = run(['mise', 'which', 'zig'], cwd=ROOT, env=dict(os.environ, HOME=__import__('pwd').getpwuid(os.getuid()).pw_dir)) if shutil.which('mise') else None
    zig = mz.stdout.strip() if mz is not None and mz.returncode == 0 and mz.stdout.strip() else 'zig'
    src = os.path.join(W, 'tree')
    shutil.rmtree(src, True)
    def skip(d, names):
        top = os.path.abspath(d) == ROOT   # (only the tree's top: build output, caches, scratch files there)
        return [n for n in names if n.startswith('zig-out') or n == '.zig-cache' or n.endswith('.bee')
                or (top and (n.startswith('subsurf') or n in ('Docs', 'Material')))]
    shutil.copytree(ROOT, src, ignore=skip)
    caught = survived = 0
    for name, f, old, new, secs in M:
        if PICK and name not in PICK:
            continue
        path = os.path.join(src, f)
        good = open(os.path.join(ROOT, f)).read()
        if good.count(old) != 1:
            print(f'  ?? {name}: its text is not in {f} once')
            survived += 1
            continue
        open(path, 'w').write(good.replace(old, new))
        out, cache = os.path.join(W, 'out'), os.path.join(W, 'zc')
        b = run([zig, 'build', '-p', out, '--cache-dir', cache], cwd=src)
        open(path, 'w').write(good)
        if b.returncode != 0:
            err = [l for l in b.stderr.splitlines() if 'error:' in l]
            print(f'  ?? {name}: does not build: {err[:2]}')
            survived += 1
            continue
        r = run([sys.executable, os.path.join(HERE, 'coedit.py'), os.path.join(out, 'bin', 'beemodel'), '40'],
                env=dict(os.environ, COEDIT_ONLY=secs), timeout=3600)
        last = (r.stdout.strip().splitlines() or [''])[-1]
        dead = not last.endswith('fails 0')
        print(f'  {"caught  " if dead else "SURVIVED"} {name} ({secs}: {last})', flush=True)
        caught += dead
        survived += not dead
    shutil.rmtree(W, True)
    print(f'mutants caught {caught}, survived {survived}')
    sys.exit(1 if survived else 0)


main()
