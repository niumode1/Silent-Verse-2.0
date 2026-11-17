# ============================================================
# MaterialTestYard — 出生点附近的材料试验场
# ============================================================
# 内容开发期用：把材料库里的固体材料各放一份在出生点前方，形成一片
# 可交互的样品场，方便测试抓握、磨损、燃烧、建造等。
#
# 布局是确定性的（按 material_id 排序，不使用随机数）：同种子同世界
# → 同一样品位置。液态材料需要容器，暂不生成（避免被当成固体方块）。
# ============================================================
class_name MaterialTestYard
extends RefCounted

const ITEM_ID_BASE := 2_000_000
const COLS := 8
const COL_GAP_M := 1.15
const ROW_GAP_M := 1.85
const START_FORWARD_M := 7.0
const TREE_CLEARANCE_M := 1.4

## 样品场总行数：固体材料 + 抓握木棍 5 + 重物 4。
static func _rows_total() -> int:
	var solid: int = 0
	for m in MaterialDB.get_all_materials():
		if (m as MaterialProperty).phase != "liquid":
			solid += 1
	return int(ceil(float(solid + 9) / float(COLS)))


## 生成一块平坦的试验台。样品场铺在坡上，圆柱会一直滚走、长杆会嵌进
## 坡面被 Jolt 推穿三角网；台面是让样品稳定摆放的唯一可靠办法。
static func build_platform(world: WorldGenerator, anchor: Vector3,
		look_target: Vector3) -> StaticBody3D:
	var platform := StaticBody3D.new()
	platform.name = "TestYardPad"
	if world == null or world.terrain == null:
		return platform

	var up: Vector3 = anchor.normalized()
	var forward: Vector3 = look_target - anchor
	forward -= up * forward.dot(up)
	if forward.length() < 0.001:
		forward = up.cross(Vector3.RIGHT)
		if forward.length() < 0.001:
			forward = up.cross(Vector3.FORWARD)
	forward = forward.normalized()

	var rows: int = _rows_total()
	forward = _choose_flat_forward(world, up, forward, rows)
	var right: Vector3 = forward.cross(up).normalized()

	var span_fwd: float = float(maxi(rows - 1, 0)) * ROW_GAP_M
	var span_right: float = float(COLS - 1) * COL_GAP_M
	var margin: float = 3.0
	var thickness: float = 0.5

	# 台面必须高于覆盖范围内的最高地形，否则样品会被地形顶穿
	var top_radius: float = -INF
	for i in range(7):
		var f: float = START_FORWARD_M - margin \
			+ (span_fwd + margin * 2.0) * float(i) / 6.0
		for j in range(7):
			var r: float = -span_right * 0.5 - margin \
				+ (span_right + margin * 2.0) * float(j) / 6.0
			var d: Vector3 = _displace(up, forward, right, f, r,
				world.planet_radius)
			top_radius = maxf(top_radius,
				world.terrain.get_surface_radius(d * world.planet_radius))
	top_radius += 0.12
	var center_fwd: float = START_FORWARD_M + span_fwd * 0.5
	var center_dir: Vector3 = _displace(up, forward, right, center_fwd, 0.0,
		world.planet_radius)
	# 台面法线用场中心方向的「真实重力方向」，不用出生点的 up：
	# 两者差 0.2° 时，圆柱样品会一直朝低处滚。
	# 同时必须是右手基（x×y=z），镜像变换会让 Jolt 的法线方向出错。
	var pad_fwd: Vector3 = forward - center_dir * forward.dot(center_dir)
	pad_fwd = pad_fwd.normalized()
	var pad_x: Vector3 = center_dir.cross(pad_fwd).normalized()
	var basis := Basis(pad_x, center_dir, pad_fwd)
	platform.transform = Transform3D(basis,
		center_dir * (top_radius - thickness * 0.5))
	platform.collision_layer = 2   # 地形层：物品定位射线 / 玩家都走这一层
	platform.collision_mask = 0

	var shape := BoxShape3D.new()
	shape.size = Vector3(span_right + margin * 2.0, thickness,
		span_fwd + margin * 2.0)
	var collider := CollisionShape3D.new()
	collider.shape = shape
	platform.add_child(collider)

	var mesh_instance := MeshInstance3D.new()
	var box_mesh := BoxMesh.new()
	box_mesh.size = shape.size
	mesh_instance.mesh = box_mesh
	var pad_mat := StandardMaterial3D.new()
	pad_mat.albedo_color = Color(0.40, 0.38, 0.35)
	pad_mat.roughness = 1.0
	mesh_instance.material_override = pad_mat
	platform.add_child(mesh_instance)

	return platform


