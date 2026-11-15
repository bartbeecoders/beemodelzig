#!/usr/bin/env python3
"""The node editor (nodeed.zig) on BeeModel alone, by its headless driver and in
tests/wl_fake.py.

  * edits: moving, values dragged, links made, picked up, cut with the knife,
    reroutes, the add menu (by the pointer, typed, from a dropped wire), the
    palette, delete / duplicate / copy / paste / collapse, comment frames (made,
    moved, resized), align / distribute, quick keys, a material socket picked
    up, Tab into a material function, geometry node trees (New Tree, add menu),
    logic graphs: each runs cleanly, changes the graph (or not: a control), adds
    or takes the nodes it should, and its MGRF and NTRE chunks read back the
    same (save -> open -> save);
  * undo and redo: Ctrl+Z after an edit takes it away, enough of them give the
    graph before it, redo the edit again;
  * the look: every node type of the three catalogues drawn at 100 % and 50 %,
    the preview pane, the add menu, the palette, the minimap, the context menu:
    drawn, no crash, something shown;
  * the window: tests/wl_fake.py, a node dragged, Shift+A typed, Enter, Ctrl+S:
    the same bytes as the headless driver gives;
  * damaged graphs (random bytes in the MGRF and NTRE chunks): the node editor
    draws them at every zoom, no crash.

    python3 tests/nodeed.py BIN [runs=1]

BEE_CPU (default 16) pins the runs; NE_ONLY=a,b runs some cases (or sections:
edits, undo, look, window, damaged).
"""
import os, random, shutil, struct, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import temphome  # noqa: F401 (a HOME of our own)
import beefile
from PIL import Image, ImageChops

ROOT = os.path.dirname(HERE)
BIN = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, 'zig-out-debug/bin/beemodel'))
RUNS = int(sys.argv[2]) if len(sys.argv) > 2 else 1
CPU = os.environ.get('BEE_CPU', '16')
ONLY = [x for x in os.environ.get('NE_ONLY', '').split(',') if x]
FAILS = []
T = tempfile.mkdtemp(prefix='beened-', dir='/tmp')
HELD = []
CANVAS = (0, 104, 1060, 680)      # (below the title line, left of the pane, above the toasts)
PIX_MAX = 8


def check(cond, msg):
    print(('  ok   ' if cond else '  FAIL ') + msg, flush=True)
    if not cond:
        FAILS.append(msg)


def want(*names):
    return not ONLY or any(n in ONLY for n in names)


PORT_KEY = {'delete': '111', 'home': '102'}


def port_args(bee, setup, acts):
    a = ['--op', 'file.open ' + bee]
    for s in setup:
        if s[0] == 'select':
            a += ['--select', s[1]]
        else:
            a += ['--op', (s[0] + ' ' + (s[1] if len(s) > 1 else '')).strip()]
    a += ['--move', '640,400']
    for x in acts:
        k = x[0]
        if k in ('move', 'click', 'rclick', 'dbl'):
            a += ['--' + k, f'{x[1]},{x[2]}']
        elif k == 'drag':
            a += ['--drag', f'{x[1]},{x[2]},{x[3]},{x[4]}']
        elif k == 'mdrag':
            a += ['--mdrag', f'{x[1]},{x[2]},{x[3]},{x[4]}']
        elif k == 'sdrag':
            a += ['--shift-drag', f'{x[1]},{x[2]},{x[3]},{x[4]}']
        elif k == 'adrag':
            a += ['--mods', 'alt', '--drag', f'{x[1]},{x[2]},{x[3]},{x[4]}', '--mods', 'none']
        elif k == 'key':
            a += ['--key', PORT_KEY.get(x[1], x[1])]
        elif k == 'skey':
            a += ['--key', 'shift+' + x[1]]
        elif k == 'ckey':
            a += ['--key', 'ctrl+' + x[1]]
        elif k == 'cskey':
            a += ['--key', 'ctrl+shift+' + x[1]]
        elif k == 'type':
            a += ['--type', x[1]]
        elif k == 'wheel':
            a += ['--wheel', f'{x[1]},{x[2]},{x[3]}']
        elif k == 'op':
            a += ['--op', (x[1] + ' ' + (x[2] if len(x) > 2 else '')).strip()]
    return a


