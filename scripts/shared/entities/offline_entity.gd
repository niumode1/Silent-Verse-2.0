# ============================================================
# OfflineEntity — 离线实体懒计算
# ============================================================
# 职责：管理离线玩家/动物的状态快照和代谢模拟。
# 仅在有其他玩家靠近或玩家重新上线时才"唤醒"并进行完整计算。
# 服务端权威存储。大批量离线实体几乎不消耗 CPU。
# ============================================================
class_name OfflineEntity
extends RefCounted

# ============================================================
# 状态快照
# ============================================================

## 实体类型 "human" / "animal"
var entity_type: String = "human"

## 物种标签（动物时使用）
var species: String = ""

## 离线时的 3D 位置（世界坐标）
var position: Vector3 = Vector3.ZERO

## 离线时的朝向
var rotation: Vector3 = Vector3.ZERO

## 离线时间戳 Unix 秒
var offline_since: float = 0.0

# ============================================================
# 生命统计数据（离线时的快照值）
# ============================================================

## 饥饿值 0-100（100=饱腹, 0=饿死）
var hunger: float = 100.0

## 口渴值 0-100（0=渴死）
var thirst: float = 100.0

## 体温 °C（正常 ~37）
var body_temperature: float = 37.0

## 生命值 0-100（0=死亡）
var health: float = 100.0

# ============================================================
# 藏身处加成（玩家自建）
# ============================================================

## 是否有藏身处
var has_shelter: bool = false

## 藏身处温度保护系数 0-1（1=室内温度）
var shelter_temperature_bonus: float = 0.0

## 藏身处隐蔽系数 0-1（1=完全隐藏，不可被发现）
var shelter_hide_bonus: float = 0.0

## 藏身处代谢衰减减免 0-1（1=完全停止衰减）
var shelter_decay_reduction: float = 0.0

# ============================================================
# 陷阱/警报（玩家离线前设置）
# ============================================================

## 是否有陷阱
var has_trap: bool = false

## 陷阱伤害值
var trap_damage: float = 0.0

## 陷阱触发概率 0-1
var trap_trigger_chance: float = 0.0

## 是否有警报（触发时通知周围玩家）
var has_alarm: bool = false

## 警报范围 m
var alarm_range: float = 0.0

# ============================================================
# 物品栏快照
# ============================================================

## 携带的物品 [{"material_id": "...", "mass_kg": ...}]
var inventory: Array = []

## 穿戴的护甲 {"head": mat_id, "chest": mat_id, ...}
var equipped_armor: Dictionary = {}

# ============================================================
# 代谢衰减常量
# ============================================================

## 无保护时的饥饿衰减速率（/秒）
const BASE_HUNGER_DECAY: float = 0.0001

## 无保护时的口渴衰减速率（/秒）
const BASE_THIRST_DECAY: float = 0.00015

## 无保护时的体温衰减速率（无保暖时 °C/秒）
const BASE_TEMP_DECAY: float = 0.00005

## 外部环境温度 °C（默认温暖气候，冬季更低）
var ambient_temperature: float = 20.0

# ============================================================
# 懒计算：追赶模拟
# ============================================================

