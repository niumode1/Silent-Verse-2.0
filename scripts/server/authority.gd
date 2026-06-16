# ============================================================
# Authority — 服务端权威验证层
# ============================================================
# 职责：接收客户端动作请求，在服务端执行物理/化学计算，
# 验证合法性，广播结果给附近玩家。
# 所有玩家操作必须经过此层——这是防作弊的唯一关口。
# ============================================================
class_name Authority
extends Node

## 引用 ENetServer 用于广播
var _server: ENetServer = null

## 在线玩家完整数据 {peer_id: {player_body, position, inventory, ...}}
var _player_data: Dictionary = {}

## 世界状态引用（后续接入）
var _world_state: Node = null

# ============================================================
# 初始化
# ============================================================

func setup(server: ENetServer) -> void:
	_server = server
	_server.action_received.connect(_on_action_received)
	_server.player_connected.connect(_on_player_joined)
	_server.player_disconnected.connect(_on_player_left)

func _on_player_joined(peer_id: int) -> void:
	# 为新玩家创建随机身体
	var body := PlayerBody.new()
	body.roll_innate_traits()
	_player_data[peer_id] = {
		"player_body": body,
		"inventory": [],
		"equipped": {},
		"position": Vector3.ZERO
	}

func _on_player_left(peer_id: int) -> void:
	if _player_data.has(peer_id):
		_player_data.erase(peer_id)

# ============================================================
# 动作处理
# ============================================================

func _on_action_received(peer_id: int, action_type: int, data: Dictionary) -> void:
	print("  >>> Authority processing action ", action_type, " from peer ", peer_id)
	match action_type:
		NetworkPacket.ActionType.SWING:
			_handle_swing(peer_id, data)
		NetworkPacket.ActionType.INTERACT:
			_handle_interact(peer_id, data)
		NetworkPacket.ActionType.BUILD:
			_handle_build(peer_id, data)
		NetworkPacket.ActionType.EQUIP:
			_handle_equip(peer_id, data)
		NetworkPacket.ActionType.UNEQUIP:
			_handle_unequip(peer_id, data)
		NetworkPacket.ActionType.DROP:
			_handle_drop(peer_id, data)
		NetworkPacket.ActionType.PICKUP:
			_handle_pickup(peer_id, data)
		NetworkPacket.ActionType.EAT:
			_handle_eat(peer_id, data)
		NetworkPacket.ActionType.DRINK:
			_handle_drink(peer_id, data)

# ============================================================
# 挥击（砍树/挖矿/攻击）
# ============================================================

func _handle_swing(peer_id: int, data: Dictionary) -> void:
	var player: Dictionary = _player_data.get(peer_id)
	if not player:
		return

	var body: PlayerBody = player["player_body"]
	if not body:
		return

	# 从 data 中提取挥击参数
	var angular_velocity: float = data.get("angular_velocity", 5.0)
	var lever_arm: float = data.get("lever_arm", 0.8)
	var target_id: String = data.get("target_id", "")
	var target_type: String = data.get("target_type", "")
	var hit_position: Vector3 = _vec_from_dict(data.get("hit_position", {}))

	# 获取装备中的武器
	var weapon_material: MaterialProperty = MaterialDB.get_material("flint")  # 默认石斧
	var weapon_mass: float = 2.0
	var tip_radius: float = 0.001  # 磨尖程度
	var equipped: Dictionary = player.get("equipped", {})
	if equipped.has("weapon"):
		var weapon_id: String = equipped["weapon"]
		weapon_material = MaterialDB.get_material(weapon_id)
		if weapon_material:
			weapon_mass = weapon_material.density * 0.0005  # ~500cm³
			tip_radius = 0.003 if weapon_material.hardness_mohs < 5.0 else 0.001

	# 疲劳因素
	var fatigue: float = body.get_fatigue_factor(data.get("activity_time", 0.0))

	# 挥击物理
	var actual_omega: float = angular_velocity * fatigue
	var linear_velocity: float = PhysicsCalc.swing_linear_velocity(actual_omega, lever_arm)

	# 计算伤害/砍入
	var result: Dictionary = {}
	if target_type == "tree":
		var wood := MaterialDB.get_material(target_id) if target_id != "" else MaterialDB.get_material("oak_wood")
		if wood:
			var ek: float = PhysicsCalc.swing_kinetic_energy(weapon_mass, linear_velocity)
			var depth := PhysicsCalc.chop_cut_depth(ek, 0.005, wood.shear_strength, wood.youngs_modulus, 0.0)
			result = {"action": "chop", "target": target_id, "cut_depth": depth}
			# 给玩家加技能经验
			body.gain_skill_experience("chopping", 0.1)

	elif target_type == "rock":
		var rock := MaterialDB.get_material(target_id) if target_id != "" else MaterialDB.get_material("granite")
		if rock and PhysicsCalc.can_mine(weapon_material.hardness_mohs, rock.hardness_mohs):
			var impact_force: float = PhysicsCalc.momentum(weapon_mass, linear_velocity) / 0.001
			var vol := PhysicsCalc.mine_volume_per_strike(impact_force, 1e-4,
				rock.compressive_strength, rock.fracture_toughness)
			result = {"action": "mine", "target": target_id, "volume_mined": vol}
			body.gain_skill_experience("mining", 0.1)

	elif target_type == "player" or target_type == "animal":
		var target_mat := MaterialDB.get_material("meat_raw")
		var damage := PhysicsCalc.calculate_strike_damage(
			weapon_material, weapon_mass, actual_omega, lever_arm, tip_radius, target_mat, 1.0
		)
		result = {"action": "attack", "target": target_id, "damage": damage}
		body.gain_skill_experience("combat", 0.2)

	else:
		# 默认：对地形/空气挥击——无目标
		result = {"action": "swing", "target": "air"}

	# 消耗体力
	body.expend_stamina(1.0)

	# 锻炼（如果用了力）
	if angular_velocity > 2.0:
		body.exercise_strength(0.5, 1.0)
		body.exercise_endurance(1.0)

	# 发送结果给请求者
	var result_pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_RESULT, {
		"action": NetworkPacket.ActionType.SWING,
		"result": result
	})
	_server.send_to(peer_id, result_pkt)

	print(">> Sending result to peer ", peer_id, ": ", result.get("action", "?"))
	# 广播给附近玩家
	var pos := _get_player_position(peer_id)
	var broadcast_pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_BROADCAST, {
		"peer_id": peer_id,
		"action": "swing",
		"result": result
	})
	_server.broadcast_nearby_except(broadcast_pkt, pos, peer_id)

