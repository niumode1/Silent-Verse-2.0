# ============================================================
# WorldRenderer — 星球地表/海洋/树木/物品渲染
# ============================================================
# 当前为内容开发期：客户端本地确定性生成世界，分端/流式下发延后。
# 地表用连续三角网格（按地形高度位移），不再用 150m CSG 方块。
# 海洋是海平面上的半透明网格，树木和地面物品是独立 MeshInstance3D。
# ============================================================
class_name WorldRenderer
extends Node3D

@export var surface_spacing: float = 50.0  # 地表网格边长 m
@export var water_offset: float = 0.15      # 水面略高于海平面
@export var tree_scale: float = 1.0

var world_generator: WorldGenerator = null
var spawn_point: Vector3 = Vector3.ZERO
var spawn_look_target: Vector3 = Vector3.ZERO

var _materials: Dictionary = {}
var _items_root: Node3D = null
var _trees_root: Node3D = null

## 可见地表网格的顶点半径，供玩家贴地采样
var _surface_heights: Array = []
var _surface_steps_phi: int = 0
var _surface_steps_theta: int = 0

## 材料 → 颜色。地表矿脉露头与地面物品共用，避免两套映射
var _material_colors: Dictionary = {
	"oak_wood": Color(0.36, 0.24, 0.13),
	"pine_wood": Color(0.45, 0.30, 0.16),
	"birch_wood": Color(0.62, 0.55, 0.42),
	"bamboo": Color(0.48, 0.55, 0.25),
	"granite": Color(0.55, 0.53, 0.50),
	"limestone": Color(0.78, 0.75, 0.66),
	"sandstone": Color(0.68, 0.58, 0.38),
	"flint": Color(0.28, 0.28, 0.32),
	"obsidian": Color(0.08, 0.08, 0.10),
	"basalt": Color(0.22, 0.22, 0.24),
	"slate": Color(0.38, 0.42, 0.46),
	"clay": Color(0.62, 0.42, 0.32),
	"coal": Color(0.12, 0.12, 0.12),
	"iron_ore_hematite": Color(0.55, 0.18, 0.12),
	"iron_ore_magnetite": Color(0.25, 0.22, 0.24),
	"copper_ore_malachite": Color(0.15, 0.65, 0.45),
	"tin_ore_cassiterite": Color(0.45, 0.30, 0.18),
	"gold_ore": Color(0.75, 0.62, 0.25),
}


func _ready() -> void:
	world_generator = WorldGenerator.new(WorldGenerator.DEFAULT_SEED, WorldGenerator.DEFAULT_PLANET_RADIUS)
	world_generator.max_elevation = WorldGenerator.DEFAULT_MAX_ELEVATION
	world_generator.generate()
	PhysicsConstants.configure_planet(world_generator.planet_radius)

	var land_pct: float = snapped(world_generator._estimate_land_ratio() * 100, 0.1)
	print("World: land=", land_pct, "%, trees=", world_generator.trees.size())

	var world_items := WorldItemSpawner.generate(world_generator)

	_setup_environment()
	_generate_surface_mesh()
	_find_spawn_point(world_items)
	_report_spawn_surroundings(world_items)
	_aim_sun_at_spawn()
	_generate_water_mesh()
	_generate_core()
	_generate_trees()
	# 等一帧，让地形碰撞体进入物理空间，物品射线才能命中
	await get_tree().physics_frame
	_generate_world_items(world_items)

	var player: FirstPersonController = get_node_or_null("../FirstPersonController")
	if player:
		# 与可见三角面一致的高度采样，保证上/下坡连续，不按网格跳变
		player.ground_sampler = Callable(self, "_sample_mesh_radius")
		player.terrain = world_generator.terrain
		player.planet_radius = world_generator.planet_radius
		# 等玩家控制器 _ready() 完成（_camera onready 就绪）后再出生
		player.call_deferred("spawn_on_surface", spawn_point, spawn_look_target)


# ============================================================
# 环境 / 天空
# ============================================================

