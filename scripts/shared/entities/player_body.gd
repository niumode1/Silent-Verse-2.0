# ============================================================
# PlayerBody — 人类生物力学实体
# ============================================================
# 职责：定义人类玩家的身体参数、先天变异、锻炼系统。
# 每次投胎时重新随机生成。服务端权威存储，客户端仅表现。
# ============================================================
class_name PlayerBody
extends Resource

# ============================================================
# 基础身体参数
# ============================================================

## 体重 kg（初始 ~70kg，随机变异）
@export var body_mass: float = 70.0

## 身高 m（初始 ~1.7m）
@export var height: float = 1.70

# ============================================================
# 先天属性（0.7 - 1.3 随机，1.0 = 人类平均）
# ============================================================

## 体格 — 影响力量/负重基础
@export var physique: float = 1.0

## 耐力 — 影响疲劳恢复速度
@export var endurance: float = 1.0

## 智力 — 影响学习速度（锻炼效率）
@export var intelligence: float = 1.0

## 视力 — 影响远距离感知
@export var vision: float = 1.0

## 代谢率 — 影响饥饿/口渴消耗速度
@export var metabolism: float = 1.0

# ============================================================
# 可锻炼属性（初始基于先天，随劳动增长）
# ============================================================

## 当前最大力量输出 N
@export var current_strength: float = 420.0

## 基础最大力量（未经锻炼）N
@export var base_strength: float = 420.0

## 最大可达到的力量 N（先天上限）
@export var max_strength: float = 588.0

## 当前最大耐力（可连续劳动时间）s
@export var current_stamina: float = 600.0

## 基础耐力 s
@export var base_stamina: float = 600.0

## 最大耐力 s
@export var max_stamina: float = 1200.0

# ============================================================
# 技能经验（特定动作的熟练度 0-100）
# ============================================================

## 伐木技能
@export var skill_chopping: float = 0.0

## 采矿技能
@export var skill_mining: float = 0.0

## 锻造技能
@export var skill_forging: float = 0.0

## 建造技能
@export var skill_building: float = 0.0

## 农耕技能
@export var skill_farming: float = 0.0

## 烹饪技能
@export var skill_cooking: float = 0.0

## 狩猎/战斗技能
@export var skill_combat: float = 0.0

# ============================================================
# 先天疾病
# ============================================================

## 视力缺陷 0-1
@export var vision_defect: float = 0.0

## 关节脆弱 0-1
@export var joint_fragility: float = 0.0

## 代谢异常 0-1
@export var metabolic_disorder: float = 0.0

## 免疫低下 0-1
@export var immune_deficiency: float = 0.0

## 骨质疏松 0-1（缺钙/代谢疾病）。骨吸收先从内壁开始：骨皮质变薄、
## 密度下降，但外径几乎不变。属于「轻微改变部分骨属性」，不是换材料。
@export var osteoporosis: float = 0.0

# ============================================================
# 骨骼材料属性
# ============================================================
# 骨头不是不可破坏的运动学约束，而是一根有真实材料属性的承力梁：
# 皮质骨密度 ~1900 kg/m³、抗拉 ~130 MPa、抗压 ~180 MPa、
# 弹性模量 ~17 GPa。载荷超过截面抗弯极限就在受力点断裂。

const BONE_DENSITY := 1900.0               # kg/m³
const BONE_TENSILE_STRENGTH := 130.0e6     # Pa
const BONE_COMPRESSIVE_STRENGTH := 180.0e6 # Pa
const BONE_ELASTIC_MODULUS := 17.0e9       # Pa

## 各骨段的骨皮质外径/内径 (m)，真实解剖量级
const BONE_SECTIONS := {
	"humerus": {"outer": 0.025, "inner": 0.016},     # 肱骨
	"radius_ulna": {"outer": 0.019, "inner": 0.012}, # 桡尺骨
	"metacarpal": {"outer": 0.008, "inner": 0.005},  # 掌骨
	"phalanx": {"outer": 0.0065, "inner": 0.004},    # 指骨
}

# ============================================================
# 初始化 / 投胎随机
# ============================================================

## 生成随机先天属性（投胎时调用）
func roll_innate_traits() -> void:
	var rng = RandomNumberGenerator.new()
	rng.randomize()

	physique = _roll_trait(rng)
	endurance = _roll_trait(rng)
	intelligence = _roll_trait(rng)
	vision = _roll_trait(rng)
	metabolism = _roll_trait(rng)

	# 体重随机 ±15%
	body_mass = 70.0 * rng.randf_range(0.85, 1.15)
	height = 1.70 * rng.randf_range(0.92, 1.08)

	# 根据体格计算力量
	base_strength = 420.0 * physique
	max_strength = base_strength * 1.4
	current_strength = base_strength

	base_stamina = 600.0 * endurance
	max_stamina = base_stamina * 2.0
	current_stamina = base_stamina

	# 先天疾病（低概率）
	vision_defect = _roll_disease(rng, 0.03)
	joint_fragility = _roll_disease(rng, 0.02)
	metabolic_disorder = _roll_disease(rng, 0.02)
	immune_deficiency = _roll_disease(rng, 0.02)
	osteoporosis = _roll_disease(rng, 0.05)

	# 技能归零
	skill_chopping = 0.0
	skill_mining = 0.0
	skill_forging = 0.0
	skill_building = 0.0
	skill_farming = 0.0
	skill_cooking = 0.0
	skill_combat = 0.0

