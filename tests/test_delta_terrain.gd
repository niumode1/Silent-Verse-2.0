# ============================================================
# test_delta_terrain.gd — 堆积增量改变地形高度/碰撞
# ============================================================
# 运行：godot --headless --path . scenes/test_delta_terrain.tscn
# 验证：
#   · MatterDelta 按休止角抬高地表面
#   · GroundChunk.rebuild() 后出现新的固体格
#   · 堆积物组成进入物质场采样
#   · 清除 delta 后地形恢复
# ============================================================
extends Node

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("[DeltaTerrain] 生成世界……")
	var world := WorldGenerator.new(42)
	world.generate()
	var field := MatterField.new(world)
	var chunk := _build_chunk(world, field)
	var top := _top_cell(chunk)
	var point := chunk.get_world_center(top)

	var base_radius := field.get_surface_radius_at(point)
	var base_count := chunk.get_solid_count()
	var base_mass := chunk.get_total_mass()

	var delta := MatterDelta.new()
	delta.deposit(point, [{"material_id": "granite", "fraction": 1.0}],
		{"density": 2700.0, "angle_of_repose_deg": 30.0},
		2000.0, 2000.0 / 2700.0)
	_check(delta.get_height_at(point) > 0.2,
		"deposit raises surface at pile center (%.2f m)"
		% delta.get_height_at(point))
	_check(delta.get_height_at(point + point.normalized() * 50.0) == 0.0
		or delta.get_height_at(point + point.normalized() * 50.0) < 0.01,
		"surface far from pile is unchanged")

	field.set_delta(delta)
	chunk.rebuild()
	var new_radius := field.get_surface_radius_at(point)
	var new_count := chunk.get_solid_count()
	var new_mass := chunk.get_total_mass()
	_check(new_radius > base_radius + 0.2,
		"chunk surface rises (%.2f → %.2f m)" % [base_radius, new_radius])
	_check(new_count > base_count,
		"rebuild adds solid cells (%.0f → %.0f)" % [base_count, new_count])
	_check(new_mass > base_mass,
		"rebuild adds mass (%.1f → %.1f kg)" % [base_mass, new_mass])
	var sample := field.sample(point, 0.2)
	var granite := _fraction(sample["composition"], "granite")
	_check(granite > 0.4,
		"deposit composition appears in field (granite %.2f)" % granite)
	var mesh := chunk.build_mesh()
	_check(mesh != null and mesh.get_surface_count() > 0,
		"mesh rebuilds with new surface")

	field.set_delta(null)
	chunk.rebuild()
	_check(absf(float(chunk.get_solid_count()) - float(base_count)) < 0.5,
		"clearing delta restores base terrain")

	# 挖走也写成 delta：重建后坑还在
	var removal_delta := MatterDelta.new()
	removal_delta.remove_volume(point, 0.125, [], 0.0)
	_check(removal_delta.get_removal_depth_at(point) > 0.1,
		"removal records a pit depth")
	field.set_delta(removal_delta)
	chunk.rebuild()
	var pit_radius := field.get_surface_radius_at(point)
	var pit_count := chunk.get_solid_count()
	_check(pit_radius < base_radius - 0.05,
		"removal lowers surface (%.2f → %.2f m)" % [base_radius, pit_radius])
	_check(pit_count < base_count,
		"removal reduces solid cells (%.0f → %.0f)" % [base_count, pit_count])
	field.set_delta(null)
	chunk.rebuild()
	_check(absf(float(chunk.get_solid_count()) - float(base_count)) < 0.5,
		"clearing removal restores terrain")

	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _build_chunk(world: WorldGenerator, field: MatterField) -> GroundChunk:
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
	var anchor: Vector3 = dir * world.terrain.get_surface_radius(
		dir * world.planet_radius)
	var up := anchor.normalized()
	var forward := up.cross(Vector3.RIGHT)
	if forward.length() < 0.01:
		forward = up.cross(Vector3.FORWARD)
	forward = forward.normalized()
	var right := up.cross(forward).normalized()
	return GroundChunk.new(field, anchor, right, forward)


func _top_cell(chunk: GroundChunk) -> Vector3i:
	var keys := chunk.get_all_keys()
	var top: Vector3i = keys[0]
	for key in keys:
		if (key as Vector3i).y > top.y:
			top = key
	return top


func _fraction(composition: Array, material_id: String) -> float:
	for entry in composition:
		if String(entry["material_id"]) == material_id:
			return float(entry["fraction"])
	return 0.0


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
