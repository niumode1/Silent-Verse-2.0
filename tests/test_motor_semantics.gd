# ============================================================
# test_motor_semantics.gd — HingeJoint3D 电机参数语义（Jolt）
# ============================================================
# 2 kg 手臂挂在原点的铰链上，质心在 -0.28 m（重力力矩约 5.5 N·m）。
# 电机目标 90°，PARAM_MOTOR_MAX_IMPULSE = 0.5。
#   - 如果它被当作「冲量」：0.5 / dt ≈ 30 N·m → 能抬到 90° 并撑住
#   - 如果它被当作「力矩」：0.5 N·m < 5.5 N·m → 抬不起来
# ============================================================
extends Node

var _arm: RigidBody3D
var _joint: HingeJoint3D
var _frames := 0


func _ready() -> void:
	var anchor := StaticBody3D.new()
	anchor.collision_layer = 0
	anchor.collision_mask = 0
	add_child(anchor)

	_arm = RigidBody3D.new()
	_arm.mass = 2.0
	_arm.can_sleep = false
	_arm.collision_layer = 0
	_arm.collision_mask = 0
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.05
	col.shape = sh
	col.position = Vector3(0.0, -0.28, 0.0)
	_arm.add_child(col)
	add_child(_arm)
	_arm.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)

	_joint = HingeJoint3D.new()
	add_child(_joint)
	# 绕 +Z（前方）旋转 = 把下垂的手臂向侧面抬起
	_joint.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	_joint.node_a = _joint.get_path_to(anchor)
	_joint.node_b = _joint.get_path_to(_arm)
	_joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	_joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(-160.0))
	_joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(160.0))
	_joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	_joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.5)
	_joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 6.0)
	print("motor max=0.5, gravity moment≈%.2f N·m" % (2.0 * 9.81 * 0.28))


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames == 120:
		_joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
	if _frames % 30 == 0:
		var dir: Vector3 = _arm.global_transform.basis * Vector3(0.0, -1.0, 0.0)
		var angle := rad_to_deg(atan2(-dir.y, dir.x))
		print("f=%d arm dir=%s angle_from_down=%.1f° ω=%.2f" % [
			_frames, str(dir), angle, _arm.angular_velocity.length()])
	if _frames >= 240:
		var dir: Vector3 = _arm.global_transform.basis * Vector3(0.0, -1.0, 0.0)
		var raised: bool = absf(dir.x) > 0.7
		print("=== Motor 0.5 抬起了 5.5 N·m 的手臂：%s (dir %s) ===" %
			["是 → max_impulse 按单步冲量用" if raised else "否", str(dir)])
		get_tree().quit(0)
