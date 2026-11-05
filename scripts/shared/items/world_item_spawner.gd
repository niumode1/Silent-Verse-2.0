# ============================================================
# WorldItemSpawner — 从世界生成结果产出真实物品实体
# ============================================================
# 赛季开局一次性生成地表石头、倒木、矿脉露头。
# 所有位置/材质/尺寸由世界种子确定，同种子同世界 → 客户端与
# 服务端各自生成也会得到相同物品列表（Phase 1 的确定性同步方式；
# 后续接入网络时改为服务端广播 ITEM_SPAWN）。
#
# 这里只生成「物品实体」，不注册、不模拟物理。
# ============================================================
class_name WorldItemSpawner
extends RefCounted

const ITEM_ID_BASE := 1_000_000
const SAMPLE_COUNT := 2500
const LOG_FRACTION := 0.08
const MAX_LOGS := 120

## 常见地表石块（按海拔加权）
const LOWLAND_STONES := [
	{"id": "limestone", "weight": 0.28},
	{"id": "sandstone", "weight": 0.28},
	{"id": "clay", "weight": 0.18},
	{"id": "flint", "weight": 0.16},
	{"id": "granite", "weight": 0.10},
]

const MIDLAND_STONES := [
	{"id": "granite", "weight": 0.28},
	{"id": "limestone", "weight": 0.20},
	{"id": "sandstone", "weight": 0.18},
	{"id": "flint", "weight": 0.14},
	{"id": "basalt", "weight": 0.10},
	{"id": "slate", "weight": 0.10},
]

const HIGHLAND_STONES := [
	{"id": "granite", "weight": 0.34},
	{"id": "basalt", "weight": 0.28},
	{"id": "slate", "weight": 0.18},
	{"id": "obsidian", "weight": 0.12},
	{"id": "flint", "weight": 0.08},
]

## 生成全部世界物品。返回 Array[ItemEntity]，id 从 item_id_base 连续分配。
static func generate(world: WorldGenerator, item_id_base: int = ITEM_ID_BASE) -> Array:
	var items: Array = []
	if world == null or not world.is_generated:
		return items

	var rng := RandomNumberGenerator.new()
	rng.seed = world.get_seed() ^ 0xC0FFEE

	var next_id: int = item_id_base
	next_id = _spawn_surface_stones_and_ores(world, rng, items, next_id)
	_spawn_fallen_logs(world, rng, items, next_id)
	return items

# ============================================================
# 地表石头 / 矿脉露头
# ============================================================

static func _spawn_surface_stones_and_ores(world: WorldGenerator, rng: RandomNumberGenerator,
		items: Array, next_id: int) -> int:
	var terrain: Terrain = world.terrain
	var ore_gen: OreVein = world.ore_gen
	var planet_radius: float = world.planet_radius

	for i in range(SAMPLE_COUNT):
		var dir := WorldGenerator.random_direction(rng)
		var sample_point := dir * planet_radius
		if not terrain.is_land(sample_point):
			continue

		var elevation := terrain.get_elevation(sample_point)
		if elevation < 1.0:
			continue

		var surface := dir * terrain.get_surface_radius(sample_point)
		# 避开树干碰撞体，避免刚体一开始就嵌在树里被弹穿地形
		if _is_near_tree(world, surface, 2.0):
			continue
		var deposits: Array = ore_gen.get_ore_deposits(sample_point, elevation, terrain)
		var roll := rng.randf()

		# 矿脉露头：靠近矿脉时优先出现矿石
		if not deposits.is_empty() and roll < 0.55:
			var deposit: Dictionary = deposits[rng.randi_range(0, deposits.size() - 1)]
			var ore_id: String = String(deposit.get("ore_id", "granite"))
			var richness: float = float(deposit.get("richness", 0.5))
			items.append(_make_ore(next_id, ore_id, richness, surface, dir, rng, world, elevation))
			next_id += 1
			continue

		# 普通石块：按地质省选岩性
		if roll < 0.90:
			var province := terrain.get_province(sample_point)
			var flags: int = int(province.get("flags", 0))
			var stone_id := _pick_stone(rng, elevation, flags)
			items.append(_make_stone(next_id, stone_id, surface, dir, rng, world, elevation))
			next_id += 1

	return next_id

