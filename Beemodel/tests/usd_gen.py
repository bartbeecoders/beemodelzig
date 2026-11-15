#!/usr/bin/env python3
"""Random OpenUSD files made with OpenUSD itself (pxr), for tests/usd.py: each
seed a stage (.usda) with what file.import_usd reads - transforms of every
kind, meshes (n-gons, left-handed, UVs per point / per corner, indexed or
not), GeomSubsets binding materials, UsdPreviewSurface materials (values,
textures, UsdTransform2d), references to another file and inside the file,
payloads, variant sets, instanceable prims, classes, inactive prims, guides,
invisible prims, rigid bodies and joints - its crate twin (.usdc, written by
pxr), and a layer of every value type for the readers.

    LD_PRELOAD=/usr/lib/libjemalloc.so.2 python3 tests/usd_gen.py OUTDIR SEED [N]
    LD_PRELOAD=... python3 tests/usd_gen.py --big OUTDIR TRIANGLES PRIMS

writes OUTDIR/s<seed>.usda, s<seed>.usdc, s<seed>_ref.usda, types<seed>.usda /
.usdc (N seeds from SEED); --big: one large crate file (big.usdc). With
USDGEN_NOAXIS set no rotateX / Y / Z ops and of the three-axis rotations
rotateXYZ alone (tests/usd.py's imports; s_stage asks for all of them).
"""
import math, os, random, struct, sys, zlib
from pxr import Gf, Sdf, Usd, UsdGeom, UsdShade, Vt

try:
    from pxr import UsdPhysics
except ImportError:
    UsdPhysics = None


def png(path, w, h, f):
    raw = b''.join(b'\0' + bytes(c for x in range(w) for c in f(x, y)) for y in range(h))
    def ch(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xffffffff)
    open(path, 'wb').write(b'\x89PNG\r\n\x1a\n' + ch(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0))
                           + ch(b'IDAT', zlib.compress(raw)) + ch(b'IEND', b''))


