# ============================================================
# test_arm_walk.gd — 行走时手臂稳定性诊断
# ============================================================
# 运行：godot --headless --path . scenes/test_arm_walk.tscn
#
# 让玩家持续向前走，记录：
#   - 手臂刚体的角速度（乱晃的直接指标）
#   - 手/臂与玩家自身胶囊的接触力
#   - 肩/肘/腕关节角相对目标的偏差
# ============================================================
extends Node

var _controller: Node = null
var _frames := 0
var _walk_from := 60
var _measure_from := 120
var _end_frame := 420

var _max_angvel := 0.0
var _sum_angvel := 0.0
var _n := 0
var _max_contact := 0.0
var _contact_frames := 0
var _max_joint_err := 0.0
var _speed_max := 0.0
var _turn_from := 180
var _turn_to := 300
var _yaw := 0.0


func _ready() -> void:
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)
	_controller = scene.get_node_or_null("FirstPersonController")
	print("[Walk] controller=", _controller)


func _physics_process(delta: float) -> void:
	_frames += 1
	if _controller == null:
		return
	if _frames == _walk_from:
		Input.action_press("move_forward")
		print("[Walk] start walking")
	# 边走边转视角（90°/s），模拟鼠标看向侧面
	if _frames >= _turn_from and _frames < _turn_to:
		_yaw += deg_to_rad(90.0) * delta
		_controller.set("_yaw", _yaw)

	if _frames < _measure_from:
		return

	var arms: Array = _controller.get("_arm_bodies")
	if arms.is_empty():
		return

	for h in range(arms.size()):
		for key in ["upper", "forearm"]:
			var rb: RigidBody3D = arms[h][key]
			var w: float = rb.angular_velocity.length()
			_max_angvel = maxf(_max_angvel, w)
			_sum_angvel += w
			_n += 1
			var cf: Variant = rb.get("contact_force")
			if cf is Vector3:
				var f: float = (cf as Vector3).length()
				_max_contact = maxf(_max_contact, f)
				if f > 1.0:
					_contact_frames += 1
		var palm: RigidBody3D = _controller.get("_palm_bodies")[h]
		var w2: float = palm.angular_velocity.length()
		_max_angvel = maxf(_max_angvel, w2)
		_sum_angvel += w2
		_n += 1
		var cf2: Variant = palm.get("contact_force")
		if cf2 is Vector3:
			var f2: float = (cf2 as Vector3).length()
			_max_contact = maxf(_max_contact, f2)
			if f2 > 1.0:
				_contact_frames += 1

		# 关节角与目标角的偏差
		var angles: Dictionary = _controller.get("_arm_angles")[h]
		for jd in _controller.get("_arm_joints")[h]:
			var target: float = deg_to_rad(float(angles[jd["key"]]))
			var actual: float = float(_controller.call("_joint_angle", jd))
			_max_joint_err = maxf(_max_joint_err, absf(target - actual))

	_speed_max = maxf(_speed_max, (_controller as CharacterBody3D).velocity.length())

	if _frames >= _end_frame:
		Input.action_release("move_forward")
		_report()
		get_tree().quit(0)


func _report() -> void:
	print("\n--- Walk Report ---")
	print("speed max            : %.2f m/s" % _speed_max)
	print("mean arm |ω|         : %.2f rad/s" % (_sum_angvel / maxf(_n, 1)))
	print("max  arm |ω|         : %.2f rad/s" % _max_angvel)
	print("max joint angle err  : %.1f°" % rad_to_deg(_max_joint_err))
	print("max contact force    : %.1f N" % _max_contact)
	print("frames with contact  : %d" % _contact_frames)
	print("=== Arm Walk: %s ===" % (
		"PASS" if _max_angvel < 8.0 and _max_joint_err < deg_to_rad(35.0) else "FAIL"))
