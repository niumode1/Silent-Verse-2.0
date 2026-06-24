# ============================================================
# ReactionSystem — 化学反应注册表与评估引擎
# ============================================================
# 职责：加载 reactions.json，运行时根据输入物和条件匹配反应，
# 按反应公式计算产物。服务端权威计算，客户端仅读取结果。
# 所有反应必须满足质量守恒（输入=输出）。
# ============================================================
class_name ReactionSystem
extends Node

## 反应注册表 {reaction_id: reaction_data}
var _reactions: Dictionary = {}

## 按类型索引 {type: [reaction_data]}
var _by_type: Dictionary = {}

## 是否已加载
var is_loaded: bool = false

# ============================================================
# 加载
# ============================================================

func load_from_file(file_path: String = "res://scripts/shared/data/reactions.json") -> bool:
	if not FileAccess.file_exists(file_path):
		printerr("ReactionSystem: File not found: ", file_path)
		return false

	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		printerr("ReactionSystem: Cannot open file")
		return false

	var json = JSON.new()
	var error = json.parse(file.get_as_text())
	file.close()
	if error != OK:
		printerr("ReactionSystem: JSON parse error")
		return false

	_reactions.clear()
	_by_type.clear()

	for rxn in json.get_data()["reactions"]:
		var rxn_id = rxn["id"]
		_reactions[rxn_id] = rxn
		var rxn_type = rxn["type"]
		if not _by_type.has(rxn_type):
			_by_type[rxn_type] = []
		_by_type[rxn_type].append(rxn)

	is_loaded = true
	print("ReactionSystem: Loaded ", _reactions.size(), " reactions in ", _by_type.size(), " types")
	return true

# ============================================================
# 反应查询
# ============================================================

func get_reaction(id: String) -> Dictionary:
	return _reactions.get(id, {})

func get_by_type(type: String) -> Array:
	return _by_type.get(type, [])

func get_all_reactions() -> Array:
	var result: Array = []
	for rxn in _reactions.values():
		result.append(rxn)
	return result

# ============================================================
# 反应匹配
# ============================================================

## 查找匹配输入物的反应
## @param present_materials: [{material_id, mass_kg}] 当前存在的物质
## @param temperature: 当前温度 °C
## @param atmosphere: "oxygen" / "reducing" / "anaerobic" / "aerobic" / "any"
## @return Array[Dictionary] 匹配的反应列表，每个含 {reaction, match_quality, limiting_input}
func find_possible_reactions(present_materials: Array, temperature: float,
							  atmosphere: String = "oxygen") -> Array:
	var matches: Array = []

	for rxn in _reactions.values():
		var match_result = _check_reaction_match(rxn, present_materials, temperature, atmosphere)
		if match_result["matches"]:
			matches.append(match_result)

	return matches

func _check_reaction_match(rxn: Dictionary, present: Array, temp: float, atmosphere: String) -> Dictionary:
	var result = {"reaction": rxn, "matches": false, "match_quality": 0.0, "limiting_input": ""}

	# 温度检查
	var temp_min: float = rxn.get("temperature_min", 0.0)
	if rxn.has("temperature_max"):
		var temp_max: float = rxn["temperature_max"]
		if temp < temp_min or temp > temp_max:
			return result
	else:
		if temp < temp_min:
			return result

	# 气氛检查
	var required_atmo: String = rxn.get("atmosphere_required", "any")
	if required_atmo != "any" and required_atmo != atmosphere:
		return result

	# 输入物检查
	var inputs: Array = rxn["inputs"]
	var _total_match: float = 0.0
	var min_ratio: float = INF
	var limiting: String = ""

	for inp in inputs:
		var found = _find_in_present(inp, present)
		if not found["found"]:
			return result
		_total_match += found["match_fraction"]
		if found["match_fraction"] < min_ratio:
			min_ratio = found["match_fraction"]
			limiting = found["material_name"]

	result["matches"] = true
	result["match_quality"] = min_ratio
	result["limiting_input"] = limiting
	return result

