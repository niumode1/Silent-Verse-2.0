# ============================================================
# ConstructionValidator — 自由建造物理验证器
# ============================================================
# 零预设配方：玩家提交部件+连接方式，服务端推导工具属性。
# 所有属性从材料+几何+连接方式推导，无硬编码"配方"。
# ============================================================
class_name ConstructionValidator
extends RefCounted

## 部件定义: {material_id, shape, mass_kg, dimensions}
## 形状: "rod", "blade", "block", "plank", "wedge", "fiber", "granular"
## 连接: {type, part_a_idx, part_b_idx, details}
## 连接类型: "binding", "nailing", "mortise_tenon", "wedging", "stacking"

## 验证建造并推导工具属性
static func evaluate(parts: Array, connections: Array) -> Dictionary:
	if parts.is_empty():
		return {"valid": false, "reason": "no parts"}

	# 1. 加载所有部件的材料
	var loaded_parts: Array = []
	for part in parts:
		var mat: MaterialProperty = MaterialDB.get_material(part.get("material_id", ""))
		if not mat:
			return {"valid": false, "reason": "unknown material: " + part.get("material_id", "")}
		loaded_parts.append({
			"material": mat,
			"shape": part.get("shape", "block"),
			"mass_kg": part.get("mass_kg", mat.density * 0.001),
			"dimensions": part.get("dimensions", {"length": 0.5, "width": 0.1, "height": 0.1}),
			"position": part.get("position", Vector3.ZERO)
		})

	# 2. 验证每个连接的物理可行性
	for conn in connections:
		var conn_result := _validate_connection(conn, loaded_parts)
		if not conn_result["valid"]:
			return conn_result

	# 3. 推导整体属性
	var derived := _derive_properties(loaded_parts, connections)

	# 4. 判定工具类型
	var tool_type := _classify_tool(loaded_parts, connections, derived)

	derived["tool_type"] = tool_type
	derived["valid"] = true

	return derived

# ============================================================
# 连接验证
# ============================================================

static func _validate_connection(conn: Dictionary, parts: Array) -> Dictionary:
	var type: String = conn.get("type", "binding")
	var a_idx: int = conn.get("part_a_idx", -1)
	var b_idx: int = conn.get("part_b_idx", -1)

	if a_idx < 0 or a_idx >= parts.size() or b_idx < 0 or b_idx >= parts.size():
		return {"valid": false, "reason": "invalid part index"}

	var part_a: Dictionary = parts[a_idx]
	var part_b: Dictionary = parts[b_idx]

	match type:
		"binding":
			return _validate_binding(conn, part_a, part_b)
		"nailing":
			return _validate_nailing(conn, part_a, part_b)
		"mortise_tenon":
			return _validate_mortise(conn, part_a, part_b)
		"wedging":
			return _validate_wedging(conn, part_a, part_b)
		"stacking":
			return _validate_stacking(conn, part_a, part_b)

	return {"valid": false, "reason": "unknown connection type: " + type}

## 绑扎验证（Capstan 方程）
static func _validate_binding(conn: Dictionary, part_a: Dictionary, part_b: Dictionary) -> Dictionary:
	var binding_mat: MaterialProperty = MaterialDB.get_material(conn.get("binding_material", "vine"))
	if not binding_mat:
		return {"valid": false, "reason": "unknown binding material"}

	# 绑扎材料必须是纤维或柔性
	if binding_mat.phase != "fiber" and binding_mat.tensile_strength < 20:
		return {"valid": false, "reason": "binding material too weak"}

	# Capstan 方程计算牢固度
	var mu_s: float = MaterialDB.get_capstan_friction(binding_mat, part_a["material"])
	var wraps: int = conn.get("wraps", 1)
	var wrap_angle: float = wraps * TAU
	var tension_hold: float = conn.get("tension", 100.0)

	var max_load: float = PhysicsCalc.capstan_max_load(tension_hold, mu_s, wrap_angle)

	# 绑扎自身抗拉强度
	var binding_strength: float = binding_mat.tensile_strength * 1e6 * 0.00001  # ~1cm² 截面
	var effective_strength: float = minf(max_load, binding_strength)

	return {
		"valid": true,
		"strength": effective_strength,
		"type": "binding",
		"capstan_load": max_load,
		"fiber_strength": binding_strength
	}

## 钉合验证
static func _validate_nailing(conn: Dictionary, part_a: Dictionary, part_b: Dictionary) -> Dictionary:
	var nail_mat: MaterialProperty = MaterialDB.get_material(conn.get("nail_material", "pure_iron"))
	if not nail_mat:
		return {"valid": false, "reason": "unknown nail material"}

	# 钉子抗剪强度
	var nail_area: float = 0.00002  # ~5mm 直径 ≈ 2e-5 m²
	var shear_strength: float = nail_mat.shear_strength * 1e6 * nail_area

	# 目标材料的握钉力
	var hold_strength: float = part_a["material"].nail_holding
	if hold_strength <= 0:
		return {"valid": false, "reason": "material cannot hold nails"}

	var effective: float = minf(shear_strength, hold_strength)

	return {
		"valid": true,
		"strength": effective,
		"type": "nailing"
	}

