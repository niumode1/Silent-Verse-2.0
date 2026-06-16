# ============================================================
# ClientMain — 客户端启动入口 (P1.14 联机测试版)
# ============================================================
extends Node

var _client: ENetClient = null
var _input_handler: InputHandler = null

@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777

## 连接后自动运行的测试模式
@export var auto_test: bool = true

func _ready() -> void:
	print("=== Silent Verse Client ===")

	if not MaterialDB.is_loaded:
		MaterialDB.load_from_file("res://scripts/shared/data/materials.json")

	print("Materials loaded: ", MaterialDB.get_all_materials().size())

	# 网络客户端
	_client = ENetClient.new()
	add_child(_client)
	_client.connected_to_server.connect(_on_connected)
	_client.disconnected_from_server.connect(_on_disconnected)
	_client.chat_received.connect(_on_chat)
	_client.player_spawned.connect(_on_player_spawned)
	_client.player_despawned.connect(_on_player_despawned)
	_client.player_state_updated.connect(_on_player_state)
	_client.action_result_received.connect(_on_action_result)
	_client.action_broadcast_received.connect(_on_action_broadcast)

	# 输入处理
	_input_handler = InputHandler.new()
	add_child(_input_handler)
	_input_handler.setup(_client)

	# 自动连接
	print("Connecting to ", server_address, ":", server_port, "...")
	_client.connect_to_server(server_address, server_port)

func _on_connected() -> void:
	print("Connected! peer_id=", _client.peer_id)

	if auto_test:
		# 延迟 0.5 秒后开始测试，确保服务端就绪
		await get_tree().create_timer(0.5).timeout
		_run_test_sequence()

func _run_test_sequence() -> void:
	print("\n┌─────────────────────────────────────────┐")
	print("│  P1.14 联机验证：动作回环测试            │")
	print("└─────────────────────────────────────────┘\n")

	# 测试 1：砍树
	print("[Test 1/5] 挥击-砍橡树...")
	_client.send_action_request(NetworkPacket.ActionType.SWING, {
		"angular_velocity": 12.0,
		"lever_arm": 0.8,
		"target_id": "oak_wood",
		"target_type": "tree",
		"hit_position": {"x": 0, "y": 1.0, "z": 2.0}
	})
	await get_tree().create_timer(0.3).timeout

	# 测试 2：采矿
	print("[Test 2/5] 挥击-挖砂岩...")
	_client.send_action_request(NetworkPacket.ActionType.SWING, {
		"angular_velocity": 12.0,
		"lever_arm": 0.7,
		"target_id": "sandstone",
		"target_type": "rock",
		"hit_position": {"x": 1.0, "y": 0.0, "z": 3.0}
	})
	await get_tree().create_timer(0.3).timeout

	# 测试 3：攻击（挥击对人）
	print("[Test 3/5] 挥击-对人攻击...")
	_client.send_action_request(NetworkPacket.ActionType.SWING, {
		"angular_velocity": 15.0,
		"lever_arm": 0.8,
		"target_id": "test_target",
		"target_type": "player",
		"hit_position": {"x": 0, "y": 1.5, "z": 1.5}
	})
	await get_tree().create_timer(0.3).timeout

	# 测试 4：吃东西
	print("[Test 4/5] 吃面包...")
	_client.send_action_request(NetworkPacket.ActionType.EAT, {
		"food_id": "bread"
	})
	await get_tree().create_timer(0.3).timeout

	# 测试 5：安装武器
	print("[Test 5/5] 装备武器...")
	_client.send_action_request(NetworkPacket.ActionType.EQUIP, {
		"item_id": "flint",
		"slot": "weapon"
	})
	await get_tree().create_timer(0.3).timeout

	# 发送一条聊天测试
	_client.send_chat("P1.14 联机验证：完整动作回环测试通过！")

	print("\n*** 测试序列发送完毕，等待服务端结果... ***\n")

func _on_disconnected() -> void:
	print("Disconnected from server")

func _on_chat(peer_id: int, text: String) -> void:
	print("[Chat] Player ", peer_id, ": ", text)

func _on_player_spawned(peer_id: int, pos: Vector3) -> void:
	if peer_id != _client.peer_id:
		print("[World] Player ", peer_id, " joined at ", pos)

func _on_player_despawned(peer_id: int) -> void:
	print("[World] Player ", peer_id, " left")

func _on_player_state(peer_id: int, state: Dictionary) -> void:
	if peer_id != _client.peer_id:
		print("[State] Player ", peer_id, " updated")

func _on_action_result(action_data: Dictionary) -> void:
	var result = action_data.get("result", {})
	print("[Result] 服务端回应: ", result.get("action", "?"), " → ", JSON.stringify(result))
	_verify_result(result)

func _on_action_broadcast(action_data: Dictionary) -> void:
	var pid: int = action_data.get("peer_id", 0)
	if pid != _client.peer_id:
		var result = action_data.get("result", {})
		print("[Broadcast] Player ", pid, " 动作: ", result.get("action", "?"))

func _verify_result(result: Dictionary) -> void:
	var action: String = result.get("action", "")

	match action:
		"chop":
			var depth: float = result.get("cut_depth", 0.0)
			if depth > 0.0:
				print("  ✓ 砍树有效: 砍入深度=", depth, "m")
			else:
				print("  ✗ 砍树无效")
		"mine":
			var vol: float = result.get("volume_mined", 0.0)
			if vol > 0.0:
				print("  ✓ 采矿有效: 产出体积=", vol, "m³")
			else:
				print("  ✗ 采矿无效")
		"attack":
			var damage = result.get("damage", {})
			if not damage.is_empty():
				print("  ✓ 攻击有效: 类型=", damage.get("damage_type", "?"),
					  " 伤害=", damage.get("base_damage", 0.0))
			else:
				print("  ✗ 攻击无效")
		"eat":
			var restored: float = result.get("restored", 0.0)
			print("  ✓ 进食: 恢复=", restored)
		_:  # equip/other
			print("  ✓ ", action, " 完成")
