# 自定义弹簧约束的全物理双足：躯干/大腿/小腿/脚全部刚体，
# 不用 Godot 关节，关节由 6DOF 弹簧-阻尼约束实现。
extends Node3D

const FRAMES := 600
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

var _bodies: Array = []
var _links: Array = []
var _feet: Array = []
var _torso: RigidBody3D
var _frames := 0


func _ready() -> void:
	Engine.physics_ticks_per_second = 120
	_build_floor()
	_build_torso()
	_build_leg(-1.0)
	_build_leg(1.0)


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


func _make_body(name: String, mass: float, size: Vector3, pos: Vector3,
		probe: bool = false, collide_floor: bool = false) -> RigidBody3D:
	var body: RigidBody3D = preload(
		"res://scripts/client/contact_force_probe.gd").new() if probe \
		else RigidBody3D.new()
	body.name = name
	body.mass = mass
	body.can_sleep = false
	body.continuous_cd = true
	body.collision_layer = 4
	body.collision_mask = 2 if collide_floor else 0
	body.linear_damp = 0.4
	body.angular_damp = 0.8
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
	_bodies.append(body)
	return body


func _build_torso() -> void:
	_torso = _make_body("Torso", TORSO_MASS, Vector3(0.30, 0.55, 0.22),
		Vector3(0.0, 1.17, 0.0))


func _build_leg(side: float) -> void:
	var x := side * LEG_X
	var thigh := _make_body("Thigh", THIGH_MASS,
		Vector3(0.14, THIGH_LEN, 0.16), Vector3(x, 0.71, 0.0))
	var shin := _make_body("Shin", SHIN_MASS,
		Vector3(0.12, SHIN_LEN, 0.14), Vector3(x, 0.29, 0.0))
	var foot := _make_body("Foot", FOOT_MASS,
		Vector3(0.12, 0.08, 0.28), Vector3(x, 0.04, -0.05), true, true)
	_feet.append(foot)
	# 锚点在各自局部坐标：躯干原点、关节位置
	_add_link(_torso, thigh, Vector3(x, HIP_Y, 0.0),
		Vector3(0.0, THIGH_LEN * 0.5, 0.0))
	_add_link(thigh, shin, Vector3(0.0, -THIGH_LEN * 0.5, 0.0),
		Vector3(0.0, SHIN_LEN * 0.5, 0.0))
	_add_link(shin, foot, Vector3(0.0, -SHIN_LEN * 0.5, 0.0),
		Vector3(0.0, 0.04, 0.0))


func _add_link(a: RigidBody3D, b: RigidBody3D,
		local_a: Vector3, local_b: Vector3) -> void:
	_links.append({"a": a, "b": b, "la": local_a, "lb": local_b})


func _anchor_velocity(body: RigidBody3D, world_point: Vector3) -> Vector3:
	return body.linear_velocity + body.angular_velocity.cross(
		world_point - body.global_position)


func _physics_process(_delta: float) -> void:
	_frames += 1
	for link in _links:
		var a: RigidBody3D = link["a"]
		var b: RigidBody3D = link["b"]
		var pa: Vector3 = a.global_transform * (link["la"] as Vector3)
		var pb: Vector3 = b.global_transform * (link["lb"] as Vector3)
		var va: Vector3 = _anchor_velocity(a, pa)
		var vb: Vector3 = _anchor_velocity(b, pb)
		var force: Vector3 = (pa - pb) * 40000.0 - (vb - va) * 900.0
		force = force.limit_length(12000.0)
		b.apply_force(force, pb - b.global_position)
		a.apply_force(-force, pa - a.global_position)

		# 姿态：目标 = a 的朝向（直立）；站立时所有关节 0°。
		var target_q: Quaternion = a.global_transform.basis.get_rotation_quaternion()
		var q_err: Quaternion = target_q \
			* b.global_transform.basis.get_rotation_quaternion().inverse()
		var ang: float = q_err.get_angle()
		var axis: Vector3 = q_err.get_axis()
		if ang > PI:
			ang -= TAU
			axis = -axis
		var wrel: Vector3 = b.angular_velocity - a.angular_velocity
		var torque: Vector3 = axis * (ang * 20000.0) - wrel * 600.0
		torque = torque.limit_length(6000.0)
		b.apply_torque(torque)
		a.apply_torque(-torque)

	if _frames % 30 == 0:
		var up: Vector3 = _torso.global_transform.basis.y.normalized()
		print("  f%d y=%.3f pitch=%.1f° roll=%.1f° feetN=(%.0f,%.0f)" % [
			_frames, _torso.global_position.y,
			rad_to_deg(atan2(up.z, up.y)),
			rad_to_deg(atan2(up.x, up.y)),
			_feet[0].contact_force.length(), _feet[1].contact_force.length()])
	if _frames >= FRAMES:
		var up := _torso.global_transform.basis.y.normalized()
		print("=== Spring Full Biped: %s ===" % (
			"PASS" if up.dot(Vector3.UP) > 0.8 and _torso.global_position.y > 0.7
			else "FAIL"))
		get_tree().quit(0)
