# ============================================================
# test_soil_particles.gd — 脱落物质 → C++ DEM 粒子
# ============================================================
# 运行：godot --headless --path . scenes/test_soil_particles.tscn
# 验证：
#   · MatterField 参数能设置 C++ 内核
#   · GroundChunk 移除的物质能按质量生成粒子
#   · 粒子总质量与脱落质量一致（误差 ≤ 一个粒子）
#   · 推进后质量守恒、位置有限
# ============================================================
extends Node

const RADIUS := 0.01
var _pass := 0
var _fail := 0


func _ready() -> void:
	var cls = ClassDB.instantiate("SoilDEMKernel")
	if cls == null:
		print("=== Results: 0/1 passed, 1 failed ===")
		print("  FAIL: SoilDEMKernel not registered (build the GDExtension first)")
		get_tree().quit(0)
		return

	print("[SoilParticles] 生成世界……")
	var world := WorldGenerator.new(42)
	world.generate()
	var field := MatterField.new(world)
	var chunk := _build_chunk(world, field)
	var key := _top_cell(chunk)
	var center := chunk.get_world_center(key)
	var normal := center.normalized()
	var tool := MaterialDB.get_material("oak_wood")

	var result := chunk.apply_contact(tool, center, -normal * 600.0,
		0.05, 0.02, normal, 0.5, 0.004, 0.01, false)
	var removed: Dictionary = result["removed"]
	_check(int(result["cells_removed"]) > 0, "contact removed material")
	if removed.is_empty():
		print("=== Results: %d/%d passed, %d failed ===" % [
			_pass, _pass + _fail, _fail])
		get_tree().quit(0)
		return

	var params := field.get_dem_parameters(center, 0.5)
	var kernel = ClassDB.instantiate("SoilDEMKernel")
	kernel.setup_material(RADIUS, params["density"], params["cohesion_pa"],
		params["friction"], params["stiffness"], params["damping"])
	kernel.set_bounds(center - Vector3(0.5, 0.5, 0.5),
		center + Vector3(0.5, 0.5, 0.5))
	var spawned: int = kernel.spawn_from_mass(
		float(removed["mass_kg"]), center, 0.05, 7)

	print("  removed mass=%.3f kg, spawned %d particles × %.4f kg"
		% [float(removed["mass_kg"]), spawned,
		float(kernel.get_particle_mass())])
	_check(spawned > 0, "spawned particles from removed mass")
	var particle_mass := float(kernel.get_particle_mass())
	var diff := absf(float(kernel.get_total_mass())
		- float(removed["mass_kg"]))
	_check(diff <= particle_mass + 1.0e-6,
		"spawned mass matches removed mass (diff %.4f kg <= one particle)"
		% diff)
	_check(int(kernel.get_particle_count()) == spawned,
		"particle count matches")

	for i in range(60):
		kernel.step(1.0 / 240.0)
	_check(int(kernel.get_step_count()) == 60, "kernel stepped")
	var finite := true
	for p in kernel.get_positions():
		if not p.is_finite():
			finite = false
			break
	_check(finite, "positions finite after stepping")
	var after_diff := absf(float(kernel.get_total_mass())
		- float(kernel.get_particle_mass()) * float(spawned))
	_check(after_diff < 1.0e-6, "particle mass conserved")

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