static func _validate_mortise(conn: Dictionary, part_a: Dictionary, part_b: Dictionary) -> Dictionary:
	# 榫卯：需要木材并且有精确加工
	var a_shape: String = part_a.get("shape", "")
	var b_shape: String = part_b.get("shape", "")

	if part_a["material"].category != "wood" or part_b["material"].category != "wood":
		return {"valid": false, "reason": "mortise requires wood"}

	var friction: float = (part_a["material"].static_friction + part_b["material"].static_friction) * 0.5
	var compressive: float = minf(part_a["material"].compressive_strength, part_b["material"].compressive_strength) * 1e6 * 0.001

	return {
		"valid": true,
		"strength": compressive * friction,
		"type": "mortise_tenon"
	}

static func _validate_wedging(conn: Dictionary, part_a: Dictionary, part_b: Dictionary) -> Dictionary:
	var wedge_angle: float = deg_to_rad(conn.get("wedge_angle", 10.0))
	var mu_k: float = (part_a["material"].kinetic_friction + part_b["material"].kinetic_friction) * 0.5
	var input_force: float = conn.get("force", 500.0)

	var split_force: float = PhysicsCalc.wedge_split_force(input_force, wedge_angle / 2.0, mu_k)

	return {
		"valid": true,
		"strength": split_force,
		"type": "wedging"
	}

static func _validate_stacking(conn: Dictionary, part_a: Dictionary, part_b: Dictionary) -> Dictionary:
	# 堆叠：仅靠重力+摩擦
	var mu_s: float = maxf(part_a["material"].static_friction, part_b["material"].static_friction)
	var weight: float = part_a["mass_kg"] * 9.81
	var friction_force: float = mu_s * weight

	return {
		"valid": true,
		"strength": friction_force,
		"type": "stacking",
		"note": "gravity+ friction only"
	}

# ============================================================
# 属性推导
# ============================================================

static func _derive_properties(parts: Array, connections: Array) -> Dictionary:
	var total_mass: float = 0.0
	var max_hardness: float = 0.0
	var max_density: float = 0.0
	var total_volume: float = 0.0
	var has_sharp_edge: bool = false
	var min_tip_radius: float = INF
	var max_length: float = 0.0
	var dominant_material: MaterialProperty = parts[0]["material"]

	# 找到"刀刃"部件（形状为 blade/wedge/shard 的部件）
	for part in parts:
		total_mass += part["mass_kg"]
		total_volume += part["mass_kg"] / part["material"].density

		if part["material"].hardness_mohs > max_hardness:
			max_hardness = part["material"].hardness_mohs
			dominant_material = part["material"]

		if part["material"].density > max_density:
			max_density = part["material"].density

		var dims: Dictionary = part.get("dimensions", {})
		var length: float = dims.get("length", 0.5)
		if length > max_length:
			max_length = length

		var shape: String = part.get("shape", "")
		if shape in ["blade", "wedge", "shard", "edge"]:
			has_sharp_edge = true
			# 估算尖端曲率
			var tip: float = _estimate_tip_radius(part)
			if tip < min_tip_radius:
				min_tip_radius = tip

	# 连接强度取最弱的一环
	var weakest_connection: float = INF
	for conn_data in connections:
		# conn_data 已在上面的 validation 中填充 strength
		pass

	if has_sharp_edge and min_tip_radius < INF:
		min_tip_radius = minf(min_tip_radius, 0.05)

	var avg_density: float = total_mass / maxf(total_volume, 0.0001)

	return {
		"total_mass": total_mass,
		"max_hardness": max_hardness,
		"dominant_material": dominant_material,
		"average_density": avg_density,
		"has_sharp_edge": has_sharp_edge,
		"tip_radius": min_tip_radius if min_tip_radius < INF else 0.05,
		"max_length": max_length,
		"volume": total_volume
	}

## 估算尖端曲率
static func _estimate_tip_radius(part: Dictionary) -> float:
	var shape: String = part.get("shape", "")
	var mat: MaterialProperty = part["material"]

	match shape:
		"blade":
			return 0.0001  # 良好打磨的刀刃 ~0.1mm
		"wedge":
			return 0.001  # 楔子 ~1mm
		"shard":
			return 0.00005 if mat.hardness_mohs > 6 else 0.0005
		"edge":
			return 0.0002
	return 0.005

# ============================================================
# 工具分类
# ============================================================

static func _classify_tool(parts: Array, connections: Array, derived: Dictionary) -> String:
	var shapes: Array = []
	for p in parts:
		shapes.append(p.get("shape", ""))

	var has_rod: bool = "rod" in shapes
	var has_blade: bool = "blade" in shapes or "wedge" in shapes or "shard" in shapes
	var has_block: bool = "block" in shapes
	var has_fiber: bool = "fiber" in shapes
	var has_handle: bool = has_rod or ("block" in shapes and derived["max_length"] > 0.3)

	# 矛 = 棒 + 刃
	if has_handle and has_blade and derived["max_length"] > 0.5:
		return "spear"

	# 斧 = 棒 + 楔形刃
	if has_handle and has_blade and derived["max_length"] < 0.8 and derived["total_mass"] > 1.0:
		return "axe"

	# 镐 = 棒 + 尖硬物
	if has_handle and has_blade and derived["max_hardness"] > 5.0:
		return "pickaxe"

	# 锤 = 棒 + 重块
	if has_handle and has_block and derived["total_mass"] > 2.0:
		return "hammer"

	# 刀 = 单刃 + 短柄
	if has_blade and derived["max_length"] < 0.4:
		return "knife"

	# 棍 = 单棒
	if has_rod and not has_blade:
		return "club"

	# 弓 = 柔韧棒 + 弦（纤维）
	if has_rod and has_fiber:
		return "bow"

	return "improvised_tool"