def mesh(r, stage, path, left=False, uvmode=0, indexed=False, ngon=False):
    m = UsdGeom.Mesh.Define(stage, path)
    nx, ny = r.randint(1, 4), r.randint(1, 4)
    pts = [(x + r.uniform(-.2, .2), y + r.uniform(-.2, .2), r.uniform(-.5, .5)) for y in range(ny + 1) for x in range(nx + 1)]
    counts, idx = [], []
    for y in range(ny):
        for x in range(nx):
            a = y * (nx + 1) + x
            q = [a, a + 1, a + nx + 2, a + nx + 1]
            if ngon and r.random() < .3:
                counts += [3, 3]
                idx += [q[0], q[1], q[2], q[0], q[2], q[3]]
            else:
                counts.append(4)
                idx += q
    if r.random() < .15:
        counts.append(2)                        # (a face of two corners: left out)
        idx += [0, 1]
    m.CreatePointsAttr([Gf.Vec3f(*p) for p in pts])
    m.CreateFaceVertexCountsAttr(counts)
    m.CreateFaceVertexIndicesAttr(idx)
    if left:
        m.CreateOrientationAttr('leftHanded')
    if uvmode:
        pv = UsdGeom.PrimvarsAPI(m).CreatePrimvar(r.choice(['st', 'st', 'UVMap', 'uv', 'map1', 'st0']),
                                                   Sdf.ValueTypeNames.TexCoord2fArray,
                                                   UsdGeom.Tokens.vertex if uvmode == 1 else UsdGeom.Tokens.faceVarying)
        n = len(pts) if uvmode == 1 else len(idx)
        if indexed:
            k = max(2, n // 2)
            pv.Set([Gf.Vec2f(r.random(), r.random()) for _ in range(k)])
            pv.SetIndices(Vt.IntArray([r.randrange(k) for _ in range(n)]))
        else:
            pv.Set([Gf.Vec2f(r.random(), r.random()) for _ in range(n)])
    return m, len(counts)


def xform_ops(r, x):
    xf = UsdGeom.Xformable(x)
    kinds = r.sample(['t', 's', 'rx', 'ry', 'rz', 'r3', 'or', 'tf', 'piv'], r.randint(0, 4))
    if os.environ.get('USDGEN_NOAXIS'):     # (no rotateX / Y / Z)
        kinds = [k for k in kinds if k not in ('rx', 'ry', 'rz')]
    for k in kinds:
        if k == 't':
            xf.AddTranslateOp().Set(Gf.Vec3d(r.uniform(-3, 3), r.uniform(-3, 3), r.uniform(-3, 3)))
        elif k == 's':
            xf.AddScaleOp(opSuffix='s%d' % r.randrange(9)).Set(Gf.Vec3f(r.choice([1, 2, .5, -1]), r.uniform(.5, 2), r.uniform(.5, 2)))
        elif k in ('rx', 'ry', 'rz'):
            op = {'rx': xf.AddRotateXOp, 'ry': xf.AddRotateYOp, 'rz': xf.AddRotateZOp}[k]
            op(opSuffix='a%d' % r.randrange(9)).Set(r.uniform(-180, 180))
        elif k == 'r3':
            op = r.choice([xf.AddRotateXYZOp, xf.AddRotateXZYOp, xf.AddRotateYXZOp, xf.AddRotateYZXOp, xf.AddRotateZXYOp, xf.AddRotateZYXOp])
            if os.environ.get('USDGEN_NOAXIS'):    # (rotateXYZ alone)
                op = xf.AddRotateXYZOp
            op(opSuffix='b%d' % r.randrange(9)).Set(Gf.Vec3f(r.uniform(-90, 90), r.uniform(-90, 90), r.uniform(-90, 90)))
        elif k == 'or':
            q = Gf.Quatf(r.uniform(-1, 1), r.uniform(-1, 1), r.uniform(-1, 1), r.uniform(-1, 1)).GetNormalized()
            xf.AddOrientOp(opSuffix='c%d' % r.randrange(9)).Set(q)
        elif k == 'tf':
            m = Gf.Matrix4d().SetRotate(Gf.Rotation(Gf.Vec3d(r.random(), r.random(), r.random() + .1), r.uniform(-90, 90)))
            m.SetTranslateOnly(Gf.Vec3d(r.uniform(-2, 2), 0, r.uniform(-2, 2)))
            if r.random() < .3:
                m = m * Gf.Matrix4d(Gf.Vec4d(1, 1.5, 1, 1))          # (a shear after the turn: baked)
            xf.AddTransformOp(opSuffix='d%d' % r.randrange(9)).Set(m)
        elif k == 'piv':
            p = xf.AddTranslateOp(opSuffix='pivot')
            p.Set(Gf.Vec3d(r.uniform(-1, 1), r.uniform(-1, 1), 0))
            a = r.uniform(-90, 90)
            if os.environ.get('USDGEN_NOAXIS'):
                xf.AddRotateXYZOp(opSuffix='pv').Set(Gf.Vec3f(0, 0, a))
            else:
                xf.AddRotateZOp(opSuffix='pv').Set(a)
            xf.AddTranslateOp(opSuffix='pivot', isInverseOp=True)
    if r.random() < .08:
        xf.SetResetXformStack(True)


def material(r, stage, path, texdir, ntex):
    mt = UsdShade.Material.Define(stage, path)
    sh = UsdShade.Shader.Define(stage, path + '/S')
    sh.CreateIdAttr('UsdPreviewSurface')
    mt.CreateSurfaceOutput().ConnectToSource(sh.ConnectableAPI(), 'surface')
    if r.random() < .5:
        sh.CreateInput('diffuseColor', Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(r.random(), r.random(), r.random()))
    if r.random() < .5:
        sh.CreateInput('metallic', Sdf.ValueTypeNames.Float).Set(r.random())
    if r.random() < .5:
        sh.CreateInput('roughness', Sdf.ValueTypeNames.Float).Set(r.random())
    if r.random() < .3:
        sh.CreateInput('opacity', Sdf.ValueTypeNames.Float).Set(r.choice([1.0, .4, r.random()]))
    if r.random() < .3:
        sh.CreateInput('ior', Sdf.ValueTypeNames.Float).Set(r.uniform(1, 2.5))
    if r.random() < .2:
        sh.CreateInput('opacityThreshold', Sdf.ValueTypeNames.Float).Set(r.choice([0.0, .5]))
    if r.random() < .3:
        sh.CreateInput('emissiveColor', Sdf.ValueTypeNames.Color3f).Set(Gf.Vec3f(r.random(), r.random(), 0))
    if ntex and r.random() < .6:
        st = UsdShade.Shader.Define(stage, path + '/St')
        st.CreateIdAttr('UsdPrimvarReader_float2')
        st.CreateInput('varname', Sdf.ValueTypeNames.Token).Set('st')
        src = st.ConnectableAPI()
        if r.random() < .5:
            x2 = UsdShade.Shader.Define(stage, path + '/X2')
            x2.CreateIdAttr('UsdTransform2d')
            x2.CreateInput('in', Sdf.ValueTypeNames.Float2).ConnectToSource(st.ConnectableAPI(), 'result')
            x2.CreateInput('scale', Sdf.ValueTypeNames.Float2).Set(Gf.Vec2f(r.choice([1, 2, 3]), r.choice([1, 2])))
            x2.CreateInput('translation', Sdf.ValueTypeNames.Float2).Set(Gf.Vec2f(r.random(), 0))
            src = x2.ConnectableAPI()
        def tex(name, out, f):
            t = UsdShade.Shader.Define(stage, path + '/' + name)
            t.CreateIdAttr('UsdUVTexture')
            t.CreateInput('file', Sdf.ValueTypeNames.Asset).Set('./tex/t%d.png' % r.randrange(ntex))
            t.CreateInput('st', Sdf.ValueTypeNames.Float2).ConnectToSource(src, 'result')
            sh.CreateInput(f, Sdf.ValueTypeNames.Float3 if out == 'rgb' else Sdf.ValueTypeNames.Float).ConnectToSource(t.ConnectableAPI(), out)
            return t
        if r.random() < .7:
            tex('Base', 'rgb', 'diffuseColor')
        kind = r.randrange(4)
        if kind == 0:                                # one ORM map: b metallic, g roughness
            t = tex('Orm', 'b', 'metallic')
            sh.CreateInput('roughness', Sdf.ValueTypeNames.Float).ConnectToSource(t.ConnectableAPI(), 'g')
        elif kind == 1:                              # a map each (one channel)
            tex('Met', r.choice(['r', 'g', 'b']), 'metallic')
            tex('Rough', r.choice(['r', 'g', 'b']), 'roughness')
        elif kind == 2:
            tex('Rough', 'r', 'roughness')
        if r.random() < .4:
            t = UsdShade.Shader.Define(stage, path + '/Nrm')
            t.CreateIdAttr('UsdUVTexture')
            t.CreateInput('file', Sdf.ValueTypeNames.Asset).Set('./tex/t%d.png' % r.randrange(ntex))
            sh.CreateInput('normal', Sdf.ValueTypeNames.Normal3f).ConnectToSource(t.ConnectableAPI(), 'rgb')
        if r.random() < .2:
            tex('Emi', 'rgb', 'emissiveColor')
    return mt


def stage_of(r, out, seed, ntex):
    path = os.path.join(out, 's%d.usda' % seed)
    ref = os.path.join(out, 's%d_ref.usda' % seed)
    # the referenced file: a prim with meshes, a default prim, a material of its own
    rs = Usd.Stage.CreateNew(ref)
    UsdGeom.SetStageUpAxis(rs, r.choice(['Y', 'Z']))
    pr = UsdGeom.Xform.Define(rs, '/Part')
    rs.SetDefaultPrim(pr.GetPrim())
    xform_ops(r, pr)
    m, _ = mesh(r, rs, '/Part/Body', uvmode=r.randrange(3), indexed=r.random() < .5)
    mt = material(r, rs, '/Part/Looks/M', out, ntex)
    UsdShade.MaterialBindingAPI.Apply(m.GetPrim()).Bind(mt)
    UsdGeom.Xform.Define(rs, '/Other')
    mesh(r, rs, '/Other/Leg')
    rs.GetRootLayer().Save()

    st = Usd.Stage.CreateNew(path)
    UsdGeom.SetStageUpAxis(st, r.choice(['Y', 'Z', 'Z']))
    UsdGeom.SetStageMetersPerUnit(st, r.choice([1, .01, .01, .1, 2.5]))
    root = UsdGeom.Xform.Define(st, '/World')
    st.SetDefaultPrim(root.GetPrim())
    xform_ops(r, root)
    mats = [material(r, st, '/World/Looks/M%d' % k, out, ntex) for k in range(r.randint(1, 3))]
    def walk(parent, d):
        for k in range(r.randint(1, 3)):
            p = '%s/N%d_%d' % (parent, d, k)
            kind = r.random()
            if kind < .45 or d >= 3:
                mm, nf = mesh(r, st, p, left=r.random() < .2, uvmode=r.randrange(3), indexed=r.random() < .5, ngon=r.random() < .5)
                xform_ops(r, mm)
                if r.random() < .6:
                    UsdShade.MaterialBindingAPI.Apply(mm.GetPrim()).Bind(r.choice(mats))
                if r.random() < .3:
                    sub = UsdGeom.Subset.Define(st, p + '/Sub')
                    sub.CreateElementTypeAttr('face')
                    sub.CreateFamilyNameAttr(r.choice(['materialBind', 'materialBind', 'other']))
                    sub.CreateIndicesAttr([f for f in range(nf) if r.random() < .5] + [nf + 5])
                    UsdShade.MaterialBindingAPI.Apply(sub.GetPrim()).Bind(r.choice(mats))
                if r.random() < .1:
                    UsdGeom.Imageable(mm).CreatePurposeAttr(r.choice(['guide', 'proxy', 'render']))
                if r.random() < .08:
                    UsdGeom.Imageable(mm).CreateVisibilityAttr('invisible')
                if r.random() < .06:
                    mm.GetPrim().SetActive(False)
            else:
                x = UsdGeom.Xform.Define(st, p)
                xform_ops(r, x)
                if r.random() < .3:
                    UsdShade.MaterialBindingAPI.Apply(x.GetPrim()).Bind(r.choice(mats))
                if r.random() < .25:
                    x.GetPrim().GetReferences().AddReference('./s%d_ref.usda' % seed, r.choice(['', '/Part', '/Other']) or Sdf.Path())
                    x.GetPrim().SetInstanceable(r.random() < .5)
                    continue
                elif r.random() < .15:
                    x.GetPrim().GetPayloads().AddPayload('./s%d_ref.usda' % seed)
                    continue
                elif r.random() < .15:
                    vs = x.GetPrim().GetVariantSets().AddVariantSet('look')
                    for v in ('a', 'b'):
                        vs.AddVariant(v)
                        vs.SetVariantSelection(v)
                        with vs.GetVariantEditContext():
                            mesh(r, st, p + '/V' + v, uvmode=1)
                    vs.SetVariantSelection(r.choice(['a', 'b']))
                walk(p, d + 1)
    walk('/World', 0)
    cls = st.CreateClassPrim('/_Proto')
    mesh(r, st, '/_Proto/M')
    inst = UsdGeom.Xform.Define(st, '/World/Inst')
    inst.GetPrim().GetReferences().AddInternalReference('/_Proto')
    xform_ops(r, inst)
    if UsdPhysics is not None and r.random() < .5:
        b = UsdGeom.Xform.Define(st, '/World/Body')
        UsdPhysics.RigidBodyAPI.Apply(b.GetPrim())
        if r.random() < .5:
            UsdPhysics.MassAPI.Apply(b.GetPrim()).CreateMassAttr(r.uniform(.1, 5))
        bm, _ = mesh(r, st, '/World/Body/Box')
        UsdPhysics.CollisionAPI.Apply(bm.GetPrim())
        UsdPhysics.MeshCollisionAPI.Apply(bm.GetPrim()).CreateApproximationAttr(r.choice(['convexHull', 'boundingCube', 'boundingSphere', 'none']))
        b2 = UsdGeom.Xform.Define(st, '/World/Body2')
        UsdPhysics.RigidBodyAPI.Apply(b2.GetPrim())
        mesh(r, st, '/World/Body2/Lid')
        j = r.choice([UsdPhysics.RevoluteJoint, UsdPhysics.PrismaticJoint, UsdPhysics.FixedJoint, UsdPhysics.SphericalJoint]).Define(st, '/World/J')
        j.CreateBody0Rel().SetTargets(['/World/Body'])
        j.CreateBody1Rel().SetTargets(['/World/Body2'])
        j.CreateLocalPos0Attr(Gf.Vec3f(r.uniform(-1, 1), 1, 0))
        if hasattr(j, 'CreateAxisAttr'):
            j.CreateAxisAttr(r.choice(['X', 'Y', 'Z']))
        if hasattr(j, 'CreateLowerLimitAttr') and r.random() < .7:
            j.CreateLowerLimitAttr(-r.uniform(10, 90))
            j.CreateUpperLimitAttr(r.uniform(10, 90))
    st.GetRootLayer().Save()
    Sdf.Layer.FindOrOpen(path).Export(os.path.join(out, 's%d.usdc' % seed))


def types_of(r, out, seed):
    """A layer of every value type, scalars and arrays."""
    lay = Sdf.Layer.CreateNew(os.path.join(out, 'types%d.usda' % seed))
    st = Usd.Stage.Open(lay)
    p = st.DefinePrim('/T', 'Xform')
    T = Sdf.ValueTypeNames
    def f():
        return float(r.choice([r.uniform(-1e3, 1e3), r.randint(-50, 50), 0.0, -0.0, 1e-9, 0.1, r.uniform(-1, 1)]))
    kinds = [(T.Bool, lambda: r.random() < .5), (T.UChar, lambda: r.randrange(256)), (T.Int, lambda: r.randint(-2**31, 2**31 - 1)),
             (T.UInt, lambda: r.randrange(2**32)), (T.Int64, lambda: r.randint(-2**40, 2**40)), (T.UInt64, lambda: r.randrange(2**40)),
             (T.Half, f), (T.Float, f), (T.Double, f), (T.TimeCode, f), (T.String, lambda: 'str%d \\ "q"' % r.randrange(99)),
             (T.Token, lambda: 'tok%d' % r.randrange(99)), (T.Asset, lambda: Sdf.AssetPath('./a%d.png' % r.randrange(9))),
             (T.Float2, lambda: Gf.Vec2f(f(), f())), (T.Float3, lambda: Gf.Vec3f(f(), f(), f())), (T.Float4, lambda: Gf.Vec4f(f(), f(), f(), f())),
             (T.Double2, lambda: Gf.Vec2d(f(), f())), (T.Double3, lambda: Gf.Vec3d(f(), f(), f())), (T.Half3, lambda: Gf.Vec3h(f(), f(), f())),
             (T.Int2, lambda: Gf.Vec2i(r.randint(-9, 9), 3)), (T.Int3, lambda: Gf.Vec3i(r.randint(-200, 200), 3, -1)),
             (T.Point3f, lambda: Gf.Vec3f(f(), f(), f())), (T.Color3f, lambda: Gf.Vec3f(r.random(), r.random(), r.random())),
             (T.Normal3f, lambda: Gf.Vec3f(0, 1, 0)), (T.TexCoord2f, lambda: Gf.Vec2f(r.random(), r.random())),
             (T.Quatf, lambda: Gf.Quatf(f(), f(), f(), f())), (T.Quatd, lambda: Gf.Quatd(f(), f(), f(), f())), (T.Quath, lambda: Gf.Quath(1, 0, 0, 0)),
             (T.Matrix4d, lambda: Gf.Matrix4d(*[f() for _ in range(16)])), (T.Matrix3d, lambda: Gf.Matrix3d(*[f() for _ in range(9)])),
             (T.Matrix2d, lambda: Gf.Matrix2d(*[f() for _ in range(4)])), (T.Matrix4d, lambda: Gf.Matrix4d(r.choice([1, 2, -3])))]
    for k, (tn, gen) in enumerate(kinds):
        p.CreateAttribute('s%d' % k, tn).Set(gen())
        n = r.choice([0, 1, 3, 7, 40, 300])
        try:
            p.CreateAttribute('a%d' % k, tn.arrayType).Set([gen() for _ in range(n)])
        except Exception:
            pass
    big = p.CreateAttribute('ints', T.IntArray)
    big.Set(Vt.IntArray([r.choice([0, 1, 2, 7, 1000, -5, 2**20]) * (i % 3) for i in range(r.choice([20, 500, 3000]))]))
    p.CreateAttribute('floats', T.FloatArray).Set(Vt.FloatArray([float(r.randint(-100, 100)) for _ in range(500)]))
    p.CreateAttribute('flut', T.FloatArray).Set(Vt.FloatArray([r.choice([.5, .25, 3.75]) for _ in range(500)]))
    p.CreateAttribute('hlut', T.HalfArray).Set(Vt.HalfArray([r.choice([.5, .25, 3.75]) for _ in range(300)]))
    p.CreateAttribute('dlut', T.DoubleArray).Set(Vt.DoubleArray([r.choice([.5, .1, 3.75]) for _ in range(300)]))
    p.CreateAttribute('i64s', T.Int64Array).Set(Vt.Int64Array([r.randint(-1000, 1000) for _ in range(400)]))
    p.CreateRelationship('rel').SetTargets(['/T', '/T.s1'])
    p.SetMetadata('kind', 'component')
    p.SetMetadata('documentation', 'doc %d' % seed)
    p.GetReferences().AddReference('./x.usda', '/A')
    p.GetPayloads().AddPayload('./y.usda')
    p.SetMetadata('apiSchemas', Sdf.TokenListOp.Create(prependedItems=['A%d' % seed, 'B']))
    vs = p.GetVariantSets().AddVariantSet('v')
    vs.AddVariant('one')
    vs.SetVariantSelection('one')
    p.SetInstanceable(True)
    lay.Save()
    lay.Export(os.path.join(out, 'types%d.usdc' % seed))


def big(out, tris, prims):
    st = Usd.Stage.CreateNew(os.path.join(out, 'big.usda'))
    UsdGeom.Xform.Define(st, '/W')
    per = max(1, tris // prims)
    side = max(1, int(math.sqrt(per / 2)))
    for k in range(prims):
        m = UsdGeom.Mesh.Define(st, '/W/M%d' % k)
        UsdGeom.Xformable(m).AddTranslateOp().Set(Gf.Vec3d(k % 50, k // 50, 0))
        pts = [Gf.Vec3f(x / side, y / side, (x * y + k) % 7 * .01 + k * 1e-4) for y in range(side + 1) for x in range(side + 1)]
        idx = []
        for y in range(side):
            for x in range(side):
                a = y * (side + 1) + x
                idx += [a, a + 1, a + side + 2, a, a + side + 2, a + side + 1]
        m.CreatePointsAttr(pts)
        m.CreateFaceVertexCountsAttr([3] * (len(idx) // 3))
        m.CreateFaceVertexIndicesAttr(idx)
        pv = UsdGeom.PrimvarsAPI(m).CreatePrimvar('st', Sdf.ValueTypeNames.TexCoord2fArray, UsdGeom.Tokens.faceVarying)
        pv.Set([Gf.Vec2f((i % 7) / 7 + .01 + k * 1e-5, (i % 5) / 5 + .01) for i in range(len(idx))])
    st.GetRootLayer().Export(os.path.join(out, 'big.usdc'))
    os.remove(os.path.join(out, 'big.usda'))


def main():
    if sys.argv[1] == '--big':
        return big(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    out, seed = sys.argv[1], int(sys.argv[2])
    n = int(sys.argv[3]) if len(sys.argv) > 3 else 1
    os.makedirs(os.path.join(out, 'tex'), exist_ok=True)
    ntex = 4
    for k in range(ntex):
        w, h = [(8, 8), (16, 4), (3, 5), (64, 32)][k]
        png(os.path.join(out, 'tex', 't%d.png' % k), w, h, lambda x, y, k=k: ((x * 37 + k * 50) % 256, (y * 53) % 256, (x * y * 11) % 256, 255))
    for s in range(seed, seed + n):
        r = random.Random(s)
        stage_of(r, out, s, ntex)
        types_of(r, out, s)


if __name__ == '__main__':
    main()
