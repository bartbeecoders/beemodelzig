#!/usr/bin/env python3
"""Each guard of tests/ai.py shown failing: the code it guards broken, one
thing at a time, in a copy of the sources; that section of the suite must then
fail. A mutant that survives is a test that passes on nothing.

    python3 tests/ai_mutants.py WORKDIR [name...]   (WORKDIR under /tmp)

The builds (release: small, the quota of /tmp) run one after the other, each
removed when its test is done, and so do the tests: they pin the program to
BEE_CPU (default 12).
"""
import os, re, shutil, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
# zig as the repo's mise.toml picks it (its shim finds no version in WORKDIR),
# asked before temphome moves HOME and the XDG folders away from mise's
_mz = subprocess.run(['mise', 'which', 'zig'], cwd=ROOT, capture_output=True, text=True) if shutil.which('mise') else None
ZIG = _mz.stdout.strip() if _mz and _mz.returncode == 0 and _mz.stdout.strip() else 'zig'
import temphome  # noqa: F401,E402 (a HOME of its own: the user's ~/.config stays as it is)
W = os.path.abspath(sys.argv[1])
M = [  # name, file, old, new, the sections that must fail
    # --- the child process (aiproc.zig)
    ('stderr not in the pipe', 'src/aiproc.zig', '        _ = linux.dup2(p[1], 2);\n', '', 'cli'),
    ('stdin not /dev/null', 'src/aiproc.zig', '        if (linux.errno(devnull) == .SUCCESS) _ = linux.dup2(@intCast(devnull), 0);\n', '        _ = devnull;\n', 'headless'),
    ('Stop: no KILL after TERM', 'src/aiproc.zig', '        if (kill_at == 0) _ = linux.kill(pid, .KILL);', '        if (kill_at == 0) {}', 'cli'),
    ('the end waits for the pipe', 'src/aiproc.zig', '    var st0: i32 = 0;\n    const w = linux.wait4', '    if (fd >= 0) return;\n    var st0: i32 = 0;\n    const w = linux.wait4', 'cli'),
    ('private files 0644', 'src/aiproc.zig', '.TRUNC = true, .CLOEXEC = true }, 0o600);', '.TRUNC = true, .CLOEXEC = true }, 0o644);', 'or'),
    ('the AI folder not 0700', 'src/aiproc.zig', '    _ = linux.chmod(@ptrCast(&dir), 0o700);\n', '', 'or'),
    # --- the CLIs' stream (ai.zig)
    ('a longer line buffer', 'src/ai.zig', 'const LINE_CAP = 262144;', 'const LINE_CAP = 262144 * 4;', 'cli'),
    ('a skipped line\'s end read', 'src/ai.zig', '                line_skip = false; // (the end of a skipped one)', '                line_skip = false;\n                cliLine(line[0..nl]);', 'cli'),
    ('the MCP prefix kept', 'src/ai.zig', '    if (std.mem.startsWith(u8, nm, s_strip)) nm = nm[s_strip.len..];\n', '', 'cli'),
    ('no resume', 'src/ai.zig', '    if (sid_len > 0 and sid_prov == which + 1) {', '    if (sid_len > 0 and sid_prov == which + 2) {', 'cli'),
    ('not one undo step', 'src/ai.zig', '    undo.groupBegin();\n    grouped = true;', '    grouped = false;', 'cli'),
    ('the bridge misnamed', 'src/ai.zig', '        req.raw(",\\"args\\":[\\"--mcp-bridge\\"],\\"env\\":{\\"BEEMODEL_SOCKET\\":");', '        req.raw(",\\"args\\":[\\"--mcp-bridgex\\"],\\"env\\":{\\"BEEMODEL_SOCKET\\":");', 'cli'),
    ('Enter does not send', 'src/ai.zig', '.hint = s_prompt_hint, .enter_sends = true', '.hint = s_prompt_hint, .enter_sends = false', 'cli'),
    ('the world text one word off', 'src/ai.zig', 'Answer briefly: what you built', 'Answer shortly: what you built', 'fuzz'),
    # --- OpenRouter
    ('a step more', 'src/ai.zig', '    if (or_n >= (if (local) ol_steps else or_steps)) {', '    if (or_n > (if (local) ol_steps else or_steps)) {', 'or'),
    ('tool results cut at 120', 'src/ai.zig', '        hist.q(tmpS()[0..@min(tmp_len, 12000)]);', '        hist.q(tmpS()[0..@min(tmp_len, 120)]);', 'or'),
    ('Ollama thinks', 'src/ai.zig', '    if (local) rbody.raw(",\\"reasoning_effort\\":\\"none\\"");\n', '', 'or'),
    ('no key sent', 'src/ai.zig', '    if (proc.curl(url[0..url_len], rbody.items(), if (local) null else hdr[0..hdr_len])) return true;', '    if (proc.curl(url[0..url_len], rbody.items(), null)) return true;', 'or'),
    ('the indent one short', 'src/ai.zig', 'spaces[15 - @min(p.len, 15) ..]', 'spaces[15 - @min(p.len, 14) ..]', 'or'),
    ('the step not an agent\'s', 'src/ai.zig', '    @memcpy(label[0..7], "Agent: ");', '    @memcpy(label[0..7], "Agent  ");', 'cli'),
    # --- Ask AI
    ('scope not asked for', 'src/aiask.zig', '    if (scope) ctx.raw("Change only the selection.', '    if (false) ctx.raw("Change only the selection.', 'ask'),
    ('a move not seen', 'src/aiask.zig', '    H(&h, o.loc);\n', '', 'ask'),
    ('names joined by commas', 'src/aiask.zig', '        if (k > 0) at = put(b, at, if (k + 1 == n) " and " else ", ");', '        if (k > 0) at = put(b, at, ", ");', 'ask'),
    ('15 listed', 'src/aiask.zig', '            if (listed >= 16) break;', '            if (listed >= 15) break;', 'ask'),
    ('Up skips one', 'src/aiask.zig', '            const np = hpos + 1; // Up: older', '            const np = hpos + 2; // Up: older', 'ask'),
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
        shutil.copytree(f'{ROOT}/tests', f'{d}/tests', ignore=shutil.ignore_patterns('__pycache__'))
        shutil.copy(f'{ROOT}/build.zig', d)
        if os.path.exists(f'{ROOT}/build.zig.zon'):
            shutil.copy(f'{ROOT}/build.zig.zon', d)
            # (its path dependencies, ../BeeZigUi: next to the copy, a link to the real one)
            for rel in re.findall(r'\.path = "\.\./([^"/]+)"', open(f'{ROOT}/build.zig.zon').read()):
                if not os.path.exists(f'{W}/{rel}'):
                    os.symlink(os.path.normpath(os.path.join(ROOT, '..', rel)), f'{W}/{rel}')
        p = f'{d}/{fn}'
        t = open(p).read()
        if old not in t:
            print(f'  ?    {name}: the code is not there', flush=True)
            bad.append(name)
            continue
        open(p, 'w').write(t.replace(old, new, 1))
        r = subprocess.run([ZIG, 'build', '-p', f'{d}/out', '--cache-dir', f'{d}/zc', '--release=fast'], cwd=d, capture_output=True, text=True)
        shutil.rmtree(f'{d}/zc', ignore_errors=True)
        if r.returncode != 0:
            print(f'  ?    {name}: it does not build: {r.stderr[-300:]}', flush=True)
            bad.append(name)
            continue
        env = dict(os.environ, AI_ONLY=sec, AI_FUZZ='30')
        r = subprocess.run([sys.executable, f'{HERE}/ai.py', f'{d}/out/bin/beemodel'], env=env, capture_output=True, text=True, timeout=1800)
        last = [ln for ln in r.stdout.split('\n') if ln.startswith('ai: fails')]
        n = int(last[-1].split()[-1]) if last else -1
        if n > 0:
            print(f'  ok   {name}: caught ({n} fail in {sec})', flush=True)
        else:
            print(f'  FAIL {name}: survived ({sec}: {last})', flush=True)
            bad.append(name)
    finally:
        shutil.rmtree(d, ignore_errors=True)
print(f'ai_mutants: {len(M) - len(bad)} of {len(M)} caught')
print(f'ai_mutants: fails {len(bad)}')
sys.exit(1 if bad else 0)