func _setup_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	var sky := Sky.new()
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = Color(0.16, 0.38, 0.72)
	sky_mat.sky_horizon_color = Color(0.70, 0.82, 0.92)
	sky_mat.ground_bottom_color = Color(0.16, 0.13, 0.10)
	sky_mat.ground_horizon_color = Color(0.48, 0.44, 0.38)
	sky.sky_material = sky_mat
	env.sky = sky

	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = 0.90
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.fog_enabled = true
	env.fog_light_color = Color(0.70, 0.80, 0.90)
	env.fog_density = 0.0002

	var world_env := WorldEnvironment.new()
	world_env.name = "WorldEnvironment"
	world_env.environment = env
	add_child(world_env)


func _report_spawn_surroundings(world_items: Array) -> void:
	var nearest_tree := INF
	for entry in world_generator.trees.values():
		var tree_pos: Vector3 = entry.get("position", Vector3.ZERO)
		var ground := tree_pos.normalized() * _sample_mesh_radius(tree_pos)
		nearest_tree = minf(nearest_tree, ground.distance_to(spawn_point))
	var nearest_item := INF
	for item in world_items:
		nearest_item = minf(nearest_item, item.transform.origin.distance_to(spawn_point))
	print("Spawn nearest: tree=", snapped(nearest_tree, 0.1), "m item=", snapped(nearest_item, 0.1), "m")


func _aim_sun_at_spawn() -> void:
	var light: DirectionalLight3D = get_node_or_null("../DirectionalLight3D")
	if light == null:
		return
	var up := spawn_point.normalized()
	var tangent := up.cross(Vector3.RIGHT)
	if tangent.length() < 0.01:
		tangent = up.cross(Vector3.FORWARD)
	tangent = tangent.normalized()
	light.global_position = spawn_point + up * 1000.0
	light.look_at(spawn_point, tangent)
	light.light_energy = 1.15
	light.shadow_enabled = true
	light.shadow_opacity = 0.35
	light.shadow_blur = 1.5


func _find_spawn_point(world_items: Array) -> void:
	var pr: float = world_generator.planet_radius
	var terrain: Terrain = world_generator.terrain

	# 优先选平坦地面上的树（避免出生就面对陡坡），其次选离物品最近的
	var best_dir := Vector3.ZERO
	var best_ground := Vector3.ZERO
	var best_item := Vector3.ZERO
	var best_score := -INF
	var best_relief := INF
	var best_item_distance := INF
	var best_height := 0.0
	var best_species := ""
	var best_item_material := ""

	for entry in world_generator.trees.values():
		var tree_pos: Vector3 = entry.get("position", Vector3.ZERO)
		if tree_pos.length() < 0.001:
			continue
		var dir := tree_pos.normalized()
		var probe := dir * pr
		if not terrain.is_land(probe):
			continue
		var elev: float = terrain.get_elevation(probe)
		if elev < 20.0 or elev > 120.0:
			continue
		var ground := dir * _sample_mesh_radius(probe)
		var relief := _local_relief(dir, 25.0)
		var tree: TreeGrowth = entry.get("tree", null)
		var tree_height: float = tree.height if tree != null else 0.0

		var nearest := INF
		var nearest_pos := Vector3.ZERO
		var nearest_material := ""
		for item in world_items:
			var d: float = item.transform.origin.distance_to(ground)
			if d < nearest:
				nearest = d
				nearest_pos = item.transform.origin
				nearest_material = item.material_id

		# 综合评分：树 + 30m 内有物品优先；其次高树、平坦、物品近
		var score := tree_height - relief * 0.5 - minf(nearest, 200.0) * 0.05
		if nearest <= 30.0:
			score += 100.0
		if score > best_score:
			best_score = score
			best_relief = relief
			best_item_distance = nearest
			best_height = tree_height
			best_species = String(entry.get("species", "oak"))
			best_item_material = nearest_material
			best_dir = dir
			best_ground = ground
			best_item = nearest_pos

	if best_dir.length() < 0.001:
		_find_spawn_point_fallback()
		return

	# 站在树的另一侧 18m，面向树；最近的物品在树后方
	var toward_item := best_item - best_ground
	toward_item = toward_item - best_dir * toward_item.dot(best_dir)
	if toward_item.length() < 0.001:
		toward_item = best_dir.cross(Vector3.RIGHT)
	toward_item = toward_item.normalized()

	var axis := best_dir.cross(toward_item).normalized()
	var spawn_dir := best_dir.rotated(axis, -18.0 / pr)
	if not terrain.is_land(spawn_dir * pr):
		spawn_dir = best_dir

	spawn_point = spawn_dir * _sample_mesh_radius(spawn_dir * pr)
	spawn_look_target = best_ground + best_dir * 6.0
	print("Spawn: near tree, score=", snapped(best_score, 0.1), " relief=", snapped(best_relief, 0.1),
		"m height=", snapped(best_height, 0.1), "m species=", best_species,
		" item=", snapped(best_item_distance, 0.1), "m (", best_item_material, ")")


