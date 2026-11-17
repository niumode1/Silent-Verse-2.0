# ============================================================
# test_soil_contact.gd — 力 → 地面屈服 → 移除物质
# ============================================================
# 运行：godot --headless --path . scenes/test_soil_contact.tscn
# 验证：
#   · 力小的时候地面不屈服、不产生脱落物
#   · 力足够大时按 ContactResolver 的位移体积移除格子
#   · 脱落物质量 = 被移除格子的质量，块总质量守恒
#   · 物质场能推导 DEM 参数
# ============================================================
extends Node

const CELL := 0.5

var _pass := 0
var _fail := 0
var _world: WorldGenerator
var _field: MatterField


func _ready() -> void:
	print("[SoilContact] 生成世界……")
	_world = WorldGenerator.new(42)
	_world.generate()
	_field = MatterField.new(_world)
	_test_dem_params()
	_test_low_force()
	_test_high_force()
	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _build_chunk() -> GroundChunk:
	var rng := RandomNumberGenerator.new()
	rng.seed = 314
	var dir := Vector3.ZERO
	for i in range(300):
		var candidate := _random_dir(rng)
		var probe := candidate * _world.planet_radius
		if _world.terrain.is_land(probe) \
				and _world.terrain.get_elevation(probe) > 5.0:
			dir = candidate
			break
	var anchor: Vector3 = dir * _world.terrain.get_surface_radius(
		dir * _world.planet_radius)
	var up := anchor.normalized()
	var forward := up.cross(Vector3.RIGHT)
	if forward.length() < 0.01:
		forward = up.cross(Vector3.FORWARD)
	forward = forward.normalized()
	var right := up.cross(forward).normalized()
	return GroundChunk.new(_field, anchor, right, forward)


func _top_cell(chunk: GroundChunk) -> Vector3i:
	var keys := chunk.get_all_keys()
	var top: Vector3i = keys[0]
	for key in keys:
		if (key as Vector3i).y > top.y:
			top = key
	return top


func _test_dem_params() -> void:
	print("[DEM params]")
	var dir := Vector3(0.3, 0.8, 0.5).normalized()
	var pos: Vector3 = dir * (_world.planet_radius - 1.0)
	var p := _field.get_dem_parameters(pos, 1.0)
	_check(float(p["density"]) > 0.0, "density positive")
	_check(float(p["cohesion_pa"]) >= 0.0, "cohesion non-negative")
	_check(float(p["friction"]) > 0.2 and float(p["friction"]) < 1.0,
		"friction in range")
	_check(float(p["stiffness"]) > 0.0, "stiffness positive")
	_check(float(p["moisture"]) >= 0.0 and float(p["moisture"]) <= 1.0,
		"moisture in range")


func _test_low_force() -> void:
	print("[Low force]")
	var chunk := _build_chunk()
	var key := _top_cell(chunk)
	var center := chunk.get_world_center(key)
	var normal := center.normalized()
	var tool := MaterialDB.get_material("oak_wood")
	var result := chunk.apply_contact(tool, center, -normal * 0.2,
		0.001, 0.0002, normal, 0.5, 0.005, 0.01, false)
	var contact: Dictionary = result["contact"]
	_check(not contact.is_empty(), "contact resolved")
	_check(int(result["cells_removed"]) == 0,
		"small force does not remove material")


func _test_high_force() -> void:
	print("[High force]")
	var chunk := _build_chunk()
	var key := _top_cell(chunk)
	var center := chunk.get_world_center(key)
	var normal := center.normalized()
	var tool := MaterialDB.get_material("oak_wood")
	var before_mass := chunk.get_total_mass()
	var before_count := chunk.get_solid_count()
	var result := chunk.apply_contact(tool, center, -normal * 600.0,
		0.05, 0.02, normal, 0.5, 0.004, 0.01, false)
	var removed: Dictionary = result["removed"]
	var count := int(result["cells_removed"])
	_check(count > 0, "large force removes cells (%d)" % count)
	if count > 0:
		_check(float(removed["mass_kg"]) > 0.0,
			"removed payload has mass")
		_check(chunk.get_solid_count() == before_count - count,
			"solid count decreases by removed cells")
		_check(absf(chunk.get_total_mass()
			- (before_mass - float(removed["mass_kg"]))) < 0.001,
			"chunk mass conserved")
		var comp: Array = removed["composition"]
		var total := 0.0
		for entry in comp:
			total += float(entry["fraction"])
		_check(absf(total - 1.0) < 0.001,
			"removed composition sums to 1")
		var mesh := chunk.build_mesh()
		_check(mesh != null and mesh.get_surface_count() > 0,
			"mesh rebuilds after removal")


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
