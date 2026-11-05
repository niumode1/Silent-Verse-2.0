# ============================================================
# WorldGenerator — 赛季世界程序化生成
# ============================================================
# 赛季开局时一次性生成全部地形/矿产/植被/土壤。
# 使用种子保证同种子=同世界（确定性）。
# ============================================================
class_name WorldGenerator
extends RefCounted

## Phase 1 默认世界参数（客户端/服务端/测试共用，避免各写一份）
const DEFAULT_SEED := 42
const DEFAULT_PLANET_RADIUS := 3978.87
const DEFAULT_MAX_ELEVATION := 400.0

## 赛季种子
var _seed_value: int = 0

## 世界生成专用随机源（不用全局 randf，保证同种子同世界）
var _rng := RandomNumberGenerator.new()

## 行星半径 m
var planet_radius: float = DEFAULT_PLANET_RADIUS

## 最大海拔 m
var max_elevation: float = 1000.0

## 陆地/海洋比（目标 ~4:6）
var land_ratio_target: float = 0.4

## 子生成器
var terrain: Terrain = null
var ore_gen: OreVein = null
var soil_grid: SoilGrid = null
var climate: Climate = null

## 活跃的树木实例 {position_key: TreeGrowth}
var trees: Dictionary = {}

## 生成状态
var is_generated: bool = false
var generation_progress: float = 0.0

# ============================================================
# 初始化与生成
# ============================================================

func _init(p_seed: int = 0, p_radius: float = DEFAULT_PLANET_RADIUS) -> void:
	_seed_value = p_seed
	planet_radius = p_radius

func generate() -> void:
	print("WorldGenerator: Generating world (R=", planet_radius, "m)...")

	# 1. 地形
	terrain = Terrain.new(planet_radius, _seed_value)
	terrain.max_elevation = max_elevation
	terrain.land_ratio_target = land_ratio_target
	terrain.build()
	generation_progress = 0.2

	# 2. 矿产
	ore_gen = OreVein.new(_seed_value)
	generation_progress = 0.4

	# 3. 土壤
	soil_grid = SoilGrid.new()
	generation_progress = 0.6

	# 4. 气候
	climate = Climate.new()
	generation_progress = 0.7

	# 5. 初始植被（独立随机源，保证同种子同森林）
	_rng.seed = _seed_value
	_generate_initial_vegetation()
	generation_progress = 0.9

	is_generated = true
	generation_progress = 1.0
	print("WorldGenerator: Done — land ", _estimate_land_ratio() * 100, "%")

# ============================================================
# 查询
# ============================================================

## 获取某点的地表位置（球心→半径线）
func get_surface_point(position: Vector3) -> Vector3:
	if not terrain:
		return position.normalized() * planet_radius
	var r: float = terrain.get_surface_radius(position)
	return position.normalized() * r

## 查询某点的完整世界数据
func query_world(position: Vector3) -> Dictionary:
	var result: Dictionary = {
		"elevation": 0.0,
		"is_land": false,
		"latitude": 0.0,
		"ores": [],
		"soil": {},
		"temperature": 0.0,
		"precipitation": 0.0,
	}

	if not is_generated:
		return result

	var elev: float = terrain.get_elevation(position)
	var lat: float = terrain.get_latitude(position)
	var is_land: bool = terrain.is_land(position)

	result["elevation"] = elev
	result["is_land"] = is_land
	result["latitude"] = lat

	if climate:
		result["temperature"] = get_temperature_at(position, elev)
		result["precipitation"] = climate.get_precipitation(lat, elev)

	if is_land and ore_gen:
		result["ores"] = ore_gen.get_ore_deposits(position, elev, terrain)

	if is_land and soil_grid:
		result["soil"] = soil_grid.get_soil_at(position)

	return result

## 某位置/海拔的温度（世界物品、气候查询共用）
func get_temperature_at(position: Vector3, elevation: float) -> float:
	if climate == null or terrain == null:
		return 20.0
	return climate.get_temperature(terrain.get_latitude(position), elevation)

