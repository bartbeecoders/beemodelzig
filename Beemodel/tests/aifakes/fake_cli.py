#!/usr/bin/env python3
"""A stand-in for the claude and grok programs (tests/ai.py puts it first on
PATH under both names, in the test's temp dir). It never reaches the network
or a real AI: it reads its arguments as the real ones do, logs what it was
given (argv, working directory, environment, stdin, its MCP configuration
file) to $HOME/<name>.runs.jsonl, and plays a scripted stream picked by a word
in the prompt. Where the real tool would call BeeModel, it starts the MCP
bridge its configuration names (beemodel --mcp-bridge) and calls tools.

Words: tower (build through the bridge), slow, fail, crash, garbage, huge,
noeol, maxturns, broken (an error result), toolerr, longtool, flood, orphan,
termignore, multi, unicode; --version prints a version.
"""
import json, os, signal, stat, subprocess, sys, time

NAME = os.path.basename(sys.argv[0])
ARGS = sys.argv[1:]
OUT = sys.stdout.buffer


def opt(flag, default=None):
    return ARGS[ARGS.index(flag) + 1] if flag in ARGS and ARGS.index(flag) + 1 < len(ARGS) else default


def say(obj):
    OUT.write((json.dumps(obj) + '\n').encode())
    OUT.flush()


def raw(b):
    OUT.write(b)
    OUT.flush()


def cfg_path():
    if NAME == 'claude':
        return opt('--mcp-config')
    return os.path.join(opt('--cwd', '.'), '.grok', 'config.toml')


def log_run():
    home = os.environ.get('HOME', '.')
    st0 = os.fstat(0)
    try:
        os.set_blocking(0, False)
        got = os.read(0, 16)
    except OSError:
        got = b'?'
    cfg = cfg_path()
    rec = {'args': ARGS, 'argv0': sys.argv[0], 'cwd': os.getcwd(),
           'stdin_dev': stat.S_ISCHR(st0.st_mode), 'stdin': got.decode('latin1'),
           'env': {k: os.environ.get(k) for k in ('BEEMODEL_SOCKET', 'OPENROUTER_API_KEY', 'BEEMODEL_AGENT_PERMISSION')},
           'stdout_is_stderr': os.path.sameopenfile(1, 2)}
    if cfg and os.path.exists(cfg):
        rec['cfg'] = open(cfg).read()
        rec['cfg_mode'] = stat.S_IMODE(os.stat(cfg).st_mode)
        rec['cfg_dir_mode'] = stat.S_IMODE(os.stat(os.path.dirname(cfg)).st_mode)
    with open(os.path.join(home, NAME + '.runs.jsonl'), 'a') as f:
        f.write(json.dumps(rec) + '\n')
    n = sum(1 for _ in open(os.path.join(home, NAME + '.runs.jsonl')))
    return n


def server():
    """The MCP server (command, args, env) its configuration names."""
    if NAME == 'claude':
        c = json.load(open(opt('--mcp-config')))['mcpServers']['beemodel']
        return c['command'], c['args'], c.get('env', {})
    import tomllib
    c = tomllib.load(open(cfg_path(), 'rb'))['mcp_servers']['beemodel']
    return c['command'], c['args'], c.get('env', {})


