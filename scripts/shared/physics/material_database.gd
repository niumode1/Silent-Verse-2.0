# ============================================================
# MaterialDB — 材料数据库单例
# ============================================================
# 职责：从 materials.json 加载所有材料数据，
# 提供按 ID / 类别 / 反应标签查询的接口。
# 服务端启动时加载，运行时只读。客户端加载用于预测渲染。
# ============================================================
extends Node

## 全部材料字典 {material_id: MaterialProperty}
var _materials: Dictionary = {}

## 按类别索引 {category: Array[MaterialProperty]}
var _by_category: Dictionary = {}

## 按反应标签索引 {tag: Array[MaterialProperty]}
var _by_reactivity_tag: Dictionary = {}

## 是否已加载
var is_loaded: bool = false

# ============================================================
# 加载
# ============================================================

## 从 JSON 文件加载材料数据库
## @param file_path: materials.json 的路径，默认 "res://scripts/shared/data/materials.json"
func load_from_file(file_path: String = "res://scripts/shared/data/materials.json") -> bool:
	if not FileAccess.file_exists(file_path):
		printerr("MaterialDB: File not found: ", file_path)
		return false

	var file = FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		printerr("MaterialDB: Cannot open file: ", file_path)
		return false

	var json_text = file.get_as_text()
	file.close()

	var json = JSON.new()
	var error = json.parse(json_text)
	if error != OK:
		printerr("MaterialDB: JSON parse error: ", json.get_error_message())
		return false

	var data = json.get_data()
	if not data.has("materials"):
		printerr("MaterialDB: Missing 'materials' key in JSON")
		return false

	_materials.clear()
	_by_category.clear()
	_by_reactivity_tag.clear()

	for mat_data in data["materials"]:
		var mat = MaterialProperty.new()
		_populate_from_dict(mat, mat_data)

		var validation = mat.validate()
		if not validation["valid"]:
			printerr("MaterialDB: Validation failed for ", mat.material_id, ": ", validation["errors"])
			continue

		_materials[mat.material_id] = mat

		# 按类别索引
		if not _by_category.has(mat.category):
			_by_category[mat.category] = []
		_by_category[mat.category].append(mat)

		# 按反应标签索引
		for tag in mat.reactivity_tags:
			if not _by_reactivity_tag.has(tag):
				_by_reactivity_tag[tag] = []
			_by_reactivity_tag[tag].append(mat)

	is_loaded = true
	print("MaterialDB: Loaded ", _materials.size(), " materials in ", _by_category.size(), " categories")
	return true

