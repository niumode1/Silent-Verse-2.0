# ============================================================
# PlanetInterior — 行星内部结构（地壳 / 地幔 / 外核 / 内核）
# ============================================================
# 分层顺序与物质组成按地球内部结构：
#   地壳（按地质省的岩石）→ 地幔（橄榄岩+玄武岩）→
#   外核（熔融铁镍）→ 内核（固态铁镍）。
#
# 厚度比例不能照搬地球：本项目星球半径只有 ~4 km，而地形起伏有 ~1 km，
# 若按地球 0.55% 的地壳比例，地壳只有 22 m，连山都装不下。因此把地壳
# 加厚到 45% R，保证地形和全部矿脉都在地壳内；层序和成分保持现实。
#
# 深度按「海平面以下」计算；地表以上的地形属于地壳。
# 温度/压力是随深度连续变化的近似剖面，供采矿、热学与测量使用。
# ============================================================
class_name PlanetInterior
extends RefCounted

const CRUST_FRACTION := 0.45
const MANTLE_FRACTION := 0.35
const OUTER_CORE_FRACTION := 0.12

const CRUST_DENSITY := 2700.0
const MANTLE_DENSITY := 3300.0
const OUTER_CORE_DENSITY := 7000.0
const INNER_CORE_DENSITY := 8000.0

var planet_radius: float = 3978.87
var terrain: Terrain = null

var _crust_bottom_r: float = 0.0
var _mantle_bottom_r: float = 0.0
var _outer_core_bottom_r: float = 0.0


func _init(p_radius: float = 3978.87, p_terrain: Terrain = null) -> void:
	planet_radius = p_radius
	terrain = p_terrain
	_recompute()

func _recompute() -> void:
	_crust_bottom_r = planet_radius * (1.0 - CRUST_FRACTION)
	_mantle_bottom_r = planet_radius \
		* (1.0 - CRUST_FRACTION - MANTLE_FRACTION)
	_outer_core_bottom_r = planet_radius \
		* (1.0 - CRUST_FRACTION - MANTLE_FRACTION - OUTER_CORE_FRACTION)

func reseed_radius(new_radius: float) -> void:
	planet_radius = new_radius
	_recompute()


## 半径 r 处属于哪一层。
func get_layer_at_radius(r: float) -> String:
	if r >= _crust_bottom_r:
		return "crust"
	if r >= _mantle_bottom_r:
		return "mantle"
	if r >= _outer_core_bottom_r:
		return "outer_core"
	return "inner_core"


## 各层边界（海平面以下深度，m）与半径，供调试/UI/测试使用。
func get_layer_boundaries() -> Dictionary:
	return {
		"surface_r": planet_radius,
		"crust_bottom_r": _crust_bottom_r,
		"mantle_bottom_r": _mantle_bottom_r,
		"outer_core_bottom_r": _outer_core_bottom_r,
		"crust_thickness_m": planet_radius - _crust_bottom_r,
		"mantle_thickness_m": _crust_bottom_r - _mantle_bottom_r,
		"outer_core_thickness_m": _mantle_bottom_r - _outer_core_bottom_r,
		"inner_core_radius_m": _outer_core_bottom_r,
	}


## 位置处的物质组成（体积分数，总和 = 1）。
func get_composition(position: Vector3) -> Array:
	var layer := get_layer_at_radius(position.length())
	var mix: Dictionary = {}

	match layer:
		"crust":
			var bedrock := _crust_bedrock(position)
			_add(mix, String(bedrock[0]), 0.60)
			_add(mix, String(bedrock[1]), 0.25)
			_add(mix, "gravel", 0.15)
		"mantle":
			_add(mix, "peridotite", 0.85)
			_add(mix, "basalt", 0.15)
		"outer_core":
			_add(mix, "molten_iron", 0.92)
			_add(mix, "iron_nickel", 0.08)
		"inner_core":
			_add(mix, "iron_nickel", 0.90)
			_add(mix, "pure_iron", 0.10)

	var total: float = 0.0
	for id in mix:
		total += float(mix[id])
	var out: Array = []
	if total <= 0.0:
		return out
	for id in mix:
		out.append({"material_id": String(id),
			"fraction": float(mix[id]) / total})
	out.sort_custom(func(a, b): return float(a["fraction"]) > float(b["fraction"]))
	return out


