# ============================================================
# Forge — 锻造系统
# ============================================================
# 管理加热→锻打→淬火→回火→磨刃流程。
# 全部由材料属性+温度+物理公式驱动。
# ============================================================
class_name Forge
extends RefCounted

## 工件当前材料属性
var workpiece_material: MaterialProperty = null

## 工件质量 kg
var workpiece_mass: float = 1.0

## 工件当前温度 °C
var workpiece_temperature: float = 20.0

## 工件当前硬度（可因加工硬化提升）
var current_hardness: float = 0.0

## 工件当前韧性
var current_toughness: float = 0.0

## 尖端曲率半径 m（磨刃决定）
var tip_radius: float = 0.01

## 锻造完成度 0-1
var forge_progress: float = 0.0

## 状态: "raw", "heating", "forging", "quenched", "tempered", "sharpened", "finished"
var state: String = "raw"

## 锻造历史
var history: Array = []

# ============================================================
# 初始化
# ============================================================

## 加载粗金属（海绵铁/粗铜等）
func load_ingot(material_id: String, mass: float, purity: float = 0.9) -> bool:
	var mat: MaterialProperty = MaterialDB.get_material(material_id)
	if not mat:
		return false

	workpiece_material = mat
	workpiece_mass = mass
	workpiece_temperature = 20.0
	current_hardness = mat.hardness_mohs
	current_toughness = mat.fracture_toughness
	tip_radius = 0.01
	forge_progress = 0.0
	state = "raw"
	history.clear()
	return true

# ============================================================
# 加热
# ============================================================

## 在炉中加热工件
func heat_in_furnace(furnace_temp: float, delta: float) -> void:
	if state != "raw" and state != "heating":
		return
	state = "heating"

	# 热传导：工件升温
	var temp_diff: float = furnace_temp - workpiece_temperature
	var heating_rate: float = workpiece_material.specific_heat
	if heating_rate > 0:
		workpiece_temperature += temp_diff * delta * 0.02

	if workpiece_temperature >= workpiece_material.forging_temperature:
		state = "forging"

	history.append({"action": "heat", "temp": workpiece_temperature})

## 工件是否可锻
func is_forgable() -> bool:
	return workpiece_temperature >= workpiece_material.forging_temperature

# ============================================================
# 锻打
# ============================================================

## 锤击（服务端权威计算）
func hammer_strike(hammer_mass: float, hammer_velocity: float, contact_area: float) -> Dictionary:
	if state != "forging":
		return {"success": false, "reason": "too cold to forge"}

	if not workpiece_material:
		return {"success": false, "reason": "no workpiece"}

	# 锻打变形量
	var deformation: float = PhysicsCalc.forge_deformation(
		hammer_mass, hammer_velocity,
		workpiece_material.yield_strength, contact_area
	)

	# 加工硬化
	current_hardness = PhysicsCalc.work_hardening_increase(
		current_hardness, workpiece_material.max_hardness_mohs, deformation
	)
	current_toughness = PhysicsCalc.work_hardening_toughness_decrease(
		current_toughness, workpiece_material.min_toughness, deformation
	)

	# 锻打进度
	forge_progress = minf(forge_progress + deformation * 0.1, 1.0)

	# 温度缓慢下降
	workpiece_temperature -= 5.0

	if workpiece_temperature < workpiece_material.forging_temperature * 0.6:
		state = "heating"  # 需要重新加热

	history.append({"action": "hammer", "hardness": current_hardness, "toughness": current_toughness})

	return {
		"success": true,
		"deformation": deformation,
		"hardness": current_hardness,
		"toughness": current_toughness,
		"progress": forge_progress,
		"temperature": workpiece_temperature
	}

# ============================================================
# 淬火（奥氏体化→马氏体）
# ============================================================

func quench(quenchant: String = "water") -> Dictionary:
	if state != "forging":
		return {"success": false, "reason": "must be forging temperature first"}

	if workpiece_temperature < 700:
		return {"success": false, "reason": "not hot enough for austenitization"}

	# 冷却速率取决于淬火介质
	var cooling_rate: float = 500.0  # °C/s，水中
	if quenchant == "oil":
		cooling_rate = 200.0
	elif quenchant == "air":
		cooling_rate = 20.0

	# 淬火后硬度变化
	var new_hardness: float = PhysicsCalc.quench_hardness_change(
		current_hardness, workpiece_material.max_hardness_mohs, workpiece_temperature
	)

	current_hardness = new_hardness
	workpiece_temperature = 50.0  # 淬火后冷却
	state = "quenched"

	history.append({"action": "quench", "quenchant": quenchant, "hardness": current_hardness})

	return {
		"success": true,
		"hardness": current_hardness,
		"toughness": current_toughness,
		"quenchant": quenchant,
		"cooling_rate": cooling_rate
	}

# ============================================================
# 回火（消除应力，恢复韧性）
# ============================================================

func temper(temper_temp: float) -> Dictionary:
	if state != "quenched" and state != "forging":
		return {"success": false, "reason": "must quench first"}

	var result: Dictionary = PhysicsCalc.temper_effect(
		current_hardness, workpiece_material.hardness_mohs,
		current_toughness, workpiece_material.fracture_toughness,
		temper_temp
	)

	current_hardness = result["hardness"]
	current_toughness = result["toughness"]
	workpiece_temperature = temper_temp
	state = "tempered"

	history.append({"action": "temper", "temp": temper_temp, "hardness": current_hardness, "toughness": current_toughness})

	return {
		"success": true,
		"hardness": current_hardness,
		"toughness": current_toughness
	}

# ============================================================
# 磨刃
# ============================================================

func sharpen(whetstone_material: MaterialProperty, duration: float, pressure: float) -> Dictionary:
	if state != "tempered" and state != "quenched" and state != "forging":
		# 任何阶段都可以磨，但锻造后最好
		pass

	if whetstone_material.hardness_mohs <= current_hardness:
		return {"success": false, "reason": "whetstone too soft"}

	# Archard 磨损模型
	var sliding_speed: float = 0.5
	var wear_coeff: float = 1e-5
	var wear_rate: float = PhysicsCalc.sharpen_wear_rate(
		wear_coeff, pressure, sliding_speed, workpiece_material.hardness_vickers
	)

	# 尖端缩小
	var min_radius: float = 0.00001  # 金属可磨到 ~10μm
	tip_radius = PhysicsCalc.sharpen_new_tip_radius(
		tip_radius, wear_rate, duration, 1.0, min_radius
	)

	if tip_radius <= min_radius * 1.1:
		state = "sharpened"

	history.append({"action": "sharpen", "tip_radius": tip_radius})

	return {
		"success": true,
		"tip_radius": tip_radius,
		"wear_rate": wear_rate
	}

## 完成
func finish() -> void:
	state = "finished"

## 获取工具属性（用于后续伤害计算等）
func get_tool_properties() -> Dictionary:
	return {
		"material": workpiece_material,
		"mass": workpiece_mass,
		"hardness": current_hardness,
		"toughness": current_toughness,
		"tip_radius": tip_radius,
		"state": state,
		"forge_progress": forge_progress
	}
