#!/usr/bin/env python3
"""OpenUSD's own reading of a layer (pxr's Sdf): every spec's fields as
file.usd_dump writes them ("path TAB field TAB value", the value forms
usdlayer.zig's dumpText documents; dump_lines here). tests/usd.py compares
BeeModel's file.usd_dump of the same file with this.

    LD_PRELOAD=/usr/lib/libjemalloc.so.2 python3 tests/usd_pxr.py FILE...

prints, per file, "== FILE" then its lines.
"""
import struct, sys
from pxr import Gf, Sdf, Vt


def x4(x):
    """x 10000, rounded to the nearest (even), as an integer (wDbl)."""
    return str(int(round(float(x) * 10000.0)))


def f32(x):
    return struct.unpack('<f', struct.pack('<f', float(x)))[0]


def form(v):
    """A value as file.usd_dump writes it: "i n", "d n", "s text", "v k n ..",
    "f n x sum abs", "a n x sum abs", "l n a|b", "r n asset>path|..",
    "m n set=sel|..", "none"; an empty list: LIST0 (any empty kind)."""
    if v is None or v in ('dict', 'timesamples') or (isinstance(v, tuple) and v[:1] == ('ty',)):
        return 'none'
    if isinstance(v, bool):
        return 'i %d' % int(v)
    if isinstance(v, int):
        return 'i %d' % v
    if isinstance(v, float):
        return 'd ' + x4(v)
    if isinstance(v, str):
        return 's ' + v
    if isinstance(v, tuple):
        return 'v %d %s' % (len(v), ' '.join(x4(x) for x in v))
    if isinstance(v, list):
        if not v:
            return 'LIST0'
        e = v[0]
        if isinstance(e, str):
            return 'l %d %s' % (len(v), '|'.join(v))
        if isinstance(e, tuple) and len(e) == 2 and (e[0] is None or isinstance(e[0], str)) and (e[1] is None or isinstance(e[1], str)):
            if all(isinstance(a, str) and isinstance(b, str) for a, b in v) and v is not None and getattr(form, 'vsel', False):
                pass
            return 'r %d %s' % (len(v), '|'.join('%s>%s' % (a or '', b or '') for a, b in v))
        flat = [c for x in v for c in (x if isinstance(x, tuple) else (x,))]
        k = len(v[0]) if isinstance(v[0], tuple) else 1
        if all(isinstance(c, int) and not isinstance(c, bool) for c in flat) or all(isinstance(c, bool) for c in flat):
            ints = [int(c) for c in flat]
            return 'a %d %d %d %d' % (len(v), k, sum(ints), sum(abs(c) for c in ints))
        fl = [f32(c) for c in flat]
        return 'f %d %d %s %s' % (len(v), k, x4(sum(fl)), x4(sum(abs(c) for c in fl)))
    return '?'


def dump_lines(specs):
    out = []
    for path, _, fields in specs:
        for k, v in fields.items():
            if k == 'variantSelection' and isinstance(v, list):
                out.append('%s\t%s\t%s' % (path, k, 'm %d %s' % (len(v), '|'.join('%s=%s' % ab for ab in v)) if v else 'LIST0'))
            else:
                out.append('%s\t%s\t%s' % (path, k, form(v)))
    return out


def i32(x):
    x &= 0xffffffff
    return x - (1 << 32) if x >= 1 << 31 else x


def items(op):
    out = []
    if op.isExplicit:
        out += list(op.explicitItems)
    else:
        for name in ('explicitItems', 'addedItems', 'prependedItems', 'appendedItems'):
            out += list(getattr(op, name))
    return out


def ref(r):
    p = str(r.primPath) if r.primPath and not r.primPath.isEmpty else None
    return (r.assetPath, p)