## 位置处的完整内部状态。
func get_state_at(position: Vector3) -> Dictionary:
	var r: float = maxf(position.length(), 0.001)
	var layer := get_layer_at_radius(r)
	var depth: float = maxf(planet_radius - r, 0.0)
	return {
		"layer": layer,
		"depth_m": depth,
		"composition": get_composition(position),
		"temperature_c": get_temperature_at_radius(r),
		"pressure_pa": get_pressure_at_radius(r),
	}


## 按地球地温曲线的分层近似。
func get_temperature_at_radius(r: float) -> float:
	if r >= _crust_bottom_r:
		var f: float = clampf((planet_radius - r)
			/ maxf(planet_radius - _crust_bottom_r, 0.001), 0.0, 1.0)
		return lerpf(15.0, 550.0, f)
	if r >= _mantle_bottom_r:
		var f: float = clampf((_crust_bottom_r - r)
			/ maxf(_crust_bottom_r - _mantle_bottom_r, 0.001), 0.0, 1.0)
		return lerpf(550.0, 3000.0, f)
	if r >= _outer_core_bottom_r:
		var f: float = clampf((_mantle_bottom_r - r)
			/ maxf(_mantle_bottom_r - _outer_core_bottom_r, 0.001), 0.0, 1.0)
		return lerpf(3000.0, 5000.0, f)
	var f: float = clampf((_outer_core_bottom_r - r)
		/ maxf(_outer_core_bottom_r, 0.001), 0.0, 1.0)
	return lerpf(5000.0, 5500.0, f)


## 静水压近似：P = ∫ρ·g(r)dr，g(r)=g0·r/R（均匀球体）。
func get_pressure_at_radius(r: float) -> float:
	r = clampf(r, 0.0, planet_radius)
	var g0: float = PhysicsConstants.g0
	var coeff: float = g0 / (2.0 * planet_radius)
	var pressure: float = 0.0

	# 地壳：从海平面到 min(r, 地壳底)
	var crust_lo: float = maxf(r, _crust_bottom_r)
	pressure += CRUST_DENSITY * coeff \
		* (planet_radius * planet_radius - crust_lo * crust_lo)
	if r < _crust_bottom_r:
		var mantle_lo: float = maxf(r, _mantle_bottom_r)
		pressure += MANTLE_DENSITY * coeff \
			* (_crust_bottom_r * _crust_bottom_r - mantle_lo * mantle_lo)
	if r < _mantle_bottom_r:
		var core_lo: float = maxf(r, _outer_core_bottom_r)
		pressure += OUTER_CORE_DENSITY * coeff \
			* (_mantle_bottom_r * _mantle_bottom_r - core_lo * core_lo)
	if r < _outer_core_bottom_r:
		pressure += INNER_CORE_DENSITY * coeff \
			* (_outer_core_bottom_r * _outer_core_bottom_r - r * r)
	return pressure


func _crust_bedrock(position: Vector3) -> Array:
	if terrain == null:
		return ["granite", "flint"]
	var flags: int = int(terrain.get_province(position).get("flags", 0))
	if flags & Terrain.PROV_GRANITE:
		return ["granite", "flint"]
	if flags & Terrain.PROV_METAMORPHIC:
		return ["slate", "flint"]
	if flags & Terrain.PROV_VOLCANIC:
		return ["basalt", "obsidian"]
	if flags & Terrain.PROV_SEDIMENTARY:
		return ["limestone", "sandstone"]
	if flags & Terrain.PROV_COASTAL:
		return ["sandstone", "gravel"]
	return ["sandstone", "limestone"]


func _add(mix: Dictionary, id: String, amount: float) -> void:
	if amount <= 0.0:
		return
	mix[id] = float(mix.get(id, 0.0)) + amount
