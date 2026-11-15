#!/usr/bin/env python3
"""Each guard of tests/mcp.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that section of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/mcp_mutants.py WORKDIR [name...]   (WORKDIR under /tmp)

The builds (release: small, the quota of /tmp) run one after the other and so do
the tests: they pin BeeModel to BEE_CPU (default 12).
"""
import os, shutil, subprocess, sys
import temphome  # noqa: F401 (a HOME of its own: the user's ~/.config stays as it is)

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
W = os.path.abspath(sys.argv[1])
M = [  # name, file, old, new, the sections that must fail
    # --- JSON
    ('json: nesting to 65', 'src/json.zig', 'const MAX_DEPTH = 64;', 'const MAX_DEPTH = 65;', 'proto'),
    ('json: trailing zeros kept', 'src/json.zig', "while (n > start and w.b.items[n - 1] == '0') n -= 1;", '_ = &n;', 'proto'),
    ('json: control characters raw', 'src/json.zig', '} else if (c < 0x20) {', '} else if (c < 0x01) {', 'proto'),
    ('json: an escaped quote ends a string', 'src/json.zig', "                    if (s == '\\\\') {\n                        i += 1;\n                        continue;\n                    }", '', 'proto'),
    ('json: \\u not decoded', 'src/json.zig', "                    if (code < 0x80) {\n                        c = @truncate(code);", "                    if (true) {\n                        c = @truncate(code);", 'proto'),
    # --- the protocol, the tools
    ('tools/list: hidden operators listed', 'src/mcp.zig', 'if (!flags.safe[i] or e.hidden) continue;', 'if (!flags.safe[i]) continue;', 'proto'),
    ('notifications answered', 'src/mcp.zig', 'const rid = id orelse return; // notifications get no answer', 'const rid = id orelse "null";', 'proto'),
    ('rotation in radians', 'src/mcp.zig', 'const k: f32 = 0.017453293;', 'const k: f32 = 1.0;', 'tools'),
    ('size not scaled', 'src/mcp.zig', 'return .{ (hi[0] - lo[0]) * @abs(wp[6]), (hi[1] - lo[1]) * @abs(wp[7]), (hi[2] - lo[2]) * @abs(wp[8]) };', '_ = wp;\n    return .{ hi[0] - lo[0], hi[1] - lo[1], hi[2] - lo[2] };', 'tools'),
    ('rename: not unique', 'src/mcp.zig', '        if (objFind(nm) == null) break;', '        break;', 'tools'),
    ('select: extend ignored', 'src/mcp.zig', '    if (!extend) scene.deselectAll();', '    if (!extend or true) scene.deselectAll();', 'tools'),
    # --- permissions, undo, the activity
    ('files: an edit', 'src/agent.zig', 'if (std.mem.startsWith(u8, id, "file.")) return 2;', 'if (std.mem.startsWith(u8, id, "file.")) return 1;', 'perm'),
    ('read-only: not by prefix', 'src/agent.zig', 'if (std.mem.startsWith(u8, e, "read")) {', 'if (std.mem.eql(u8, e, "read-only")) {', 'perm'),
    ('the refusal worded otherwise', 'src/mcp.zig', '"\' permission and agents are set to \'"', '"\' permission, agents are set to \'"', 'perm'),
    ('a request not one step', 'src/mcp.zig', '        undo.groupBegin();\n        dispatch(&mark);\n        changed = undo.groupEnd(label);', '        dispatch(&mark);\n        undo.label(label);\n        changed = false;', 'undo'),
    ('the step not named', 'src/mcp.zig', 'std.fmt.bufPrint(&lb, "Agent: {s}", .{tool})', 'std.fmt.bufPrint(&lb, "Edit: {s}", .{tool})', 'window'),
    ('revert: any step', 'src/agent.zig', '    return std.mem.startsWith(u8, undo.nameOf(undo.current()), "Agent:");', '    return true;', 'window'),
    # --- materials
    ('material_graph_set: a failure kept', 'src/mcpmat.zig', '    defer if (!ok) {\n        ma.graph = save;', '    defer if (!ok) {\n        _ = &save;', 'mat'),
    ('graph_json: no sockets', 'src/mcpmat.zig', '        if (p & 0xffff == 0) continue;\n        if (written)', '        if (true) continue;\n        if (written)', 'mat'),
    ('param names from 0', 'src/graphops.zig', 'for (sg.nodesOf(ma)[0 .. n + 1]) |*x| {', 'for (sg.nodesOf(ma)[0..n]) |*x| {', 'mat'),
    # --- the transport
    ('only the first line of a read', 'src/mcp.zig', '        cl_len[k] = rest;\n    }', '        cl_len[k] = 0;\n        break;\n    }', 'fuzz'),
    ('a fifth client kept waiting', 'src/mcp.zig', '            } else _ = linux.close(fd); // full', '            } else {}', 'fuzz'),
    ('a long line kept', 'src/mcp.zig', '    if (room == 0) return dropClient(k);', '    if (room == 0) {\n        cl_len[k] = 0;\n        return;\n    }', 'fuzz'),
    ('the bridge says nothing', 'src/mcp.zig', 'const e = "beemodel: no running BeeModel to bridge to (start it first)\\n";', 'const e = "";', 'bridge'),
]
want = sys.argv[2:]
if want:
    M = [x for x in M if x[0] in want]
os.makedirs(W, exist_ok=True)
bad = []
for k, (name, fn, old, new, sec) in enumerate(M):
    d = f'{W}/m{k}'
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    try:
        shutil.copytree(f'{ROOT}/src', f'{d}/src')
        shutil.copytree(f'{ROOT}/tests', f'{d}/tests')
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', d)
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            print(f'  ?    {name}: the code is not there', flush=True)
            bad.append(name)
            continue
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run(['zig', 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '--release=fast'], cwd=d, capture_output=True, text=True)
        if r.returncode != 0:
            print(f'  ?    {name}: it does not build: {r.stderr[-300:]}', flush=True)
            bad.append(name)
            continue
        e = dict(os.environ, MCP_ONLY=sec, MCP_FUZZ='60')
        r = subprocess.run([sys.executable, '-u', f'{d}/tests/mcp.py', f'{d}/out/bin/beemodel'],
                           env=e, capture_output=True, text=True, timeout=1800)
        fails = [ln for ln in r.stdout.splitlines() if 'FAIL' in ln]
        if r.returncode != 0 and not fails:
            fails = [f'it stopped ({r.returncode}) ' + r.stderr[-160:]]
        st = 'ok' if fails else 'LIVE'
        print(f'  {st:4} {name}: ' + (f'{len(fails)} failed in {sec}: {fails[0].strip()[:100]}' if fails else f'nothing in {sec} failed'), flush=True)
        if not fails:
            bad.append(name)
    finally:
        shutil.rmtree(d, ignore_errors=True)
print('survivors', len(bad), bad)
sys.exit(1 if bad else 0)
