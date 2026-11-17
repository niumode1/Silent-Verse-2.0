# ============================================================
# OreVein — 地下矿脉生成器（3D 噪声，Minecraft 式随机分布）
# ============================================================
# 每种矿有自己的深度带、寄主岩性和三维噪声场：
#   - 用 FastNoiseLite 的 3D FBM 生成团块/脉状分布，而不是表面哈希；
#   - 同一位置可以同时有多个矿种；越靠近深度带边缘越稀；
#   - 寄主地质省匹配时阈值更低（铜在沉积岩、锡在花岗岩、铁在变质/火山）；
#   - 全部由世界种子决定，同种子同世界。
#
# 公开接口：
#   get_ore_deposits(position, elevation, terrain)          地表露头（旧接口）
#   get_ore_deposits_at_depth(position, depth_m, terrain)   任意深度
#   get_ore_at(position, depth_m, terrain)                  取最富的一个
# ============================================================
class_name OreVein
extends RefCounted

## 深度单位：海平面以下或地表以下的米数由调用方定义；
## 这里的深度带按「地表以下」使用，全部落在地壳内。
const ORE_DEFS := [
	{"id": "flint", "host": "any", "min_depth": 0.0,
		"max_depth": 60.0, "frequency": 0.080, "threshold": 0.72},
	{"id": "coal", "host": "sedimentary", "min_depth": 5.0,
		"max_depth": 400.0, "frequency": 0.020, "threshold": 0.68},
	{"id": "copper_ore_malachite", "host": "sedimentary", "min_depth": 20.0,
		"max_depth": 800.0, "frequency": 0.035, "threshold": 0.72},
	{"id": "iron_ore_hematite", "host": "metamorphic", "min_depth": 100.0,
		"max_depth": 1200.0, "frequency": 0.030, "threshold": 0.73},
	{"id": "iron_ore_magnetite", "host": "volcanic", "min_depth": 150.0,
		"max_depth": 1500.0, "frequency": 0.035, "threshold": 0.74},
	{"id": "tin_ore_cassiterite", "host": "granite", "min_depth": 80.0,
		"max_depth": 1000.0, "frequency": 0.045, "threshold": 0.75},
	{"id": "gold_ore", "host": "metamorphic", "min_depth": 300.0,
		"max_depth": 1700.0, "frequency": 0.050, "threshold": 0.78},
]

var _seed_value: int = 0
var _noises: Dictionary = {}


func _init(p_seed: int = 0) -> void:
	_seed_value = p_seed
	_setup_noises()


func _setup_noises() -> void:
	_noises.clear()
	for ore in ORE_DEFS:
		var ore_id := String(ore["id"])
		var noise := FastNoiseLite.new()
		noise.seed = _seed_value ^ ore_id.hash()
		noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		noise.fractal_octaves = 3
		noise.frequency = float(ore["frequency"])
		_noises[ore_id] = noise


## 旧接口：地表露头。depth 视为 0，允许任何矿以较低概率露头。
func get_ore_deposits(position: Vector3, _elevation: float,
		terrain: Terrain) -> Array:
	return get_ore_deposits_at_depth(position, 0.0, terrain, true)


## 任意深度（地表以下，m）的矿脉列表，按富集度从高到低。
func get_ore_deposits_at_depth(position: Vector3, depth_m: float,
		terrain: Terrain, surface_outcrop: bool = false) -> Array:
	var results: Array = []
	var province: Dictionary = terrain.get_province(position) if terrain else {}
	var depth: float = maxf(depth_m, 0.0)

	for ore in ORE_DEFS:
		var min_depth: float = float(ore["min_depth"])
		var max_depth: float = float(ore["max_depth"])
		if surface_outcrop and depth <= 1.0:
			# 矿体可以在地表露出，不严格按最小埋深拦截，但概率更低
			min_depth = 0.0
		if depth < min_depth or depth > max_depth:
			continue

		var threshold: float = float(ore["threshold"])
		var host: String = String(ore["host"])
		if host != "any" and not _match_host(host, province):
			threshold += 0.10  # 寄主岩性不符：仍可能出现，但稀有
		if surface_outcrop and depth <= 1.0:
			threshold += 0.06

		# 深度带边缘平滑衰减
		var edge: float = minf(50.0, maxf((max_depth - min_depth) * 0.2, 1.0))
		var window: float = smoothstep(min_depth, min_depth + edge, depth) \
			* (1.0 - smoothstep(max_depth - edge, max_depth, depth))
		threshold += (1.0 - window) * 0.15

		var value: float = _noise_value(String(ore["id"]), position)
		if value < threshold:
			continue

		var richness: float = clampf(
			(value - threshold) / maxf(1.0 - threshold, 0.001) * 1.8,
			0.1, 1.0)
		results.append({
			"ore_id": String(ore["id"]),
			"richness": richness,
			"depth_m": depth,
		})

	results.sort_custom(func(a, b): return float(a["richness"]) > float(b["richness"]))
	return results


## 取该位置最富的矿种；没有则返回空字典。
func get_ore_at(position: Vector3, depth_m: float,
		terrain: Terrain) -> Dictionary:
	var deposits := get_ore_deposits_at_depth(position, depth_m, terrain)
	return deposits[0] if not deposits.is_empty() else {}


## 每种矿的定义（深度带/寄主/频率），供测试与工具使用。
func get_ore_definitions() -> Array:
	return ORE_DEFS.duplicate(true)


func reseed(new_seed: int) -> void:
	_seed_value = new_seed
	_setup_noises()


# ============================================================
# 内部
# ============================================================

func _noise_value(ore_id: String, position: Vector3) -> float:
	var noise: FastNoiseLite = _noises.get(ore_id, null)
	if noise == null:
		return 0.0
	var v: float = noise.get_noise_3d(position.x, position.y, position.z)
	return clampf((v + 1.0) * 0.5, 0.0, 1.0)


func _match_host(host: String, province: Dictionary) -> bool:
	var flags: int = int(province.get("flags", 0))
	match host:
		"sedimentary":
			return (flags & Terrain.PROV_SEDIMENTARY) != 0
		"volcanic":
			return (flags & Terrain.PROV_VOLCANIC) != 0
		"metamorphic":
			return (flags & Terrain.PROV_METAMORPHIC) != 0
		"granite":
			return (flags & Terrain.PROV_GRANITE) != 0
	return false
