# ============================================================
# test_self_collision.gd — 玩家自身碰撞层回归测试
# ============================================================
# 运行：godot --headless --path . scenes/test_self_collision.tscn
#
# 玩家身体在 layer 8（位值 128），手脚在 layer 4（位值 8）。
# Jolt 的碰撞过滤是双向的：只有双方 mask 都包含对方 layer 才会
# 产生接触。少配一边就会出现「手穿进身体」的假物理。
# 本测试让一只「手」落到「躯干」上，验证它没有穿过去。
# ============================================================
extends Node

var _hand: RigidBody3D = null
var _frames := 0


func _ready() -> void:
	# 躯干：layer 8，mask 包含 layer 4（位值 8）
	var torso := StaticBody3D.new()
	torso.name = "Torso"
	torso.collision_layer = 128   # layer 8
	torso.collision_mask = 8      # layer 4
	var torso_col := CollisionShape3D.new()
	var torso_shape := BoxShape3D.new()
	torso_shape.size = Vector3(0.44, 0.6, 0.30)
	torso_col.shape = torso_shape
	torso.add_child(torso_col)
	add_child(torso)
	torso.global_position = Vector3(0.0, 0.3, 0.0)

	# 手：layer 4，mask 包含 layer 8（位值 128）
	_hand = RigidBody3D.new()
	_hand.name = "Hand"
	_hand.collision_layer = 8     # layer 4
	_hand.collision_mask = 128    # layer 8
	var hand_col := CollisionShape3D.new()
	var hand_shape := BoxShape3D.new()
	hand_shape.size = Vector3(0.09, 0.09, 0.09)
	hand_col.shape = hand_shape
	_hand.add_child(hand_col)
	add_child(_hand)
	_hand.global_position = Vector3(0.0, 1.2, 0.0)


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames != 120:
		return
	var y: float = _hand.global_position.y
	# 躯干顶面在 y=0.6；手没穿过去就应该停在 0.65 左右
	var ok: bool = y > 0.5
	print("hand_y=%.3f (torso top=0.600)" % y)
	print("=== Self Collision: %s ===" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