func _local_relief(dir: Vector3, radius_m: float) -> float:
	var pr: float = world_generator.planet_radius
	var t1 := dir.cross(Vector3.RIGHT)
	if t1.length() < 0.01:
		t1 = dir.cross(Vector3.FORWARD)
	t1 = t1.normalized()
	var t2 := dir.cross(t1).normalized()
	var angle := radius_m / pr

	var heights: Array[float] = []
	heights.append(_sample_mesh_radius(dir * pr))
	heights.append(_sample_mesh_radius(dir.rotated(t1, angle) * pr))
	heights.append(_sample_mesh_radius(dir.rotated(t1, -angle) * pr))
	heights.append(_sample_mesh_radius(dir.rotated(t2, angle) * pr))
	heights.append(_sample_mesh_radius(dir.rotated(t2, -angle) * pr))

	var lo: float = heights[0]
	var hi: float = heights[0]
	for h in heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	return hi - lo


func _find_spawn_point_fallback() -> void:
	var pr: float = world_generator.planet_radius
	var terrain: Terrain = world_generator.terrain
	for lat in range(-20, 25, 2):
		for lon in range(0, 360, 5):
			var phi: float = deg_to_rad(90.0 - float(lat))
			var theta: float = deg_to_rad(float(lon))
			var dir := Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
			var probe := dir * pr
			if terrain.is_land(probe):
				var elev: float = terrain.get_elevation(probe)
				if elev > 20.0 and elev < 120.0:
					spawn_point = dir * terrain.get_surface_radius(probe)
					var tangent := dir.cross(Vector3.RIGHT).normalized()
					spawn_look_target = spawn_point + tangent * 100.0
					print("Spawn: fallback lat=", lat, " elev=", snapped(elev, 1), "m")
					return
	spawn_point = Vector3(pr, 0, 0)
	spawn_look_target = spawn_point + Vector3(0, 0, -100)


# ============================================================
# 地表 / 海洋 / 地核
# ============================================================

func _grid_steps() -> Array:
	var pr: float = world_generator.planet_radius
	var arc: float = surface_spacing / pr
	var steps_phi: int = maxi(int(PI / arc), 2)
	var steps_theta: int = maxi(int(TAU / arc), 3)
	return [steps_phi, steps_theta]


func _dir(phi: float, theta: float) -> Vector3:
	var s := sin(phi)
	return Vector3(s * cos(theta), cos(phi), s * sin(theta))


func _surface_point(dir: Vector3) -> Vector3:
	var pr: float = world_generator.planet_radius
	var probe := dir * pr
	return dir * world_generator.terrain.get_surface_radius(probe)