# ============================================================
# 倒木（树基附近）
# ============================================================

static func _spawn_fallen_logs(world: WorldGenerator, rng: RandomNumberGenerator,
		items: Array, next_id: int) -> void:
	if world.trees.is_empty():
		return

	var keys: Array = world.trees.keys()
	keys.sort()  # 保证遍历顺序确定

	var target: int = mini(MAX_LOGS, int(float(keys.size()) * LOG_FRACTION))
	if target <= 0:
		return

	var step: float = float(keys.size()) / float(target)
	var cursor: float = 0.0
	var spawned: int = 0

	while int(cursor) < keys.size() and spawned < target:
		var entry: Dictionary = world.trees[keys[int(cursor)]]
		var tree_pos: Vector3 = entry.get("position", Vector3.ZERO)
		var species: String = String(entry.get("species", "oak"))
		var dir := tree_pos.normalized()
		var tree: TreeGrowth = entry.get("tree", null)
		var trunk_radius: float = maxf(tree.trunk_diameter * 0.5 if tree != null else 0.4, 0.3)
		var material_id := _species_to_material(species)

		# 只在相对平坦的树基放倒木，避免木棍沿坡乱滚/乱跳
		if not _tree_site_flat(world, dir, 4.0):
			cursor += step
			continue

		# 倒木放在树干旁边，而不是树心/树干碰撞体里
		var tangent := dir.cross(Vector3.RIGHT)
		if tangent.length() < 0.01:
			tangent = dir.cross(Vector3.FORWARD)
		tangent = tangent.normalized()
		var offset_axis := dir.cross(tangent).normalized()
		var offset_angle: float = (trunk_radius + 1.5) / world.planet_radius
		var log_dir := dir.rotated(offset_axis, offset_angle)
		var log_probe := log_dir * world.planet_radius
		var log_surface := log_dir * world.terrain.get_surface_radius(log_probe)
		var log_elevation := world.terrain.get_elevation(log_probe)

		items.append(_make_log(next_id, material_id, log_surface, log_dir, log_elevation, rng, world))
		next_id += 1
		spawned += 1
		cursor += step

# ============================================================
# 物品构造
# ============================================================

static func _make_stone(item_id: int, material_id: String, surface: Vector3,
		dir: Vector3, rng: RandomNumberGenerator, world: WorldGenerator,
		elevation: float) -> ItemEntity:
	var size := rng.randf_range(0.12, 0.42)
	var item := ItemEntity.new()
	item.item_id = item_id
	item.material_id = material_id
	item.shape = "block"
	item.dimensions = {
		"length": size * rng.randf_range(0.9, 1.3),
		"width": size * rng.randf_range(0.8, 1.2),
		"height": size * rng.randf_range(0.6, 1.0),
	}
	item.temperature_c = world.get_temperature_at(surface, elevation)
	item.transform = Transform3D(ItemGeometry.basis_from_up(dir), surface + dir * (size * 0.4))
	item.set_in_world(item.transform)
	return item

static func _make_ore(item_id: int, material_id: String, richness: float, surface: Vector3,
		dir: Vector3, rng: RandomNumberGenerator, world: WorldGenerator,
		elevation: float) -> ItemEntity:
	var size := rng.randf_range(0.25, 0.65) * (0.7 + richness * 0.6)
	var item := ItemEntity.new()
	item.item_id = item_id
	item.material_id = material_id
	item.shape = "block"
	item.dimensions = {
		"length": size * rng.randf_range(1.0, 1.5),
		"width": size * rng.randf_range(0.8, 1.2),
		"height": size * rng.randf_range(0.7, 1.1),
	}
	item.temperature_c = world.get_temperature_at(surface, elevation)
	item.transform = Transform3D(ItemGeometry.basis_from_up(dir), surface + dir * (size * 0.35))
	item.set_in_world(item.transform)
	return item

