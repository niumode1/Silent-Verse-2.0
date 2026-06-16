# ============================================================
# InputHandler — 客户端输入采集与预处理
# ============================================================
# 职责：将玩家键盘/鼠标输入转换为动作请求，发送给服务端。
# 配合 Prediction 模块做客户端预测 → 服务器校正的循环。
# ============================================================
class_name InputHandler
extends Node

## 引用 ENetClient
var _client: ENetClient = null

## 移动输入向量
var move_input: Vector3 = Vector3.ZERO

## 朝向（鼠标看向的方向）
var look_direction: Vector3 = Vector3.FORWARD

## 挥击输入（左键按下瞬间）
var is_swinging: bool = false

## 交互输入（E 键按下瞬间）
var is_interacting: bool = false

## 上次发送时间（用于限流）
var _last_send_time: float = 0.0

## 发送间隔 s（网络 tick rate）
@export var send_interval: float = 0.05  # 20Hz

## 待发送的动作队列
var _pending_actions: Array = []

# ============================================================
# 初始化
# ============================================================

func setup(client: ENetClient) -> void:
	_client = client

# ============================================================
# 输入采集
# ============================================================

func _process(_delta: float) -> void:
	if not _client or not _client.is_connected:
		return

	# 移动输入
	var raw_move: Vector2 = Input.get_vector("move_left", "move_right", "move_forward", "move_backward")
	move_input = Vector3(raw_move.x, 0.0, raw_move.y).normalized()

	# 蹲伏减速
	if Input.is_action_pressed("crouch"):
		move_input *= 0.5

	# 冲刺加速
	if Input.is_action_pressed("sprint"):
		move_input *= 1.5

	# 挥击（左键）
	if Input.is_action_just_pressed("primary_action"):
		is_swinging = true
		_queue_action(NetworkPacket.ActionType.SWING, {
			"angular_velocity": 12.0,
			"lever_arm": 0.8,
			"hit_position": {"x": 0, "y": 0, "z": 2.0}
		})

	# 交互（E 键）
	if Input.is_action_just_pressed("interact"):
		is_interacting = true
		_queue_action(NetworkPacket.ActionType.INTERACT, {
			"interact_type": "use"
		})

	# 背包（Tab）
	if Input.is_action_just_pressed("inventory"):
		# 客户端本地切换背包 UI
		pass

	# 仅当有动作或实际移动时才发送（避免刷屏）
	if _pending_actions.size() == 0 and move_input.length() < 0.01:
		return
	var now: float = Time.get_unix_time_from_system()
	if now - _last_send_time >= send_interval:
		_send_batch()
		_last_send_time = now

# ============================================================
# 发送
# ============================================================

func _queue_action(action_type: int, data: Dictionary) -> void:
	_pending_actions.append({"type": action_type, "data": data})

func _send_batch() -> void:
	# 发送移动+朝向（即使没有动作也要送位置）
	var actions_data: Array = []
	for act in _pending_actions:
		actions_data.append(act)
	_pending_actions.clear()

	_client.send_player_input(move_input, look_direction, actions_data)

	# 如果有重要动作，单独再发一次确保送达
	for act in actions_data:
		_client.send_action_request(act["type"], act["data"])

# ============================================================
# 鼠标控制
# ============================================================

func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		# 鼠标移动更新朝向
		var mouse_delta: Vector2 = event.relative
		# 简单处理：水平转动影响 Y 轴旋转
		look_direction = look_direction.rotated(Vector3.UP, -mouse_delta.x * 0.002)
		look_direction = look_direction.normalized()