func _generate_surface_mesh() -> void:
	var steps: Array = _grid_steps()
	var steps_phi: int = steps[0]
	var steps_theta: int = steps[1]
	var terrain: Terrain = world_generator.terrain
	var pr: float = world_generator.planet_radius

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	_surface_steps_phi = steps_phi
	_surface_steps_theta = steps_theta
	_surface_heights.clear()

	# 先铺共享顶点，再建索引 → 法线自动平滑，不会出现大片平面色块
	var indices: Array = []
	var vertex_count := 0
	for ip in range(steps_phi + 1):
		var phi := PI * float(ip) / float(steps_phi)
		var row: Array = []
		var height_row: Array = []
		for it in range(steps_theta):
			var theta := TAU * float(it) / float(steps_theta)
			var dir := _dir(phi, theta)
			var probe := dir * pr
			var elev: float = terrain.get_elevation(probe)
			var radius: float = terrain.get_surface_radius(probe)
			st.set_color(_surface_color(probe, elev))
			row.append(vertex_count)
			height_row.append(radius)
			st.add_vertex(dir * radius)
			vertex_count += 1
		indices.append(row)
		_surface_heights.append(height_row)

	for ip in range(steps_phi):
		for it in range(steps_theta):
			var it_next := (it + 1) % steps_theta
			var i00: int = indices[ip][it]
			var i01: int = indices[ip][it_next]
			var i11: int = indices[ip + 1][it_next]
			var i10: int = indices[ip + 1][it]

			st.add_index(i00)
			st.add_index(i11)
			st.add_index(i01)
			st.add_index(i00)
			st.add_index(i10)
			st.add_index(i11)

	st.generate_normals()
	var mesh := st.commit()
	if mesh == null:
		printerr("WorldRenderer: surface mesh generation failed")
		return

	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 1.0
	mat.metallic = 0.0

	var mi := MeshInstance3D.new()
	mi.name = "TerrainSurface"
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)

	# 地形碰撞体（供角色/物品物理使用）
	var terrain_body := StaticBody3D.new()
	terrain_body.name = "TerrainBody"
	terrain_body.collision_layer = 2   # 地形专用层，供物品射线定位
	terrain_body.collision_mask = 0
	var terrain_phys := PhysicsMaterial.new()
	terrain_phys.friction = 0.65
	terrain_phys.bounce = 0.0
	terrain_body.physics_material_override = terrain_phys
	var collider := CollisionShape3D.new()
	var terrain_shape := mesh.create_trimesh_shape()
	if terrain_shape is ConcavePolygonShape3D:
		# 双面碰撞：防止物品从网格背面穿进星球内部
		terrain_shape.backface_collision = true
	collider.shape = terrain_shape
	terrain_body.add_child(collider)
	add_child(terrain_body)

	print("Surface mesh: ", steps_theta, "×", steps_phi, " quads, spacing=", surface_spacing, "m")


## 树/物品用的双线性高度：贴合可见网格，不浮空
func _sample_mesh_radius(at_position: Vector3) -> float:
	if _surface_heights.is_empty() or _surface_steps_phi <= 0 or _surface_steps_theta <= 0:
		return world_generator.terrain.get_surface_radius(at_position)

	var dir := at_position.normalized()
	var phi := acos(clampf(dir.y, -1.0, 1.0))
	var theta := atan2(dir.z, dir.x)
	if theta < 0.0:
		theta += TAU

	var fip := (phi / PI) * float(_surface_steps_phi)
	var fit := (theta / TAU) * float(_surface_steps_theta)
	var ip_floor := int(floor(fip))
	var it_floor := int(floor(fit))
	# tx 沿 theta/it 方向，ty 沿 phi/ip 方向
	var tx := fit - float(it_floor)
	var ty := fip - float(ip_floor)

	var ip0: int = clampi(ip_floor, 0, _surface_steps_phi - 1)
	var ip1: int = mini(ip0 + 1, _surface_steps_phi)
	var it0: int = it_floor % _surface_steps_theta
	var it1: int = (it0 + 1) % _surface_steps_theta

	var h00: float = _surface_heights[ip0][it0]
	var h01: float = _surface_heights[ip0][it1]
	var h10: float = _surface_heights[ip1][it0]
	var h11: float = _surface_heights[ip1][it1]

	# 与地表网格的三角剖分一致（对角线 v00-v11）
	if tx >= ty:
		return h00 + (h01 - h00) * tx + (h11 - h01) * ty + 0.03
	return h00 + (h10 - h00) * ty + (h11 - h10) * tx + 0.03