## 随机一个属性值（正态近似，中心 1.0，范围 0.7-1.3）
func _roll_trait(rng: RandomNumberGenerator) -> float:
	var base: float = rng.randf_range(0.7, 1.3)
	return base

## 随机疾病
func _roll_disease(rng: RandomNumberGenerator, probability: float) -> float:
	if rng.randf() < probability:
		return rng.randf_range(0.1, 0.5)
	return 0.0

# ============================================================
# 力量计算
# ============================================================

## 获取当前最大力量输出 N
func get_max_force() -> float:
	var force: float = current_strength * (1.0 - joint_fragility * 0.5)
	return maxf(force, 50.0)

# ============================================================
# 关节力矩（肌肉支撑力）
# ============================================================
# 肌肉对关节的力矩 = 肌力 × 力臂。力臂是人体解剖几何常数，
# 不是玩法数值：肩 ~0.25 m、肘 ~0.18 m、腕 ~0.033 m，
# 指间关节 2-4 mm。肌力本身由 PlayerBody 的锻炼系统决定。
const JOINT_MOMENT_ARMS := {
	"shoulder": 0.25,     # m
	"elbow": 0.18,        # m
	"wrist": 0.033,       # m
	"finger_mcp": 0.004,  # m
	"finger_pip": 0.003,  # m
	"finger_dip": 0.002,  # m
	"thumb_cmc_adduct": 0.008,  # m，拇指 CMC 内收/外展（对掌）
}

## 不主动发力时肌肉维持姿势的静力支撑占比（肌紧张/姿态反射）。
## 健康成人的姿态性共激活约为最大随意收缩的 40-60%；低于这个值，
## 连自然行走的惯性都会让手臂乱甩。超过这个力矩的外载仍会把关节
## 压弯，玩家必须主动发力才能顶住。
const PASSIVE_SUPPORT_RATIO := 0.5

## 某一关节当前能输出的最大力矩 N·m
func get_joint_max_torque(joint: String) -> float:
	return get_max_force() * float(JOINT_MOMENT_ARMS.get(joint, 0.0))

## 不主动控制时该关节的支撑力矩 N·m
func get_joint_passive_torque(joint: String) -> float:
	return get_joint_max_torque(joint) * PASSIVE_SUPPORT_RATIO

# ============================================================
# 骨骼力学
# ============================================================

## 骨质疏松后的骨截面 (m)。骨吸收主要发生内壁：外径略缩、内径扩大。
func get_bone_section(bone: String) -> Dictionary:
	var sec: Dictionary = BONE_SECTIONS.get(bone, BONE_SECTIONS["phalanx"])
	var severity: float = clampf(osteoporosis, 0.0, 1.0)
	return {
		"outer": float(sec["outer"]) * (1.0 - 0.05 * severity),
		"inner": float(sec["inner"]) * (1.0 + 0.20 * severity),
	}

## 该骨段在弯曲载荷下的断裂力矩 N·m。
## 抗弯截面模量 W = π(D⁴-d⁴)/(32D)，断裂条件 M > σ·W。
## 骨质疏松只轻微降低抗拉强度，主要靠骨皮质变薄降低 W。
func get_bone_fracture_moment(bone: String) -> float:
	var sec := get_bone_section(bone)
	var outer: float = sec["outer"]
	var inner: float = sec["inner"]
	var w: float = PI * (pow(outer, 4.0) - pow(inner, 4.0)) / (32.0 * outer)
	var strength: float = BONE_TENSILE_STRENGTH * (1.0 - 0.15 * clampf(osteoporosis, 0.0, 1.0))
	return strength * w

## 获取当前最大负重 kg（长期携带）
func get_carry_capacity() -> float:
	return body_mass * 0.2 * physique

## 获取短途搬运上限 kg
func get_lift_capacity() -> float:
	return body_mass * 0.5 * physique

## 获取当前奔跑速度 m/s
func get_sprint_speed() -> float:
	var base_speed: float = 8.0 * physique
	return maxf(base_speed, 4.0)

## 获取耐力跑步速度 m/s
func get_jog_speed() -> float:
	return 5.0 * physique

# ============================================================
# 挥击能力
# ============================================================

