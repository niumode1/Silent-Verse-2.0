# ============================================================
# MatterField — 世界的物质场查询
# ============================================================
# 地面不是一个整体，也不是一张网格；每个位置、每个深度都是一种
# 物质组成 + 状态：
#   composition: [{material_id, fraction}]   物质组成（总和 = 1）
#   state:       含水率 / 压实度 / 温度 / 压力 / 密度 / 抗剪强度 / 休止角
#
# 组成来源：
#   0–3 m   表土/黏土/砂/砾石（Terrain.get_subsurface_composition）
#   更深    地壳基岩（PlanetInterior）
#   矿脉    OreVein 的 3D 噪声查询，按富集度混入
#
# 这个类不存任何格子、不存道具，只是纯查询；同种子同位置 → 同结果。
# ============================================================
class_name MatterField
extends RefCounted

var world: WorldGenerator = null
var terrain: Terrain = null
var interior: PlanetInterior = null
var ore_gen: OreVein = null

var _moisture_noise: FastNoiseLite = null

## 玩家造成的稀疏增量（堆积）；为 null 时只看基底。
var delta: MatterDelta = null


func _init(p_world: WorldGenerator) -> void:
	world = p_world
	if world == null:
		return
	terrain = world.terrain
	interior = world.interior
	ore_gen = world.ore_gen
	_moisture_noise = FastNoiseLite.new()
	_moisture_noise.seed = world.get_seed() ^ 0x51ED
	_moisture_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_moisture_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_moisture_noise.fractal_octaves = 2
	_moisture_noise.frequency = 0.02


## 位置处的地表半径（含堆积增量）。
func get_surface_radius_at(position: Vector3) -> float:
	if terrain == null:
		return 0.0
	var radius: float = terrain.get_surface_radius(position)
	if delta != null:
		radius += delta.get_surface_offset(position)
	return radius


## 位置处离地表的深度（m）。地表以上返回 0。
func get_depth_at(position: Vector3) -> float:
	if terrain == null:
		return 0.0
	return maxf(get_surface_radius_at(position) - position.length(), 0.0)


func set_delta(new_delta: MatterDelta) -> void:
	delta = new_delta


## 采样一个位置：组成 + 状态。depth_m 由调用方给出（见 get_depth_at）。
func sample(position: Vector3, depth_m: float) -> Dictionary:
	var composition := _sample_composition(position, depth_m)
	if delta != null:
		var deposit_mass := delta.get_mass_near(position, 0.5)
		if deposit_mass > 0.0:
			var deposited := delta.get_composition_near(position, 0.5)
			if not deposited.is_empty():
				# 以 0.125 m³ 的参考格子质量做权重：少量堆积只轻微改变
				# 组成，大量堆积（倒了一堆土）会主导。
				var reference_mass := get_density(composition) * 0.125
				var weight := clampf(deposit_mass
					/ maxf(deposit_mass + reference_mass, 1.0e-9), 0.0, 0.95)
				composition = _blend_compositions(composition, deposited, weight)
	var state := _sample_state(position, depth_m, composition)
	return {
		"composition": composition,
		"state": state,
		"density": float(state["density"]),
		"depth_m": depth_m,
	}


# ============================================================
# 组成
# ============================================================

func _sample_composition(position: Vector3, depth_m: float) -> Array:
	var comp: Array = []
	if depth_m <= 3.0 and terrain != null:
		comp = terrain.get_subsurface_composition(position, depth_m)
	elif interior != null:
		comp = interior.get_composition(position)
	else:
		comp = [{"material_id": "granite", "fraction": 1.0}]

	# 矿脉：一个格子里如果有矿，按富集度混入一部分矿石
	if ore_gen != null and terrain != null:
		var ore := ore_gen.get_ore_at(position, depth_m, terrain)
		if not ore.is_empty():
			var richness: float = clampf(float(ore.get("richness", 0.2)), 0.0, 1.0)
			var ore_fraction: float = clampf(0.08 + 0.30 * richness, 0.05, 0.40)
			for entry in comp:
				entry["fraction"] = float(entry["fraction"]) * (1.0 - ore_fraction)
			comp.append({"material_id": String(ore["ore_id"]),
				"fraction": ore_fraction})

	return _normalize(comp)


func _blend_compositions(base: Array, added: Array, weight: float) -> Array:
	var mix: Dictionary = {}
	for entry in base:
		var id := String(entry["material_id"])
		mix[id] = float(mix.get(id, 0.0)) \
			+ float(entry["fraction"]) * (1.0 - weight)
	for entry in added:
		var id := String(entry["material_id"])
		mix[id] = float(mix.get(id, 0.0)) \
			+ float(entry["fraction"]) * weight
	var out: Array = []
	for id in mix:
		var f := float(mix[id])
		if f > 0.0:
			out.append({"material_id": String(id), "fraction": f})
	return _normalize(out)


