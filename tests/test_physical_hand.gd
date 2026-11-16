# ============================================================
# test_physical_hand.gd — 物理手指稳定性隔离测试
# ============================================================
# 运行：godot --headless --path . scenes/test_physical_hand.tscn
#
# 目的：在玩家角色之外单独验证「手掌 + 3 节指骨 + 铰链」在 Jolt 下
# 能否稳定保持形状、正常弯曲，不飞散、不抖动。
#
# 背景（回归用例）：Joint3D 必须「先设 global_transform，再连
# node_a/node_b」。顺序反了时关节会按原点的错误框架建立，指骨会
# 像没有关节一样自由下落——这正是此前物理手原型被禁用的原因。
#
# 测试分三阶段：
#   1. 静置 60 物理帧
#   2. 24 帧内把手指从 0° 合到 30°
#   3. 保持 120 帧
# 校验：
#   - 无 NaN
#   - 任一指骨到手掌中心距离 < 0.25 m
#   - 最大线速度 < 20 m/s
#   - 手指确实合拢（指尖低于手掌平面）
# ============================================================
extends Node

const SEG_LENGTHS := [0.035, 0.025, 0.02]
const SEG_MASS := 0.02
const PALM_SIZE := Vector3(0.10, 0.035, 0.11)
## 手指根节点位于手掌前缘（与视觉骨架 _build_fingers_on_hand 一致）
const FINGER_BASE_Z := -0.055
const FRAMES_IDLE := 60
const FRAMES_CLOSE := 24
const FRAMES_HOLD := 120

var _palm: StaticBody3D = null
var _segments: Array = []
var _joints: Array = []
var _frame := 0
var _max_speed := 0.0
var _max_distance := 0.0
var _nan_detected := false
var _finished := false

func _ready() -> void:
	print("=== Physical Finger Stability Test ===")
	_build_finger()
	print("Built palm + 3 finger segments + 3 hinge joints")

func _build_finger() -> void:
	_palm = StaticBody3D.new()
	_palm.name = "Palm"
	_palm.collision_layer = 4
	_palm.collision_mask = 1
	var palm_mat := PhysicsMaterial.new()
	palm_mat.friction = 0.9
	palm_mat.bounce = 0.0
	_palm.physics_material_override = palm_mat
	var palm_col := CollisionShape3D.new()
	var palm_shape := BoxShape3D.new()
	palm_shape.size = PALM_SIZE
	palm_col.shape = palm_shape
	_palm.add_child(palm_col)
	add_child(_palm)

	for j in range(3):
		var seg := RigidBody3D.new()
		seg.name = "FingerSegment%d" % j
		seg.mass = SEG_MASS
		seg.gravity_scale = 0.0
		seg.collision_layer = 4
		seg.collision_mask = 1
		seg.linear_damp = 0.15
		seg.angular_damp = 0.35
		seg.continuous_cd = true
		var mat := PhysicsMaterial.new()
		mat.friction = 0.9
		mat.bounce = 0.0
		seg.physics_material_override = mat
		add_child(seg)

		var length: float = SEG_LENGTHS[j]
		var center_z := FINGER_BASE_Z - _offset_before(j) - length * 0.5
		seg.global_transform = Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, center_z))

		var mi := MeshInstance3D.new()
		var cap := CapsuleMesh.new()
		cap.radius = 0.009
		cap.height = length
		mi.mesh = cap
		mi.rotation.x = PI * 0.5
		seg.add_child(mi)

		var col := CollisionShape3D.new()
		var shape := CapsuleShape3D.new()
		shape.radius = 0.009
		shape.height = maxf(length - 0.004, 0.004)
		col.shape = shape
		col.rotation.x = PI * 0.5
		seg.add_child(col)
		_segments.append(seg)

	for j in range(3):
		var joint := HingeJoint3D.new()
		add_child(joint)
		var parent_body: Node3D = _palm if j == 0 else _segments[j - 1]
		var seg: RigidBody3D = _segments[j]

		var joint_pos := Vector3(0.0, 0.0, FINGER_BASE_Z - _offset_before(j))
		# 铰链轴 = 全局 X（手指朝 -Z，绕 X 弯曲）
		var z := Vector3.RIGHT
		var x := z.cross(Vector3.UP).normalized()
		var y := z.cross(x).normalized()
		# 顺序：先设关节框架与参数，再连节点
		joint.global_transform = Transform3D(Basis(x, y, z), joint_pos)
		joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
		joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, 0.0)
		joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(30.0))
		joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
		joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
		joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.2)
		joint.node_a = joint.get_path_to(parent_body)
		joint.node_b = joint.get_path_to(seg)
		_joints.append(joint)

func _offset_before(j: int) -> float:
	var total := 0.0
	for k in range(j):
		total += SEG_LENGTHS[k]
	return total

func _physics_process(_delta: float) -> void:
	if _finished:
		return
	_frame += 1

	if _frame == FRAMES_IDLE:
		for seg in _segments:
			(seg as RigidBody3D).sleeping = false
		for joint in _joints:
			joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(30.0))
			joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 4.0)

	if _frame == FRAMES_IDLE + FRAMES_CLOSE:
		for joint in _joints:
			joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)

	_measure()

	if _frame >= FRAMES_IDLE + FRAMES_CLOSE + FRAMES_HOLD:
		_finished = true
		_report()

func _measure() -> void:
	for seg in _segments:
		var pos: Vector3 = seg.global_position
		if is_nan(pos.x) or is_nan(pos.y) or is_nan(pos.z):
			_nan_detected = true
			return
		_max_distance = maxf(_max_distance, pos.length())
		var speed: float = (seg as RigidBody3D).linear_velocity.length()
		_max_speed = maxf(_max_speed, speed)

func _report() -> void:
	var passed := 0
	var failed := 0

	print("\n--- Report ---")
	print("Frames: ", _frame)
	print("Max distance from palm: %.4f m" % _max_distance)
	print("Max linear speed: %.3f m/s" % _max_speed)

	if not _nan_detected:
		passed += 1
		print("PASS: no NaN")
	else:
		failed += 1
		printerr("FAIL: NaN detected")

	if _max_distance < 0.25:
		passed += 1
		print("PASS: segments stayed near palm (< 0.25 m)")
	else:
		failed += 1
		printerr("FAIL: segments escaped palm (< 0.25 m required, got %.3f m)" % _max_distance)

	if _max_speed < 20.0:
		passed += 1
		print("PASS: speed bounded (< 20 m/s)")
	else:
		failed += 1
		printerr("FAIL: segments accelerated away (%.3f m/s)" % _max_speed)

	var tip: RigidBody3D = _segments[2]
	if tip.global_position.y < -0.02:
		passed += 1
		print("PASS: finger actually curled (tip y=%.3f m)" % tip.global_position.y)
	else:
		failed += 1
		printerr("FAIL: finger did not curl, hinge may be inert (tip y=%.3f m)"
			% tip.global_position.y)

	print("\n=== Results: ", passed, "/", passed + failed, " passed, ", failed, " failed ===")
	if OS.has_feature("headless"):
		get_tree().quit(1 if failed > 0 else 0)
