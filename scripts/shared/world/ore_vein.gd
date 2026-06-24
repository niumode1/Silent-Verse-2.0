# ============================================================
# OreVein — 矿脉生成器
# ============================================================
# 按地质规则在球形行星表面分布矿脉。
# 铜在沉积岩区域，铁在火山/变质岩区域，锡与花岗岩伴生，
# 金银稀有，深层分布。
# ============================================================
class_name OreVein
extends RefCounted

## 矿脉定义: {ore_material_id, min_depth, max_depth, density, host_rock_category}
var _ore_types: Array = []

var _seed_value: int = 0

func _init(p_seed: int = 0) -> void:
	_seed_value = p_seed
	_setup_ore_types()

func _setup_ore_types() -> void:
	_ore_types = [
		# 地表常见矿石
		{"id": "flint",          "min_h": -10, "max_h": 200,  "density": 0.15, "host": "any"},
		{"id": "limestone",      "min_h": -50, "max_h": 500,  "density": 0.30, "host": "sedimentary"},
		{"id": "sandstone",      "min_h": -30, "max_h": 400,  "density": 0.30, "host": "sedimentary"},
		{"id": "clay",           "min_h": -10, "max_h": 200,  "density": 0.20, "host": "any"},

		# 铜矿 — 沉积岩区
		{"id": "copper_ore_malachite", "min_h": -100,"max_h": 300, "density": 0.08, "host": "sedimentary"},

		# 铁矿 — 火山/深层
		{"id": "iron_ore_hematite",  "min_h": -300, "max_h": 600, "density": 0.10, "host": "volcanic"},
		{"id": "iron_ore_magnetite", "min_h": -500, "max_h": 400, "density": 0.06, "host": "volcanic"},

		# 锡矿 — 花岗岩伴生
		{"id": "tin_ore_cassiterite","min_h": -200, "max_h": 500, "density": 0.05, "host": "granite"},

		# 贵金属 — 稀有，深层
		{"id": "gold_ore",           "min_h": -800, "max_h": 200, "density": 0.01, "host": "volcanic"},

		# 煤炭 — 沉积岩
		{"id": "coal",               "min_h": -400, "max_h": 300, "density": 0.12, "host": "sedimentary"},
	]

## 判断某位置是否生成矿脉
## @param position: 世界坐标
## @param elevation: 该点海拔 m
## @param terrain: Terrain 实例
## @return Array[Dictionary] 该位置的矿脉列表 [{ore_id, richness}]
func get_ore_deposits(position: Vector3, elevation: float, _terrain: Terrain) -> Array:
	var results: Array = []
	var n3d: Vector3 = position.normalized()

	for ore in _ore_types:
		# 深度检查
		if elevation < ore["min_h"] or elevation > ore["max_h"]:
			continue

		# 用种子+位置生成确定性的存在判定
		var ore_seed: float = _hash_position(position, ore["id"])
		if ore_seed > ore["density"]:
			continue

		# 寄主岩石匹配
		var host: String = ore["host"]
		if host != "any":
			if not _match_host_rock(host, elevation, n3d):
				continue

		# 富集度 0-1
		var richness: float = (ore["density"] - ore_seed) / ore["density"]
		richness = clampf(richness * 2.0, 0.1, 1.0)

		results.append({"ore_id": ore["id"], "richness": richness, "elevation": elevation})

	return results

## 宿主岩石匹配
func _match_host_rock(host: String, elevation: float, _n3d: Vector3) -> bool:
	match host:
		"sedimentary":
			# 沉积岩在中低海拔
			return elevation > -400 and elevation < 400
		"volcanic":
			# 火山岩在中高海拔或深层
			return elevation > 300 or elevation < -300
		"granite":
			# 花岗岩在高海拔
			return elevation > 200
	return false

## 确定性哈希（同位置同种子 → 同结果）
func _hash_position(pos: Vector3, ore_id: String) -> float:
	var h: float = sin(pos.x * 127.1 + pos.y * 311.7 + pos.z * 74.7 + _seed_value * 31.3 + ore_id.hash() * 0.001)
	h = h - floor(h)
	return h

func reseed(new_seed: int) -> void:
	_seed_value = new_seed
