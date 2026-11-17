# ============================================================
# FractureGenerator — 凸多面体破裂
# ============================================================
# 把一个凸体积按平面反复切开，得到若干凸碎片。碎片形状是破裂面
# 交出来的真实几何，不是噪波球/方块：
#   · 每个碎片 = 一组半空间平面；
#   · 顶点由 Geometry3D.compute_convex_mesh_points 求交；
#   · 面按平面分组、排序、三角化；
#   · 体积由三角面片积分，质量 = 体积 × 密度。
#
# 当前切面方向由确定性 RNG 给出；后续应换成应力张量/层理/解理方向，
# 接口不变。
# ============================================================
class_name FractureGenerator
extends RefCounted

const EPS := 1.0e-4


## 把 size 大小的长方体切成 count 块，返回：
## [{planes, vertices, faces, volume, centroid}, ...]
static func fracture_box(size: Vector3, count: int, seed_value: int) -> Array:
	var half := size * 0.5
	var planes: Array[Plane] = [
		Plane(Vector3.RIGHT, half.x),
		Plane(Vector3.LEFT, half.x),
		Plane(Vector3.UP, half.y),
		Plane(Vector3.DOWN, half.y),
		Plane(Vector3.BACK, half.z),
		Plane(Vector3.FORWARD, half.z),
	]
	var root := _make_fragment(planes)
	if root.is_empty():
		return []
	var fragments: Array = [root]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var min_volume: float = float(root["volume"]) * 0.01

	while fragments.size() < count:
		# 每次切最大的那块
		var index := 0
		for i in range(1, fragments.size()):
			if float(fragments[i]["volume"]) > float(fragments[index]["volume"]):
				index = i
		var parent: Dictionary = fragments[index]
		var split := _split(parent, rng)
		if split.is_empty():
			break
		fragments.remove_at(index)
		fragments.append(split[0])
		fragments.append(split[1])

	# 过滤掉退化碎片（理论上不会出现，防御）
	var out: Array = []
	for fragment in fragments:
		if float(fragment["volume"]) > min_volume * 0.1:
			out.append(fragment)
	return out


static func _split(parent: Dictionary, rng: RandomNumberGenerator) -> Array:
	var centroid: Vector3 = parent["centroid"]
	var parent_planes: Array = parent["planes"]
	var parent_volume: float = float(parent["volume"])
	for attempt in range(24):
		var normal := Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0))
		if normal.length() < 0.01:
			continue
		normal = normal.normalized()
		var d := normal.dot(centroid)
		var planes_a: Array = []
		var planes_b: Array = []
		for plane in parent_planes:
			planes_a.append(plane)
			planes_b.append(plane)
		planes_a.append(Plane(normal, d))
		planes_b.append(Plane(-normal, -d))
		var a := _make_fragment(planes_a)
		var b := _make_fragment(planes_b)
		if a.is_empty() or b.is_empty():
			continue
		if float(a["volume"]) < parent_volume * 0.05 \
				or float(b["volume"]) < parent_volume * 0.05:
			continue
		return [a, b]
	return []


## 由半空间平面求凸多面体：顶点、面、体积、质心。
static func _make_fragment(planes: Array) -> Dictionary:
	var typed: Array[Plane] = []
	for plane in planes:
		typed.append(plane as Plane)
	var vertices: PackedVector3Array = Geometry3D.compute_convex_mesh_points(typed)
	if vertices.size() < 4:
		return {}
	var centroid := Vector3.ZERO
	for v in vertices:
		centroid += v
	centroid /= float(vertices.size())

	var faces: Array = []
	for plane in typed:
		var ring: Array = []
		for i in range(vertices.size()):
			if absf((plane as Plane).distance_to(vertices[i])) <= EPS:
				ring.append(i)
		if ring.size() < 3:
			continue
		# 去重
		var unique: Array = []
		for idx in ring:
			var duplicate := false
			for existing in unique:
				if vertices[int(existing)].distance_to(vertices[int(idx)]) <= EPS:
					duplicate = true
					break
			if not duplicate:
				unique.append(idx)
		if unique.size() < 3:
			continue
		faces.append(_sort_ring(vertices, unique, plane.normal))

	var volume := _polyhedron_volume(vertices, faces, centroid)
	if volume <= 0.0:
		return {}
	return {
		"planes": typed,
		"vertices": vertices,
		"faces": faces,
		"volume": volume,
		"centroid": centroid,
	}


