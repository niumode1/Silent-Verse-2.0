# ============================================================
# test_arm_lift.gd — 手臂四自由度电机回归
# ============================================================
# 运行：godot --headless --path . scenes/test_arm_lift.tscn
#
# 阶段 A（0-100 帧）：两侧 shoulder_z = +90°（侧举）。要求上臂真的抬到
#   身体外侧（与 outward 方向点积 > 0.5），而不是被关节限位/惯量卡住。
# 阶段 B（100-220 帧）：shoulder_z=0、shoulder_x=60°、elbow_x=90°、
#   wrist_x=45°，要求各关节角都跟上目标。
#
# 守住三件事：
#   1. 肩部横滚中间体必须有正常转动惯量，否则 Jolt 铰链电机没力矩；
#   2. 搬运手臂时不能手写刚体速度，否则会把电机速度冲掉；
#   3. 侧举轴左右镜像，否则左臂会横穿胸前。
# ============================================================
extends Node

const PHASE_A_END := 100
const PHASE_B_END := 220

var _controller: Node = null
var _frames := 0
var _done := false
var _phase_a: Array = []


func _ready() -> void:
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)
	_controller = scene.get_node_or_null("FirstPersonController")


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _controller == null or _done:
		return
	var angles_list: Array = _controller.get("_arm_angles")
	var actives: Array = _controller.get("_arm_active_until")
	if angles_list.size() < 2 or actives.size() < 2:
		return
	var now_ms := Time.get_ticks_msec()
	for h in range(2):
		var angles: Dictionary = angles_list[h]
		if _frames < PHASE_A_END:
			angles["shoulder_z"] = 90.0
			actives[h]["shoulder_z"] = now_ms + 600
		else:
			angles["shoulder_z"] = 0.0
			angles["shoulder_x"] = 60.0
			angles["elbow_x"] = 90.0
			angles["wrist_x"] = 45.0
			angles["wrist_y"] = 60.0
			for key in ["shoulder_z", "shoulder_x", "elbow_x", "wrist_x", "wrist_y"]:
				actives[h][key] = now_ms + 600
	_controller.call("_apply_arm_pose")

	if _frames == PHASE_A_END:
		_phase_a = _measure()
	if _frames >= PHASE_B_END:
		_done = true
		_report(_phase_a, _measure())
		get_tree().quit(0)


func _measure() -> Array:
	var joints_all: Array = _controller.get("_arm_joints")
	var bodies: Array = _controller.get("_arm_bodies")
	var root: Node3D = _controller.get("_body_root")
	var right: Vector3 = root.global_transform.basis.x.normalized()
	var out: Array = []
	for h in range(2):
		var angles := {}
		for jd in joints_all[h]:
			angles[jd["key"]] = rad_to_deg(float(_controller.call("_joint_angle", jd)))
		var upper: RigidBody3D = bodies[h]["upper"]
		var dir: Vector3 = (-upper.global_transform.basis.y).normalized()
		var outward: Vector3 = right if h == 1 else -right
		out.append({"angles": angles, "outward": dir.dot(outward)})
	return out


func _report(a: Array, b: Array) -> void:
	var a_ok := true
	var b_ok := true
	for h in range(2):
		print("hand %d A: shoulder_z=%.1f° outward=%.2f" %
			[h, a[h]["angles"]["shoulder_z"], a[h]["outward"]])
		if a[h]["outward"] <= 0.5 or absf(a[h]["angles"]["shoulder_z"] - 90.0) > 30.0:
			a_ok = false
		var ang: Dictionary = b[h]["angles"]
		print("hand %d B: shoulder_x=%.1f° elbow_x=%.1f° wrist_x=%.1f° wrist_y=%.1f°" %
			[h, ang["shoulder_x"], ang["elbow_x"], ang["wrist_x"], ang["wrist_y"]])
		if absf(ang["shoulder_x"] - 60.0) > 25.0 \
				or absf(ang["elbow_x"] - 90.0) > 25.0 \
				or absf(ang["wrist_x"] - 45.0) > 25.0 \
				or absf(ang["wrist_y"] - 60.0) > 25.0:
			b_ok = false
	print("=== Arm Lift: %s (A侧举 %s, B多关节 %s) ===" %
		["PASS" if a_ok and b_ok else "FAIL",
		"ok" if a_ok else "bad", "ok" if b_ok else "bad"])