func _surface_color(probe: Vector3, elev: float) -> Color:
	var base: Color
	var province := world_generator.terrain.get_province(probe)
	var flags: int = int(province.get("flags", 0))
	var river: float = float(province.get("river", 0.0))

	if elev < 0.0:
		base = Color(0.16, 0.20, 0.20)                 # 海床
	elif (flags & Terrain.PROV_VOLCANIC) != 0:
		base = Color(0.26, 0.21, 0.18)                 # 火山岩
	elif (flags & Terrain.PROV_METAMORPHIC) != 0:
		base = Color(0.40, 0.40, 0.37)                 # 变质岩
	elif (flags & Terrain.PROV_GRANITE) != 0:
		base = Color(0.62, 0.60, 0.55)                 # 花岗岩
	elif elev < 8.0:
		base = Color(0.76, 0.70, 0.50)                 # 沙滩
	elif elev < 120.0:
		base = Color(0.20, 0.40, 0.14)                 # 草地/沉积低地
	elif elev < 260.0:
		base = Color(0.36, 0.34, 0.28)                 # 岩石
	else:
		base = Color(0.88, 0.90, 0.94)                 # 雪

	if (flags & Terrain.PROV_RIVER) != 0 or river > 0.0:
		base = base.lerp(Color(0.10, 0.28, 0.52), clampf(0.45 + river * 0.4, 0.0, 0.9))
	if elev > 300.0 and (flags & Terrain.PROV_RIVER) == 0:
		base = Color(0.88, 0.90, 0.94)

	if elev >= 0.0:
		var ores: Array = world_generator.ore_gen.get_ore_deposits(
			probe, elev, world_generator.terrain)
		if not ores.is_empty():
			var ore_id: String = String(ores[0].get("ore_id", ""))
			base = base.lerp(_material_color(ore_id, base), 0.35)
	return base


func _generate_water_mesh() -> void:
	var steps: Array = _grid_steps()
	var steps_phi: int = steps[0]
	var steps_theta: int = steps[1]
	var pr: float = world_generator.planet_radius
	var water_r: float = pr + water_offset
	var terrain: Terrain = world_generator.terrain

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0

	for ip in range(steps_phi):
		var phi0 := PI * float(ip) / float(steps_phi)
		var phi1 := PI * float(ip + 1) / float(steps_phi)
		for it in range(steps_theta):
			var th0 := TAU * float(it) / float(steps_theta)
			var th1 := TAU * float(it + 1) / float(steps_theta)
			var center := _dir((phi0 + phi1) * 0.5, (th0 + th1) * 0.5)
			if terrain.is_land(center * pr):
				continue

			var p0 := _dir(phi0, th0) * water_r
			var p1 := _dir(phi0, th1) * water_r
			var p2 := _dir(phi1, th1) * water_r
			var p3 := _dir(phi1, th0) * water_r

			st.add_vertex(p0)
			st.add_vertex(p2)
			st.add_vertex(p1)
			st.add_vertex(p0)
			st.add_vertex(p3)
			st.add_vertex(p2)
			quads += 1

	if quads == 0:
		return

	st.generate_normals()
	var mesh := st.commit()

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.05, 0.22, 0.50, 0.72)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.roughness = 0.06
	mat.metallic = 0.15
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mi := MeshInstance3D.new()
	mi.name = "OceanSurface"
	mi.mesh = mesh
	mi.material_override = mat
	add_child(mi)
	print("Ocean mesh: ", quads, " quads")


func _generate_core() -> void:
	var core_radius: float = world_generator.planet_radius - world_generator.terrain.max_depth - 10.0
	core_radius = maxf(core_radius, 1.0)
	var sphere := SphereMesh.new()
	sphere.radius = core_radius
	sphere.height = core_radius * 2.0
	sphere.radial_segments = 32
	sphere.rings = 16

	var mi := MeshInstance3D.new()
	mi.name = "PlanetCore"
	mi.mesh = sphere
	mi.material_override = _mat(Color(0.14, 0.12, 0.10))
	add_child(mi)


# ============================================================
# 树木
# ============================================================