## 追赶计算 — 当玩家重新上线或其他人靠近时调用一次
## @param current_time: Unix 秒
## @return 实体当前状态（存活/死亡/数据）
func catch_up(current_time: float) -> Dictionary:
	var elapsed: float = current_time - offline_since
	if elapsed <= 0.0:
		return {"status": "alive", "hunger": hunger, "thirst": thirst,
				"body_temperature": body_temperature, "health": health}

	# 计算代谢消耗
	var decay_multiplier: float = 1.0 - shelter_decay_reduction

	# 饥饿衰减
	hunger -= BASE_HUNGER_DECAY * elapsed * decay_multiplier
	# 口渴衰减（比饥饿快）
	thirst -= BASE_THIRST_DECAY * elapsed * decay_multiplier
	# 体温变化（受藏身处和环境温差影响）
	var temp_loss: float = BASE_TEMP_DECAY * elapsed * (1.0 - shelter_temperature_bonus)
	# 环境越冷，体温降越快
	if ambient_temperature < 20.0:
		temp_loss *= (20.0 - ambient_temperature) / 10.0
	body_temperature -= temp_loss

	# 健康衰减（饥饿/口渴/低体温综合影响）
	if hunger <= 0:
		health -= abs(hunger) * 0.001
		hunger = 0.0
	if thirst <= 0:
		health -= abs(thirst) * 0.002
		thirst = 0.0
	if body_temperature < 30.0:
		health -= (30.0 - body_temperature) * 0.01 * elapsed / 3600.0

	# 判定
	if health <= 0.0:
		return {"status": "dead", "cause": _get_death_cause(),
				"hunger": hunger, "thirst": thirst,
				"body_temperature": body_temperature, "health": 0.0}

	return {"status": "alive", "hunger": hunger, "thirst": thirst,
			"body_temperature": body_temperature, "health": health}

func _get_death_cause() -> String:
	if thirst <= 0 and hunger <= 0:
		return "starvation_and_dehydration"
	if thirst <= 0:
		return "dehydration"
	if hunger <= 0:
		return "starvation"
	if body_temperature < 25.0:
		return "hypothermia"
	return "unknown"

# ============================================================
# 初始化 / 快照
# ============================================================

## 从在线玩家创建离线快照
## @param player_node: 玩家的在线实体
## @param current_time: Unix 秒
static func snapshot_from_player(player_node: Node, current_time: float) -> OfflineEntity:
	var entity := OfflineEntity.new()
	entity.entity_type = "human"
	entity.position = player_node.global_position
	entity.rotation = player_node.global_rotation
	entity.offline_since = current_time
	# 假设玩家节点有这些属性
	if "hunger" in player_node: entity.hunger = player_node.hunger
	if "thirst" in player_node: entity.thirst = player_node.thirst
	if "body_temperature" in player_node: entity.body_temperature = player_node.body_temperature
	if "health" in player_node: entity.health = player_node.health
	return entity

## 从在线动物创建离线快照
static func snapshot_from_animal(animal_node: Node, species: String, current_time: float) -> OfflineEntity:
	var entity := OfflineEntity.new()
	entity.entity_type = "animal"
	entity.species = species
	entity.position = animal_node.global_position
	entity.rotation = animal_node.global_rotation
	entity.offline_since = current_time
	return entity

# ============================================================
# 被发现判定
# ============================================================

## 计算实体被另一玩家发现的难度
## @param observer_distance: 观察者距离 m
## @param observer_vision: 观察者视力属性 0-1
## @param is_night: 是否夜晚
## @return 被发现概率 0-1
func get_detection_chance(observer_distance: float, observer_vision: float, is_night: bool) -> float:
	if shelter_hide_bonus >= 1.0:
		return 0.0  # 完美隐藏

	var base_chance: float = maxf(1.0 - observer_distance / 100.0, 0.0)
	base_chance *= observer_vision
	base_chance *= (1.0 - shelter_hide_bonus)

	if is_night:
		base_chance *= 0.3  # 夜晚更难被发现
	if entity_type == "animal":
		# 动物自身有隐匿能力
		var animal_data: AnimalBody = AnimalBody.create(species)
		if animal_data:
			base_chance *= (1.0 - animal_data.stealth_level)

	return clampf(base_chance, 0.0, 1.0)

# ============================================================
# 陷阱判定
# ============================================================

## 检查陷阱是否触发
## @return Dictionary {triggered: bool, damage: float}
func check_trap_trigger() -> Dictionary:
	if not has_trap:
		return {"triggered": false, "damage": 0.0}
	if randf() < trap_trigger_chance:
		return {"triggered": true, "damage": trap_damage}
	return {"triggered": false, "damage": 0.0}

## 检查警报是否触发
func check_alarm_trigger() -> Dictionary:
	if not has_alarm:
		return {"triggered": false, "range": 0.0}
	return {"triggered": true, "range": alarm_range}