## 生成样品物品。返回 Array[ItemEntity]，id 从 ITEM_ID_BASE 连续分配。
static func generate(world: WorldGenerator, anchor: Vector3,
		look_target: Vector3) -> Array:
	var items: Array = []
	if world == null or world.terrain == null:
		return items

	var up: Vector3 = anchor.normalized()
	var forward: Vector3 = look_target - anchor
	forward -= up * forward.dot(up)
	if forward.length() < 0.001:
		forward = up.cross(Vector3.RIGHT)
		if forward.length() < 0.001:
			forward = up.cross(Vector3.FORWARD)
	forward = forward.normalized()

	var mats: Array = MaterialDB.get_all_materials()
	mats.sort_custom(func(a: MaterialProperty, b: MaterialProperty) -> bool:
		return a.material_id < b.material_id)

	var rows_total: int = _rows_total()
	# 在出生点前方找一个尽量平坦的方向：坡上圆柱形样品会一直滚走。
	forward = _choose_flat_forward(world, up, forward, rows_total)
	var right: Vector3 = forward.cross(up).normalized()

	var next_id: int = ITEM_ID_BASE
	var col: int = 0
	var row: int = 0

	# 材料库里的每一种固体材料各一份
	for m in mats:
		var mat: MaterialProperty = m
		if mat.phase == "liquid":
			continue
		var shape: String = _shape_for(mat)
		var dims: Dictionary = _dimensions_for(mat, shape, next_id)
		items.append(_make_sample(world, up, forward, right,
			START_FORWARD_M + float(row) * ROW_GAP_M,
			(float(col) - (float(COLS) - 1.0) * 0.5) * COL_GAP_M,
			mat.material_id, shape, dims, next_id))
		next_id += 1
		col += 1
		if col >= COLS:
			col = 0
			row += 1

	# 抓握测试：不同直径/长度的木棍（对应 HANDOFF §5.1 的握持瓶颈）
	var grip: Array = [
		{"d": 0.030, "l": 0.30},
		{"d": 0.032, "l": 0.30},
		{"d": 0.035, "l": 0.50},
		{"d": 0.040, "l": 1.00},
		{"d": 0.065, "l": 1.50},
	]
	for entry in grip:
		var d: float = float(entry["d"])
		var l: float = float(entry["l"])
		items.append(_make_sample(world, up, forward, right,
			START_FORWARD_M + float(row) * ROW_GAP_M,
			(float(col) - (float(COLS) - 1.0) * 0.5) * COL_GAP_M,
			"oak_wood", "fiber", {"length": l, "diameter": d}, next_id,
			"grip D%.1fcm x %.2fm" % [d * 100.0, l]))
		next_id += 1
		col += 1
		if col >= COLS:
			col = 0
			row += 1

	# 重物测试：几十公斤级的岩块 / 金属块
	var heavy: Array = [
		{"id": "granite", "size": 0.30},
		{"id": "limestone", "size": 0.32},
		{"id": "pure_iron", "size": 0.14},
		{"id": "flint", "size": 0.22},
	]
	for entry in heavy:
		var s: float = float(entry["size"])
		items.append(_make_sample(world, up, forward, right,
			START_FORWARD_M + float(row) * ROW_GAP_M,
			(float(col) - (float(COLS) - 1.0) * 0.5) * COL_GAP_M,
			String(entry["id"]), "block",
			{"length": s * 1.15, "width": s, "height": s * 0.8}, next_id))
		next_id += 1
		col += 1
		if col >= COLS:
			col = 0
			row += 1

	return items


