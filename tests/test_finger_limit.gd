# 隔离试验：冲量受限的关节马达出力时，铰链限位还管不管用。
# 手指现在不施加求解器外的外力，全靠 PARAM_MOTOR_MAX_IMPULSE = τ·dt 的
# 马达出力。必须确认限位约束压得住这个力矩，否则手指会转到解剖范围之外，
# 抓握几何整个失效。
extends Node

const ContactForceProbeScript := preload("res://scripts/client/contact_force_probe.gd")

const TORQUE := 1.68
const RAMP := 0.12
const MAX_RATE := 12.0

var _frames := 0
var _seg: RigidBody3D
var _palm: RigidBody3D
var _joint: HingeJoint3D
var _force := 0.0


func _ready() -> void:
	_palm = ContactForceProbeScript.new()
	_palm.mass = 0.4
	_palm.gravity_scale = 0.0
	_palm.can_sleep = false
	_palm.collision_layer = 4
	_palm.collision_mask = 0
	add_child(_palm)
	var pcol := CollisionShape3D.new()
	var pbox := BoxShape3D.new()
	pbox.size = Vector3(0.10, 0.035, 0.11)
	pcol.shape = pbox
	_palm.add_child(pcol)
	_palm.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.9, 0))

	_seg = ContactForceProbeScript.new()
	_seg.mass = 0.02
	_seg.gravity_scale = 0.0
	_seg.can_sleep = false
	_seg.collision_layer = 4
	_seg.collision_mask = 0
	_seg.inertia = Vector3(5e-4, 5e-4, 5e-4)
	add_child(_seg)
	var scol := CollisionShape3D.new()
	var scap := CapsuleShape3D.new()
	scap.radius = 0.009
	scap.height = 0.034
	scol.shape = scap
	scol.rotation.x = PI * 0.5
	_seg.add_child(scol)
	# 指骨中心在枢轴前方 0.017（沿 -Z）
	_seg.global_transform = Transform3D(Basis.IDENTITY, Vector3(0, 1.9, -0.017))

	_joint = HingeJoint3D.new()
	add_child(_joint)
	# 与手指一致：铰链 z 轴 = 手掌的 x 轴（屈伸轴）
	var z := (Basis.IDENTITY * Vector3.RIGHT).normalized()
	var x := z.cross(Vector3.UP).normalized()
	var y := z.cross(x).normalized()
	_joint.global_transform = Transform3D(Basis(x, y, z), Vector3(0, 1.9, 0))
	_joint.node_a = _joint.get_path_to(_palm)
	_joint.node_b = _joint.get_path_to(_seg)
	_joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	# 屈曲是绕铰链轴的负方向，所以解剖范围 [0, 30°] 要写成 [-30°, 0]。
	_joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(-30.0))
	_joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, 0.0)
	_joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	_joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
	_joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)


func _flex() -> float:
	var pa: Basis = _palm.global_transform.basis.orthonormalized()
	var sb: Basis = _seg.global_transform.basis.orthonormalized()
	var axis: Vector3 = pa.x.normalized()
	return -atan2(axis.dot(pa.z.cross(sb.z)), pa.z.dot(sb.z))


func _hinge_angle() -> float:
	# 绕铰链轴（手掌 x 轴）的右手正角，即 Jolt 限位所用的坐标
	var pa: Basis = _palm.global_transform.basis.orthonormalized()
	var sb: Basis = _seg.global_transform.basis.orthonormalized()
	var axis: Vector3 = pa.x.normalized()
	return atan2(axis.dot(pa.z.cross(sb.z)), pa.z.dot(sb.z))


func _physics_process(_delta: float) -> void:
	_frames += 1
	var dt := get_physics_process_delta_time()
	var axis: Vector3 = _palm.global_transform.basis.x.normalized()
	var ramp: float = TORQUE * dt / RAMP
	_force = move_toward(_force, TORQUE, ramp)
	# 复刻手指：只用冲量受限的马达出力（不施加求解器外的外力）
	var m := 1.0 if _frames < 60 else 0.0
	_joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, _force * dt * m)
	_joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, -6.0 * m)
	if _frames % 10 == 0:
		print("  f%d 屈=%6.2f° 铰链角=%6.2f° 扭=%+.0f 力矩=%.2f 角速度=%.1f rad/s 手掌角速度=%.2f" % [
			_frames, rad_to_deg(_flex()), rad_to_deg(_hinge_angle()),
			m, _force,
			(_seg.angular_velocity - _palm.angular_velocity).dot(axis),
			_palm.angular_velocity.length()])
	if _frames < 120:
		return
	var flex := rad_to_deg(_flex())
	print("[Finger Limit] 末角=%.2f° 铰链角=%.2f°（限位 [-30,0]）" % [flex, rad_to_deg(_hinge_angle())])
	get_tree().quit(0)
