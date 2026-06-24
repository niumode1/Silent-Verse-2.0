# ============================================================
# Furnace — 冶炼炉状态机
# ============================================================
# 玩家建炉→装料→点火→鼓风→冶炼→出铁。
# 全部由热学+化学公式驱动，温度和时间是唯一变量。
# ============================================================
class_name Furnace
extends RefCounted

## 炉体材料
var wall_material: String = "brick"

## 炉壁厚度 m
var wall_thickness: float = 0.1

## 炉内容积 m³
var internal_volume: float = 0.5

## 炉内表面积 m²
var internal_surface_area: float = 3.0

## 炉内温度 °C（当前）
var temperature: float = 20.0

## 炉内物质 [{material_id, mass_kg, phase, purity}]
var contents: Array = []

## 炉内气氛 "oxygen"/"reducing"/"neutral"
var atmosphere: String = "oxygen"

## 是否在燃烧
var is_burning: bool = false

## 燃料燃耗速率 kg/s
var fuel_burn_rate: float = 0.0

## 鼓风倍率（1.0=自然通风, 2.0=强力鼓风）
var bellows_multiplier: float = 1.0

## 外部环境温度 °C
var ambient_temperature: float = 20.0

## 累计冶炼时间 s
var elapsed_time: float = 0.0

## 炉内剩余氧气 kg（逐步消耗）
var remaining_oxygen: float = 0.0

# ============================================================
# 建造与装载
# ============================================================

## 建炉验证：检查是否有足够的耐火材料
static func can_build(wall_mat: MaterialProperty, thickness: float) -> bool:
	if wall_mat.melting_point < 1300:
		return false  # 熔点不够，炉子自己会熔化
	if wall_mat.thermal_conductivity > 2.0:
		return false  # 导热太快，保温差
	return true

## 装料（同材料自动合并）
func add_material(material_id: String, mass_kg: float) -> void:
	for item in contents:
		if item["material_id"] == material_id and item.get("phase", "solid") == "solid":
			item["mass_kg"] += mass_kg
			return
	contents.append({
		"material_id": material_id,
		"mass_kg": mass_kg,
		"phase": "solid"
	})

# ============================================================
# 热学模拟
# ============================================================

## 每 tick（1秒）更新炉温和反应
func tick(delta: float = 1.0) -> Dictionary:
	elapsed_time += delta
	var result := {"heat_change": 0.0, "reactions": [], "temperature": temperature}

	# 1. 燃料燃烧产热
	var heat_input: float = 0.0
	if is_burning:
		heat_input = _burn_fuel(delta)

	# 2. 热流失（通过炉壁传导，带隔热因子）
	var wall_mat: MaterialProperty = MaterialDB.get_material(wall_material)
	var heat_loss: float = 0.0
	if wall_mat:
		# 砖炉保温好，有效散热面积仅 15%
		var effective_area: float = internal_surface_area * 0.35
		heat_loss = PhysicsCalc.heat_conduction_rate(
			wall_mat.thermal_conductivity,
			effective_area,
			temperature,
			ambient_temperature,
			wall_thickness
		) * delta

	# 3. 净热量→温度变化
	var total_heat_capacity: float = _get_total_heat_capacity()
	if total_heat_capacity > 0:
		var net_heat: float = heat_input - heat_loss
		var temp_change: float = PhysicsCalc.temperature_change(net_heat, 1.0, total_heat_capacity)
		temperature += temp_change

	result["heat_change"] = heat_input - heat_loss

	# 4. 化学反应（达到温度条件时）
	if temperature > 100:
		var atmosphere_type: String = atmosphere
		var rxns: Array = ReactionRegistry.find_possible_reactions(contents, temperature, atmosphere_type)
		for match_data in rxns:
			var oxy_sufficient: bool = (atmosphere == "oxygen")
			var rxn_result: Dictionary = ReactionRegistry.evaluate_reaction(
				match_data["reaction"], contents, temperature, atmosphere, delta, oxy_sufficient
			)
			if rxn_result["reaction_progress"] > 0:
				result["reactions"].append(rxn_result)
				_update_contents(rxn_result)

	result["temperature"] = temperature
	return result

