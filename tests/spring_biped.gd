# 自定义弹簧约束站立诊断：不用 Godot 关节，躯干和脚之间用
# 6DOF 弹簧-阻尼约束连接，验证重躯干/轻脚能否靠自定义约束站住。
extends Node3D

const FRAMES := 600
var _body: RigidBody3D
var _feet: Array = []
var _foot_local: Array = []
var _frames := 0
var _min_y := INF


func _ready() -> void:
	Engine.physics_ticks_per_second = 120
	_build_floor()
	_build_body()
	_build_foot(-0.12)
	_build_foot(0.12)


func _build_floor() -> void:
	var fb := StaticBody3D.new()
	fb.collision_layer = 2
	fb.collision_mask = 4
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(12.0, 0.2, 12.0)
	col.shape = box
	fb.add_child(col)
	fb.position = Vector3(0.0, -0.1, 0.0)
	add_child(fb)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.6, 3.0)
	cam.look_at_from_position(Vector3(0.0, 1.6, 3.0), Vector3(0.0, 1.0, 0.0))
	add_child(cam)


func _build_body() -> void:
	_body = RigidBody3D.new()
	_body.mass = 49.0
	_body.can_sleep = false
	_body.continuous_cd = true
	_body.collision_layer = 4
	_body.collision_mask = 0
	_body.linear_damp = 0.4
	_body.angular_damp = 0.8
	var mat := PhysicsMaterial.new()
	mat.friction = 0.9
	mat.bounce = 0.0
	_body.physics_material_override = mat
	_add_box(Vector3(0.30, 0.55, 0.22), Vector3(0.0, 1.17, 0.0))
	_add_box(Vector3(0.14, 0.42, 0.16), Vector3(-0.12, 0.71, 0.0))
	_add_box(Vector3(0.14, 0.42, 0.16), Vector3(0.12, 0.71, 0.0))
	add_child(_body)
	_body.global_position = Vector3.ZERO


func _add_box(size: Vector3, offset: Vector3) -> void:
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	col.position = offset
	_body.add_child(col)


func _build_foot(x: float) -> void:
	var foot: RigidBody3D = preload(
		"res://scripts/client/contact_force_probe.gd").new()
	foot.mass = 1.2
	foot.can_sleep = false
	foot.continuous_cd = true
	foot.collision_layer = 4
	foot.collision_mask = 2
	foot.linear_damp = 0.4
	foot.angular_damp = 0.8
	var mat := PhysicsMaterial.new()
	mat.friction = 0.9
	mat.bounce = 0.0
	foot.physics_material_override = mat
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(0.12, 0.08, 0.28)
	col.shape = box
	foot.add_child(col)
	add_child(foot)
	foot.global_position = Vector3(x, 0.04, -0.05)
	_feet.append(foot)
	# 脚中心相对躯干原点的局部位置
	_foot_local.append(Vector3(x, 0.04, -0.05))


func _physics_process(delta: float) -> void:
	_frames += 1
	var dt := get_physics_process_delta_time()
	for i in range(_feet.size()):
		var foot: RigidBody3D = _feet[i]
		var target: Vector3 = _body.global_transform * (_foot_local[i] as Vector3)
		var err: Vector3 = target - foot.global_position
		var vrel: Vector3 = foot.linear_velocity - _body.linear_velocity
		# 位置弹簧 + 阻尼
		var force: Vector3 = err * 40000.0 - vrel * 900.0
		force = force.limit_length(4000.0)
		foot.apply_central_force(force)
		_body.apply_central_force(-force)
		# 姿态弹簧：脚跟随躯干朝向
		var q_err: Quaternion = _body.global_transform.basis.get_rotation_quaternion() \
			* foot.global_transform.basis.get_rotation_quaternion().inverse()
		var angle := q_err.get_angle()
		var axis := q_err.get_axis()
		if angle > PI:
			angle -= TAU
			axis = -axis
		var wrel: Vector3 = foot.angular_velocity - _body.angular_velocity
		var torque: Vector3 = axis * (angle * 8000.0) - wrel * 300.0
		torque = torque.limit_length(2000.0)
		foot.apply_torque(torque)
		_body.apply_torque(-torque)
	if _frames % 30 == 0:
		var up: Vector3 = _body.global_transform.basis.y.normalized()
		print("  f%d y=%.3f pitch=%.1f° roll=%.1f° feet=(%.3f,%.3f)" % [
			_frames, _body.global_position.y,
			rad_to_deg(atan2(up.z, up.y)),
			rad_to_deg(atan2(up.x, up.y)),
			_feet[0].global_position.y, _feet[1].global_position.y])
	if _frames >= FRAMES:
		var up := _body.global_transform.basis.y.normalized()
		print("=== Spring Biped: %s ===" % (
			"PASS" if up.dot(Vector3.UP) > 0.8 and _body.global_position.y > -0.2
			else "FAIL"))
		get_tree().quit(0)