static func _make_log(item_id: int, material_id: String, surface: Vector3,
		dir: Vector3, elevation: float, rng: RandomNumberGenerator, world: WorldGenerator) -> ItemEntity:
	var length := rng.randf_range(1.0, 2.0)
	var diameter := rng.randf_range(0.07, 0.16)

	# 倒木水平躺在地表：局部 Y = 木轴（切向），局部 Z = 地表法线
	var axis := _random_tangent(dir, rng)
	var side := axis.cross(dir).normalized()
	var basis := Basis(side, axis, dir)

	var item := ItemEntity.new()
	item.item_id = item_id
	item.material_id = material_id
	item.shape = "fiber"
	item.dimensions = {"length": length, "diameter": diameter}
	item.grain_dir_local = Vector3.UP  # 木纹沿木轴
	item.temperature_c = world.get_temperature_at(surface, elevation)
	item.transform = Transform3D(basis, surface + dir * (diameter * 0.5 + 0.05))
	item.set_in_world(item.transform)
	return item

# ============================================================
# 辅助
# ============================================================

static func _random_tangent(dir: Vector3, rng: RandomNumberGenerator) -> Vector3:
	var reference := Vector3.UP
	if absf(dir.dot(reference)) > 0.99:
		reference = Vector3.RIGHT
	var tangent := dir.cross(reference).normalized()
	return tangent.rotated(dir, rng.randf() * TAU).normalized()

static func _pick_stone(rng: RandomNumberGenerator, elevation: float, province_flags: int) -> String:
	var pool: Array
	if (province_flags & Terrain.PROV_SEDIMENTARY) != 0:
		pool = LOWLAND_STONES
	elif (province_flags & (Terrain.PROV_VOLCANIC | Terrain.PROV_METAMORPHIC | Terrain.PROV_GRANITE)) != 0:
		pool = HIGHLAND_STONES
	elif elevation < 40.0:
		pool = LOWLAND_STONES
	elif elevation < 250.0:
		pool = MIDLAND_STONES
	else:
		pool = HIGHLAND_STONES

	var total_weight: float = 0.0
	for entry in pool:
		total_weight += float(entry["weight"])
	var roll := rng.randf() * total_weight
	var cursor: float = 0.0
	for entry in pool:
		cursor += float(entry["weight"])
		if roll <= cursor:
			return String(entry["id"])
	return String(pool[pool.size() - 1]["id"])

static func _tree_site_flat(world: WorldGenerator, dir: Vector3, radius_m: float) -> bool:
	var pr: float = world.planet_radius
	var tangent := dir.cross(Vector3.RIGHT)
	if tangent.length() < 0.01:
		tangent = dir.cross(Vector3.FORWARD)
	tangent = tangent.normalized()
	var axis := dir.cross(tangent).normalized()
	var angle: float = radius_m / pr
	var heights: Array[float] = []
	heights.append(world.terrain.get_elevation(dir * pr))
	heights.append(world.terrain.get_elevation(dir.rotated(tangent, angle) * pr))
	heights.append(world.terrain.get_elevation(dir.rotated(tangent, -angle) * pr))
	heights.append(world.terrain.get_elevation(dir.rotated(axis, angle) * pr))
	heights.append(world.terrain.get_elevation(dir.rotated(axis, -angle) * pr))
	var lo: float = heights[0]
	var hi: float = heights[0]
	for h in heights:
		lo = minf(lo, h)
		hi = maxf(hi, h)
	return hi - lo <= 4.0


static func _is_near_tree(world: WorldGenerator, point: Vector3, clearance: float) -> bool:
	for entry in world.trees.values():
		var tree_pos: Vector3 = entry.get("position", Vector3.ZERO)
		if tree_pos.length() < 0.001:
			continue
		var ground := tree_pos.normalized() * world.terrain.get_surface_radius(tree_pos)
		if ground.distance_to(point) < clearance:
			return true
	return false

static func _species_to_material(species: String) -> String:
	match species:
		"pine":
			return "pine_wood"
		"birch":
			return "birch_wood"
		"bamboo":
			return "bamboo"
		_:
			return "oak_wood"