## 燃烧燃料
func _burn_fuel(delta: float) -> float:
	var total_heat: float = 0.0

	# 鼓风补充氧气（但还原气氛不补氧）
	# Bellows blast fresh air (always, even in reducing mode — blast furnace principle)
	if bellows_multiplier > 1.0:
		remaining_oxygen += internal_volume * 0.21 * PhysicsConstants.rho_air_0 * 0.1 * bellows_multiplier * delta
		remaining_oxygen = minf(remaining_oxygen, internal_volume * 0.21 * PhysicsConstants.rho_air_0)

	for i in range(contents.size() - 1, -1, -1):
		var item: Dictionary = contents[i]
		var mat: MaterialProperty = MaterialDB.get_material(item["material_id"])
		if not mat or mat.combustibility <= 0:
			continue

		# 燃烧速率受氧气和鼓风影响
		var burn_mass: float = minf(item["mass_kg"], fuel_burn_rate * delta * bellows_multiplier)
		var o2_needed: float = burn_mass * 1.5  # ~1.5x 氧气

		if o2_needed > remaining_oxygen:
			burn_mass *= maxf(remaining_oxygen, 0.0001) / maxf(o2_needed, 0.0001)
			# 氧气不足 → 还原气氛（CO 主导，用于冶炼）
			atmosphere = "reducing"

		remaining_oxygen -= minf(o2_needed, remaining_oxygen)
		if remaining_oxygen < 0:
			remaining_oxygen = 0.0

		if burn_mass <= 0:
			continue

		item["mass_kg"] -= burn_mass
		if item["mass_kg"] <= 0.01:
			contents.remove_at(i)

		# 产热
		total_heat += PhysicsCalc.combustion_heat(burn_mass, mat.heat_value, 0.9 * bellows_multiplier)

		# 生成灰烬（合并到已有灰烬）
		var ash_mass: float = burn_mass * 0.02
		if ash_mass > 0.001:
			var ash_merged := false
			for ci in contents:
				if ci["material_id"] == "wood_ash" and ci.get("phase", "solid") == "solid":
					ci["mass_kg"] += ash_mass
					ash_merged = true
					break
			if not ash_merged:
				contents.append({"material_id": "wood_ash", "mass_kg": ash_mass, "phase": "solid"})

		break  # 每 tick 只烧一种燃料

	# 高温木炭产生 CO → 还原气氛（鼓风提供O₂燃烧产生CO，CO还原矿石）
	if total_heat > 0 and temperature > 800.0:
		atmosphere = "reducing"
	elif atmosphere == "reducing" and temperature < 600.0:
		atmosphere = "oxygen"  # 温度太低，还原气氛失效

	return total_heat

## 更新炉内物（反应后，合并同材料）
func _update_contents(rxn_result: Dictionary) -> void:
	for product in rxn_result["products"]:
		if product.get("phase", "solid") == "gas":
			continue
		# 合并到已有相同材料
		var merged_prod := false
		for item in contents:
			if item["material_id"] == product["material_id"] and item.get("phase", "solid") == product.get("phase", "solid"):
				item["mass_kg"] += product["mass_kg"]
				merged_prod = true
				break
		if not merged_prod:
			contents.append({
				"material_id": product["material_id"],
				"mass_kg": product["mass_kg"],
				"phase": product.get("phase", "solid"),
				"purity": product.get("purity", 1.0)
			})

## 获取总热容
func _get_total_heat_capacity() -> float:
	var total: float = 0.0
	for item in contents:
		var mat: MaterialProperty = MaterialDB.get_material(item["material_id"])
		if mat:
			total += item["mass_kg"] * mat.specific_heat
	return maxf(total, 100.0)

# ============================================================
# 操作
# ============================================================

## 点火
func ignite() -> void:
	is_burning = true
	fuel_burn_rate = 0.0002  # kg/s，慢速持续燃烧
	remaining_oxygen = internal_volume * 0.21 * PhysicsConstants.rho_air_0

## 熄火
func extinguish() -> void:
	is_burning = false

## 鼓风
func set_bellows(level: float) -> void:
	bellows_multiplier = clampf(level, 0.5, 3.0)
	if bellows_multiplier > 1.5:
		atmosphere = "oxygen"

## 出渣（排除炉渣）
func tap_slag() -> Array:
	var slag: Array = []
	for i in range(contents.size() - 1, -1, -1):
		if contents[i].get("material_id", "") == "slag":
			slag.append(contents[i])
			contents.remove_at(i)
	return slag

## 出铁（收集金属）
func tap_metal(metal_id: String = "pure_iron") -> Array:
	var metal: Array = []
	for i in range(contents.size() - 1, -1, -1):
		if contents[i].get("material_id", "") == metal_id:
			metal.append(contents[i])
			contents.remove_at(i)
	return metal

## 获取炉内物质概览（按材料聚合）
func get_contents_summary() -> Array:
	var aggregated: Dictionary = {}
	for item in contents:
		var key: String = item["material_id"] + "_" + item.get("phase", "solid")
		if not aggregated.has(key):
			aggregated[key] = {"material_id": item["material_id"], "mass_kg": 0.0, "phase": item.get("phase", "solid")}
		aggregated[key]["mass_kg"] += item["mass_kg"]
	var summary: Array = []
	for key in aggregated:
		var a: Dictionary = aggregated[key]
		if a["mass_kg"] > 0.001:
			summary.append(a["material_id"] + ": " + str(snapped(a["mass_kg"], 0.001)) + "kg")
	return summary