def port(args, shot=None, timeout=300):
    home = tempfile.mkdtemp(prefix='nedp-', dir=T)
    sh = shot or os.path.join(home, 's.ppm')
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--shot', sh] + args, env=dict(os.environ, HOME=home),
                           capture_output=True, text=True, timeout=timeout)
        if r.returncode != 0:
            print(r.stderr[-1500:])
        return r.returncode
    except subprocess.TimeoutExpired:
        return None
    finally:
        shutil.rmtree(home, True)


def graphs(bee):
    if not os.path.exists(bee):
        return None, None
    return beefile.chunk(bee, b'MGRF'), beefile.chunk(bee, b'NTRE')


def mat_nodes(m):
    """[[(x, y) of each node] of each material] of an MGRF chunk"""
    out = []
    if not m or len(m) < 12:
        return out
    o = 12
    for _ in range(struct.unpack_from('<I', m, 8)[0]):
        n = struct.unpack_from('<I', m, o)[0]
        out.append([struct.unpack_from('<hh', m, o + 36 + k * 72 + 68) for k in range(n)])
        o += 4 + 32 + n * 72 + 480
    return out


def logic_nodes(t):
    """[nodes of each record] of an NTRE chunk"""
    if not t or len(t) < 4:
        return []
    return [struct.unpack_from('<I', t, 4 + r * 4096 + 128)[0] for r in range(struct.unpack_from('<I', t, 0)[0])]


def nodes(g):
    """all the nodes of (MGRF, NTRE)"""
    return sum(len(x) for x in mat_nodes(g[0])) + sum(logic_nodes(g[1]))


def pixdiff(a, b, box=CANVAS):
    A = Image.open(a).convert('RGB').crop(box)
    B = Image.open(b).convert('RGB').crop(box)
    d = ImageChops.difference(A, B).convert('L').point(lambda v: 255 if v > 24 else 0)
    return sum(1 for y in range(d.height) for x in range(d.width) if d.getpixel((x, y)))


def colours(a, box=CANVAS):
    return len(set(Image.open(a).convert('RGB').crop(box).get_flattened_data()))


