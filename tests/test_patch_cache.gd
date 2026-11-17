extends Node

func _ready() -> void:
	print("[PatchCache] 测试 LOD patch 缓存……")
	var world := WorldGenerator.new(42)
	world.generate()
	var renderer := preload("res://scripts/client/world_renderer.gd").new()
	renderer.world_generator = world
	renderer.near_field_enabled = true
	renderer.near_field_patch_m = 180.0
	renderer.near_field_cell_m = 4.0
	renderer.near_field_hole_radius = 65.0
	renderer.near_field_stream_move_m = 45.0
	add_child(renderer)

	var dir := Vector3.ZERO
	var rng := RandomNumberGenerator.new()
	rng.seed = 314
	for i in range(300):
		var candidate := Vector3(
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0),
			rng.randf_range(-1.0, 1.0)).normalized()
		var probe := candidate * world.planet_radius
		if world.terrain.is_land(probe) \
				and world.terrain.get_elevation(probe) > 5.0:
			dir = candidate
			break

	if dir == Vector3.ZERO:
		print("  FAIL: no land anchor")
		get_tree().quit(1)
		return

	var spawn: Vector3 = dir * world.terrain.get_surface_radius(
		dir * world.planet_radius)
	renderer.spawn_point = spawn

	# 首次生成应该重建
	var t0 := Time.get_ticks_msec()
	renderer._generate_near_ground(spawn)
	var t1 := Time.get_ticks_msec()
	_check(t1 - t0 > 1000, "first build takes time (%d ms)" % (t1 - t0))
	_check(renderer._near_chunk_cache.size() > 0, "patch created")

	# 小范围移动（30 m < 72 m 阈值）不应重建
	var up := spawn.normalized()
	var forward := up.cross(Vector3.RIGHT)
	if forward.length() < 0.01:
		forward = up.cross(Vector3.FORWARD)
	forward = forward.normalized()
	var move1: Vector3 = spawn + forward * 30.0
	t0 = Time.get_ticks_msec()
	renderer._generate_near_ground(move1)
	t1 = Time.get_ticks_msec()
	_check(t1 - t0 < 100, "small move uses cache (%d ms)" % (t1 - t0))

	# 大范围移动（80 m > 72 m 阈值）应该重建
	var move2: Vector3 = spawn + forward * 80.0
	t0 = Time.get_ticks_msec()
	renderer._generate_near_ground(move2)
	t1 = Time.get_ticks_msec()
	_check(t1 - t0 > 1000, "large move rebuilds (%d ms)" % (t1 - t0))

	print("=== Results: all passed ===")
	get_tree().quit(0)

func _check(condition: bool, label: String) -> void:
	if condition:
		print("  PASS: ", label)
	else:
		print("  FAIL: ", label)
		get_tree().quit(1)
