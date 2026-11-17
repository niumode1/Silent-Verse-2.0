# ============================================================
# test_ground_chunk.gd — 物质场 + 近场格块原型
# ============================================================
# 运行：godot --headless --path . scenes/test_ground_chunk.tscn
# 验证：
#   · 同种子同位置 → 同格子组成（确定性）
#   · 每格组成总和 = 1，状态合法
#   · 移除一格 → 产生同质量的颗粒物质，总质量守恒
#   · 网格与碰撞体可以从格子生成
# ============================================================
extends Node

const CELL := 0.5

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("[GroundChunk] 生成世界……")
	var world := WorldGenerator.new(42)
	world.generate()
	var field := MatterField.new(world)

	var rng := RandomNumberGenerator.new()
	rng.seed = 314
	var dir := Vector3.ZERO
	for i in range(300):
		var candidate := _random_dir(rng)
		var probe := candidate * world.planet_radius
		if world.terrain.is_land(probe) \
				and world.terrain.get_elevation(probe) > 5.0:
			dir = candidate
			break
	if dir == Vector3.ZERO:
		print("=== Results: 0/1 passed, 1 failed ===")
		print("  FAIL: no land anchor found")
		get_tree().quit(0)
		return

	var anchor: Vector3 = dir * world.terrain.get_surface_radius(
		dir * world.planet_radius)
	var up := anchor.normalized()
	var forward := up.cross(Vector3.RIGHT)
	if forward.length() < 0.01:
		forward = up.cross(Vector3.FORWARD)
	forward = forward.normalized()
	var right := up.cross(forward).normalized()

	var chunk := GroundChunk.new(field, anchor, right, forward)
	print("  anchor=", anchor, " solid=", chunk.get_solid_count(),
		" mass=", snapped(chunk.get_total_mass(), 0.1), " kg")

	_test_contents(chunk)
	_test_determinism(field, anchor, right, forward, chunk)
	_test_removal(chunk)
	_test_mesh(chunk)

	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _test_contents(chunk: GroundChunk) -> void:
	print("[Contents]")
	_check(chunk.get_solid_count() > 100,
		"chunk has solid cells (%d)" % chunk.get_solid_count())
	_check(chunk.get_total_mass() > 100.0,
		"chunk has mass (%.1f kg)" % chunk.get_total_mass())

	var keys := chunk.get_all_keys()
	if keys.is_empty():
		_check(false, "chunk has cells")
		return
	# 取最上面一格（最靠近地表）和最深一格
	var top: Vector3i = keys[0]
	var bottom: Vector3i = keys[0]
	for key in keys:
		var k: Vector3i = key
		if k.y > top.y:
			top = k
		if k.y < bottom.y:
			bottom = k

	var top_cell := chunk.get_cell(top)
	var bottom_cell := chunk.get_cell(bottom)
	var comp: Array = top_cell["composition"]
	var total := 0.0
	for entry in comp:
		total += float(entry["fraction"])
	_check(absf(total - 1.0) < 0.001,
		"top cell composition sums to 1 (%.4f)" % total)
	var state: Dictionary = top_cell["state"]
	_check(float(state["moisture"]) >= 0.0 and float(state["moisture"]) <= 1.0,
		"moisture is in [0,1] (%.2f)" % float(state["moisture"]))
	_check(float(state["compaction"]) > 0.0,
		"compaction is positive (%.2f)" % float(state["compaction"]))
	_check(float(state["shear_strength_pa"]) > 0.0,
		"shear strength is positive")
	_check(float(state["angle_of_repose_deg"]) >= 5.0
		and float(state["angle_of_repose_deg"]) <= 60.0,
		"angle of repose is in [5,60]")
	var top_pressure: float = float(state["pressure_pa"])
	var bottom_pressure: float = float(
		(bottom_cell["state"] as Dictionary)["pressure_pa"])
	_check(bottom_pressure >= top_pressure,
		"deeper cell has >= pressure (%.0f vs %.0f Pa)"
		% [bottom_pressure, top_pressure])
	print("  top composition: ", comp, " state: ", state)


func _test_determinism(field: MatterField, anchor: Vector3,
		right: Vector3, forward: Vector3, first: GroundChunk) -> void:
	print("[Determinism]")
	var second := GroundChunk.new(field, anchor, right, forward)
	_check(second.get_solid_count() == first.get_solid_count(),
		"same anchor → same solid count")
	var keys := first.get_all_keys()
	var same := true
	if not keys.is_empty():
		var key: Vector3i = keys[0]
		var a: Dictionary = first.get_cell(key)
		var b: Dictionary = second.get_cell(key)
		same = String(a["composition"][0]["material_id"]) \
			== String(b["composition"][0]["material_id"])
	_check(same, "same anchor → same composition")


func _test_removal(chunk: GroundChunk) -> void:
	print("[Removal]")
	var keys := chunk.get_all_keys()
	if keys.is_empty():
		_check(false, "has cells to remove")
		return
	var top: Vector3i = keys[0]
	for key in keys:
		if (key as Vector3i).y > top.y:
			top = key
	var cell: Dictionary = chunk.get_cell(top)
	var density: float = float(cell["density"])
	var before_count := chunk.get_solid_count()
	var before_mass := chunk.get_total_mass()
	var payload := chunk.remove_cell(top)
	_check(not payload.is_empty(), "remove_cell returns a payload")
	var expected_mass: float = CELL * CELL * CELL * density
	_check(absf(float(payload["mass_kg"]) - expected_mass) < 0.001,
		"payload mass = volume × density")
	_check(absf(chunk.get_total_mass()
		- (before_mass - expected_mass)) < 0.001,
		"chunk total mass decreases by payload mass")
	_check(chunk.get_solid_count() == before_count - 1,
		"solid count decreases by exactly one")


func _test_mesh(chunk: GroundChunk) -> void:
	print("[Mesh]")
	var mesh: ArrayMesh = chunk.build_mesh()
	_check(mesh != null, "mesh generated")
	if mesh == null:
		return
	_check(mesh.get_surface_count() > 0, "mesh has a surface")
	_check(mesh.surface_get_array_len(0) > 0,
		"mesh has vertices (%d)" % mesh.surface_get_array_len(0))
	var shape := chunk.build_collision_shape()
	_check(shape != null, "collision shape generated")
	if shape is ConcavePolygonShape3D:
		_check((shape as ConcavePolygonShape3D).backface_collision,
			"collision shape is double-sided")


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: ", label)
	else:
		_fail += 1
		print("  FAIL: ", label)


func _random_dir(rng: RandomNumberGenerator) -> Vector3:
	var theta: float = rng.randf() * TAU
	var phi: float = acos(2.0 * rng.randf() - 1.0)
	return Vector3(sin(phi) * cos(theta), cos(phi),
		sin(phi) * sin(theta))
