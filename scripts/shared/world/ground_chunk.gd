# ============================================================
# GroundChunk — 近场物质格块
# ============================================================
# 地面不再是一整张三角网，而是一块块 3D 格子：
#   · 每格从 MatterField 采样得到组成 + 状态；
#   · 地表以上是空气格，以下按物质场填充；
#   · 渲染用贪心式的面剔除网格（每个暴露面一个 quad），
#     顶点颜色来自该格物质组成的加权颜色；
#   · 碰撞体由同一张网格生成；格子被移除后网格可以重建。
#
# 这只是一个原型：格子和网格都是「物质场的近场缓存」，
# 真值仍然是 MatterField + 稀疏增量。
# ============================================================
class_name GroundChunk
extends RefCounted

const CELL_SIZE := 0.5
const SIZE_X := 16
const SIZE_Z := 16
const MIN_Y := -10
const MAX_Y := 2

## 常用物质颜色；未列出的材料用确定性哈希色
const MATERIAL_COLORS := {
	"topsoil": Color(0.24, 0.16, 0.09),
	"clay": Color(0.55, 0.36, 0.24),
	"sand": Color(0.78, 0.68, 0.45),
	"gravel": Color(0.45, 0.43, 0.40),
	"granite": Color(0.55, 0.53, 0.50),
	"limestone": Color(0.78, 0.75, 0.66),
	"sandstone": Color(0.68, 0.58, 0.38),
	"basalt": Color(0.22, 0.22, 0.24),
	"slate": Color(0.38, 0.42, 0.46),
	"flint": Color(0.28, 0.28, 0.32),
	"obsidian": Color(0.08, 0.08, 0.10),
	"coal": Color(0.10, 0.10, 0.10),
	"peridotite": Color(0.30, 0.36, 0.20),
	"iron_ore_hematite": Color(0.55, 0.18, 0.12),
	"iron_ore_magnetite": Color(0.25, 0.22, 0.24),
	"copper_ore_malachite": Color(0.15, 0.65, 0.45),
	"tin_ore_cassiterite": Color(0.45, 0.30, 0.18),
	"gold_ore": Color(0.75, 0.62, 0.25),
	"molten_iron": Color(0.95, 0.45, 0.10),
	"iron_nickel": Color(0.40, 0.40, 0.45),
}

var field: MatterField = null
var anchor: Vector3 = Vector3.ZERO
var basis: Basis = Basis.IDENTITY

## {Vector3i: {"composition": Array, "state": Dictionary,
##             "density": float, "center": Vector3}}
var _cells: Dictionary = {}
var _solid_count: int = 0
var _total_mass: float = 0.0
var _mesh: ArrayMesh = null
var _mesh_dirty: bool = true

## 被取走/推开的物质在世界里的空洞，用于重新提取表面
var _carved: Array = []
var _node_color_cache: Dictionary = {}


func _init(p_field: MatterField, p_anchor: Vector3,
		p_right: Vector3 = Vector3.ZERO,
		p_forward: Vector3 = Vector3.ZERO) -> void:
	field = p_field
	anchor = p_anchor
	var up: Vector3 = p_anchor.normalized()
	var forward: Vector3 = p_forward
	forward -= up * forward.dot(up)
	if forward.length() < 0.001:
		forward = up.cross(Vector3.RIGHT)
		if forward.length() < 0.001:
			forward = up.cross(Vector3.FORWARD)
	forward = forward.normalized()
	var right: Vector3 = up.cross(forward).normalized()
	if p_right.length() > 0.001:
		var candidate: Vector3 = p_right - up * p_right.dot(up)
		if candidate.length() > 0.001:
			right = candidate.normalized()
			forward = right.cross(up).normalized()
	basis = Basis(right, up, forward)
	_build_cells()


# ============================================================
# 构建
# ============================================================