func _generate_trees() -> void:
	_trees_root = Node3D.new()
	_trees_root.name = "Trees"
	add_child(_trees_root)

	var trunk_mesh := CylinderMesh.new()
	trunk_mesh.height = 1.0
	trunk_mesh.top_radius = 1.0
	trunk_mesh.bottom_radius = 1.0
	trunk_mesh.radial_segments = 6

	var canopy_sphere := SphereMesh.new()
	canopy_sphere.radius = 1.0
	canopy_sphere.height = 2.0
	canopy_sphere.radial_segments = 7
	canopy_sphere.rings = 4

	var canopy_cone := CylinderMesh.new()
	canopy_cone.height = 1.0
	canopy_cone.top_radius = 0.0
	canopy_cone.bottom_radius = 1.0
	canopy_cone.radial_segments = 7

	var trunk_mat := _mat(Color(0.44, 0.31, 0.18))
	var oak_mat := _mat(Color(0.22, 0.46, 0.16))
	var pine_mat := _mat(Color(0.14, 0.34, 0.16))
	var birch_mat := _mat(Color(0.36, 0.54, 0.22))

	var tree_colliders := StaticBody3D.new()
	tree_colliders.name = "TreeColliders"
	add_child(tree_colliders)

	var rendered := 0
	for entry in world_generator.trees.values():
		var tree: TreeGrowth = entry.get("tree", null)
		if tree == null:
			continue
		var pos: Vector3 = entry.get("position", Vector3.ZERO)
		var species: String = String(entry.get("species", "oak"))
		var dir := pos.normalized()
		var ground := dir * _sample_mesh_radius(pos)
		var height: float = maxf(tree.height, 2.0) * tree_scale
		var trunk_radius: float = maxf(tree.trunk_diameter * 0.5, 0.08)
		var basis := ItemGeometry.basis_from_up(dir)

		var trunk := MeshInstance3D.new()
		trunk.mesh = trunk_mesh
		trunk.material_override = trunk_mat
		trunk.transform = Transform3D(basis, ground + dir * (height * 0.30))
		trunk.scale = Vector3(trunk_radius, height * 0.60, trunk_radius)
		_trees_root.add_child(trunk)

		# 树干碰撞体（只挡树干，不挡树冠）
		var trunk_shape := CylinderShape3D.new()
		trunk_shape.radius = trunk_radius
		trunk_shape.height = height * 0.60
		var trunk_col := CollisionShape3D.new()
		trunk_col.shape = trunk_shape
		trunk_col.transform = Transform3D(basis, ground + dir * (height * 0.30))
		tree_colliders.add_child(trunk_col)

		var canopy := MeshInstance3D.new()
		if species == "pine":
			canopy.mesh = canopy_cone
			canopy.material_override = pine_mat
			canopy.transform = Transform3D(basis, ground + dir * (height * 0.62))
			canopy.scale = Vector3(height * 0.28, height * 0.45, height * 0.28)
		else:
			canopy.mesh = canopy_sphere
			canopy.material_override = oak_mat if species == "oak" else birch_mat
			canopy.transform = Transform3D(basis, ground + dir * (height * 0.72))
			canopy.scale = Vector3(height * 0.28, height * 0.22, height * 0.28)
		_trees_root.add_child(canopy)
		rendered += 1

	print("Trees rendered: ", rendered)


# ============================================================
# 世界物品实体（Phase 1：确定性本地生成；后续改为服务端 ITEM_SPAWN）
# ============================================================

func _generate_world_items(items: Array) -> void:
	_items_root = Node3D.new()
	_items_root.name = "WorldItems"
	add_child(_items_root)

	for item in items:
		_items_root.add_child(_build_item_body(item))

	print("World items (dynamic): ", items.size(), " (stones / logs / ore outcrops)")


