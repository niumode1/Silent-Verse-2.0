# ============================================================
# rigid_statue_probe.gd — 单刚体“雕像”站立诊断
# ============================================================
# 不是游戏角色：一个 RigidBody3D 带躯干+两条腿+两只脚的复合碰撞体，
# 不加任何控制，只靠地面接触。用来判断“完全刚性的身体在平地上
# 到底能不能站住”。如果这个都倒，问题在接触/重心/脚底支撑，不在
# 关节控制器。
extends Node3D

const FRAMES := 600
var _body: RigidBody3D
var _frames := 0
var _min_y := INF


func _ready() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.collision_layer = 2
	floor_body.collision_mask = 4
	var fc := CollisionShape3D.new()
	var fb := BoxShape3D.new()
	fb.size = Vector3(12.0, 0.2, 12.0)
	fc.shape = fb
	floor_body.add_child(fc)
	floor_body.position = Vector3(0.0, -0.1, 0.0)
	add_child(floor_body)

	_body = RigidBody3D.new()
	_body.mass = 52.0
	_body.can_sleep = false
	_body.continuous_cd = true
	_body.collision_layer = 4
	_body.collision_mask = 2
	_body.linear_damp = 0.4
	_body.angular_damp = 0.8
	var mat := PhysicsMaterial.new()
	mat.friction = 0.9
	mat.bounce = 0.0
	_body.physics_material_override = mat

	# 体节相对身体原点（原点放在脚底中心 y=0.04 附近）
	_add_box(Vector3(0.30, 0.55, 0.22), Vector3(0.0, 1.17, 0.0))  # 躯干
	_add_box(Vector3(0.14, 0.42, 0.16), Vector3(-0.12, 0.71, 0.0))
	_add_box(Vector3(0.14, 0.42, 0.16), Vector3(0.12, 0.71, 0.0))
	_add_box(Vector3(0.12, 0.42, 0.14), Vector3(-0.12, 0.29, 0.0))
	_add_box(Vector3(0.12, 0.42, 0.14), Vector3(0.12, 0.29, 0.0))
	_add_box(Vector3(0.12, 0.08, 0.28), Vector3(-0.12, 0.04, -0.05))
	_add_box(Vector3(0.12, 0.08, 0.28), Vector3(0.12, 0.04, -0.05))
	add_child(_body)
	_body.global_position = Vector3(0.0, 0.0, 0.0)
	# 让脚底刚好贴地：身体原点在 y=0，脚底 box 中心 0.04、高 0.08
	_body.global_position = Vector3(0.0, 0.0, 0.0)


func _add_box(size: Vector3, offset: Vector3) -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	col.position = offset
	_body.add_child(col)


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _body != null:
		_min_y = minf(_min_y, _body.global_position.y)
	if _frames >= FRAMES:
		var up := _body.global_transform.basis.y.normalized().dot(Vector3.UP)
		print("=== Rigid Statue ===")
		print("pos=%s up_dot=%.3f min_y=%.3f" % [
			str(_body.global_position.snapped(Vector3.ONE * 0.01)),
			up, _min_y])
		print("=== Rigid Statue: %s ===" % (
			"PASS" if up > 0.95 and absf(_body.global_position.x) < 0.3
			and absf(_body.global_position.z) < 0.4 else "FAIL"))
		get_tree().quit(0)