func _normalize(comp: Array) -> Array:
	var total: float = 0.0
	for entry in comp:
		total += maxf(float(entry.get("fraction", 0.0)), 0.0)
	if total <= 0.0:
		return [{"material_id": "granite", "fraction": 1.0}]
	var out: Array = []
	for entry in comp:
		var f: float = maxf(float(entry.get("fraction", 0.0)), 0.0) / total
		if f > 0.0:
			out.append({"material_id": String(entry["material_id"]),
				"fraction": f})
	out.sort_custom(func(a, b): return float(a["fraction"]) > float(b["fraction"]))
	return out


## 由物质场状态推导 DEM 参数，供 C++ 粒子内核使用。
## 这不是另一套物理，只是把含水率/压实度/抗剪强度折算成粒子模型
## 需要的等效参数（凝聚力是抗剪强度的一部分，不能直接全塞进接触）。
func get_dem_parameters(position: Vector3, depth_m: float) -> Dictionary:
	var sample := sample(position, depth_m)
	var state: Dictionary = sample["state"]
	var moisture: float = float(state["moisture"])
	var compaction: float = float(state["compaction"])
	var shear: float = float(state["shear_strength_pa"])

	return {
		"density": float(state["density"]),
		"cohesion_pa": clampf(shear * 0.05, 0.0, 5000.0),
		"friction": clampf(0.35 + 0.45 * compaction, 0.25, 0.90),
		"stiffness": 2000.0 + 9000.0 * compaction,
		"damping": 0.25,
		"rolling_resistance": 0.02 + 0.03 * moisture,
		"moisture": moisture,
		"compaction": compaction,
		"angle_of_repose_deg": float(state["angle_of_repose_deg"]),
	}


func get_density(composition: Array) -> float:
	var density: float = 0.0
	for entry in composition:
		var mat := MaterialDB.get_material(String(entry["material_id"]))
		if mat != null:
			density += float(entry["fraction"]) * mat.density
	return maxf(density, 1.0)


# ============================================================
# 状态
# ============================================================

func _sample_state(position: Vector3, depth_m: float,
		composition: Array) -> Dictionary:
	var moisture: float = 0.0
	if _moisture_noise != null:
		var n: float = _moisture_noise.get_noise_3d(
			position.x, position.y, position.z)
		var v: float = clampf((n + 1.0) * 0.5, 0.0, 1.0)
		moisture = clampf(0.15 + 0.65 * v - 0.00005 * depth_m, 0.05, 0.95)

	var compaction: float = clampf(0.15 + 0.0004 * depth_m, 0.15, 0.95)
	var temperature: float = 15.0
	var pressure: float = 0.0
	if interior != null:
		temperature = interior.get_temperature_at_radius(position.length())
		pressure = interior.get_pressure_at_radius(position.length())

	var density := get_density(composition)

	# 有效抗剪强度：材料本身强度 × 压实度 × 含水率修正。
	# 黏土含水会先变黏（强度升）后饱和（强度降）；砂/砾石遇水强度降。
	var clay_fraction: float = 0.0
	var strength_pa: float = 0.0
	var repose: float = 0.0
	for entry in composition:
		var mat := MaterialDB.get_material(String(entry["material_id"]))
		if mat == null:
			continue
		var f: float = float(entry["fraction"])
		if String(entry["material_id"]) == "clay":
			clay_fraction += f
		strength_pa += f * mat.shear_strength * 1.0e6
		repose += f * mat.angle_of_repose

	var moisture_factor: float = 1.0 - 0.6 * moisture
	if clay_fraction > 0.05:
		moisture_factor = 1.0 + 0.6 * moisture - 1.6 * maxf(moisture - 0.65, 0.0)
	moisture_factor = clampf(moisture_factor, 0.15, 1.4)
	var compaction_factor: float = 0.45 + 0.9 * compaction
	strength_pa *= moisture_factor * compaction_factor

	# 湿砂休止角略高，饱和后降低
	var repose_deg: float = clampf(repose, 5.0, 60.0)
	repose_deg += 8.0 * moisture
	if moisture > 0.75:
		repose_deg -= 18.0 * (moisture - 0.75)
	repose_deg = clampf(repose_deg, 5.0, 60.0)

	return {
		"moisture": moisture,
		"compaction": compaction,
		"temperature_c": temperature,
		"pressure_pa": pressure,
		"density": density,
		"shear_strength_pa": maxf(strength_pa, 1.0),
		"angle_of_repose_deg": repose_deg,
	}
