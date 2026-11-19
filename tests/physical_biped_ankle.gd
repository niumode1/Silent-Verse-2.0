# ============================================================
# physical_biped_ankle.gd — 单刚体躯干+腿、双脚踝站立
# ============================================================
# 在“刚性雕像”已经站得住的基础上，把两只脚拆成独立刚体，用踝
# 铰链连接。这样只有两个关节，先验证踝策略；通过后再逐段拆膝/髋。
extends Node3D

const FRAMES := 600
var _body: RigidBody3D
var _feet: Array = []
var _ankles: Array = []
var _frames := 0
var _min_y := INF


func _ready() -> void:
	_build_floor()
	_build_body()
	_build_foot(-0.12)
	_build_foot(0.12)
	print("[AnkleBiped] built")


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
	# 小腿碰撞不在躯干复合体里：脚必须承担全部重量。
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
	var foot: ContactForceProbe = preload(
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

	# 踝的两自由度：body ↔ 小过渡体（内外翻，绕 Z）↔ 脚（屈伸，绕 X）。
	var roll_body := RigidBody3D.new()
	roll_body.mass = 0.1
	roll_body.gravity_scale = 0.0
	roll_body.can_sleep = false
	roll_body.collision_layer = 0
	roll_body.collision_mask = 0
	roll_body.inertia = Vector3(0.01, 0.01, 0.01)
	add_child(roll_body)
	roll_body.global_position = Vector3(x, 0.08, 0.0)

	var roll_joint := _make_hinge(_body, roll_body,
		Vector3(x, 0.08, 0.0), Vector3.BACK)
	var pitch_joint := _make_hinge(roll_body, foot,
		Vector3(x, 0.08, 0.0), Vector3.RIGHT)
	_feet.append(foot)
	_ankles.append({
		"foot": foot, "roll_body": roll_body,
		"roll_joint": roll_joint, "pitch_joint": pitch_joint,
	})


func _make_hinge(a: PhysicsBody3D, b: PhysicsBody3D, pos: Vector3,
		axis: Vector3) -> HingeJoint3D:
	var joint := HingeJoint3D.new()
	add_child(joint)
	var z := axis.normalized()
	var xx := z.cross(Vector3.UP)
	if xx.length() < 0.01:
		xx = z.cross(Vector3.RIGHT)
	xx = xx.normalized()
	var yy := z.cross(xx).normalized()
	joint.global_transform = Transform3D(Basis(xx, yy, z), pos)
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b)
	joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, deg_to_rad(-30.0))
	joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(30.0))
	joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)
	return joint


func _physics_process(_delta: float) -> void:
	_frames += 1
	var dt := get_physics_process_delta_time()
	# 躯干 pitch/roll 的 PD → 踝 pitch/roll 马达目标速度。
	var up: Vector3 = _body.global_transform.basis.y.normalized()
	var pitch: float = atan2(up.z, up.y)
	var roll: float = atan2(up.x, up.y)
	var pitch_rate: float = _body.angular_velocity.x
	var roll_rate: float = _body.angular_velocity.z
	var pitch_cmd: float = clampf(pitch * 12.0 + pitch_rate * 0.8, -6.0, 6.0)
	var roll_cmd: float = clampf(roll * 12.0 + roll_rate * 0.8, -6.0, 6.0)
	for ankle in _ankles:
		var pj: HingeJoint3D = ankle["pitch_joint"]
		var rj: HingeJoint3D = ankle["roll_joint"]
		pj.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, pitch_cmd)
		pj.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 100.0 * dt)
		rj.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, roll_cmd)
		rj.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 60.0 * dt)
	if _frames % 30 == 0:
		print("  f%d y=%.3f pitch=%.1f° roll=%.1f° cmd=(%.1f,%.1f) feet_y=(%.3f,%.3f) N=(%.0f,%.0f)" % [
			_frames, _body.global_position.y, rad_to_deg(pitch),
			rad_to_deg(roll), pitch_cmd, roll_cmd,
			_feet[0].global_position.y, _feet[1].global_position.y,
			_feet[0].contact_force.length(), _feet[1].contact_force.length()])
	if _frames >= FRAMES:
		var up_dot := up.dot(Vector3.UP)
		print("=== Ankle Biped: %s ===" % (
			"PASS" if up_dot > 0.8 and _body.global_position.y > 0.7 else "FAIL"))
		get_tree().quit(0)
