# ============================================================
# physical_biped_stand.gd — 全物理下肢站立原型（M8 阶段 1）
# ============================================================
# 独立场景：平地 + 一个物理躯干 + 左右大腿/小腿/脚。
# 不使用 CharacterBody、不瞬移任何刚体；站立只靠关节马达/限位
# 和脚底接触。10 s 后报告是否站住。
#
# 运行：godot --headless --path . scenes/physical_biped_stand.tscn
# ============================================================
extends Node3D

const TORSO_MASS := 28.0
const THIGH_MASS := 7.0
const SHIN_MASS := 4.0
const FOOT_MASS := 1.2
const HIP_Y := 0.92
const THIGH_LEN := 0.42
const KNEE_Y := 0.50
const SHIN_LEN := 0.42
const ANKLE_Y := 0.08
const LEG_X := 0.12

const FRAMES := 600

var _player_body: PlayerBody = null
var _torso: RigidBody3D = null
var _legs: Array = []          # [{thigh, shin, foot, joints}]
var _joints: Array = []        # [{joint, torque}]
var _frames := 0
var _failed := false
var _max_abs_y := 0.0
var _min_y := INF


func _ready() -> void:
	_player_body = PlayerBody.new()
	_player_body.roll_innate_traits()
	_build_floor()
	_build_torso()
	_build_leg(-1.0)
	_build_leg(1.0)
	print("[Biped] body built, strength=%.0f N" % _player_body.current_strength)


func _make_body(label: String, mass: float, size: Vector3,
		pos: Vector3) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.name = label
	body.mass = mass
	body.gravity_scale = 1.0
	body.can_sleep = false
	body.continuous_cd = true
	body.collision_layer = 4
	# 阶段 1 只和地面碰撞；自碰撞留给后续阶段，先避免关节处互顶。
	body.collision_mask = 2
	body.linear_damp = 0.2
	body.angular_damp = 0.4
	var mat := PhysicsMaterial.new()
	mat.friction = 0.9
	mat.bounce = 0.0
	body.physics_material_override = mat
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = size
	col.shape = box
	body.add_child(col)
	add_child(body)
	body.global_position = pos
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	mi.mesh = mesh
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.72, 0.55, 0.42) if mass < 10.0 \
		else Color(0.30, 0.36, 0.42)
	mi.material_override = m
	body.add_child(mi)
	return body


func _build_floor() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = 2
	floor_body.collision_mask = 4
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(12.0, 0.2, 12.0)
	col.shape = box
	floor_body.add_child(col)
	floor_body.position = Vector3(0.0, -0.1, 0.0)
	add_child(floor_body)
	var mi := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(12.0, 0.2, 12.0)
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.25, 0.28, 0.22)
	mi.material_override = mat
	floor_body.add_child(mi)
	var cam := Camera3D.new()
	cam.position = Vector3(0.0, 1.6, 3.0)
	cam.look_at_from_position(Vector3(0.0, 1.6, 3.0), Vector3(0.0, 1.0, 0.0))
	add_child(cam)


func _build_torso() -> void:
	# 阶段 1 把骨盆+胸廓合成一个躯干刚体；脊柱/头在阶段 2 再拆。
	_torso = _make_body("Torso", TORSO_MASS,
		Vector3(0.30, 0.55, 0.22), Vector3(0.0, 1.17, 0.0))


func _build_leg(side: float) -> void:
	var x := side * LEG_X
	var thigh := _make_body("Thigh_%s" % ("L" if side < 0.0 else "R"),
		THIGH_MASS, Vector3(0.14, THIGH_LEN, 0.16),
		Vector3(x, 0.71, 0.0))
	var shin := _make_body("Shin_%s" % ("L" if side < 0.0 else "R"),
		SHIN_MASS, Vector3(0.12, SHIN_LEN, 0.14),
		Vector3(x, 0.29, 0.0))
	var foot := _make_body("Foot_%s" % ("L" if side < 0.0 else "R"),
		FOOT_MASS, Vector3(0.12, 0.08, 0.28),
		Vector3(x, 0.04, -0.05))

	var hip := _make_hinge(_torso, thigh, Vector3(x, HIP_Y, 0.0),
		"hip", deg_to_rad(-80.0), deg_to_rad(35.0))
	var knee := _make_hinge(thigh, shin, Vector3(x, KNEE_Y, 0.0),
		"knee", deg_to_rad(-8.0), deg_to_rad(145.0))
	var ankle := _make_hinge(shin, foot, Vector3(x, ANKLE_Y, 0.0),
		"ankle", deg_to_rad(-30.0), deg_to_rad(30.0))
	_legs.append({
		"thigh": thigh, "shin": shin, "foot": foot,
		"hip": hip, "knee": knee, "ankle": ankle,
	})