func _find_in_present(input_spec: Dictionary, present: Array) -> Dictionary:
	# 匹配逻辑：按 material_id 或 material_category 或 reactivity_tag
	var required_id: String = input_spec.get("material", "")
	var required_category: String = input_spec.get("material_category", "")
	var required_ratio: float = input_spec.get("mass_ratio", 1.0)

	if input_spec.get("source", "") == "atmosphere":
		# 气氛来源（氧气等）总可用
		return {"found": true, "match_fraction": 1.0, "material_name": input_spec.get("material", "atmosphere")}

	for item in present:
		var mat_id: String = item.get("material_id", "")
		var mat: MaterialProperty = MaterialDB.get_material(mat_id) if MaterialDB.has_material(mat_id) else null

		if required_id != "" and mat_id == required_id:
			var available_ratio: float = item["mass_kg"] / required_ratio
			return {"found": true, "match_fraction": available_ratio, "material_name": mat_id}

		if required_category != "" and mat != null and mat.category == required_category:
			var available_ratio: float = item["mass_kg"] / required_ratio
			return {"found": true, "match_fraction": available_ratio, "material_name": mat_id}

	return {"found": false, "match_fraction": 0.0, "material_name": ""}

# ============================================================
# 反应执行（核心）
# ============================================================

## 执行一个反应
## @param reaction: 反应数据
## @param inputs: [{material_id, mass_kg}] 输入物
## @param temperature: 当前温度 °C
## @param atmosphere: 气氛类型
## @param elapsed_time_s: 反应经过时间（懒计算）
## @param oxygen_sufficient: 氧气是否充足（用于燃烧/还原）
## @return Dictionary {products, heat_released_j, mass_conservation_ok}
func evaluate_reaction(reaction: Dictionary, inputs: Array, temperature: float,
						_atmosphere: String, elapsed_time_s: float,
						oxygen_sufficient: bool = true) -> Dictionary:

	# 找到所有匹配的输入物并确定限制反应物
	var used_masses: Dictionary = {}
	var input_refs: Dictionary = {}
	var limiting_multiplier: float = INF

	for inp_spec in reaction["inputs"]:
		if inp_spec.get("source", "") == "atmosphere":
			continue
		var spec_id: String = inp_spec.get("material", inp_spec.get("material_category", ""))
		var spec_ratio: float = inp_spec["mass_ratio"]
		if spec_ratio <= 0:
			continue
		for inp in inputs:
			if inp["material_id"] == spec_id or _material_matches(inp["material_id"], inp_spec):
				var available: float = inp["mass_kg"]
				used_masses[spec_id] = available
				input_refs[spec_id] = inp
				var capacity: float = available / spec_ratio
				if capacity < limiting_multiplier:
					limiting_multiplier = capacity
				break

	if limiting_multiplier >= INF or limiting_multiplier <= 0:
		return {"products": [], "heat_released_j": 0.0, "mass_conservation_ok": true, "reaction_progress": 0.0, "total_input_mass": 0.0, "total_output_mass": 0.0}

	# 计算反应规模（受限制反应物约束）
	var total_input_mass: float = 0.0
	for inp_spec in reaction["inputs"]:
		if inp_spec.get("source", "") == "atmosphere":
			continue
		var sid: String = inp_spec.get("material", inp_spec.get("material_category", ""))
		var sr: float = inp_spec["mass_ratio"]
		if sr > 0 and used_masses.has(sid):
			total_input_mass += sr * limiting_multiplier

	# 计算反应进度（受温度和时间影响）
	var temp_optimal: float = reaction.get("temperature_optimal", reaction.get("temperature_min", 100))
	var temp_min: float = reaction.get("temperature_min", 0.0)
	var temp_factor: float = clampf((temperature - temp_min) / maxf(temp_optimal - temp_min, 1.0), 0.1, 2.0)
	var duration_per_kg: float = reaction.get("duration_per_kg_seconds", 3600.0)
	var progress: float = temp_factor * elapsed_time_s / duration_per_kg
	progress = clampf(progress, 0.0, 1.0)

	# 不完全燃烧判定
	var use_incomplete: bool = false
	if reaction.has("incomplete_combustion") and not oxygen_sufficient:
		use_incomplete = true

	# 消耗反应物
	var effective_mass: float = total_input_mass * progress
	for spec_id in input_refs:
		var inp_item: Dictionary = input_refs[spec_id]
		var spec_ratio: float = 0.0
		for inp_spec in reaction["inputs"]:
			if inp_spec.get("material", "") == spec_id or inp_spec.get("material_category", "") == spec_id:
				spec_ratio = inp_spec["mass_ratio"]
				break
		if spec_ratio > 0:
			var consumed: float = spec_ratio * limiting_multiplier * progress
			consumed = minf(consumed, inp_item["mass_kg"])
			inp_item["mass_kg"] -= consumed

	# 生成产物
	var products: Array = []
	var output_list: Array
	if use_incomplete:
		output_list = reaction["incomplete_combustion"]["outputs"]
	else:
		output_list = reaction["outputs"]

	var total_output_mass: float = 0.0
	for out in output_list:
		if out.get("phase", "solid") == "gas":
			total_output_mass += effective_mass * out["mass_ratio"]
			continue
		var product_mass: float = effective_mass * out["mass_ratio"]
		total_output_mass += product_mass
		var product_entry: Dictionary = {
			"material_id": out["material"],
			"mass_kg": product_mass,
			"phase": out.get("phase", "solid"),
			"hazardous": out.get("hazardous", false)
		}
		if out.has("purity_range"):
			var purity: float = randf_range(out["purity_range"][0], out["purity_range"][1])
			product_entry["purity"] = purity
		products.append(product_entry)

	# 热量计算
	var heat: float = 0.0
	if reaction.has("energy_output_mj_per_kg_input"):
		heat = effective_mass * reaction["energy_output_mj_per_kg_input"] * 1e6
	if reaction.get("is_exothermic", false):
		heat = effective_mass * reaction.get("exothermic_heat_kj_per_kg", 0.0) * 1000.0

	# 质量守恒验证
	var mass_ok: bool = abs(effective_mass - total_output_mass) < effective_mass * 0.01 + 0.001

	return {
		"products": products,
		"heat_released_j": heat,
		"total_input_mass": effective_mass,
		"total_output_mass": total_output_mass,
		"reaction_progress": progress,
		"mass_conservation_ok": mass_ok,
		"incomplete_combustion": use_incomplete
	}