# ============================================================
# 样品构造
# ============================================================

static func _make_sample(world: WorldGenerator, up: Vector3, forward: Vector3,
		right: Vector3, fwd_m: float, right_m: float,
		material_id: String, shape: String, dims: Dictionary, item_id: int,
		label: String = "") -> ItemEntity:
	var dir: Vector3 = _displace(up, forward, right, fwd_m, right_m,
		world.planet_radius)
	dir = _avoid_trees(world, dir, up, forward, right, fwd_m, right_m)
	var surface: Vector3 = dir * world.terrain.get_surface_radius(
		dir * world.planet_radius)

	var item := ItemEntity.new()
	item.item_id = item_id
	item.material_id = material_id
	item.shape = shape
	item.dimensions = dims
	item.temperature_c = world.get_temperature_at(surface,
		world.terrain.get_elevation(surface))
	item.transform = Transform3D(
		_basis_for(world, dir, forward, shape, dims), surface)
	if shape == "fiber":
		item.grain_dir_local = Vector3.UP  # 木纹 / 纤维沿杆轴
	item.set_in_world(item.transform)
	item.set_meta("test_yard", true)

	var mat: MaterialProperty = MaterialDB.get_material(material_id)
	if label == "":
		label = "%s\nH%.1f  rho%.0f  %s" % [
			material_id,
			mat.hardness_mohs if mat != null else 0.0,
			mat.density if mat != null else 0.0,
			mat.phase if mat != null else ""]
	item.set_meta("test_label", label)
	return item


static func _shape_for(mat: MaterialProperty) -> String:
	if mat.phase == "fiber" or mat.category == "wood":
		return "fiber"
	if mat.phase == "granular" or mat.phase == "powder":
		return "sphere"
	return "block"


static func _dimensions_for(mat: MaterialProperty, shape: String,
		seed_id: int) -> Dictionary:
	var k: int = seed_id % 5
	if shape == "fiber":
		if mat.category == "wood":
			return {"length": 0.45 + 0.15 * float(k),
				"diameter": 0.035 + 0.005 * float(k % 3)}
		return {"length": 0.50, "diameter": 0.025}
	if shape == "sphere":
		return {"radius": 0.05 + 0.01 * float(k % 3)}

	var base: float = 0.13
	match mat.category:
		"stone", "ore":
			base = 0.17
		"metal":
			base = 0.11
		"processed":
			base = 0.14
		"organic":
			base = 0.12
		"soil":
			base = 0.12
		"plant":
			base = 0.13
		"wood":
			base = 0.14
	return {"length": base * 1.2, "width": base, "height": base * 0.8}


# ============================================================
# 球面布局
# ============================================================

## 在出生点前方的扇形里挑一个地表起伏最小的方向，避免样品场铺在陡坡上。
static func _choose_flat_forward(world: WorldGenerator, up: Vector3,
		forward: Vector3, rows: int) -> Vector3:
	var best: Vector3 = forward
	var best_relief: float = INF
	for deg in [-75.0, -50.0, -25.0, 0.0, 25.0, 50.0, 75.0]:
		var cand: Vector3 = forward.rotated(up, deg_to_rad(deg)).normalized()
		var cand_right: Vector3 = cand.cross(up).normalized()
		var relief: float = _footprint_relief(world, up, cand, cand_right, rows)
		if relief < best_relief:
			best_relief = relief
			best = cand
	return best


