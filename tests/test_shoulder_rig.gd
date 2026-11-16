# ============================================================
# test_shoulder_rig.gd — 肩部双铰链电机权限回归
# ============================================================
# 运行：godot --headless --path . scenes/test_shoulder_rig.tscn
#
# 静态锚点 → 横滚中间体（铰链轴 X）→ 上臂（铰链轴 Z）。
# Jolt 的 HingeJoint3D 电机冲量上限会按另一端刚体的转动惯量缩放：
# 中间体如果只是颗 0.02 m 的小球（惯量 ~4e-5），肩部电机几乎使不出
# 力矩，大臂永远抬不起来。这里把中间体设成控制器里的真实配置
# （惯量 0.05），要求 Z 轴电机把上臂抬过 60°。
# ============================================================
extends Node

var _anchor: StaticBody3D
var _roll: RigidBody3D
var _upper: RigidBody3D
var _j_z: HingeJoint3D
var _frames := 0
var _ref_local_a: Vector3
var _ref_local_b: Vector3
var _axis_local_a: Vector3


func _ready() -> void:
	_anchor = StaticBody3D.new()
	_anchor.collision_layer = 0
	_anchor.collision_mask = 0
	add_child(_anchor)
	_anchor.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)

	_roll = _body(0.1)
	# 控制器里的肩部横滚体：小球质量 + 与上臂同量级的惯量
	_roll.inertia = Vector3(0.05, 0.05, 0.05)
	_upper = _body(2.0)
	# 质心居中：刚体原点就是质心，关节在刚体上方 0.28 m（与真实上臂一致）
	_upper.global_position = Vector3(0.0, -0.28, 0.0)

	_hinge(_anchor, _roll, Vector3.RIGHT)
	_j_z = _hinge(_roll, _upper, Vector3.BACK)
	print("built: roll inertia=0.05, upper CoM 0.28 m below joint")


func _body(mass: float) -> RigidBody3D:
	var rb := RigidBody3D.new()
	rb.mass = mass
	rb.gravity_scale = 0.0
	rb.can_sleep = false
	rb.collision_layer = 0
	rb.collision_mask = 0
	var col := CollisionShape3D.new()
	var sh := SphereShape3D.new()
	sh.radius = 0.02
	col.shape = sh
	rb.add_child(col)
	add_child(rb)
	rb.global_transform = Transform3D(Basis.IDENTITY, Vector3.ZERO)
	return rb


func _hinge(a: PhysicsBody3D, b: PhysicsBody3D, axis: Vector3) -> HingeJoint3D:
	var joint := HingeJoint3D.new()
	add_child(joint)
	var z := -axis
	var x := z.cross(Vector3.UP)
	if x.length() < 0.01:
		x = z.cross(Vector3.RIGHT)
	x = x.normalized()
	var y := z.cross(x).normalized()
	joint.global_transform = Transform3D(Basis(x, y, z), Vector3.ZERO)
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b)
	joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(-30))
	joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(150))
	# 与控制器建关节时一致：先开电机，参数全 0，之后每帧再改
	joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)
	if axis == Vector3.BACK:
		var a_basis := a.global_transform.basis.orthonormalized()
		var b_basis := b.global_transform.basis.orthonormalized()
		_axis_local_a = a_basis.inverse() * axis
		_ref_local_a = a_basis.inverse() * x
		_ref_local_b = b_basis.inverse() * x
	return joint


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames > 1:
		_j_z.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 1.8)
		_j_z.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 6.0)
	if _frames % 30 == 0 or _frames == 150:
		print("f=%d angle=%.1f°" % [_frames, rad_to_deg(_angle())])
	if _frames >= 150:
		var deg := rad_to_deg(_angle())
		print("=== Shoulder Rig: %s (%.1f°) ===" %
			["PASS" if absf(deg) > 60.0 else "FAIL", deg])
		get_tree().quit(0)


func _angle() -> float:
	var axis: Vector3 = (_roll.global_transform.basis * _axis_local_a).normalized()
	var va: Vector3 = (_roll.global_transform.basis * _ref_local_a).normalized()
	var vb: Vector3 = (_upper.global_transform.basis * _ref_local_b).normalized()
	return atan2(axis.dot(va.cross(vb)), va.dot(vb))