func _build_cells() -> void:
	_cells.clear()
	_carved.clear()
	_node_color_cache.clear()
	_solid_count = 0
	_total_mass = 0.0
	_mesh_dirty = true
	if field == null or field.terrain == null:
		return

	var half_x: float = float(SIZE_X - 1) * CELL_SIZE * 0.5
	var half_z: float = float(SIZE_Z - 1) * CELL_SIZE * 0.5
	for x in range(SIZE_X):
		for z in range(SIZE_Z):
			for y in range(MIN_Y, MAX_Y + 1):
				var local := Vector3(
					float(x) * CELL_SIZE - half_x,
					float(y) * CELL_SIZE,
					float(z) * CELL_SIZE - half_z)
				var world_pos: Vector3 = anchor + basis * local
				var surface: float = field.terrain.get_surface_radius(world_pos)
				if world_pos.length() >= surface:
					continue  # 空气格
				var depth: float = surface - world_pos.length()
				var sample := field.sample(world_pos, depth)
				_cells[Vector3i(x, y, z)] = {
					"composition": sample["composition"],
					"state": sample["state"],
					"density": float(sample["density"]),
					"center": world_pos,
				}
				_solid_count += 1
				_total_mass += CELL_SIZE * CELL_SIZE * CELL_SIZE \
					* float(sample["density"])


# ============================================================
# 查询 / 修改
# ============================================================

func get_solid_count() -> int:
	return _solid_count

func get_total_mass() -> float:
	return _total_mass

func is_solid(key: Vector3i) -> bool:
	return _cells.has(key)

func get_cell(key: Vector3i) -> Dictionary:
	return _cells.get(key, {})

func get_all_keys() -> Array:
	return _cells.keys()

func get_local_center(key: Vector3i) -> Vector3:
	var half_x: float = float(SIZE_X - 1) * CELL_SIZE * 0.5
	var half_z: float = float(SIZE_Z - 1) * CELL_SIZE * 0.5
	return Vector3(float(key.x) * CELL_SIZE - half_x,
		float(key.y) * CELL_SIZE,
		float(key.z) * CELL_SIZE - half_z)

func get_world_center(key: Vector3i) -> Vector3:
	return anchor + basis * get_local_center(key)


## 移除一格，返回这一格的物质（质量守恒的「脱落物」）。
## 返回 {} 表示该位置没有物质。
func remove_cell(key: Vector3i) -> Dictionary:
	if not _cells.has(key):
		return {}
	var cell: Dictionary = _cells[key]
	var volume: float = CELL_SIZE * CELL_SIZE * CELL_SIZE
	var density: float = float(cell["density"])
	var payload := {
		"composition": (cell["composition"] as Array).duplicate(true),
		"state": (cell["state"] as Dictionary).duplicate(true),
		"volume_m3": volume,
		"mass_kg": volume * density,
		"density": density,
		"world_position": get_world_center(key),
	}
	_cells.erase(key)
	_carved.append({
		"center": get_world_center(key),
		"radius": CELL_SIZE * 0.72,
	})
	_solid_count -= 1
	_total_mass = maxf(_total_mass - volume * density, 0.0)
	_mesh_dirty = true
	_node_color_cache.clear()
	return payload


## 世界坐标附近的一格（用于接触点定位）。
func find_cell_at_world(world_position: Vector3) -> Vector3i:
	var local: Vector3 = basis.inverse() * (world_position - anchor)
	var half_x: float = float(SIZE_X - 1) * CELL_SIZE * 0.5
	var half_z: float = float(SIZE_Z - 1) * CELL_SIZE * 0.5
	return Vector3i(
		int(round((local.x + half_x) / CELL_SIZE)),
		int(round(local.y / CELL_SIZE)),
		int(round((local.z + half_z) / CELL_SIZE)))


# ============================================================
# 网格 / 碰撞
# ============================================================

func build_mesh() -> ArrayMesh:
	if _mesh != null and not _mesh_dirty:
		return _mesh
	_mesh_dirty = false
	_mesh = _build_mesh_internal()
	return _mesh


func build_collision_shape() -> Shape3D:
	var mesh := build_mesh()
	if mesh == null:
		return null
	var shape := mesh.create_trimesh_shape()
	if shape is ConcavePolygonShape3D:
		(shape as ConcavePolygonShape3D).backface_collision = true
	return shape