func _build_item_body(item: ItemEntity) -> ItemPhysicsBody:
	var body := ItemPhysicsBody.new()
	body.item = item
	body.planet_radius = world_generator.planet_radius
	body.mass = clampf(item.get_mass_kg(), 0.5, 2000.0)
	body.gravity_scale = 0.0
	if item.shape == "fiber":
		body.linear_damp = 0.25
		body.angular_damp = 0.45
	else:
		body.linear_damp = 0.10
		body.angular_damp = 0.20
	body.continuous_cd = true
	body.collision_layer = 1
	body.collision_mask = 15  # 地形(2)+树/物品(1)+手(4)+玩家(8)

	# 用材料真实摩擦/恢复系数驱动滑动、滚动和停距
	var item_material = item.get_material()
	if item_material != null:
		var phys_mat := PhysicsMaterial.new()
		phys_mat.friction = clampf(item_material.kinetic_friction, 0.0, 1.0)
		phys_mat.bounce = clampf(item_material.restitution * 0.15, 0.0, 0.15)
		body.physics_material_override = phys_mat

	var visual := _build_item_visual(item)
	body.add_child(visual)
	for collision_shape in ItemCollision.build_shapes(item, visual.mesh):
		var col := CollisionShape3D.new()
		col.shape = collision_shape as Shape3D
		body.add_child(col)

	# 初始位置对齐到可见/碰撞网格，再抬高 0.5m 落下；
	# 精确噪声高度和 50m 网格可能差很多，直接放在噪声高度会嵌进地形。
	var dir := item.transform.origin.normalized()
	var exact_ground: float = world_generator.terrain.get_surface_radius(item.transform.origin)
	var radial_offset: float = item.transform.origin.length() - exact_ground
	var visible_ground: float = _sample_mesh_radius(item.transform.origin)

	# 用物理射线落到真实地形碰撞面，避免采样误差让物品生成在地形内部
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space != null:
		var from := dir * (world_generator.planet_radius + 1000.0)
		var to := dir * (world_generator.planet_radius - 1000.0)
		var query := PhysicsRayQueryParameters3D.create(from, to, 2)
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			visible_ground = (hit["position"] as Vector3).length()

	var dims: Dictionary = item.dimensions
	var lift: float = 0.12
	if item.shape == "fiber":
		var length: float = float(dims.get("length", 1.0))
		var diameter: float = float(dims.get("diameter", dims.get("width", 0.1)))
		# 倒木两端也要贴地，取两端地表最高点，避免一端埋进坡面
		var axis_world: Vector3 = item.transform.basis.y.normalized()
		var p_a: Vector3 = item.transform.origin + axis_world * length * 0.5
		var p_b: Vector3 = item.transform.origin - axis_world * length * 0.5
		visible_ground = maxf(visible_ground,
			maxf(_sample_mesh_radius(p_a), _sample_mesh_radius(p_b)))
		lift += diameter * 0.5
	elif item.shape == "sphere":
		lift += float(dims.get("radius", 0.2))
	else:
		lift += float(dims.get("height", 0.2)) * 0.5

	body.transform = Transform3D(item.transform.basis, dir * (visible_ground + lift))
	body.fallback_position = dir * (visible_ground + lift)
	body.set_meta("spawn_pos", body.transform.origin)
	body.set_meta("spawn_dir", dir)
	return body


func _build_item_visual(item: ItemEntity) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var dims := item.dimensions

	if item.custom_mesh != null:
		mi.mesh = item.custom_mesh
		mi.material_override = _mat(_material_color(item.material_id, Color(0.5, 0.5, 0.5)))
		mi.transform = Transform3D.IDENTITY
		return mi

	match item.shape:
		"fiber":
			var cm := CylinderMesh.new()
			cm.height = float(dims.get("length", 1.0))
			var diameter: float = float(dims.get("diameter", dims.get("width", 0.2)))
			cm.top_radius = diameter * 0.5
			cm.bottom_radius = diameter * 0.5
			cm.radial_segments = 8
			cm.rings = 2
			mi.mesh = cm
		"sphere":
			var radius: float = float(dims.get("radius", 0.2))
			var sm := SphereMesh.new()
			sm.radius = radius
			sm.height = radius * 2.0
			sm.radial_segments = 8
			sm.rings = 4
			mi.mesh = sm
		_:
			var bm := BoxMesh.new()
			bm.size = Vector3(
				float(dims.get("length", 0.2)),
				float(dims.get("height", 0.2)),
				float(dims.get("width", 0.2)))
			mi.mesh = bm

	mi.material_override = _mat(_material_color(item.material_id, Color(0.5, 0.5, 0.5)))
	mi.transform = Transform3D.IDENTITY
	return mi





# ============================================================
# 材质缓存
# ============================================================

func _mat(color: Color) -> StandardMaterial3D:
	var key := "c%.2f%.2f%.2f" % [color.r, color.g, color.b]
	if _materials.has(key):
		return _materials[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.92
	m.metallic = 0.0
	_materials[key] = m
	return m


func _material_color(material_id: String, fallback: Color) -> Color:
	return _material_colors.get(material_id, fallback)