## 球面均匀随机方向（世界生成、物品生成共用）
static func random_direction(rng: RandomNumberGenerator) -> Vector3:
	var theta := rng.randf() * TAU
	var phi := acos(2.0 * rng.randf() - 1.0)
	return Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))

## 获取指定位置附近的树木列表
func get_nearby_trees(position: Vector3, radius: float) -> Array:
	var result: Array = []
	for pos_key in trees.keys():
		var tree_pos: Vector3 = trees[pos_key].get("position", Vector3.ZERO)
		if position.distance_to(tree_pos) <= radius:
			result.append({"position": tree_pos, "tree": trees[pos_key]})
	return result

## 在某位置种树
func plant_tree(position: Vector3, species: String, game_day: float) -> TreeGrowth:
	var tree := TreeGrowth.create_sapling(species, game_day)
	var key: String = _position_key(position)
	trees[key] = {"position": position, "tree": tree, "species": species}
	return tree

## 砍树
func harvest_tree(position: Vector3) -> Dictionary:
	var key: String = _position_key(position)
	if not trees.has(key):
		return {"success": false, "reason": "no tree"}
	var tree: TreeGrowth = trees[key]["tree"]
	var mass: float = tree.get_harvestable_mass()
	var species: String = trees[key]["species"]
	tree.kill()
	trees.erase(key)
	return {"success": true, "mass_kg": mass, "species": species}

# ============================================================
# 内部
# ============================================================

func _generate_initial_vegetation() -> void:
	# 在陆地上稀疏撒种
	var tree_count: int = int(planet_radius * planet_radius * 0.0001)  # ~1500 trees
	tree_count = mini(tree_count, 5000)

	for i in range(tree_count):
		var dir := random_direction(_rng)
		var pos := dir * planet_radius

		if not terrain.is_land(pos):
			continue

		var elev: float = terrain.get_elevation(pos)
		var lat: float = terrain.get_latitude(pos)

		# 根据气候选树种
		var species: String = _pick_tree_species(lat, elev)

		var tree := TreeGrowth.create_sapling(species, 0)
		# 给予随机初始生长（模拟已有的森林）
		var maturity: float = _rng.randf() * 0.8 + 0.1
		var data: Dictionary = TreeGrowth.SPECIES_DATA.get(species, TreeGrowth.SPECIES_DATA["oak"])
		tree.biomass = data["max_biomass"] * maturity * maturity
		tree.height = data["max_height"] * maturity
		tree.trunk_diameter = data["max_diameter"] * pow(maturity, 0.4)
		tree.last_growth_day = 0

		var key: String = _position_key(pos)
		trees[key] = {"position": pos, "tree": tree, "species": species}

	print("  Initial trees: ", trees.size())

func _pick_tree_species(latitude: float, elevation: float) -> String:
	var abs_lat: float = abs(latitude)
	if abs_lat > 60:
		return "pine"  # 寒带松
	if elevation > 500:
		return "pine"  # 高山松
	if abs_lat < 30:
		return "oak"   # 热带橡木
	if _rng.randf() < 0.3:
		return "birch"
	if _rng.randf() < 0.2:
		return "pine"
	return "oak"

func _estimate_land_ratio() -> float:
	if not terrain:
		return 0.0
	# 独立随机源，避免消耗植被 RNG 状态
	var ratio_rng := RandomNumberGenerator.new()
	ratio_rng.seed = _seed_value ^ 0x9E3779B9
	var samples: int = 2000
	var land: int = 0
	for i in range(samples):
		var dir := random_direction(ratio_rng)
		if terrain.is_land(dir * planet_radius):
			land += 1
	return float(land) / float(samples)

## 供世界物品生成器等外部系统使用
func get_seed() -> int:
	return _seed_value

func _position_key(pos: Vector3) -> String:
	return "%.1f_%.1f_%.1f" % [pos.x, pos.y, pos.z]
