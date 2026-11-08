@tool
class_name DotNetVisibility
extends Resource

## A map's potentially visible set for snapshot interest: "could anything in the cluster at A see
## anything in the cluster at B". A point's cluster is a walk down the map's BSP tree (one plane test
## per level, about twenty on a mid-size map); the answer is one bit of a decoded PVS row.
## [br][br]
## [b]Conservative.[/b] The PVS is computed for whole clusters, so it only drops what no position in
## either cluster can see. A point inside solid (cluster -1), outside [member bounds], or with no data
## answers [code]true[/code]; the interest adds an audible radius on top
## ([member DotNetInterestDistance.visibility_audible_radius]). Doors (area portals) are not modelled:
## a closed door is treated as open. Server-side selection only: the wire format and the clients are
## untouched.
## [br][br]
## From a BSP's visibility ([method bake_bsp], [method from_dot_map_mesh]) or hand-made rooms
## ([method from_cells]); saved like any resource ([code]ResourceSaver[/code]). Read only once built, so
## safe on the snapshot workers. Assign to [member DotNetInterestDistance.visibility].

## Per plane nx, ny, nz, d in metres and Godot axes: a point is in front when n.p - d >= 0.
@export var planes: PackedFloat32Array = PackedFloat32Array()
## Per node: plane, front child, back child. A child below 0 is leaf -1 - child.
@export var nodes: PackedInt32Array = PackedInt32Array()
## The root node.
@export var head: int = 0
## Per leaf: its cluster, -1 for solid.
@export var leaf_cluster: PackedInt32Array = PackedInt32Array()
## Per cluster, [member row_bytes] bytes: bit c of byte c / 8 set when it may see cluster c.
@export var rows: PackedByteArray = PackedByteArray()
@export var row_bytes: int = 0
## Clusters in the source map.
@export var clusters: int = 0
## Outside this box every point answers visible. Empty: no bound.
@export var bounds: AABB = AABB()

## Identifies this set's contents to the native core, which keeps its own copy: a new value per
## instance and per rebuild. Never saved.
var serial: int = 0

static var _serials: int = 0


func _init() -> void:
	_bump()


func _bump() -> void:
	_serials += 1
	serial = _serials


## Whether this holds a usable set. An empty one answers everything visible.
func is_ready() -> bool:
	var node_count := nodes.size() / 3
	return clusters > 0 and row_bytes == (clusters + 7) >> 3 and rows.size() == clusters * row_bytes \
		and nodes.size() == node_count * 3 and node_count > 0 and head >= 0 and head < node_count \
		and planes.size() % 4 == 0 and not leaf_cluster.is_empty()


## The cluster at [param p], -1 for none (solid, outside [member bounds], no data). The same walk, in
## doubles, as the native core's.
func cluster_of(p: Vector3) -> int:
	if bounds.has_volume():
		var lo := bounds.position
		var hi := bounds.end
		if p.x < lo.x or p.y < lo.y or p.z < lo.z or p.x > hi.x or p.y > hi.y or p.z > hi.z:
			return -1
	var node := head
	var guard := nodes.size() / 3 + 1
	while node >= 0 and guard > 0:
		guard -= 1
		var at := node * 3
		var pl := nodes[at] * 4
		var d := planes[pl] * p.x + planes[pl + 1] * p.y + planes[pl + 2] * p.z - planes[pl + 3]
		node = nodes[at + 1] if d >= 0.0 else nodes[at + 2]
	if node >= 0:
		return -1
	var leaf := -1 - node
	return leaf_cluster[leaf] if leaf < leaf_cluster.size() else -1


## Whether anything at [param from] could see anything at [param to]. Conservative: see the class.
func visible(from: Vector3, to: Vector3) -> bool:
	if not is_ready():
		return true
	return cluster_sees(cluster_of(from), cluster_of(to))


## [method visible] by clusters, for a caller that looks each point up once.
func cluster_sees(from: int, to: int) -> bool:
	if from < 0 or to < 0 or from >= clusters or to >= clusters:
		return true
	return rows[from * row_bytes + (to >> 3)] & (1 << (to & 7)) != 0


## What the native core reads ([code]DotNetNativeCore.set_interest[/code]'s [code]vis[/code]). Packed
## arrays are shared, not copied; the core copies them only when [member serial] changes.
func native_dict() -> Dictionary:
	return {
		"serial": serial, "planes": planes, "nodes": nodes, "head": head, "leaf_cluster": leaf_cluster,
		"rows": rows, "row_bytes": row_bytes, "clusters": clusters, "bounds": bounds,
	}


func describe() -> Dictionary:
	var seen := 0
	for b in rows:
		var v := b
		while v:
			seen += v & 1
			v >>= 1
	return {
		"clusters": clusters, "nodes": nodes.size() / 3, "leaves": leaf_cluster.size(),
		"seen_share": snappedf(float(seen) / float(maxi(1, clusters * clusters)), 0.001),
		"bytes": planes.size() * 4 + nodes.size() * 4 + leaf_cluster.size() * 4 + rows.size(),
	}


