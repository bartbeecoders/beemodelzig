#!/usr/bin/env python3
"""Each behaviour tests/menus_wl.py guards, shown failing: the menus' code
(src/menus.zig, the bits of app.zig and editors.zig that open menus) broken
one thing at a time in a copy of the sources; the groups of the suite named
for it must then fail. A mutant that survives is a check that passes on
nothing. Each one is also the control for its fix: the current sources minus
that one change. (The guards that compared pixels with the original's went
with it, and their mutants too.)

    python3 tests/menus_mutants.py WORKDIR [name...]

(Debug builds without the GPU helper, one at a time - the window cases pin to
BEE_CPU, 20 by default - each removed once it ran.)
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
MN, APP, ED = 'src/menus.zig', 'src/app.zig', 'src/editors.zig'
# name, [(file, old, new)], the groups that must fail
M = [
    ('the menu under the submenu takes the pointer (hit order)', [(MN, '''    if (m.sub >= 0) {
        const r = m.lv[1].rect;
        if (r.contains(px, py)) return .{ .level = 1, .idx = listAt(m.lv[1].items, py - r.y + m.lv[1].scroll) };
    }
    const r = m.lv[0].rect;
    if (r.contains(px, py)) return .{ .level = 0, .idx = listAt(m.lv[0].items, py - r.y + m.lv[0].scroll) };''', '''    const r = m.lv[0].rect;
    if (r.contains(px, py)) return .{ .level = 0, .idx = listAt(m.lv[0].items, py - r.y + m.lv[0].scroll) };
    if (m.sub >= 0) {
        const r1 = m.lv[1].rect;
        if (r1.contains(px, py)) return .{ .level = 1, .idx = listAt(m.lv[1].items, py - r1.y + m.lv[1].scroll) };
    }''')], 'bar,small'),
    ('entries run on the press, not the release', [(MN, '''    if (h.level >= 0) return;
    if (owner < 0) {''', '''    if (h.level >= 0) {
        if (h.idx >= 0) choose(@intCast(h.level), @intCast(h.idx));
        return;
    }
    if (owner < 0) {'''), (MN, '    if (h.level >= 0 and h.idx >= 0) choose(@intCast(h.level), @intCast(h.idx));\n}', '    if (false and h.level >= 0 and h.idx >= 0) choose(@intCast(h.level), @intCast(h.idx));\n}')], 'bar,outliner'),
    ('the opening right-click\'s release picks (no 4 px test)', [(MN, 'if (@abs(ui.mx - m.md_x) + @abs(ui.my - m.md_y) < 4) return;', 'if (@abs(ui.mx - m.md_x) + @abs(ui.my - m.md_y) < 0) return;')], 'viewport'),
    ('the submenu not kept above the bottom', [(MN, 'const v1 = fitV(l0.rect.y + listY(l0.items, @intCast(m.sub)) - l0.scroll - 4, listH(l1.items));',
                                                'const v1 = [2]i32{ l0.rect.y + listY(l0.items, @intCast(m.sub)) - l0.scroll - 4, listH(l1.items) };')], 'small'),
    ('the menu not kept in the window', [(MN, 'var x = @min(l0.x, ww - w);', 'var x = l0.x;')], 'viewport'),
    ('a greyed entry keeps the menu open', [(MN, '    const area = m.area;\n    close();\n    switch (it) {', '    const area = m.area;\n    if (why(it) == null) close();\n    switch (it) {')], 'grey'),
    ('the menu takes every key', [(MN, '        else => return false,\n    }\n    ensure_visible = true;', '        else => {},\n    }\n    ensure_visible = true;')], 'bar'),
    ('the app drops the keys a menu leaves', [(APP, '    if (menus.isOpen() and menus.key(key)) return;', '    if (menus.isOpen()) {\n        _ = menus.key(key);\n        return;\n    }')], 'bar'),
    ('Esc from the menu closes only the submenu', [(MN, 'if (m.sub >= 0 and m.focus != 0) {\n                m.sub = -1; // back to the menu', 'if (m.sub >= 0) {\n                m.sub = -1; // back to the menu')], 'bar'),
    ('a press on a widget only closes the menu', [(MN, '                repass = true;', '                repass = false;')], 'pass'),
    ('the area\'s type pressed again opens it again', [(MN, 'and m.lv[0].items.ptr == &cat.items_area) close();', 'and false) close();')], 'pass'),
    ('the header\'s menus open on the press', [(ED, '    _ = ui.press(wid, r, ui.LMB);\n    if (ui.releasedOn(wid) and r.contains(ui.mx, ui.my)) {', '    if (ui.press(wid, r, ui.LMB)) {')], 'pass'),
    ('the header\'s menus under the button', [(ED, '        menus.openAt(items, ui.mx, ui.my, area);\n    }\n}', '        menus.openAt(items, r.x, r.bottom() + 2, area);\n    }\n}')], 'pass'),
    ('the viewport\'s list: Add over nothing', [(ED, '} else menus.openAt(&cat.ctx_object, ui.mx, ui.my, i);', '} else menus.openAt(if (pickable(cv, &n.view, r) != null) &cat.ctx_object else &cat.items_add, ui.mx, ui.my, i);')], 'viewport'),
    ('Open Recent shows the paths', [(MN, 'const b = std.fs.path.basename(p);', 'const b = p;')], 'recent'),
    ('Open Recent runs nothing', [(MN, '            @import("files.zig").guarded(.recent, recentPath(k));', '            _ = k;')], 'recent'),
]
want = sys.argv[2:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
# the copy builds as the sources do: the UI library next to it (build.zig.zon:
# ../BeeZigUi), and the project's zig (mise.toml) found from the project
_zui = os.path.join(os.path.dirname(ROOT), 'BeeZigUi')
if os.path.isdir(_zui) and not os.path.exists(os.path.join(W, 'BeeZigUi')):
    os.symlink(_zui, os.path.join(W, 'BeeZigUi'))
_mz = subprocess.run(['mise', 'which', 'zig'], cwd=ROOT, capture_output=True, text=True,  # (mise's own installs: the real home, read only)
                     env=dict(os.environ, HOME=__import__('pwd').getpwuid(os.getuid()).pw_dir)) if shutil.which('mise') else None
ZIG = _mz.stdout.strip() if _mz is not None and _mz.returncode == 0 and _mz.stdout.strip() else 'zig'


def one(k):
    name, edits, groups = M[k]
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', d)
        for fn, old, new in edits:
            p = f'{d}/{fn}'
            t = open(p).read()
            if t.count(old) != 1:
                return name, '?', f'the code is not there ({fn}: {old[:50]!r})'
            open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run([ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '-Dgpu=false'], cwd=d, capture_output=True, text=True)
        shutil.rmtree(f'{d}/zc', ignore_errors=True)
        if r.returncode != 0:
            return name, '?', 'it does not build: ' + r.stderr[-300:]
        e = dict(os.environ, MW_ONLY=groups)
        r = subprocess.run([sys.executable, '-u', f'{HERE}/menus_wl.py', f'{d}/out/bin/beemodel'],
                           env=e, capture_output=True, text=True)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln and 'untouched' not in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        return name, ('ok' if fails else 'LIVE'), (f'{len(fails)} failed in {groups}: {fails[0].strip()[:120]}' if fails else f'nothing in {groups} failed')
    finally:
        shutil.rmtree(d, ignore_errors=True)


bad = []
for k in range(len(M)):
    name, st, msg = one(k)
    print(f'  {st:4} {name}: {msg}', flush=True)
    if st != 'ok':
        bad.append(name)
print(f'menus_mutants: {len(M) - len(bad)} of {len(M)} caught; survivors {len(bad)} {bad}')
sys.exit(1 if bad else 0)
