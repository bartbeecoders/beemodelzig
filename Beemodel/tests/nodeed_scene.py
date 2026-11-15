"""The node editor tests' every-type scene: each node type of the three catalogues,
seven to a page (a material, a geometry node tree, a logic graph on an object of
its own), placed in a row, a few links."""
MAT = "image noise checker gradient mix ramp math bump normalmap texcoord position normal camera vcolor time constant color fresnel vmath separate combine mapping panner rotator voronoi hsv invert brightcon desaturate gamma blackbody brick wave whitenoise triplanar reroute scalarparam vectorparam textureparam fninput fnoutput fncall".split()
GEO = "input output grid cube sphere cylinder line transform join set_position extrude subdivide boolean merge realize position normal index value combine_xyz separate_xyz math vector_math noise random group distribute instance curve_line curve_circle curve_to_mesh resample trim fillet curve_to_points terrain terrace erode lsystem".split()
LOG = "begin tick key overlap hit timer message move rotate set_property spawn destroy play_action impulse visibility send set_variable branch variable math info get_property shatter set_strength field".split()

def pages(per=7):
    out = []
    for kind, names in (('M', MAT), ('G', GEO), ('L', LOG)):
        for p in range(0, len(names), per):
            out.append((kind, p // per + 1, names[p:p + per]))
    return out

def scene():
    s = []
    for kind, i, names in pages():
        o = f'O{kind}{i}'
        s.append(f'add("cube", "{o}", {i * 3}, 0, 0)')
        if kind == 'M':
            s.append(f'm = material("{kind}{i}")\nassign("{o}", m)')
            for k, t in enumerate(names):
                s.append(f'node(m, "{t}")\nop("material.node_move", "{kind}{i} {k + 1} {20 + 180 * k} {20 + 30 * (k % 2)}")')
        elif kind == 'G':
            s.append(f't = gtree("{kind}{i}")')
            for k, t in enumerate(names):
                s.append(f'gnode(t, "{t}")\nop("tree.node_move", "{kind}{i} {k + 1} {20 + 180 * k} {20 + 30 * (k % 2)}")')
            s.append(f'mm = modifier("{o}", "geometry")\nmodset("{o}", mm, "tree", t)')
        else:
            s.append(f'op("logic.new", "{kind}{i}")')
            for k, t in enumerate(names):
                s.append(f'op("logic.node", "{kind}{i} {t}")\nop("tree.node_move", "{kind}{i} {k + 1} {20 + 180 * k} {20 + 30 * (k % 2)}")')
            s.append(f'op("logic.attach", "{kind}{i} {o}")')
    # a few links, so wires of each kind show
    s.append('link("M2", 1, 2, 1)\nlink("M3", 2, 3, 1)\nsocket("M1", "base", 3)')
    s.append('op("tree.link", "G1 3 8 1")\nop("tree.link", "L1 1 2 1")')
    return '\n'.join(s)