def val(v, field=''):
    if v is None:
        return None
    if isinstance(v, bool):
        return v
    if type(v).__name__ in ('Specifier', 'Variability', 'Permission'):
        return int(v.value)
    if isinstance(v, int):
        return v
    if isinstance(v, float):
        return v
    if isinstance(v, str):
        return v
    if isinstance(v, Sdf.AssetPath):
        return v.path
    if isinstance(v, Sdf.Path):
        return str(v)
    if isinstance(v, Sdf.TimeCode):
        return float(v)
    if isinstance(v, (Gf.Quatf, Gf.Quatd, Gf.Quath)):
        return tuple(float(x) for x in v.imaginary) + (float(v.real),)
    if isinstance(v, (Gf.Matrix2d, Gf.Matrix3d, Gf.Matrix4d)):
        n = {Gf.Matrix2d: 2, Gf.Matrix3d: 3, Gf.Matrix4d: 4}[type(v)]
        return tuple(float(v[i][j]) for i in range(n) for j in range(n))
    if not type(v).__name__.endswith('Array') and type(v).__name__.startswith('Vec') or isinstance(v, (Gf.Vec2f, Gf.Vec3f, Gf.Vec4f, Gf.Vec2d, Gf.Vec3d, Gf.Vec4d, Gf.Vec2h, Gf.Vec3h, Gf.Vec4h)):
        return tuple(float(x) for x in v)
    if isinstance(v, (Gf.Vec2i, Gf.Vec3i, Gf.Vec4i)):
        return tuple(float(x) for x in v)
    if isinstance(v, (Sdf.ReferenceListOp, Sdf.PayloadListOp)):
        return [ref(r) for r in items(v)]
    if isinstance(v, Sdf.Payload):
        return [ref(v)]
    if isinstance(v, (Sdf.TokenListOp, Sdf.StringListOp)):
        return [str(x) for x in items(v)]
    if isinstance(v, Sdf.PathListOp):
        return [str(x) for x in items(v)]
    if isinstance(v, dict):
        if field == 'variantSelection':
            return sorted((str(a), str(b)) for a, b in v.items())
        return 'dict'
    tn = type(v).__name__
    if tn.endswith('Array') or isinstance(v, (list, tuple)):
        out = [val(x) for x in v]
        if tn in ('Int64Array', 'UInt64Array', 'UIntArray'):
            out = [i32(x) for x in out]
        if tn == 'BoolArray':
            out = [int(x) for x in out]
        if tn in ('Vec2iArray', 'Vec3iArray', 'Vec4iArray'):
            out = [tuple(int(c) for c in x) for x in out]
        if tn == 'TimeCodeArray':
            out = [float(x) for x in out]
        return out
    if field == 'timeSamples':
        return 'timesamples'
    return ('ty', tn)


def fields(lay, p):
    """A spec's fields: its info keys (pxr's Python lists those), and the
    ones it keeps as children and list ops."""
    s = lay.GetObjectAtPath(p)
    f = {}
    if s is None:
        return f
    for k in s.ListInfoKeys():
        if not s.HasInfo(k):            # (a required field at its fallback: not in the file)
            continue
        try:
            f[k] = val(s.GetInfo(k), k)
        except Exception as e:          # (a kind pxr's Python cannot give)
            f[k] = ('ty', str(e)[:20])
    if p == Sdf.Path.absoluteRootPath:
        names = [c.name for c in lay.rootPrims]
        if names:
            f['primChildren'] = names
        if lay.subLayerPaths:
            f['subLayers'] = list(lay.subLayerPaths)
        if 'subLayerOffsets' in f or lay.subLayerPaths:
            f.setdefault('subLayerOffsets', 'dict')
        return f
    if isinstance(s, Sdf.PrimSpec):
        names = [c.name for c in s.nameChildren]
        if names:
            f['primChildren'] = names
        props = [c.name for c in s.properties]
        if props:
            f['properties'] = props
        vs = list(s.variantSets.keys())
        if vs:
            f['variantSetChildren'] = vs
    elif isinstance(s, Sdf.VariantSetSpec):
        vs = [v.name for v in s.variants.values()] if hasattr(s.variants, 'values') else list(s.variants)
        if vs:
            f['variantChildren'] = vs
    elif isinstance(s, Sdf.AttributeSpec):
        if s.connectionPathList.isExplicit or len(items(s.connectionPathList)):
            f['connectionPaths'] = [str(x) for x in items(s.connectionPathList)]
    elif isinstance(s, Sdf.RelationshipSpec):
        if s.targetPathList.isExplicit or len(items(s.targetPathList)):
            f['targetPaths'] = [str(x) for x in items(s.targetPathList)]
    return f


def dump(path):
    lay = Sdf.Layer.FindOrOpen(path)
    specs = []
    paths = []
    lay.Traverse(Sdf.Path.absoluteRootPath, lambda p: paths.append(p))
    for p in paths:
        specs.append((str(p), 0, fields(lay, p)))
    return dump_lines(specs)


if __name__ == '__main__':
    for fn in sys.argv[1:]:
        print('== ' + fn)
        try:
            for line in dump(fn):
                print(line)
        except Exception as e:
            print('!! %s' % e)
