# ============================================================
# test_delta_persistence.gd — 物质增量持久化 + 跨块加载
# ============================================================
# 运行：godot --headless --path . scenes/test_delta_persistence.tscn
# 验证：
#   · MatterDelta 能序列化/反序列化，质量和几何一致
#   · 能写到文件再读回
#   · 同一个 delta 传给两个块：只有附近的块看到变化
# ============================================================
extends Node

const SAVE_PATH := "user://matter_delta_test.json"
var _pass := 0
var _fail := 0


func _ready() -> void:
	_test_roundtrip()
	_test_file_roundtrip()
	_test_cross_chunk()
	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _make_delta() -> MatterDelta:
	var delta := MatterDelta.new()
	var p1 := Vector3(100.0, 200.0, 300.0)
	var p2 := Vector3(120.0, 210.0, 310.0)
	delta.deposit(p1,
		[{"material_id": "topsoil", "fraction": 0.7},
		 {"material_id": "clay", "fraction": 0.3}],
		{"density": 1600.0, "angle_of_repose_deg": 32.0},
		500.0, 0.3125)
	delta.remove_volume(p2, 0.2,
		[{"material_id": "granite", "fraction": 1.0}], 540.0)
	return delta


func _test_roundtrip() -> void:
	print("[Roundtrip]")
	var delta := _make_delta()
	var data := delta.to_dict()
	var loaded := MatterDelta.from_dict(data)
	_check(loaded.get_deposit_count() == delta.get_deposit_count(),
		"deposit count preserved")
	_check(loaded.get_removal_count() == delta.get_removal_count(),
		"removal count preserved")
	_check(absf(loaded.get_total_mass() - delta.get_total_mass()) < 1.0e-6,
		"deposit mass preserved")
	_check(absf(loaded.get_total_removed_volume()
		- delta.get_total_removed_volume()) < 1.0e-6,
		"removed volume preserved")
	var p1 := Vector3(100.0, 200.0, 300.0)
	_check(absf(loaded.get_height_at(p1) - delta.get_height_at(p1)) < 1.0e-6,
		"pile height preserved")
	var p2 := Vector3(120.0, 210.0, 310.0)
	_check(absf(loaded.get_removal_depth_at(p2)
		- delta.get_removal_depth_at(p2)) < 1.0e-6,
		"pit depth preserved")


func _test_file_roundtrip() -> void:
	print("[File]")
	var delta := _make_delta()
	_check(delta.save_to_file(SAVE_PATH), "delta saved to file")
	var loaded := MatterDelta.load_from_file(SAVE_PATH)
	_check(loaded != null, "delta loaded from file")
	if loaded == null:
		return
	_check(loaded.get_deposit_count() == 1, "loaded deposit count")
	_check(loaded.get_removal_count() == 1, "loaded removal count")
	_check(absf(loaded.get_total_mass() - 500.0) < 1.0e-6,
		"loaded mass = 500 kg")


func _test_cross_chunk() -> void:
	print("[Cross chunk]")
	var world := WorldGenerator.new(42)
	world.generate()
	var field := MatterField.new(world)
	var dirs := _find_land_dirs(world, 2)
	if dirs.size() < 2:
		_check(false, "found two land anchors")
		return
	var chunk_a := _build_chunk(world, field, dirs[0])
	var chunk_b := _build_chunk(world, field, dirs[1])
	var base_a := chunk_a.get_solid_count()
	var base_b := chunk_b.get_solid_count()
	var top := _top_cell(chunk_a)
	var point := chunk_a.get_world_center(top)
	var delta := MatterDelta.new()
	delta.deposit(point, [{"material_id": "granite", "fraction": 1.0}],
		{"density": 2700.0, "angle_of_repose_deg": 30.0},
		2000.0, 2000.0 / 2700.0)
	field.set_delta(delta)
	chunk_a.rebuild()
	chunk_b.rebuild()
	var new_a := chunk_a.get_solid_count()
	var new_b := chunk_b.get_solid_count()
	_check(new_a > base_a, "nearby chunk sees the deposit (%.0f → %.0f)"
		% [base_a, new_a])
	_check(new_b == base_b, "far chunk is unchanged (%.0f → %.0f)"
		% [base_b, new_b])
	_check(field.get_surface_radius_at(point) > 0.0,
		"shared field samples the delta")
	field.set_delta(null)


func _find_land_dirs(world: WorldGenerator, count: int) -> Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = 314
	var out: Array = []
	for i in range(2000):
		if out.size() >= count:
			break
		var dir := _random_dir(rng)
		var probe := dir * world.planet_radius
		if not world.terrain.is_land(probe):
			continue
		if world.terrain.get_elevation(probe) < 5.0:
			continue
		var too_close := false
		for existing in out:
			if (existing as Vector3).angle_to(dir) < 0.3:
				too_close = true
				break
		if not too_close:
			out.append(dir)
	return out


func _build_chunk(world: WorldGenerator, field: MatterField,
		dir: Vector3) -> GroundChunk:
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
