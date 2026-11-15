"""Reading .bee files in the tests: chunks, whatever the version."""
import struct, zlib


def chunks(path_or_bytes):
    """[(tag, data)] in the file's order, ZCHK inflated."""
    d = open(path_or_bytes, 'rb').read() if isinstance(path_or_bytes, str) else path_or_bytes
    assert d[:4] == b'BEEM', 'not a .bee file'
    out, o = [], 8
    while len(d) - o >= 8:
        tag, size = d[o:o + 4], struct.unpack_from('<I', d, o + 4)[0]
        body = d[o + 8:o + 8 + size]
        if tag == b'ZCHK':
            tag, raw = body[:4], struct.unpack_from('<I', body, 4)[0]
            body = zlib.decompress(body[8:], -15)
            assert len(body) == raw
        out.append((tag, body))
        o += 8 + size
    return out


def chunk(path_or_bytes, tag):
    for t, b in chunks(path_or_bytes):
        if t == tag:
            return b
    return None


def meshes(path_or_bytes):
    """The MESH chunks as (verts [(x, y, z)], polygons [[v...]])."""
    out = []
    for t, b in chunks(path_or_bytes):
        if t != b'MESH':
            continue
        nv, np, nl = struct.unpack_from('<III', b)
        v = struct.unpack_from(f'<{nv * 3}f', b, 12)
        off = struct.unpack_from(f'<{np + 1}I', b, 12 + nv * 12)
        loops = struct.unpack_from(f'<{nl}I', b, 12 + nv * 12 + (np + 1) * 4)
        out.append(([v[i * 3:i * 3 + 3] for i in range(nv)], [list(loops[off[i]:off[i + 1]]) for i in range(np)]))
    return out


def objects(path_or_bytes):
    """OBJS as dicts: name, loc, rot, scl, type, flags, mesh."""
    b = chunk(path_or_bytes, b'OBJS')
    n = struct.unpack_from('<I', b)[0]
    out = []
    for k in range(n):
        r = b[4 + k * 84:4 + (k + 1) * 84]
        f = struct.unpack_from('<9f', r, 32)
        out.append(dict(name=r[:32].split(b'\0')[0].decode(), loc=f[:3], rot=f[3:6], scl=f[6:9], color=struct.unpack_from('<I', r, 68)[0],
                        type=struct.unpack_from('<I', r, 72)[0], flags=struct.unpack_from('<I', r, 76)[0], mesh=struct.unpack_from('<I', r, 80)[0]))
    return out


REC = 1856


def workspaces(c):
    """WSPC parsed: (current, [workspace]); trees as nested tuples, numbers gone."""
    n, cur = struct.unpack_from('<II', c)
    out = []
    for k in range(n):
        r = c[8 + k * REC:8 + (k + 1) * REC]
        root, act, vp, maxed, tab = struct.unpack_from('<IiIiI', r, 24)
        node = lambda i: r[64 + i * 32:64 + (i + 1) * 32]
        cam = lambda i: struct.unpack_from('<6f', r, 64 + 32 * 32 + i * 24)

        def tree(i):
            b = node(i)
            if b[0] == 1:
                return ('leaf', b[1], tuple(round(x, 3) for x in cam(i)) if b[1] == 0 else None)
            return ('split', b[0], struct.unpack_from('<I', b, 4)[0], tree(b[8]), tree(b[9]))
        floats = sorted((node(i)[10], node(i)[1], struct.unpack_from('<4i', node(i), 12)) for i in range(32) if node(i)[0] == 1 and node(i)[3] & 1)
        out.append(dict(name=r[:24].split(b'\0')[0].decode(), tree=tree(root), floats=floats, tab=tab, maxed=maxed >= 0))
    return cur, out