class Mcp:
    def __init__(self):
        cmd, args, env = server()
        self.p = subprocess.Popen([cmd, *args], env=dict(os.environ, **env), text=True,
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        self.n = 0
        self.call('initialize', {'protocolVersion': '2025-06-18', 'capabilities': {},
                                 'clientInfo': {'name': NAME, 'version': '9'}})

    def call(self, method, params):
        self.n += 1
        self.p.stdin.write(json.dumps({'jsonrpc': '2.0', 'id': self.n, 'method': method, 'params': params}) + '\n')
        self.p.stdin.flush()
        while True:
            ln = self.p.stdout.readline()
            if not ln:
                return {}
            r = json.loads(ln)
            if r.get('id') == self.n:
                return r

    def tool(self, name, args):
        r = self.call('tools/call', {'name': name, 'arguments': args}).get('result', {})
        return (r.get('content') or [{}])[0].get('text', ''), r.get('isError', False)

    def close(self):
        self.p.stdin.close()
        self.p.wait(5)


def main():
    if '--version' in ARGS:
        log_run()
        print('9.9.9 (Claude Code)' if NAME == 'claude' else 'grok 9.9.9\nsecond line')
        return 0
    n = log_run()
    prompt = opt('-p', '')
    sid = opt('--resume') or opt('-r') or 'sess-%s-%d' % (NAME, n)
    pre = 'mcp__beemodel__' if NAME == 'claude' else 'beemodel__'
    if 'termignore' in prompt:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
    say({'type': 'system', 'subtype': 'init', 'session_id': sid, 'model': 'fake', 'tools': [pre + 'scene_summary']})
    if 'cfuzz' in prompt:
        return cfuzz(int(prompt.split('cfuzz')[1].split()[0]), sid)
    if 'slow' in prompt or 'termignore' in prompt:
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Working on it.'}]}})
        time.sleep(60)
        return 0
    if 'orphan' in prompt:
        # a child that keeps the pipe open after this one ends
        subprocess.Popen(['sleep', '30'], start_new_session=True)
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Left a child behind.'}]}})
        say({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': sid})
        return 0
    if 'fail' in prompt:
        raw(b'the fake failed on purpose\n')
        print('and said so on stderr', file=sys.stderr, flush=True)
        return 3
    if 'crash' in prompt:
        raw(b'{"type":"assistant","message":{"content":[{"type":"text","text":"half a li')
        os.kill(os.getpid(), signal.SIGSEGV)
        return 0
    if 'maxturns' in prompt:
        say({'type': 'result', 'subtype': 'error_max_turns', 'is_error': True, 'session_id': sid})
        return 0
    if 'broken' in prompt:
        say({'type': 'result', 'subtype': 'error_during_execution', 'is_error': True, 'result': 'Something broke\non two lines', 'session_id': sid})
        return 0
    if 'garbage' in prompt:
        for ln in [b'plain text output', b'{not json', b'  {"type": "assistant", "message": }', b'[1, 2, 3]',
                   b'\x00\xff\xfe binary \x01', b'', b'    ', b'{"type":"unknown","x":1}',
                   b'{"type":"assistant","message":{"content":"a string, not a list"}}',
                   b'{"type":"user","message":{"content":[{"type":"tool_result","content":123}]}}',
                   b'{"type":"assistant","message":{"content":[{"type":"text","text":"tab\\there\\rand a CR"}]}}',
                   b'{"type":"assistant","message":{"content":[{"type":"text","text":""},{"type":"image"},{"type":"tool_use"}]}}',
                   b'{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"image"}]},{"type":"tool_result","content":[]},{"type":"tool_result","content":"\\u00e9t\\u00e9 \\ud83d\\ude00"}]}}',
                   b'{"type":"system","session_id":123}', b'{"type":"result","subtype":"","is_error":false}',
                   b'{"type":"result","is_error":"yes"}', b'{"type":"result","is_error":true}',
                   b'{' * 70 + b'}' * 70, b'\r', b'{"type":"assistant","message":{"content":[{"type":"text","text":"done with the garbage"}]}}']:
            raw(ln + b'\n')
        say({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': sid})
        return 0
    if 'huge' in prompt:
        for size in (262142, 262143, 262144, 600000):
            raw(b'{"type":"user","message":{"content":[{"type":"tool_result","content":"' + b'Q' * (size - 60) + b'"}]}}' + b' ' * 4 + b'\n')
            say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'after %d' % size}]}})
        say({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': sid})
        return 0
    if 'noeol' in prompt:
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'no newline at the end'}]}})
        raw(json.dumps({'type': 'result', 'subtype': 'error_x', 'is_error': True, 'result': 'the last line', 'session_id': sid}).encode())
        return 0
    if 'flood' in prompt:
        for i in range(3000):
            raw(b'{"type":"assistant","message":{"content":[{"type":"text","text":"line %d of the flood, with some words to make it longer"}]}}\n' % i)
        say({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': sid})
        return 0
    if 'multi' in prompt or 'unicode' in prompt:
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'First line\n\nThird line after an empty one\n  indented\n' + 'w' * 2100}]}})
        say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Ünïcödé ✓ 漢字 — fine'}]}})
        say({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': sid})
        return 0
    m = Mcp()
    if 'toolerr' in prompt:
        text, err = m.tool('no_such_tool', {})
        say({'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 't1', 'name': pre + 'no_such_tool', 'input': {}}]}})
        say({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': text, 'is_error': err}]}})
        text, err = m.tool('script_eval', {'code': 'print(1/0'})
        say({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't2', 'content': [{'type': 'text', 'text': text}], 'is_error': err}]}})
        say({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': sid})
        m.close()
        return 0
    if 'longtool' in prompt:
        code = 'x = 1\n' * 120 + 'add("cube", "Long", 3, 0, 0)\nprint("a\\nb\\nc", ' + '"y" + ' * 30 + '"z")'
        say({'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 't1', 'name': pre + 'script_eval', 'input': {'code': code}}]}})
        text, err = m.tool('script_eval', {'code': code})
        say({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': text + '\n' + 'r' * 300, 'is_error': err}]}})
        say({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': sid})
        m.close()
        return 0
    if '--- What this request is about' in prompt:
        return ask(m, prompt, sid, pre)
    # tower (and anything else): look, build through the bridge, answer
    say({'type': 'assistant', 'message': {'role': 'assistant', 'content': [
        {'type': 'text', 'text': 'Looking at the scene first.'},
        {'type': 'tool_use', 'id': 't1', 'name': pre + 'scene_summary', 'input': {}}]}, 'session_id': sid})
    text, err = m.tool('scene_summary', {})
    say({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': text[:300], 'is_error': err}]}})
    base = 'Tower' if NAME == 'claude' else 'Grok'
    code = 'for i in 0..3 { add("cube", "%s" + str(i), 0, 0.5 + i, 0) }\nprint("built", count())' % base
    say({'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 't2', 'name': pre + 'script_eval', 'input': {'code': code}}]}})
    text, err = m.tool('script_eval', {'code': code})
    say({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't2', 'content': [{'type': 'text', 'text': text}], 'is_error': err}]}})
    say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Built a tower of 3 cubes.\nAsk for a roof next.'}]}})
    say({'type': 'result', 'subtype': 'success', 'is_error': False, 'result': 'Built.', 'session_id': sid})
    m.close()
    return 0


def rtext(r):
    pool = ['plain', 'two\nlines', 'tab\there', 'cr\rhere', '', ' ', '  lead', 'é ü 漢 😀', '\\', '"quoted"', '\x01\x02',
            'x' * r.randrange(0, 3000), 'word ' * r.randrange(0, 600), '\n\n\n', 'end\n']
    return ''.join(r.choice(pool) for _ in range(r.randrange(0, 4)))


def revent(r):
    k = r.randrange(9)
    if k == 0:
        return {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': rtext(r)} for _ in range(r.randrange(0, 3))]}}
    if k == 1:
        return {'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 't', 'name': r.choice(['mcp__beemodel__x', 'beemodel__y', 'z', '', 'mcp__beemodel__']),
                                                              'input': r.choice([{}, {'code': rtext(r)}, [1, 2], 'str', None, {'a': {'b': [rtext(r)]}}])}]}}
    if k == 2:
        c = r.choice([rtext(r), [{'type': 'text', 'text': rtext(r)}], [{'type': 'image'}], [], 5, None, {'text': 'x'}])
        return {'type': 'user', 'message': {'content': [{'type': 'tool_result', 'content': c, 'is_error': r.choice([True, False, 'true', 1, None])}]}}
    if k == 3:
        return {'type': 'result', 'subtype': r.choice(['success', 'error_max_turns', 'error_x', '', None, 5]), 'is_error': r.choice([True, False, None]),
                'result': r.choice([rtext(r), None, 7]), 'session_id': r.choice(['s%d' % r.randrange(9), '', None, 'x' * 300])}
    if k == 4:
        return {'type': 'system', 'session_id': r.choice(['s%d' % r.randrange(9), '', 'y' * 200, None])}
    if k == 5:
        return {'type': r.choice(['assistant', 'user', 'result', 'other', '', None]), 'message': r.choice([None, {}, {'content': None}, {'content': 'str'}, {'content': [None, 1, 'x', {}]}])}
    if k == 6:
        return [rtext(r)]
    if k == 7:
        return rtext(r)
    return {'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': rtext(r)}], 'extra': {'deep': [[[[r.randrange(9)]]]]}}}


def cfuzz(seed, sid):
    """A random stream: events of every shape, broken lines, odd bytes, a line
    past the buffer now and then, written in random pieces; a random end."""
    import random
    r = random.Random(seed)
    out = bytearray()
    for _ in range(r.randrange(1, 25)):
        b = json.dumps(revent(r), ensure_ascii=r.random() < 0.5).encode('utf-8', 'surrogatepass')
        m = r.randrange(14)
        if m == 0:
            b = b[:r.randrange(len(b) + 1)]
        elif m == 1:
            b = bytes(r.randrange(256) for _ in range(r.randrange(60)))
        elif m == 2:
            b = b'  ' + b + b'  \r'
        elif m == 3 and r.random() < 0.3:
            b = b'{"type":"user","message":{"content":[{"type":"tool_result","content":"' + b'Z' * r.choice([262000, 262141, 262142, 262143, 270000]) + b'"}]}}'
        out += b + r.choice([b'\n', b'\n', b'\n', b'\r\n', b'\n\n'])
    if r.random() < 0.2:
        out = out.rstrip(b'\n')
    k = 0
    while k < len(out):
        n = r.randrange(1, 70000)
        raw(bytes(out[k:k + n]))
        k += n
        if r.random() < 0.2:
            time.sleep(0.01)
    return r.choice([0, 0, 0, 1, 2, 127, 255])


def ask(m, prompt, sid, pre):
    """Ask AI: the request, then what was selected. "bigger" doubles the
    selected objects, "stray" moves the Light too, "delete the light" deletes it."""
    req = prompt.split('\n\n--- What')[0].strip()
    low = req.lower()
    names = [json.loads(ln[ln.index('{"name":'):])['name'] for ln in prompt.split('\n') if '{"name":' in ln]
    if 'delete the light' in low:
        code = 'delete("Light")\nprint(count())'
    elif 'bigger' in low or 'stray' in low:
        code = ''.join('scale("%s", get("%s", "sx") * 2, get("%s", "sy") * 2, get("%s", "sz") * 2)\n' % (n, n, n, n) for n in names)
        if 'stray' in low:
            code += 'move("Light", 9, 9, 9)\nmove("Camera", 1, 2, 3)\n'
        code += 'print("done")'
    else:
        code = 'print("nothing to do")'
    say({'type': 'assistant', 'message': {'content': [{'type': 'tool_use', 'id': 't1', 'name': pre + 'script_eval', 'input': {'code': code}}]}, 'session_id': sid})
    text, err = m.tool('script_eval', {'code': code})
    say({'type': 'user', 'message': {'content': [{'type': 'tool_result', 'tool_use_id': 't1', 'content': text, 'is_error': err}]}})
    say({'type': 'assistant', 'message': {'content': [{'type': 'text', 'text': 'Done: %s (%s).\nAnything else?' % (req[:60], ', '.join(names))}]}})
    say({'type': 'result', 'subtype': 'success', 'is_error': False, 'session_id': sid})
    m.close()
    return 0


sys.exit(main())
