#!/usr/bin/env python3
"""A stand-in for curl (tests/ai.py puts it first on PATH). It takes the
arguments the AI Assistant gives curl (-sS -m 600 -H @headers
[--data-binary @body] URL), logs them with the files' contents and modes to
$HOME/curl.runs.jsonl, and talks to 127.0.0.1 only: any other host fails as
an unknown one would, so nothing reaches the network. With FAKE_CURL_REAL set
it runs that real curl instead, after the same check."""
import json, os, stat, sys, urllib.parse

ARGS = sys.argv[1:]


def main():
    hdr = body = None
    url = None
    i = 0
    while i < len(ARGS):
        a = ARGS[i]
        if a == '-H':
            hdr = ARGS[i + 1]
            i += 2
        elif a == '--data-binary':
            body = ARGS[i + 1]
            i += 2
        elif a == '-m':
            i += 2
        elif a.startswith('-'):
            i += 1
        else:
            url = a
            i += 1
    rec = {'args': ARGS, 'url': url}
    for k, v in (('hdr', hdr), ('body', body)):
        if v and v.startswith('@') and os.path.exists(v[1:]):
            p = v[1:]
            rec[k + '_path'] = p
            rec[k + '_mode'] = stat.S_IMODE(os.stat(p).st_mode)
            rec[k + '_dir_mode'] = stat.S_IMODE(os.stat(os.path.dirname(p)).st_mode)
            rec[k] = open(p, 'rb').read().decode('utf-8', 'replace')
    home = os.environ.get('HOME', '.')
    with open(os.path.join(home, 'curl.runs.jsonl'), 'a') as f:
        f.write(json.dumps(rec) + '\n')
    u = urllib.parse.urlsplit(url or '')
    if u.hostname not in ('127.0.0.1', 'localhost') or u.scheme != 'http':
        sys.stderr.write('curl: (6) Could not resolve host: %s\n' % (u.hostname or ''))
        return 6
    real = os.environ.get('FAKE_CURL_REAL')
    if real:
        os.execv(real, [real] + ARGS)
    import http.client
    headers = {}
    if hdr and hdr.startswith('@'):
        for ln in open(hdr[1:]).read().split('\n'):
            if ':' in ln:
                k, v = ln.split(':', 1)
                headers[k.strip()] = v.strip()
    data = open(body[1:], 'rb').read() if body and body.startswith('@') else None
    try:
        c = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=600)
        c.request('POST' if data is not None else 'GET', u.path + ('?' + u.query if u.query else ''), body=data, headers=headers)
        r = c.getresponse()
        out = r.read()
    except ConnectionRefusedError:
        sys.stderr.write("curl: (7) Failed to connect to %s port %d after 0 ms: Couldn't connect to server\n" % (u.hostname, u.port or 80))
        return 7
    except Exception as e:  # (a server that hangs up)
        sys.stderr.write('curl: (52) Empty reply from server\n')
        return 52
    sys.stdout.buffer.write(out)
    sys.stdout.flush()
    return 0


sys.exit(main())