## 计算给定武器重量下的最大挥击角速度 rad/s
## 重武器 → 速度下降，但动能可能更高（取决于杠杆臂）
func get_max_swing_angular_velocity(weapon_mass: float, lever_arm: float) -> float:
	# 手臂+武器系统的转动惯量
	var arm_inertia: float = 0.5  # 手臂转动惯量近似
	var weapon_inertia: float = weapon_mass * lever_arm * lever_arm
	var total_inertia: float = arm_inertia + weapon_inertia

	# 可用力矩
	var max_torque: float = get_max_force() * 0.35  # 手臂力臂 ~0.35m

	# ω = sqrt(2E/I), E = τ * θ (挥击角度 ~π/2)
	var energy: float = max_torque * PI / 2.0
	var omega: float = sqrt(2.0 * energy / total_inertia)
	return omega

## 获取当前疲劳系数 (0-1, 1=满体力)
func get_fatigue_factor(current_activity_time: float) -> float:
	if current_stamina < 0.01:
		return 0.0
	var ratio: float = current_activity_time / current_stamina
	return clampf(1.0 - ratio, 0.2, 1.0)

## 消耗体力（持续劳动后调用）
func expend_stamina(activity_time: float) -> void:
	current_stamina = maxf(current_stamina - activity_time, 0.0)

## 恢复体力（休息时调用）
func recover_stamina(rest_time: float) -> void:
	var recovery_rate: float = endurance * 1.2 * (1.0 + 0.3 * skill_building / 100.0)
	current_stamina = minf(current_stamina + rest_time * recovery_rate, max_stamina)

# ============================================================
# 锻炼增益
# ============================================================

## 通过劳动锻炼力量
## @param intensity: 劳动强度 0-1
## @param duration: 持续时间 s
func exercise_strength(intensity: float, duration: float) -> void:
	if intensity < 0.3:
		return  # 太轻松，不增长
	var gain: float = intensity * duration * 0.001 * intelligence
	current_strength = minf(current_strength + gain, max_strength)

## 通过劳动锻炼耐力
func exercise_endurance(duration: float) -> void:
	var gain: float = duration * 0.002 * intelligence * endurance
	base_stamina = minf(base_stamina + gain, max_stamina)

## 提升技能经验
func gain_skill_experience(skill_name: String, amount: float) -> void:
	amount *= intelligence
	match skill_name:
		"chopping":
			skill_chopping = minf(skill_chopping + amount, 100.0)
		"mining":
			skill_mining = minf(skill_mining + amount, 100.0)
		"forging":
			skill_forging = minf(skill_forging + amount, 100.0)
		"building":
			skill_building = minf(skill_building + amount, 100.0)
		"farming":
			skill_farming = minf(skill_farming + amount, 100.0)
		"cooking":
			skill_cooking = minf(skill_cooking + amount, 100.0)
		"combat":
			skill_combat = minf(skill_combat + amount, 100.0)

## 获取技能等级对应的效率倍率
func get_skill_efficiency(skill_name: String) -> float:
	var level: float = 0.0
	match skill_name:
		"chopping": level = skill_chopping
		"mining": level = skill_mining
		"forging": level = skill_forging
		"building": level = skill_building
		"farming": level = skill_farming
		"cooking": level = skill_cooking
		"combat": level = skill_combat
		_: return 1.0
	# 技能 0→效率 0.5, 技能 50→效率 1.0, 技能 100→效率 1.5
	return 0.5 + level / 100.0

# ============================================================
# 属性衰减（长期不活动）
# ============================================================

## 因长期不活动而属性衰减
func decay_attributes(inactive_days: float) -> void:
	var decay_rate: float = 0.01 * inactive_days
	# 力量衰减
	current_strength = maxf(current_strength * (1.0 - decay_rate), base_strength * 0.8)
	# 耐力衰减
	current_stamina = maxf(current_stamina * (1.0 - decay_rate), base_stamina * 0.8)
	# 技能衰减
	var skills = ["chopping", "mining", "forging", "building", "farming", "cooking", "combat"]
	for skill in skills:
		gain_skill_experience(skill, -decay_rate)

# ============================================================
# 代谢与饥饿/口渴
# ============================================================

## 基础饥饿衰减速率 (单位/现实秒)
func get_hunger_decay_rate() -> float:
	var rate: float = 0.0001 * metabolism
	# 代谢异常加速
	rate *= (1.0 + metabolic_disorder * 2.0)
	# 体格大的人消耗更多
	rate *= physique
	return rate

## 基础口渴衰减速率（比饥饿快）
func get_thirst_decay_rate() -> float:
	return get_hunger_decay_rate() * 1.5

## 基础体温维持能力
func get_cold_resistance() -> float:
	return 1.0 / maxf(metabolism, 0.5)  # 代谢高的更耐冷