## Hand-made rooms on a grid: [param cell_cluster] is each cell's cluster (x fastest, then y, then z;
## -1 solid), [param sees] per cluster the clusters it can see (an [code]Array[/code] or
## [code]PackedInt32Array[/code] each; a cluster always sees itself, and seeing is made mutual). Builds a
## tree that halves the grid along its longest side down to single cells; outside the grid answers
## visible. For tests and for games that lay out their own rooms.
static func from_cells(
	grid_origin: Vector3, size: float, grid_dims: Vector3i, cell_cluster: PackedInt32Array, sees: Array
) -> DotNetVisibility:
	var out := DotNetVisibility.new()
	var count := sees.size()
	out.clusters = count
	out.row_bytes = (count + 7) >> 3
	var blank := PackedByteArray()
	var _r := blank.resize(count * out.row_bytes)
	out.rows = blank
	for c in count:
		out._see(c, c)
		for other: int in sees[c]:
			if other >= 0 and other < count:
				out._see(c, other)
				out._see(other, c)
	out.leaf_cluster = cell_cluster.duplicate()
	out.bounds = AABB(grid_origin, Vector3(grid_dims) * size)
	out.head = 0
	out._split(grid_origin, size, grid_dims, Vector3i.ZERO, grid_dims)
	out._bump()
	return out


func _see(from: int, to: int) -> void:
	rows[from * row_bytes + (to >> 3)] |= 1 << (to & 7)


## A node splitting cells [param lo] .. [param hi] (exclusive) at the middle of its longest side,
## returning its child reference: a node index, or -1 - cell for a single cell.
func _split(grid_origin: Vector3, size: float, grid_dims: Vector3i, lo: Vector3i, hi: Vector3i) -> int:
	var span := hi - lo
	if span.x <= 1 and span.y <= 1 and span.z <= 1:
		return -1 - (lo.x + grid_dims.x * (lo.y + grid_dims.y * lo.z))
	var axis := 0 if span.x >= span.y and span.x >= span.z else (1 if span.y >= span.z else 2)
	var mid := lo[axis] + span[axis] / 2
	var index := nodes.size() / 3
	var plane := planes.size() / 4
	var normal := Vector3.ZERO
	normal[axis] = 1.0
	planes.append_array(PackedFloat32Array([normal.x, normal.y, normal.z, grid_origin[axis] + float(mid) * size]))
	nodes.append_array(PackedInt32Array([plane, 0, 0]))
	var upper_lo := lo
	upper_lo[axis] = mid
	var lower_hi := hi
	lower_hi[axis] = mid
	var front := _split(grid_origin, size, grid_dims, upper_lo, hi)
	var back := _split(grid_origin, size, grid_dims, lo, lower_hi)
	nodes[index * 3 + 1] = front
	nodes[index * 3 + 2] = back
	return index


## From a BSP's visibility, the arrays [code]DotMapBspMesh[/code]'s [code]vis[/code] record holds (metres,
## Godot axes): [param map_planes] nx, ny, nz, d per plane, [param map_nodes] plane, front, back per node,
## [param map_leaf_cluster] per leaf, [param pvs] the rows Quake-compressed (a zero byte, then how many
## zero bytes) at [param pvs_offsets] per cluster (-1: sees everything), [param map_head] the root.
## Milliseconds: the rows are decoded once, nothing is baked per position.
static func bake_bsp(
	map_planes: PackedFloat32Array, map_nodes: PackedInt32Array, map_leaf_cluster: PackedInt32Array,
	cluster_count: int, pvs_offsets: PackedInt32Array, pvs: PackedByteArray, map_head: int,
	map_bounds: AABB = AABB()
) -> DotNetVisibility:
	var out := DotNetVisibility.new()
	out.planes = map_planes
	out.nodes = map_nodes
	out.leaf_cluster = map_leaf_cluster
	out.head = map_head
	out.bounds = map_bounds
	out.clusters = cluster_count
	out.row_bytes = (cluster_count + 7) >> 3
	var decoded := PackedByteArray()
	for c in cluster_count:
		var row := decode_row(pvs, pvs_offsets[c] if c < pvs_offsets.size() else -1, out.row_bytes)
		row[c >> 3] |= 1 << (c & 7)
		decoded.append_array(row)
	out.rows = decoded
	out._bump()
	return out


## [method bake_bsp] from a [code]DotMapBspMesh[/code] (duck-typed: dot-net does not depend on
## dot-map) whose manifest has a [code]vis[/code] record. Null when it has none.
static func from_dot_map_mesh(mesh: Object, map_bounds: AABB = AABB()) -> DotNetVisibility:
	var info: Dictionary = (mesh.get("manifest") as Dictionary).get("vis", {})
	if int(info.get("clusters", 0)) <= 0:
		return null
	return bake_bsp(
		(mesh.call("vis_bytes", "planes", 16) as PackedByteArray).to_float32_array(),
		(mesh.call("vis_bytes", "nodes", 12) as PackedByteArray).to_int32_array(),
		(mesh.call("vis_bytes", "leaf_cluster") as PackedByteArray).to_int32_array(),
		int(info["clusters"]),
		(mesh.call("vis_bytes", "pvs_offsets") as PackedByteArray).to_int32_array(),
		mesh.call("vis_bytes", "pvs", 1),
		int(info.get("head", 0)), map_bounds
	)


## One cluster's PVS row, [param bytes] long, from Quake-compressed [param pvs] at [param offset]
## (-1, or past the end: every bit set).
static func decode_row(pvs: PackedByteArray, offset: int, bytes: int) -> PackedByteArray:
	var out := PackedByteArray()
	var _r := out.resize(bytes)
	if offset < 0 or offset >= pvs.size():
		out.fill(0xFF)
		return out
	var p := offset
	var o := 0
	while o < bytes and p < pvs.size():
		var b := pvs[p]
		if b != 0:
			out[o] = b
			o += 1
			p += 1
		else:
			o += pvs[p + 1] if p + 1 < pvs.size() else bytes
			p += 2
	return out