## 样品场覆盖范围内地表高度的最大落差（m）。
static func _footprint_relief(world: WorldGenerator, up: Vector3,
		forward: Vector3, right: Vector3, rows: int) -> float:
	var depth: float = START_FORWARD_M + float(maxi(rows - 1, 0)) * ROW_GAP_M
	var half_w: float = (float(COLS) - 1.0) * 0.5 * COL_GAP_M
	var low: float = INF
	var high: float = -INF
	for i in range(5):
		var f: float = START_FORWARD_M \
			+ (depth - START_FORWARD_M) * float(i) / 4.0
		for j in range(5):
			var r: float = -half_w + 2.0 * half_w * float(j) / 4.0
			var dir: Vector3 = _displace(up, forward, right, f, r,
				world.planet_radius)
			var h: float = world.terrain.get_surface_radius(
				dir * world.planet_radius)
			low = minf(low, h)
			high = maxf(high, h)
	return high - low


## 从 anchor 方向沿切平面移动 (fwd_m 前, right_m 右)，返回新的球面方向。
static func _displace(up: Vector3, forward: Vector3, right: Vector3,
		fwd_m: float, right_m: float, radius: float) -> Vector3:
	var tangent: Vector3 = forward * fwd_m + right * right_m
	if tangent.length() < 0.0001:
		return up
	var axis: Vector3 = up.cross(tangent.normalized()).normalized()
	return up.rotated(axis, tangent.length() / radius).normalized()


## 树干附近生成物品会被静态碰撞体弹飞：后退并沿前方挪开一点。
static func _avoid_trees(world: WorldGenerator, dir: Vector3, up: Vector3,
		forward: Vector3, right: Vector3, fwd_m: float,
		right_m: float) -> Vector3:
	for _attempt in range(4):
		var probe: Vector3 = dir * world.planet_radius
		var point: Vector3 = dir * world.terrain.get_surface_radius(probe)
		if not _near_tree(world, point):
			return dir
		fwd_m += 1.6
		dir = _displace(up, forward, right, fwd_m, right_m, world.planet_radius)
	return dir


static func _near_tree(world: WorldGenerator, point: Vector3) -> bool:
	for entry in world.trees.values():
		var tree_pos: Vector3 = entry.get("position", Vector3.ZERO)
		if tree_pos.length() < 0.001:
			continue
		var ground: Vector3 = tree_pos.normalized() \
			* world.terrain.get_surface_radius(tree_pos)
		if ground.distance_to(point) < TREE_CLEARANCE_M:
			return true
	return false


## 杆轴沿「地表弦」而不是球面切平面：在斜坡上，球面切向的水平杆一端
## 会埋进坡里，Jolt 解穿透时可能把它整个推穿三角网。用两端地表点的连线
## 当轴，杆就贴着坡躺。
static func _basis_for(world: WorldGenerator, dir: Vector3, forward: Vector3,
		shape: String, dims: Dictionary) -> Basis:
	if shape != "fiber":
		return ItemGeometry.basis_from_up(dir)

	var tangent: Vector3 = forward - dir * forward.dot(dir)
	if tangent.length() < 0.001:
		tangent = dir.cross(Vector3.RIGHT)
	tangent = tangent.normalized()

	var length: float = float(dims.get("length", 0.5))
	var half: float = length * 0.5
	var p1: Vector3 = _surface_point(world, dir, tangent, -half)
	var p2: Vector3 = _surface_point(world, dir, tangent, half)
	var axis: Vector3 = (p2 - p1).normalized()
	var up_local: Vector3 = ((p1 + p2) * 0.5).normalized()
	var side: Vector3 = axis.cross(up_local).normalized()
	var z: Vector3 = side.cross(axis).normalized()
	return Basis(side, axis, z)


## 从 dir 出发，沿切向 tangent 走 offset 米，落到地表上的点。
static func _surface_point(world: WorldGenerator, dir: Vector3,
		tangent: Vector3, offset: float) -> Vector3:
	var axis: Vector3 = dir.cross(tangent).normalized()
	var moved: Vector3 = dir.rotated(axis, offset / world.planet_radius)
	moved = moved.normalized()
	return moved * world.terrain.get_surface_radius(moved * world.planet_radius)