func _make_hinge(a: PhysicsBody3D, b: PhysicsBody3D, pos: Vector3,
		muscle: String, lower: float, upper: float) -> HingeJoint3D:
	var joint := HingeJoint3D.new()
	add_child(joint)
	var axis := Vector3.RIGHT
	var z := axis
	var x := z.cross(Vector3.UP)
	if x.length() < 0.01:
		x = z.cross(Vector3.RIGHT)
	x = x.normalized()
	var y := z.cross(x).normalized()
	joint.global_transform = Transform3D(Basis(x, y, z), pos)
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b)
	joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, lower)
	joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, upper)
	joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)
	var torque: float = _player_body.get_joint_max_torque(muscle)
	var a_basis: Basis = a.global_transform.basis.orthonormalized()
	var b_basis: Basis = b.global_transform.basis.orthonormalized()
	var ref := Vector3.UP
	if absf(axis.dot(ref)) > 0.9:
		ref = Vector3.RIGHT
	_joints.append({
		"joint": joint, "torque": torque, "muscle": muscle,
		"a": a, "b": b,
		"axis_local_a": (a_basis.inverse() * axis).normalized(),
		"ref_local_a": (a_basis.inverse() * ref).normalized(),
		"ref_local_b": (b_basis.inverse() * ref).normalized(),
	})
	return joint


func _physics_process(_delta: float) -> void:
	_frames += 1
	var dt := get_physics_process_delta_time()
	# 站立保持：关节马达把角度拉回 0°。力矩仍来自 PlayerBody 的
	# 肌力 × 解剖力臂，不在场景里写死。
	var pitch := 0.0
	var pitch_rate := 0.0
	if _torso != null:
		var up: Vector3 = _torso.global_transform.basis.y.normalized()
		pitch = atan2(up.z, up.y)
		pitch_rate = _torso.angular_velocity.x
	var hip_balance := clampf(-pitch * 1.2 - pitch_rate * 0.25, -0.8, 0.8)
	var ankle_balance := clampf(pitch * 1.8 + pitch_rate * 0.35, -0.5, 0.5)
	for entry in _joints:
		var joint: HingeJoint3D = entry["joint"]
		var a: Node3D = entry["a"]
		var b: Node3D = entry["b"]
		var ab: Basis = a.global_transform.basis.orthonormalized()
		var bb: Basis = b.global_transform.basis.orthonormalized()
		var ax: Vector3 = (ab * (entry["axis_local_a"] as Vector3)).normalized()
		var ra: Vector3 = (ab * (entry["ref_local_a"] as Vector3)).normalized()
		var rb: Vector3 = (bb * (entry["ref_local_b"] as Vector3)).normalized()
		var angle: float = atan2(ax.dot(ra.cross(rb)), ra.dot(rb))
		var torque: float = float(entry["torque"])
		var target := 0.0
		match String(entry["muscle"]):
			"hip":
				target = hip_balance
			"ankle":
				target = ankle_balance
		joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY,
			clampf((angle - target) * 8.0, -6.0, 6.0))
		joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, torque * dt)
		if _frames % 60 == 0:
			print("  f%d %s angle=%.1f° torque=%.0f" % [
				_frames, entry["muscle"], rad_to_deg(angle), torque])

	if _torso != null:
		var p: Vector3 = _torso.global_position
		if is_nan(p.x) or is_nan(p.y) or is_nan(p.z):
			_failed = true
		_min_y = minf(_min_y, p.y)
		_max_abs_y = maxf(_max_abs_y, absf(p.y))

	if _frames % 60 == 0 and _torso != null:
		var e := _torso.global_transform.basis.get_euler()
		print("  f%d torso y=%.3f euler=(%.2f, %.2f, %.2f) pitch=%.1f" % [
			_frames, _torso.global_position.y,
			rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z),
			rad_to_deg(pitch)])
	if _frames >= FRAMES:
		_report()
		get_tree().quit(0)


func _report() -> void:
	var y: float = _torso.global_position.y if _torso != null else 0.0
	var up_dot: float = _torso.global_transform.basis.y.normalized().dot(Vector3.UP) \
		if _torso != null else 0.0
	var ok := not _failed and y > 0.70 and up_dot > 0.80
	print("=== Physical Biped Stand ===")
	print("torso y=%.3f min_y=%.3f up_dot=%.3f nan=%s" % [
		y, _min_y, up_dot, str(_failed)])
	print("=== Physical Biped Stand: %s ===" % ("PASS" if ok else "FAIL"))
