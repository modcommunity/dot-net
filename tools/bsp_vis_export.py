#!/usr/bin/env python3
"""Export a BSP's cluster PVS for tools/visibility_bench.gd, in metres and Godot axes.

    python3 tools/bsp_vis_export.py <dot-map-convert dir> <map.bsp> <out.json> [--scale=0.01905] [--points=400] [--seed=1]

The arrays are what dot-map-convert's `vis.attach` packs into a converted map's `vis` record (and
what `DotNetVisibility.bake_bsp` reads), plus the spawns and `points`: random standing positions
(a random empty leaf, dropped to the floor, 36 units up), the bench's positions. Needs numpy (the
dot-map-convert reader does). A map converted with a `vis` record needs none of this:
`DotNetVisibility.from_dot_map_mesh` reads it directly.
"""
import base64
import json
import random
import sys


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    if len(args) != 3:
        print(__doc__)
        return 2
    convert, bsp_path, out_path = args
    scale = float(opts.get("scale", "0.01905"))
    count = int(opts.get("points", "400"))
    rng = random.Random(int(opts.get("seed", "1")))
    sys.path.insert(0, convert)
    from dotbsp import reader, vis  # noqa: E402

    b = reader.Bsp(bsp_path)
    b.load()
    v = vis.Vis(b)
    if v.clusters <= 0 or v.head < 0:
        print("no visibility data in %s" % bsp_path)
        return 1

    def to_godot(p):
        return [p[0] * scale, p[2] * scale, -p[1] * scale]

    planes = []
    for pl in b.planes:
        planes += [pl[0], pl[2], -pl[1], pl[3] * scale]
    nodes = []
    for n in b.nodes:
        nodes += [n[0], n[1], n[2]]
    leaf_cluster = [l[1] for l in b.leafs]
    pvs, offsets = v.compact_rows()

    m = b.models[0]
    lo, hi = to_godot(m[0:3]), to_godot(m[3:6])
    bounds = [min(lo[i], hi[i]) for i in range(3)] + [abs(hi[i] - lo[i]) for i in range(3)]

    def empty(p):
        leaf = v.leaf_at(p)
        return 0 <= leaf < len(b.leafs) and b.leafs[leaf][1] >= 0 and not (b.leafs[leaf][0] & 1)

    candidates = [l for l in b.leafs if l[1] >= 0 and not (l[0] & 1)]
    points, tries = [], 0
    while len(points) < count and tries < count * 200:
        tries += 1
        l = rng.choice(candidates)
        p = [rng.uniform(l[3 + i], l[6 + i]) for i in range(3)]
        if not empty(p):
            continue
        z, floor = p[2], None
        while z > m[2]:
            if not empty([p[0], p[1], z - 4.0]):
                floor = z
                break
            z -= 4.0
        if floor is None:
            continue
        stand = [p[0], p[1], floor + 36.0]
        # Room for a standing player: the head clear too.
        if not empty(stand) or not empty([p[0], p[1], floor + 64.0]):
            continue
        points.append([round(x, 3) for x in to_godot(stand)])

    spawns = []
    for e in b.entities:
        if "spawn" in e.get("classname", "") and e.get("origin"):
            spawns.append([round(x, 3) for x in to_godot([float(t) for t in e["origin"].split()])])

    out = {
        "map": bsp_path.rsplit("/", 1)[-1], "scale": scale, "clusters": v.clusters, "head": v.head,
        "planes": planes, "nodes": nodes, "leaf_cluster": leaf_cluster, "pvs_offsets": offsets,
        "pvs": base64.b64encode(pvs).decode(), "bounds": bounds, "spawns": spawns, "points": points,
        "areas": len(v.areas), "areaportals": len(v.areaportals),
    }
    with open(out_path, "w") as f:
        json.dump(out, f)
    print("%s: %d clusters, %d planes, %d nodes, %d leafs, %d PVS bytes, %d points, %d spawns" % (
        out["map"], v.clusters, len(b.planes), len(b.nodes), len(b.leafs), len(pvs), len(points), len(spawns)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