## 把同一平面上的顶点按绕法线角度排序。
static func _sort_ring(vertices: PackedVector3Array, ring: Array,
		normal: Vector3) -> Array:
	var n := normal.normalized()
	var center := Vector3.ZERO
	for idx in ring:
		center += vertices[int(idx)]
	center /= float(ring.size())
	var tangent := n.cross(Vector3.UP)
	if tangent.length() < 0.01:
		tangent = n.cross(Vector3.RIGHT)
	tangent = tangent.normalized()
	var bitangent := n.cross(tangent).normalized()
	ring.sort_custom(func(a, b):
		var va: Vector3 = vertices[int(a)] - center
		var vb: Vector3 = vertices[int(b)] - center
		var aa := atan2(va.dot(bitangent), va.dot(tangent))
		var ab := atan2(vb.dot(bitangent), vb.dot(tangent))
		return aa < ab)
	return ring


static func _polyhedron_volume(vertices: PackedVector3Array, faces: Array,
		center: Vector3) -> float:
	var volume := 0.0
	for face in faces:
		var ring: Array = face
		if ring.size() < 3:
			continue
		var v0: Vector3 = vertices[int(ring[0])] - center
		for i in range(1, ring.size() - 1):
			var v1: Vector3 = vertices[int(ring[i])] - center
			var v2: Vector3 = vertices[int(ring[i + 1])] - center
			volume += absf(v0.dot(v1.cross(v2))) / 6.0
	return volume


## 把一次破裂直接变成独立 ItemEntity 碎片（切割即分体）。
## 每块自带网格、体积、质心；质量由材料密度 × 体积推导。
static func make_item_fragments(size: Vector3, count: int, seed_value: int,
		material_id: String, parent_transform: Transform3D) -> Array:
	var fragments := fracture_box(size, count, seed_value)
	var items: Array = []
	for fragment in fragments:
		var item := ItemEntity.new()
		item.material_id = material_id
		item.shape = "custom"
		item.dimensions = {"volume_m3": float(fragment["volume"])}
		item.custom_mesh = build_mesh(fragment)
		item.transform = parent_transform * Transform3D(Basis.IDENTITY,
			fragment["centroid"])
		item.set_in_world(item.transform)
		items.append(item)
	return items


## 由碎片生成可渲染的 ArrayMesh（每个面扇形三角化）。
static func build_mesh(fragment: Dictionary) -> ArrayMesh:
	var vertices: PackedVector3Array = fragment["vertices"]
	var faces: Array = fragment["faces"]
	var center: Vector3 = fragment["centroid"]
	if vertices.is_empty() or faces.is_empty():
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for face in faces:
		var ring: Array = face
		if ring.size() < 3:
			continue
		var p0: Vector3 = vertices[int(ring[0])] - center
		var normal := Vector3.ZERO
		var p1: Vector3 = vertices[int(ring[1])] - center
		var p2: Vector3 = vertices[int(ring[2])] - center
		normal = (p1 - p0).cross(p2 - p0).normalized()
		for i in range(1, ring.size() - 1):
			var a: Vector3 = vertices[int(ring[0])] - center
			var b: Vector3 = vertices[int(ring[i])] - center
			var c: Vector3 = vertices[int(ring[i + 1])] - center
			st.set_normal(normal)
			st.add_vertex(a)
			st.set_normal(normal)
			st.add_vertex(b)
			st.set_normal(normal)
			st.add_vertex(c)
	return st.commit()
