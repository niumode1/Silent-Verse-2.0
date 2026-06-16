# ============================================================
# AnimalBody — 动物生物力学实体
# ============================================================
# 职责：定义每种可扮演动物的身体参数和能力。
# 参数基于现实动物数据。服务端权威，决定动物在生态中的角色。
# ============================================================
class_name AnimalBody
extends Resource

# ============================================================
# 基础标识
# ============================================================

## 物种标签 "wolf" / "fox" / "rabbit"
@export var species: String = "rabbit"

## 显示名称
@export var display_name: String = "兔子"

## 体重 kg
@export var body_mass: float = 2.0

# ============================================================
# 运动能力
# ============================================================

## 最大奔跑速度 m/s
@export var max_speed: float = 12.0

## 耐力跑步速度 m/s
@export var jog_speed: float = 8.0

## 加速度 m/s²
@export var acceleration: float = 8.0

## 转向速度 rad/s
@export var turn_rate: float = 5.0

# ============================================================
# 战斗/捕食能力
# ============================================================

## 咬合力 N（现实值：狼~1200, 狐狸~200, 兔子~100）
@export var bite_force: float = 100.0

## 牙齿尖端总截面积 m²（决定咬合压强）
@export var teeth_tip_area: float = 0.000002

## 牙齿硬度（莫氏）
@export var teeth_hardness_mohs: float = 5.0

## 爪子/蹄子伤害值（兔子=0，狼有爪）
@export var claw_damage: float = 0.0

## 冲锋撞击力 N（基于体重×速度）
@export var charge_force: float = 0.0

# ============================================================
# 感知能力
# ============================================================

## 视觉感知半径 m
@export var vision_range: float = 50.0

## 嗅觉感知半径 m（比视觉远）
@export var smell_range: float = 100.0

## 听觉感知半径 m
@export var hearing_range: float = 80.0

## 夜视能力 0-1
@export var night_vision: float = 0.3

# ============================================================
# 隐匿能力
# ============================================================

## 隐匿等级 0-1（1=极易隐藏）
@export var stealth_level: float = 0.5

## 静音移动 0-1（1=完全无声）
@export var silent_movement: float = 0.3

## 可钻洞
@export var can_burrow: bool = false

## 会爬树
@export var can_climb: bool = false

# ============================================================
# 生理
# ============================================================

## 寿命 游戏年
@export var lifespan_years: float = 2.0

## 基础饥饿衰减速率 单位/秒
@export var hunger_decay_rate: float = 0.0002

## 基础口渴衰减速率
@export var thirst_decay_rate: float = 0.0003

## 可吃的食物类别 ["plant", "meat", "insect"]
@export var diet_type: String = "plant"

## 饮食转化效率 0-1
@export var food_efficiency: float = 0.3

## 繁殖率（每季新生个体数，影响种群容量）
@export var reproduction_rate: float = 8.0

# ============================================================
# 锻炼/成长（动物也可通过生存锻炼变强）
# ============================================================

## 当前力量水平 0-1（影响咬合力和速度）
@export var fitness: float = 0.7

## 最大可达到的力量水平
@export var max_fitness: float = 1.0

## 通过捕食/逃脱锻炼
func exercise_fitness(intensity: float, duration: float) -> void:
	var gain: float = intensity * duration * 0.0005
	fitness = minf(fitness + gain, max_fitness)

## 不活动衰减
func decay_fitness(inactive_days: float) -> void:
	fitness = maxf(fitness - inactive_days * 0.01, 0.5)

# ============================================================
# 派生计算
# ============================================================

## 获取当前咬合力（考虑体适能）
func get_current_bite_force() -> float:
	return bite_force * fitness

## 获取当前速度
func get_current_max_speed() -> float:
	return max_speed * fitness

## 计算咬合伤害
func calculate_bite_damage(target_material: MaterialProperty, shake_multiplier: float = 1.0) -> Dictionary:
	return PhysicsCalc.calculate_bite_damage(
		get_current_bite_force(),
		teeth_tip_area,
		teeth_hardness_mohs,
		target_material,
		shake_multiplier
	)

# ============================================================
# 预设物种工厂
# ============================================================

static func create_wolf() -> AnimalBody:
	var a := AnimalBody.new()
	a.species = "wolf"
	a.display_name = "狼"
	a.body_mass = 45.0
	a.max_speed = 15.0
	a.jog_speed = 8.0
	a.acceleration = 10.0
	a.turn_rate = 4.0
	a.bite_force = 1200.0
	a.teeth_tip_area = 0.000015
	a.teeth_hardness_mohs = 5.0
	a.claw_damage = 15.0
	a.charge_force = 500.0
	a.vision_range = 80.0
	a.smell_range = 500.0
	a.hearing_range = 200.0
	a.night_vision = 0.7
	a.stealth_level = 0.3
	a.silent_movement = 0.4
	a.can_burrow = false
	a.can_climb = false
	a.lifespan_years = 2.0
	a.hunger_decay_rate = 0.0003
	a.thirst_decay_rate = 0.0004
	a.diet_type = "meat"
	a.food_efficiency = 0.15
	a.reproduction_rate = 3.0
	a.fitness = 0.8
	a.max_fitness = 1.0
	return a

static func create_fox() -> AnimalBody:
	var a := AnimalBody.new()
	a.species = "fox"
	a.display_name = "狐狸"
	a.body_mass = 8.0
	a.max_speed = 12.0
	a.jog_speed = 6.0
	a.acceleration = 8.0
	a.turn_rate = 5.5
	a.bite_force = 200.0
	a.teeth_tip_area = 0.000006
	a.teeth_hardness_mohs = 4.5
	a.claw_damage = 5.0
	a.charge_force = 80.0
	a.vision_range = 60.0
	a.smell_range = 200.0
	a.hearing_range = 150.0
	a.night_vision = 0.6
	a.stealth_level = 0.5
	a.silent_movement = 0.6
	a.can_burrow = true
	a.can_climb = false
	a.lifespan_years = 2.0
	a.hunger_decay_rate = 0.00025
	a.thirst_decay_rate = 0.00035
	a.diet_type = "omnivore"
	a.food_efficiency = 0.2
	a.reproduction_rate = 4.0
	a.fitness = 0.75
	a.max_fitness = 1.0
	return a

static func create_rabbit() -> AnimalBody:
	var a := AnimalBody.new()
	a.species = "rabbit"
	a.display_name = "兔子"
	a.body_mass = 2.0
	a.max_speed = 12.0
	a.jog_speed = 5.0
	a.acceleration = 12.0
	a.turn_rate = 7.0
	a.bite_force = 100.0
	a.teeth_tip_area = 0.000002
	a.teeth_hardness_mohs = 2.5
	a.claw_damage = 0.0
	a.charge_force = 0.0
	a.vision_range = 40.0
	a.smell_range = 80.0
	a.hearing_range = 120.0
	a.night_vision = 0.4
	a.stealth_level = 0.8
	a.silent_movement = 0.85
	a.can_burrow = true
	a.can_climb = false
	a.lifespan_years = 2.0
	a.hunger_decay_rate = 0.0002
	a.thirst_decay_rate = 0.0003
	a.diet_type = "plant"
	a.food_efficiency = 0.3
	a.reproduction_rate = 8.0
	a.fitness = 0.7
	a.max_fitness = 1.0
	return a

## 按物种名创建
static func create(species_name: String) -> AnimalBody:
	match species_name:
		"wolf": return create_wolf()
		"fox": return create_fox()
		"rabbit": return create_rabbit()
		_: return null