# ============================================================
# 交互（捡/用）
# ============================================================

func _handle_interact(peer_id: int, data: Dictionary) -> void:
	var interact_type: String = data.get("interact_type", "")

	match interact_type:
		"pickup":
			_handle_pickup(peer_id, data)
		"use":
			# 使用手中的物品
			pass
		_:
			pass

	var pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_RESULT, {
		"action": NetworkPacket.ActionType.INTERACT,
		"result": {"ok": true}
	})
	_server.send_to(peer_id, pkt)

func _handle_build(peer_id: int, data: Dictionary) -> void:
	# 建造：玩家声称用某些材料+连接方式做了一个物品
	# 服务端验证物理可行性
	var parts: Array = data.get("parts", [])
	var connections: Array = data.get("connections", [])

	# Phase 1 简化：假设请求合法，记录结果
	var result := {"action": "build", "parts_count": parts.size(), "connections_count": connections.size()}

	var pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_RESULT, {
		"action": NetworkPacket.ActionType.BUILD,
		"result": result
	})
	_server.send_to(peer_id, pkt)

	var pos := _get_player_position(peer_id)
	_server.broadcast_nearby_except(pkt, pos, peer_id)

func _handle_equip(peer_id: int, data: Dictionary) -> void:
	var player: Dictionary = _player_data.get(peer_id)
	if not player:
		return
	var item_id: String = data.get("item_id", "")
	var slot: String = data.get("slot", "weapon")
	player["equipped"][slot] = item_id

	var pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_RESULT, {
		"action": NetworkPacket.ActionType.EQUIP,
		"result": {"slot": slot, "item": item_id}
	})
	_server.send_to(peer_id, pkt)

func _handle_unequip(peer_id: int, data: Dictionary) -> void:
	var player: Dictionary = _player_data.get(peer_id)
	if not player:
		return
	var slot: String = data.get("slot", "weapon")
	player["equipped"].erase(slot)

	var pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_RESULT, {
		"action": NetworkPacket.ActionType.UNEQUIP,
		"result": {"slot": slot}
	})
	_server.send_to(peer_id, pkt)

func _handle_drop(peer_id: int, data: Dictionary) -> void:
	# 丢弃物品：物品从玩家背包移除，加入世界
	var item_id: String = data.get("item_id", "")
	var pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_RESULT, {
		"action": NetworkPacket.ActionType.DROP,
		"result": {"item": item_id}
	})
	_server.send_to(peer_id, pkt)
	var pos := _get_player_position(peer_id)
	_server.broadcast_nearby_except(pkt, pos, peer_id)

func _handle_pickup(peer_id: int, data: Dictionary) -> void:
	# 捡起物品
	var item_id: String = data.get("item_id", "")
	var pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_RESULT, {
		"action": NetworkPacket.ActionType.PICKUP,
		"result": {"item": item_id}
	})
	_server.send_to(peer_id, pkt)

func _handle_eat(peer_id: int, data: Dictionary) -> void:
	# 吃东西：恢复饥饿值，可能中毒（取决于食物的毒性）
	var food_id: String = data.get("food_id", "")
	var food := MaterialDB.get_material(food_id)
	var result := {"action": "eat", "food": food_id, "restored": 0.0, "poisoned": false}

	if food:
		var edibility: float = food.edibility_human
		var restored: float = 30.0 * edibility
		result["restored"] = restored
		if food.toxicity > 0.2:
			result["poisoned"] = true

	var pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_RESULT, {
		"action": NetworkPacket.ActionType.EAT,
		"result": result
	})
	_server.send_to(peer_id, pkt)

func _handle_drink(peer_id: int, data: Dictionary) -> void:
	var liquid_id: String = data.get("liquid_id", "water")
	var liquid := MaterialDB.get_material(liquid_id)
	var result := {"action": "drink", "liquid": liquid_id, "restored": 0.0}

	if liquid and liquid.phase == "liquid":
		result["restored"] = 40.0

	var pkt := NetworkPacket.encode(NetworkPacket.Type.ACTION_RESULT, {
		"action": NetworkPacket.ActionType.DRINK,
		"result": result
	})
	_server.send_to(peer_id, pkt)

# ============================================================
# 辅助
# ============================================================

func _get_player_position(peer_id: int) -> Vector3:
	if _player_data.has(peer_id):
		return _player_data[peer_id].get("position", Vector3.ZERO)
	return Vector3.ZERO

func _vec_from_dict(d: Dictionary) -> Vector3:
	return Vector3(d.get("x", 0.0), d.get("y", 0.0), d.get("z", 0.0))
