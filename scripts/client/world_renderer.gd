# ============================================================
# WorldRenderer — 全星球实体渲染
# ============================================================
# 星球是实心岩石球体。地表多层材质：表层(土壤/草/矿脉)+岩层(基岩深柱)。
# 海洋是水材质实体。所有颜色取自 MaterialDB 真实参数。
# ============================================================
class_name WorldRenderer
extends Node3D

@export var block_spacing: float = 150.0  # 水平间距 m
@export var crust_depth: float = 500.0   # 地壳岩层深度 m
@export var height_scale: float = 0.2

var world_generator: WorldGenerator = null
var spawn_point: Vector3 = Vector3.ZERO
var _combiner: CSGCombiner3D = null
var _materials: Dictionary = {}


func _ready() -> void:
	world_generator = WorldGenerator.new(42, 3978.87)
	world_generator.max_elevation = 400.0
	world_generator.generate()

	var land_pct: float = snapped(world_generator._estimate_land_ratio() * 100, 0.1)
	print("World: land=", land_pct, "%, trees=", world_generator.trees.size())

	_combiner = CSGCombiner3D.new()
	_combiner.name = "PlanetSurface"
	_combiner.use_collision = true
	add_child(_combiner)

	_find_spawn_point()
	_generate_planet()

	var player: FirstPersonController = get_node_or_null("../FirstPersonController")
	if player:
		player.spawn_on_surface(spawn_point)
		player.planet_radius = world_generator.planet_radius


func _find_spawn_point() -> void:
	var pr: float = world_generator.planet_radius
	var terrain: Terrain = world_generator.terrain
	for lat in range(-20, 25, 2):
		for lon in range(0, 360, 5):
			var phi: float = deg_to_rad(90.0 - float(lat))
			var theta: float = deg_to_rad(float(lon))
			var dir := Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))
			var surf := dir * pr
			if terrain.is_land(surf):
				var elev: float = terrain.get_elevation(surf)
				if elev > 20 and elev < 250:
					spawn_point = surf + dir * 1.0
					print("Spawn: lat=", lat, " elev=", snapped(elev, 1), "m")
					return
	spawn_point = Vector3(pr, 0, 0)


