# ============================================================
# GroundDemo — 物质地面可视化测试场
# ============================================================
# 不替换正式 WorldRenderer，只是把一块 GroundChunk 挂出来看：
# 生成世界 → 找一块陆地 → 建 8×8 m 近场格块 → 网格/碰撞。
# 运行：godot --path . scenes/ground_demo.tscn
# ============================================================
extends Node3D


func _ready() -> void:
	var world := WorldGenerator.new(42)
	world.generate()
	var field := MatterField.new(world)

	var dir := _find_land_dir(world)
	var anchor: Vector3 = dir * world.terrain.get_surface_radius(
		dir * world.planet_radius)
	var up := anchor.normalized()
	var forward := up.cross(Vector3.RIGHT)
	if forward.length() < 0.01:
		forward = up.cross(Vector3.FORWARD)
	forward = forward.normalized()
	var right := up.cross(forward).normalized()

	var chunk := GroundChunk.new(field, anchor, right, forward)
	var node := GroundChunkNode.new()
	node.name = "GroundChunk"
	add_child(node)
	node.setup(chunk)

	var camera := Camera3D.new()
	camera.name = "Camera3D"
	camera.current = true
	camera.far = 500.0
	add_child(camera)
	camera.global_position = anchor - forward * 5.0 + up * 3.0
	camera.look_at(anchor + up * 0.5, up)

	var light := DirectionalLight3D.new()
	light.name = "Sun"
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)
	light.global_position = anchor + up * 20.0 + right * 10.0
	light.look_at(anchor, up)

	var env := WorldEnvironment.new()
	var environment := Environment.new()
	environment.background_mode = Environment.BG_SKY
	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.20, 0.42, 0.75)
	sky_mat.sky_horizon_color = Color(0.78, 0.84, 0.90)
	sky.sky_material = sky_mat
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	environment.ambient_light_energy = 0.8
	env.environment = environment
	add_child(env)

	print("[GroundDemo] anchor=", anchor,
		" solid=", chunk.get_solid_count(),
		" mass=", snapped(chunk.get_total_mass(), 0.1), " kg")
	var mesh := chunk.build_mesh()
	if mesh != null:
		print("[GroundDemo] mesh vertices=", mesh.surface_get_array_len(0))


func _find_land_dir(world: WorldGenerator) -> Vector3:
	var rng := RandomNumberGenerator.new()
	rng.seed = 314
	for i in range(2000):
		var theta: float = rng.randf() * TAU
		var phi: float = acos(2.0 * rng.randf() - 1.0)
		var dir := Vector3(sin(phi) * cos(theta), cos(phi),
			sin(phi) * sin(theta))
		var probe := dir * world.planet_radius
		if world.terrain.is_land(probe) \
				and world.terrain.get_elevation(probe) > 5.0:
			return dir
	return Vector3.UP