def build(code, path):
    """BeeModel runs the BeeScript (--run) and saves the scene."""
    home = tempfile.mkdtemp(prefix='nedb-', dir=T)
    sp = os.path.join(home, 's.bees')
    open(sp, 'w').write(code + f'\nop("file.save_as", "{path}")\n')
    try:
        r = subprocess.run(['taskset', '-c', CPU, BIN, '--run', sp], env=dict(os.environ, HOME=home), capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            print(r.stderr[-800:])
    except subprocess.TimeoutExpired:
        return False
    finally:
        shutil.rmtree(home, True)
    return os.path.exists(path)


def read_back(bee):
    """save -> open -> save: the graphs the same"""
    b2 = bee[:-4] + '_again.bee'
    port(['--op', 'file.open ' + bee, '--op', 'file.save_as ' + b2])
    return graphs(b2) == graphs(bee)


# --- the scenes ------------------------------------------------------------------------------

MAT = ('m = material("C")\nassign("Cube", m)\nselect("Cube")\nt = node(m, "texcoord", 4, 4)\nw = node(m, "wave", 3)\n'
       'link(m, t, w, 1)\nh = node(m, "hsv", 0.3)\nlink(m, w, h, 1, 1)\nsocket(m, "base", h)\nk = node(m, "checker", 5)\n'
       'c = node(m, "color")\nn2 = node(m, "noise", 4)\nlink(m, c, k, 1)\nmaterial("D")\n'
       'op("material.node_move", "C 1 20 20")\nop("material.node_move", "C 2 220 20")\nop("material.node_move", "C 3 420 20")\n'
       'op("material.node_move", "C 0 620 20")')
LOGIC = ('select("Cube")\nop("logic.new", "L")\nop("logic.node", "L overlap 0 0 1.5")\nop("logic.node", "L play_action")\n'
         'op("tree.link", "L 1 2 1")\nop("logic.node", "L math 2")\nop("logic.node", "L tick")\nop("logic.attach", "L Cube")')
PLAIN = 'select("Cube")'
FUNC = (MAT + '\nf = material("F")\nop("material.make_function", "C 1 2")')

NE = [('area.type_node_editor',), ('area.maximize',)]
CASES = [
    # name, scene, actions, the graph changes (a control)
    ('move', 'mat', [('drag', 300, 130, 350, 180)], True),
    ('value', 'mat', [('drag', 500, 168, 540, 168)], True),                # (Hue/Saturation's Hue)
    ('choice', 'mat', [('drag', 100, 322, 160, 322)], True),               # (Noise's Detail: a whole number)
    ('input_value', 'mat', [('op', 'node.view_fit'), ('drag', 500, 360, 560, 360)], True),
    ('link', 'mat', [('drag', 191, 168, 220, 258)], True),
    ('pick_up', 'mat', [('drag', 420, 240, 300, 500)], True),             # (Hue/Saturation's Color: dropped in empty space, gone)
    ('link_from_input', 'mat', [('drag', 20, 358, 190, 150)], True),      # (Noise's Offset onto Color's output)
    ('pick_pin', 'mat', [('drag', 621, 150, 621, 168)], True),
    ('wire_menu', 'mat', [('drag', 391, 168, 500, 500), ('type', 'invert'), ('key', 'enter')], True),
    ('add_menu', 'mat', [('move', 500, 500), ('skey', 'a'), ('type', 'voron'), ('key', 'enter')], True),
    ('add_click', 'mat', [('move', 300, 450), ('skey', 'a'), ('click', 330, 489)], True),
    ('knife', 'mat', [('adrag', 200, 300, 600, 100)], True),
    ('reroute', 'mat', [('dbl', 205, 210)], True),
    ('delete', 'mat', [('click', 300, 130), ('key', 'x')], True),
    ('duplicate', 'mat', [('click', 300, 130), ('skey', 'd')], True),
    ('copy_paste', 'mat', [('click', 300, 130), ('ckey', 'c'), ('move', 500, 500), ('ckey', 'v')], True),
    ('cut', 'mat', [('click', 300, 130), ('ckey', 'x')], True),
    ('collapse', 'mat', [('click', 300, 130), ('key', 'h')], True),
    ('box_select_move', 'mat', [('sdrag', 5, 110, 600, 770), ('drag', 300, 130, 340, 150)], True),
    ('frame', 'mat', [('click', 300, 130), ('key', 'c'), ('drag', 300, 95, 330, 300)], True),
    ('frame_delete', 'mat', [('click', 300, 130), ('key', 'c'), ('key', 'x')], False),
    ('align', 'mat', [('sdrag', 5, 110, 600, 770), ('op', 'node.align_top'), ('op', 'node.distribute_x')], True),
    ('align_left', 'mat', [('sdrag', 5, 110, 600, 770), ('op', 'node.align_left')], True),
    ('quick_key', 'mat', [('key', 'm'), ('click', 700, 500)], True),
    ('palette_click', 'mat', [('click', 480, 68), ('click', 60, 160)], True),
    ('zoom_move', 'mat', [('wheel', 400, 300, 10), ('wheel', 400, 300, 10), ('drag', 150, 170, 200, 250)], True),
    ('pan_move', 'mat', [('mdrag', 600, 600, 500, 650), ('drag', 200, 178, 260, 240)], True),
    ('fit_delete', 'mat', [('key', 'home'), ('sdrag', 5, 110, 1270, 770), ('key', 'x')], True),
    ('tab_function', 'func', [('click', 200, 130), ('key', 'tab'), ('drag', 100, 130, 150, 160)], True),
    ('new_tree', 'plain', [('click', 332, 68)], True),
    ('tree_add', 'plain', [('click', 332, 68), ('move', 300, 300), ('skey', 'a'), ('type', 'cube'), ('key', 'enter'),
                           ('move', 600, 300), ('skey', 'a'), ('type', 'transf'), ('key', 'enter'), ('drag', 470, 330, 600, 403)], True),
    ('logic_add', 'logic', [('move', 700, 500), ('skey', 'a'), ('type', 'begin'), ('key', 'enter')], True),
    ('logic_move', 'logic', [('key', 'home'), ('drag', 300, 300, 330, 330)], None),
    ('logic_delete', 'logic', [('key', 'home'), ('sdrag', 5, 110, 1270, 770), ('key', 'x')], True),
]


KEEP = os.environ.get('NE_SCENES', '')   # (a directory to keep the scenes in between runs)


def scene_file(name, code):
    p = os.path.join(KEEP or T, name + '.bee')
    if KEEP and os.path.exists(p):
        return True, p
    return build(code, p), p


def scenes():
    out = {}
    for name, code in (('mat', MAT), ('logic', LOGIC), ('plain', PLAIN), ('func', FUNC)):
        ok, p = scene_file(name, code)
        check(ok, f'BeeModel made the {name} scene')
        out[name] = p
    return out


# what an edit does to the nodes: so many more (or fewer), all of them, all moved alike
DELTA = {'add_menu': 1, 'add_click': 1, 'wire_menu': 1, 'duplicate': 1, 'copy_paste': 1, 'delete': -1, 'cut': -1, 'logic_add': 1}


def edits(sc):
    print('-- edits: run, change the graph, read back', flush=True)
    for name, scene, acts, changes in CASES:
        if not want('edits', name):
            continue
        bee = sc[scene]
        pb, pp = f'{T}/{name}_p.bee', f'{T}/{name}_p.ppm'
        rc = port(port_args(bee, NE, acts) + ['--op', 'file.save_as ' + pb], pp)
        check(rc == 0 and os.path.exists(pb), f'{name}: BeeModel ran and saved ({rc})')
        if not os.path.exists(pb):
            continue
        gp, gb = graphs(pb), graphs(bee)
        if changes is not None:
            ch = gp != gb
            check(ch == changes, f'{name}: the graph {"changed" if ch else "did not change"} (control: {changes})')
        if name in DELTA:
            check(nodes(gp) == nodes(gb) + DELTA[name], f'{name}: {nodes(gb)} nodes, then {nodes(gp)} ({DELTA[name]:+d})')
        if name == 'logic_delete':
            check(logic_nodes(gp[1]) and not any(logic_nodes(gp[1])), f'{name}: every logic node gone ({logic_nodes(gp[1])})')
        if name == 'box_select_move':
            a, b = mat_nodes(gb[0]), mat_nodes(gp[0])
            # (the nodes placed by hand: those at 0, 0 are laid out when drawn)
            d = {(q[0] - p[0], q[1] - p[1]) for x, y in zip(a, b) if len(x) == len(y) for p, q in zip(x, y) if p != (0, 0)}
            check(len(d) == 1 and d != {(0, 0)}, f'{name}: every placed node moved alike ({sorted(d)[:4]})')
        if name == 'new_tree':
            check(beefile.chunk(pb, b'MODS') != beefile.chunk(bee, b'MODS'), f'{name}: the object runs the new tree (MODS changed)')
        check(read_back(pb), f'{name}: MGRF and NTRE the same after save -> open -> save')


UNDO = [
    ('undo_move', 'mat', [('drag', 300, 130, 350, 180)]),
    ('undo_link', 'mat', [('drag', 191, 168, 220, 258)]),
    ('undo_value', 'mat', [('drag', 500, 168, 540, 168)]),
    ('undo_delete', 'mat', [('click', 300, 130), ('key', 'x')]),
    ('undo_paste', 'mat', [('click', 300, 130), ('ckey', 'c'), ('move', 500, 500), ('ckey', 'v')]),
    ('undo_frame', 'mat', [('click', 300, 130), ('key', 'c')]),
    ('undo_frame_move', 'mat', [('click', 300, 130), ('key', 'c'), ('drag', 300, 95, 330, 300)]),
    ('undo_wire_menu', 'mat', [('drag', 391, 168, 500, 500), ('type', 'invert'), ('key', 'enter')]),
    ('undo_tree', 'plain', [('click', 332, 68), ('move', 300, 300), ('skey', 'a'), ('type', 'cube'), ('key', 'enter')]),
    ('undo_logic', 'logic', [('move', 700, 500), ('skey', 'a'), ('type', 'begin'), ('key', 'enter')]),
]


def undo_redo(sc):
    print('-- undo and redo', flush=True)
    for name, scene, acts in UNDO:
        if not want('undo', name):
            continue
        bee = sc[scene]
        e, u, uu, r = f'{T}/{name}_e.bee', f'{T}/{name}_u.bee', f'{T}/{name}_uu.bee', f'{T}/{name}_r.bee'
        base = port_args(bee, NE, acts)
        port(base + ['--op', 'file.save_as ' + e])
        port(base + ['--key', 'ctrl+z', '--op', 'file.save_as ' + u])
        port(base + ['--key', 'ctrl+z'] * 6 + ['--op', 'file.save_as ' + uu])
        port(base + ['--key', 'ctrl+z', '--key', 'ctrl+shift+z', '--op', 'file.save_as ' + r])
        g0, ge, gu, guu, gr = graphs(bee), graphs(e), graphs(u), graphs(uu), graphs(r)
        check(ge[0] is not None and ge != g0, f'{name}: the edit changed the graph (control)')
        check(gu[0] is not None and gu != ge, f'{name}: one undo takes the edit away ({"the graph before it" if gu == g0 else "a step inside it"})')
        check(guu == g0, f'{name}: undos to the end give the graph before the edit')
        check(gr == ge, f'{name}: redo gives the edit again')
    # a pick-up and its link: two steps
    if want('undo', 'undo_pickup'):
        bee = sc['mat']
        acts = [('drag', 420, 240, 20, 358)]     # (Hue/Saturation's Color picked up, onto Noise's Offset)
        u1, u2 = f'{T}/pk_u1.bee', f'{T}/pk_u2.bee'
        base = port_args(bee, NE, acts)
        port(base + ['--key', 'ctrl+z', '--op', 'file.save_as ' + u1])
        port(base + ['--key', 'ctrl+z', '--key', 'ctrl+z', '--op', 'file.save_as ' + u2])
        check(graphs(u1)[0] is not None and graphs(u1) != graphs(bee), 'a link picked up and dropped elsewhere: one undo takes the new link alone')
        check(graphs(u2) == graphs(bee), 'two undos: the graph as it was')


def look(sc):
    print('-- the look: every node type, at two zooms', flush=True)
    sys.path.insert(0, HERE)
    from nodeed_scene import pages, scene
    bee = os.path.join(T, 'all.bee')
    if want('look', *[f'{k}{i}_{z}' for k, i, _ in pages() for z in (100, 50)]):
        ok, bee = scene_file('all', scene())
        check(ok, 'BeeModel made the every-type scene')
    for kind, i, names in pages():
        shots = {}
        for z in (100, 50):
            name = f'{kind}{i}_{z}'
            if not want('look', name):
                continue
            setup = [('select', f'O{kind}{i}')] + NE
            acts = [('op', 'node.zoom', str(z))] if z != 100 else []
            pp = f'{T}/{name}_p.ppm'
            rc = port(port_args(bee, setup, acts), pp)
            n = colours(pp) if rc == 0 else 0
            check(rc == 0 and n > 8, f'{name}: {", ".join(names)}: drawn ({n} colours)')
            shots[z] = pp if rc == 0 else None
        if shots.get(100) and shots.get(50):
            check(pixdiff(shots[100], shots[50]) > 0, f'{kind}{i}: 50 % not drawn as 100 %')
    # the menus, the palette, the pane's shapes, no thumbnails, far out: each shows something new
    bee = sc['mat']
    plain = f'{T}/look_base.ppm'
    port(port_args(bee, NE, []), plain)
    for name, acts, box in (
            ('add_menu', [('move', 300, 300), ('skey', 'a')], (0, 300, 1280, 680)),
            ('add_menu_typed', [('move', 300, 300), ('skey', 'a'), ('type', 'te')], (0, 300, 1280, 680)),
            ('palette', [('op', 'node.preview', '0'), ('click', 480, 68), ('move', 640, 400)], (0, 104, 1280, 680)),
            ('cube_pane', [('op', 'node.preview', '1 cube')], (1091, 107, 1273, 289)),
            ('plane_pane', [('op', 'node.preview', '1 plane')], (1091, 107, 1273, 289)),
            ('turned_pane', [('drag', 1180, 200, 1230, 170)], (1091, 107, 1273, 289)),
            ('no_thumbnails', [('op', 'node.thumbnails', '0')], CANVAS),
            ('fit', [('key', 'home')], CANVAS),
            ('zoom_33', [('op', 'node.zoom', '33')], CANVAS),
            ('zoom_150', [('op', 'node.zoom', '150')], CANVAS),
            ('minimap', [('click', 1200, 720)], (1100, 645, 1280, 728))):
        if not want('look', name):
            continue
        pp = f'{T}/{name}_p.ppm'
        rc = port(port_args(bee, NE, acts), pp)
        n = pixdiff(plain, pp, box) if rc == 0 and os.path.exists(plain) else -1
        check(n > 0, f'{name}: drawn, not as before ({n} pixels changed)')


def context_menu(sc):
    """The right button's menu: its items."""
    if not want('look', 'context_menu'):
        return
    ui = f'{T}/cm.txt'
    port(port_args(sc['mat'], NE, [('rclick', 300, 130)]) + ['--dump-ui', ui])
    pm = [ln.split('\t')[1] for ln in open(ui) if ln.startswith('menuitem\t')] if os.path.exists(ui) else []
    check(len(pm) > 0 and len(set(pm)) == len(pm), f'the context menu: {len(pm)} items, none twice ({pm[:3]}...)')


def window(sc):
    """BeeModel's own window (tests/wl_fake.py) against its headless driver."""
    if not want('window'):
        return
    print('-- the window', flush=True)
    import wl_fake
    d = tempfile.mkdtemp(prefix='nedw', dir='/tmp')
    bee = os.path.join(d, 'm.bee')
    shutil.copy(sc['mat'], bee)
    acts = [('drag', 300, 130, 350, 180), ('move', 500, 500), ('skey', 'a'), ('type', 'noise'), ('key', 'enter')]
    hb = f'{T}/w_h.bee'
    port(port_args(sc['mat'], NE, acts) + ['--op', 'file.save_as ' + hb])
    row = {c: k for k, c in zip(list(range(16, 26)) + list(range(30, 39)) + list(range(44, 51)), 'qwertyuiopasdfghjklzxcvbnm')}
    row.update({'.': 52, '/': 53, ' ': 57, '0': 11, '-': 12})
    row.update({str(i): i + 1 for i in range(1, 10)})
    f = wl_fake.Fake(BIN, size=(1280, 800), env={'BEE_CPU': CPU})
    HELD.append(f.proc)
    try:
        os.sched_setaffinity(f.proc.pid, {int(CPU)})
        f.until(lambda: f.frames > 0 and f.keyboard is not None and f.pointer is not None)
        f.enter(640, 400)
        f.motion(640, 400)
        f.pump(0.2)

        def line(s):
            f.key(28)
            for c in s:
                if c == '_':
                    f.key(12, 1)
                else:
                    f.key(row[c])
            f.key(28)
            f.pump(0.5)
        line('file.open ' + bee)
        line('area.type_node_editor')
        line('area.maximize')
        f.key(1)                                    # (out of the console's line)
        f.pump(0.2)
        t0 = os.path.getmtime(bee)

        def drag(x0, y0, x1, y1):
            f.motion(x0, y0)
            f.pump(0.05)
            f.button(0x110, True)
            f.pump(0.05)
            for s in range(1, 11):
                f.motion(x0 + (x1 - x0) * s // 10, y0 + (y1 - y0) * s // 10)
                f.pump(0.03)
            f.button(0x110, False)
            f.pump(0.1)
        drag(300, 130, 350, 180)
        f.motion(500, 500)
        f.pump(0.1)
        f.key(30, 1)                                # Shift+A
        for c in 'noise':
            f.key(row[c])
        f.key(28)
        f.pump(0.3)
        f.key(31, 4)                                # Ctrl+S
        f.until(lambda: os.path.getmtime(bee) != t0, 10)
        check(os.path.getmtime(bee) != t0, 'the window saved the file (Ctrl+S)')
        gh, gw = graphs(hb), graphs(bee)
        check(gw[0] is not None and gw[0] != graphs(sc['mat'])[0] and nodes(gw) == nodes(graphs(sc['mat'])) + 1,
              f'a node dragged and one added by Shift+A in the window ({nodes(gw)} nodes)')
        check(gw == gh, 'the window: the same bytes as the headless driver gives')
    finally:
        f.close()
        shutil.rmtree(d, True)


def damaged(sc):
    """Graphs that pass the readers' checks (types, links and counts are checked
    there) but carry wild values, places, frames and flags: NaN, infinities,
    huge numbers, positions at the i16 limits, frames without a title's end."""
    if not want('damaged'):
        return
    print('-- damaged graphs: drawn, no crash', flush=True)
    rng = random.Random(11)
    wild = [0x7fc00000, 0x7f800000, 0xff800000, 0x7f7fffff, 0xff7fffff, 0x4f000000, 0xcf000001, 0x00000001]

    def spoil(body, nodes_at, count_at, tail_at):
        n = struct.unpack_from('<I', body, count_at)[0]
        for k in range(min(n, 48)):
            o = nodes_at + k * 72
            for f in range(4):                                  # the values
                struct.pack_into('<I', body, o + 52 + f * 4, rng.choice(wild + [rng.getrandbits(32)]))
            for i in range(3):                                  # the inputs' constants
                for c in range(3):
                    struct.pack_into('<I', body, o + 4 + i * 16 + 4 + c * 4, rng.choice(wild))
            struct.pack_into('<hh', body, o + 68, rng.choice([-32768, 32767, 0, rng.randrange(-32768, 32768)]),
                             rng.choice([-32768, 32767, 1, rng.randrange(-32768, 32768)]))
        if tail_at is not None:
            for f in range(6):                                  # comment frames
                fo = tail_at + f * 48
                struct.pack_into('<hhhh', body, fo, *[rng.randrange(-32768, 32768) for _ in range(4)])
                for b in range(12, 48):
                    body[fo + b] = rng.randrange(1, 256)
            for b in range(48):                                 # collapsed flags
                body[tail_at + 288 + b] = rng.randrange(256)

    bad = 0
    runs = 0
    for k in range(6 * RUNS):
        for which, tag in (('mat', b'MGRF'), ('logic', b'NTRE')):
            raw = open(sc[which], 'rb').read()
            out = bytearray(raw[:8])
            for t, body in beefile.chunks(raw):     # (written plain: the port reads both)
                body = bytearray(body)
                if t == tag == b'MGRF':
                    o = 12
                    for _ in range(struct.unpack_from('<I', body, 8)[0]):
                        n = struct.unpack_from('<I', body, o)[0]
                        spoil(body, o + 4 + 32, o + 4, o + 4 + 32 + n * 72 + 64)
                        o += 4 + 32 + n * 72 + 480
                elif t == tag == b'NTRE':
                    for r in range(struct.unpack_from('<I', body, 0)[0]):
                        base = 4 + r * 4096
                        spoil(body, base + 160, base + 128, base + 3680)
                out += t + struct.pack('<I', len(body)) + body
            p = os.path.join(T, f'bad{k}{which}.bee')
            open(p, 'wb').write(out)
            args = ['--op', 'file.open ' + p, '--select', 'Cube'] + sum([['--op', s[0]] for s in NE], [])
            for z in ('25', '50', '100', '200'):
                args += ['--op', 'node.zoom ' + z, '--key', '102', '--move', '300,300', '--key', 'shift+a', '--key', 'esc',
                         '--drag', '300,130,350,180', '--key', 'h', '--key', 'c', '--op', 'node.preview 1 cube']
            rc = port(args, timeout=120)
            runs += 1
            if rc != 0:
                bad += 1
                print(f'    {p}: rc {rc}')
    check(bad == 0, f'{runs} damaged graphs (wild values, places, frames): no crash ({bad})')


def main():
    try:
        sc = scenes()
        edits(sc)
        undo_redo(sc)
        look(sc)
        context_menu(sc)
        window(sc)
        damaged(sc)
    finally:
        for p in HELD:
            try:
                p.kill()
            except Exception:
                pass
        shutil.rmtree(T, True)
    print(f'nodeed: fails {len(FAILS)}')
    sys.exit(1 if FAILS else 0)


main()