## 从物质场的等值面提取连续三角网（marching tetrahedra）。
## 输出不是方块：三角形顶点在采样点之间插值，表面连续、不规则；
## 不规则性来自地形/地质场本身，不额外加随机噪声。
func _build_mesh_internal() -> ArrayMesh:
	if field == null or field.terrain == null:
		return null
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	# 立方体 6 个四面体分解（围绕 0–6 对角线）
	var tets := [
		[0, 1, 2, 6], [0, 2, 3, 6], [0, 3, 7, 6],
		[0, 7, 4, 6], [0, 4, 5, 6], [0, 5, 1, 6],
	]
	var corners := [
		Vector3i(0, 0, 0), Vector3i(1, 0, 0),
		Vector3i(1, 1, 0), Vector3i(0, 1, 0),
		Vector3i(0, 0, 1), Vector3i(1, 0, 1),
		Vector3i(1, 1, 1), Vector3i(0, 1, 1),
	]

	for nx in range(SIZE_X):
		for ny in range(MIN_Y, MAX_Y):
			for nz in range(SIZE_Z):
				var pts: Array = []
				var vals: Array = []
				for c in corners:
					var key: Vector3i = Vector3i(nx, ny, nz) + c
					pts.append(_node_local(key))
					vals.append(_node_density(key))
				for tet in tets:
					_emit_tet(st, pts, vals, tet)

	return st.commit()


func _node_local(key: Vector3i) -> Vector3:
	var half_x: float = float(SIZE_X) * CELL_SIZE * 0.5
	var half_z: float = float(SIZE_Z) * CELL_SIZE * 0.5
	return Vector3(float(key.x) * CELL_SIZE - half_x,
		float(key.y) * CELL_SIZE,
		float(key.z) * CELL_SIZE - half_z)


## 正值 = 物质内部，负值 = 空气/空洞。破坏会在这里减去空洞。
func _node_density(key: Vector3i) -> float:
	var local := _node_local(key)
	var world_pos: Vector3 = anchor + basis * local
	var density: float = field.terrain.get_surface_radius(world_pos) \
		- world_pos.length()
	for carve in _carved:
		var radius: float = float(carve["radius"])
		var distance: float = world_pos.distance_to(carve["center"])
		if distance < radius:
			density -= (radius - distance) * 6.0
	return density


func _emit_tet(st: SurfaceTool, pts: Array, vals: Array, tet: Array) -> void:
	var inside: Array = []
	var outside: Array = []
	for i in tet:
		if float(vals[i]) > 0.0:
			inside.append(int(i))
		else:
			outside.append(int(i))
	if inside.is_empty() or outside.is_empty():
		return

	var crossings: Array = []
	for i in inside:
		for j in outside:
			var vi: float = float(vals[i])
			var vj: float = float(vals[j])
			var denom: float = vi - vj
			if absf(denom) < 1.0e-9:
				continue
			var t: float = vi / denom
			var p: Vector3 = (pts[i] as Vector3).lerp(pts[j] as Vector3, t)
			crossings.append(p)

	if crossings.size() == 3:
		_emit_tri(st, crossings[0], crossings[1], crossings[2])
	elif crossings.size() == 4:
		_emit_tri(st, crossings[0], crossings[1], crossings[2])
		_emit_tri(st, crossings[0], crossings[2], crossings[3])


func _emit_tri(st: SurfaceTool, p0: Vector3, p1: Vector3,
		p2: Vector3) -> void:
	var normal: Vector3 = (p1 - p0).cross(p2 - p0)
	if normal.length_squared() < 1.0e-12:
		return
	normal = normal.normalized()
	var outward: Vector3 = (anchor + basis * p0).normalized()
	if normal.dot(outward) < 0.0:
		var tmp: Vector3 = p1
		p1 = p2
		p2 = tmp
		normal = -normal
	for p in [p0, p1, p2]:
		st.set_color(_color_at_local(p))
		st.set_normal(normal)
		st.add_vertex(p)


func _color_at_local(local_pos: Vector3) -> Color:
	var world_pos: Vector3 = anchor + basis * local_pos
	var depth: float = field.get_depth_at(world_pos)
	var sample := field.sample(world_pos, depth)
	return _composition_color(sample["composition"])


func _composition_color(composition: Array) -> Color:
	var color := Color(0, 0, 0)
	var total: float = 0.0
	for entry in composition:
		var f: float = float(entry["fraction"])
		color += _material_color(String(entry["material_id"])) * f
		total += f
	if total <= 0.0:
		return Color(0.5, 0.5, 0.5)
	return color / total


func _material_color(material_id: String) -> Color:
	if MATERIAL_COLORS.has(material_id):
		return MATERIAL_COLORS[material_id]
	var h: float = float(material_id.hash() & 0xFFFFFF) / 16777215.0
	return Color.from_hsv(h, 0.35, 0.55)