## 从字典填充 MaterialProperty 实例
func _populate_from_dict(mat: MaterialProperty, data: Dictionary) -> void:
	mat.material_id = data.get("material_id", "")
	mat.display_name = data.get("display_name", "")
	mat.phase = data.get("phase", "solid")
	mat.category = data.get("category", "")

	# 力学
	mat.density = data.get("density", 1000.0)
	mat.hardness_mohs = data.get("hardness_mohs", 1.0)
	mat.hardness_vickers = data.get("hardness_vickers", 10.0)
	mat.yield_strength = data.get("yield_strength", 10.0)
	mat.tensile_strength = data.get("tensile_strength", 10.0)
	mat.compressive_strength = data.get("compressive_strength", 10.0)
	mat.shear_strength = data.get("shear_strength", 5.0)
	mat.youngs_modulus = data.get("youngs_modulus", 1.0)
	mat.shear_modulus = data.get("shear_modulus", 0.4)
	mat.bulk_modulus = data.get("bulk_modulus", 1.0)
	mat.poisson_ratio = data.get("poisson_ratio", 0.3)
	mat.fracture_toughness = data.get("fracture_toughness", 1.0)
	mat.fatigue_limit = data.get("fatigue_limit", 1.0)
	mat.static_friction = data.get("static_friction", 0.6)
	mat.kinetic_friction = data.get("kinetic_friction", 0.4)
	mat.rolling_resistance = data.get("rolling_resistance", 0.05)
	mat.restitution = data.get("restitution", 0.3)
	mat.damping_coefficient = data.get("damping_coefficient", 0.1)
	mat.abrasion_resistance = data.get("abrasion_resistance", 0.5)

	# 热学
	mat.melting_point = data.get("melting_point", 1500.0)
	mat.boiling_point = data.get("boiling_point", 3000.0)
	mat.specific_heat = data.get("specific_heat", 1000.0)
	mat.thermal_conductivity = data.get("thermal_conductivity", 1.0)
	mat.thermal_expansion = data.get("thermal_expansion", 10.0)
	mat.heat_of_fusion = data.get("heat_of_fusion", 200.0)
	mat.heat_of_vaporization = data.get("heat_of_vaporization", 2000.0)
	mat.flash_point = data.get("flash_point", 300.0)
	mat.emissivity = data.get("emissivity", 0.8)
	mat.forging_temperature = data.get("forging_temperature", 800.0)
	mat.max_hardness_mohs = data.get("max_hardness_mohs", 7.0)
	mat.min_toughness = data.get("min_toughness", 0.5)

	# 化学
	mat.combustibility = data.get("combustibility", 0.0)
	mat.heat_value = data.get("heat_value", 0.0)
	var raw_tags = data.get("reactivity_tags", [])
	mat.reactivity_tags.clear()
	for tag in raw_tags:
		mat.reactivity_tags.append(str(tag))
	mat.solubility_water = data.get("solubility_water", 0.0)
	mat.toxicity = data.get("toxicity", 0.0)
	mat.acidity_ph = data.get("acidity_ph", 7.0)
	mat.oxidation_resistance = data.get("oxidation_resistance", 0.5)
	mat.corrosiveness = data.get("corrosiveness", 0.0)

	# 流体
	mat.viscosity = data.get("viscosity", 0.0)
	mat.surface_tension = data.get("surface_tension", 0.0)
	mat.angle_of_repose = data.get("angle_of_repose", 30.0)
	mat.capillary_rise = data.get("capillary_rise", 0.0)

	# 声学
	mat.sound_speed = data.get("sound_speed", 340.0)
	mat.sound_absorption = data.get("sound_absorption", 0.1)

	# 光学
	mat.opacity = data.get("opacity", 1.0)
	mat.reflectivity = data.get("reflectivity", 0.1)
	mat.refractive_index = data.get("refractive_index", 1.0)

	# 电学
	mat.electrical_conductivity = data.get("electrical_conductivity", 0.0)

	# 结构
	mat.max_beam_span = data.get("max_beam_span", 1.0)
	mat.bond_strength_mortar = data.get("bond_strength_mortar", 0.5)
	mat.nail_holding = data.get("nail_holding", 500.0)
	mat.water_absorption = data.get("water_absorption", 5.0)

	# 生态
	mat.biodegradability = data.get("biodegradability", 0.1)
	mat.nutrient_n = data.get("nutrient_n", 0.0)
	mat.nutrient_p = data.get("nutrient_p", 0.0)
	mat.nutrient_k = data.get("nutrient_k", 0.0)
	mat.edibility_human = data.get("edibility_human", 0.0)
	var ed_animal = data.get("edibility_animal", {})
	if ed_animal is Dictionary:
		mat.edibility_animal = ed_animal
	else:
		mat.edibility_animal = {}

# ============================================================
# 查询
# ============================================================

func _ready() -> void:
	load_from_file()

## 按 ID 获取材料
func get_material(id: String) -> MaterialProperty:
	if _materials.has(id):
		return _materials[id]
	printerr("MaterialDB: Material not found: ", id)
	return null

## 获取全部材料
func get_all_materials() -> Array:
	var result: Array[MaterialProperty] = []
	for mat in _materials.values():
		result.append(mat)
	return result

## 按类别获取材料
func get_by_category(category: String) -> Array:
	if _by_category.has(category):
		return _by_category[category]
	return []

## 按反应标签获取材料
func get_by_reactivity_tag(tag: String) -> Array:
	if _by_reactivity_tag.has(tag):
		return _by_reactivity_tag[tag]
	return []

## 获取所有类别
func get_all_categories() -> Array:
	var cats: Array[String] = []
	for key in _by_category.keys():
		cats.append(key)
	return cats

## 获取所有反应标签
func get_all_reactivity_tags() -> Array:
	var tags: Array[String] = []
	for key in _by_reactivity_tag.keys():
		tags.append(key)
	return tags

## 检查材料是否存在
func has_material(id: String) -> bool:
	return _materials.has(id)

# ============================================================
# 摩擦系数查询
# ============================================================

## 获取两种材料之间的摩擦系数
func get_friction_pair(material_a: MaterialProperty, material_b: MaterialProperty, surface_wetness: float = 0.0) -> Dictionary:
	var base_us: float = maxf(material_a.static_friction, material_b.static_friction)
	var base_uk: float = maxf(material_a.kinetic_friction, material_b.kinetic_friction)

	var wetness_factor: float = 1.0 - surface_wetness * 0.7
	wetness_factor = clampf(wetness_factor, 0.15, 1.0)

	return {
		"static_friction": base_us * wetness_factor,
		"kinetic_friction": base_uk * wetness_factor
	}

## 获取 Capstan 方程的摩擦系数（绑扎牢固度）
func get_capstan_friction(binding_material: MaterialProperty, bound_material: MaterialProperty) -> float:
	return maxf(binding_material.static_friction,
				(binding_material.static_friction + bound_material.static_friction) * 0.5)