func _material_matches(mat_id: String, spec: Dictionary) -> bool:
	if spec.get("material", "") == mat_id:
		return true
	var mat: MaterialProperty = MaterialDB.get_material(mat_id) if MaterialDB.has_material(mat_id) else null
	if mat == null:
		return false
	if spec.has("material_category") and mat.category == spec["material_category"]:
		return true
	return false

func _ready() -> void:
	load_from_file()

# ============================================================
# 反应速率工具
# ============================================================

## 计算温度对反应速率的影响（Arrhenius 简化）
func temperature_rate_factor(temperature_c: float, optimal_c: float, min_c: float) -> float:
	if temperature_c < min_c:
		return 0.0
	var ratio: float = (temperature_c - min_c) / maxf(optimal_c - min_c, 1.0)
	return clampf(ratio, 0.0, 2.0)

## 估算达到目标进度所需时间
func estimate_time_to_progress(reaction: Dictionary, temperature_c: float,
								input_mass_kg: float, target_progress: float = 1.0) -> float:
	var temp_factor: float = temperature_rate_factor(
		temperature_c,
		reaction.get("temperature_optimal", reaction.get("temperature_min", 100)),
		reaction.get("temperature_min", 0.0)
	)
	if temp_factor < 0.001:
		return INF
	var base_duration: float = reaction.get("duration_per_kg_seconds", 3600.0)
	return base_duration * input_mass_kg * target_progress / temp_factor

# ============================================================
# 质量守恒验证（测试用）
# ============================================================

static func validate_mass_conservation(inputs: Array, outputs: Array,
										tolerance: float = 0.01) -> Dictionary:
	var total_in: float = 0.0
	for inp in inputs:
		total_in += inp["mass_kg"]

	var total_out: float = 0.0
	for out in outputs:
		total_out += out["mass_kg"]

	var error_ratio: float = abs(total_in - total_out) / maxf(total_in, 0.001)
	return {
		"ok": error_ratio <= tolerance,
		"input_mass": total_in,
		"output_mass": total_out,
		"error_ratio": error_ratio
	}