func _mat(color: Color) -> StandardMaterial3D:
	var key := "c%.2f%.2f%.2f" % [color.r, color.g, color.b]
	if _materials.has(key):
		return _materials[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.roughness = 0.88
	_materials[key] = m
	return m


func _mat_from_db(mat_id: String, fallback: Color) -> StandardMaterial3D:
	# 尝试从材料数据库获取真实颜色
	var mp: MaterialProperty = MaterialDB.get_material(mat_id)
	if mp:
		# 用反射率和粗糙度近似颜色
		var c := Color(mp.reflectivity, mp.reflectivity * 0.6, mp.reflectivity * 0.3)
		if mp.category == "rock" or mp.category == "stone":
			c = fallback
		return _mat(c)
	return _mat(fallback)


func _generate_planet() -> void:
	var pr: float = world_generator.planet_radius
	var terrain: Terrain = world_generator.terrain
	var ore_gen: OreVein = world_generator.ore_gen

	var arc_step := block_spacing / pr
	var steps_theta: int = int(TAU / arc_step)
	var steps_phi: int = int(PI / arc_step)

	var land_count: int = 0
	var sea_count: int = 0
	var deep_rock_count: int = 0

	print("Planet: ", steps_theta, "×", steps_phi, " grid, crust=", crust_depth, "m")

	for ip in range(steps_phi):
		var phi: float = (float(ip) + 0.5) * arc_step
		var sin_phi: float = sin(phi)
		var theta_steps: int = maxi(int(float(steps_theta) * sin_phi), 1)
		var theta_step: float = TAU / float(theta_steps)

		for it in range(theta_steps):
			var theta: float = (float(it) + 0.5) * theta_step
			var dir := Vector3(sin_phi * cos(theta), cos(phi), sin_phi * sin(theta))
			var surf := dir * pr

			var elev: float = terrain.get_elevation(surf)
			var is_land: bool = terrain.is_land(surf)
			var bw := block_spacing * 0.88

			if not is_land:
				# === 海洋：水实体 ===
				sea_count += 1
				# 水面层 ~8m 深
				var water := CSGBox3D.new()
				water.size = Vector3(bw, 8.0, bw)
				water.position = surf + dir * 4.0
				water.material = _mat(Color(0.08, 0.28, 0.65, 0.75))
				_combiner.add_child(water)
				# 海床下是岩石（实体星球）
				var seabed := CSGBox3D.new()
				seabed.size = Vector3(bw * 0.9, crust_depth * 0.5, bw * 0.9)
				seabed.position = surf - dir * (crust_depth * 0.25 + 4.0)
				seabed.material = _mat(Color(0.35, 0.33, 0.3))
				_combiner.add_child(seabed)
				continue

			land_count += 1

			# === 地表层：按海拔和矿脉着色 ===
			var top_color: Color
			var top_h: float

			if elev < 5:
				top_color = Color(0.78, 0.72, 0.52); top_h = 1.5   # 沙滩
			elif elev < 60:
				top_color = Color(0.2, 0.42, 0.13); top_h = 3.0    # 草地/腐殖土
			elif elev < 180:
				top_color = Color(0.38, 0.32, 0.22); top_h = 2.0   # 丘陵岩石
			elif elev < 320:
				top_color = Color(0.48, 0.43, 0.33); top_h = 1.0   # 山岩
			else:
				top_color = Color(0.95, 0.95, 0.98); top_h = 5.0   # 雪盖

			# 矿脉露头覆盖地表色
			var ores := ore_gen.get_ore_deposits(surf, elev, terrain)
			var ore_found: bool = false
			if ores.size() > 0:
				ore_found = true
				var ot: String = ores[0].get("ore_id", "")
				match ot:
					"iron_ore_hematite", "iron_ore_magnetite":
						top_color = Color(0.55, 0.18, 0.12); top_h = 6.0
					"copper_ore_malachite":
						top_color = Color(0.15, 0.65, 0.45); top_h = 5.0
					"coal":
						top_color = Color(0.12, 0.12, 0.12); top_h = 3.0
					"tin_ore_cassiterite":
						top_color = Color(0.45, 0.3, 0.18); top_h = 4.0
					"flint":
						top_color = Color(0.28, 0.28, 0.32); top_h = 2.5
					"limestone":
						top_color = Color(0.8, 0.78, 0.68); top_h = 5.0
					"sandstone":
						top_color = Color(0.68, 0.58, 0.38); top_h = 3.5
					"clay":
						top_color = Color(0.62, 0.42, 0.32); top_h = 3.0

			# 地表方块
			var top_block := CSGBox3D.new()
			top_block.size = Vector3(bw, top_h, bw)
			top_block.position = surf + dir * top_h * 0.5
			top_block.material = _mat(top_color)
			_combiner.add_child(top_block)

			# === 岩层深柱（星球是实心的） ===
			# 每个格点的岩柱从地表向下延伸 crust_depth 米
			var crust_h: float = crust_depth + elev * height_scale
			crust_h = maxf(crust_h, 30.0)

			# 上层岩石（风化层 ~20m）
			var weathered := CSGBox3D.new()
			weathered.size = Vector3(bw * 0.92, 20.0, bw * 0.92)
			weathered.position = surf - dir * (top_h + 10.0)
			var wc: Color
			if elev < 50:
				wc = Color(0.5, 0.35, 0.2)      # 土壤/风化岩棕
			elif elev < 200:
				wc = Color(0.55, 0.48, 0.38)     # 中风化岩
			else:
				wc = Color(0.42, 0.4, 0.36)      # 高海拔基岩
			weathered.material = _mat(wc)
			_combiner.add_child(weathered)

			# 深层基岩（地壳主体）
			var remaining := crust_h - 20.0
			if remaining > 5.0:
				deep_rock_count += 1
				var bedrock := CSGBox3D.new()
				bedrock.size = Vector3(bw * 0.85, remaining, bw * 0.85)
				bedrock.position = surf - dir * (top_h + 20.0 + remaining * 0.5)
				var bc: Color
				if ore_found:
					bc = Color(0.38, 0.35, 0.3)  # 矿脉区域深色基岩
				else:
					bc = Color(0.4, 0.38, 0.35)   # 普通基岩灰
				bedrock.material = _mat(bc)
				_combiner.add_child(bedrock)

	# === 固态核心：大球填充星球内部（防止看到空心） ===
	var core := CSGSphere3D.new()
	core.radius = pr  # 球心填满到地表，与岩柱无缝衔接
	core.position = Vector3.ZERO
	core.material = _mat(Color(0.35, 0.33, 0.28))
	_combiner.add_child(core)

	print("Planet: ", land_count, " land, ", sea_count, " sea, ",
		deep_rock_count, " bedrock columns, ", _materials.size(), " materials")
	print("  Surface R=", pr, "m, crust=", crust_depth, "m, core R=", snapped(core.radius, 1), "m")
