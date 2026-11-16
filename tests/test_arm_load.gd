# ============================================================
# test_arm_load.gd — 手臂承重 / 骨折回归测试
# ============================================================
# 运行：godot --headless --path . scenes/test_arm_load.tscn
#
# 手臂平举（肩侧举 90°，前臂水平）。手掌质量即「手里托着的东西」：
#   阶段 1：手 15 kg → 肘部外载力矩约 38 N·m，低于桡尺骨抗弯极限 74 N·m
#           肩部力矩约 74 N·m，低于肱骨 166 N·m → 不应骨折
#   阶段 2：手 60 kg → 肩部力矩约 318 N·m、肘部约 153 N·m，都超极限
#           → 必须断一根骨
# 力矩由真实质量算出，不走 apply_central_force，骨骼判定才看得到载荷。
# ============================================================
extends Node

const SETTLE_FRAMES := 90
const LOAD1_FROM := 90
const LOAD1_TO := 240
const LOAD2_FROM := 240
const LOAD2_TO := 420

var _controller: Node = null
var _frames := 0
var _broken_under_15 := false
var _hand := 1


func _ready() -> void:
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)
	_controller = scene.get_node_or_null("FirstPersonController")


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _controller == null:
		return
	var palms: Array = _controller.get("_palm_bodies")
	var arm_bodies: Array = _controller.get("_arm_bodies")
	var angles_list: Array = _controller.get("_arm_angles")
	var actives: Array = _controller.get("_arm_active_until")
	if palms.size() < 2 or arm_bodies.size() < 2 or actives.size() < 2:
		return
	var palm: RigidBody3D = palms[_hand]

	# 手臂一直保持平举：上臂水平向外，肘伸直
	var angles: Dictionary = angles_list[_hand]
	angles["shoulder_z"] = 90.0
	angles["elbow_x"] = 0.0
	var now_ms := Time.get_ticks_msec()
	actives[_hand]["shoulder_z"] = now_ms + 600
	actives[_hand]["elbow_x"] = now_ms + 600
	_controller.call("_apply_arm_pose")

	if _frames == SETTLE_FRAMES:
		palm.mass = 15.0
		print("[Load] 手质量 %0.f kg（阶段 1）" % palm.mass)

	if _frames == LOAD1_TO:
		var broken_map: Dictionary = _controller.get("_arm_broken")[_hand]
		_broken_under_15 = _any_broken(broken_map)
		print("[Load] 15 kg 平举：骨折 = %s" % str(_broken_under_15))

	if _frames == LOAD2_FROM:
		palm.mass = 60.0
		print("[Load] 手质量 %0.f kg（阶段 2）" % palm.mass)

	if _frames == LOAD2_TO:
		_report()
		get_tree().quit(0)


func _any_broken(broken_map: Dictionary) -> bool:
	for key in broken_map:
		if bool(broken_map[key]):
			return true
	return false


func _report() -> void:
	var broken_map: Dictionary = _controller.get("_arm_broken")[_hand]
	var broken_final: bool = _any_broken(broken_map)
	var names: Array = []
	for key in broken_map:
		if bool(broken_map[key]):
			names.append(key)
	print("\n--- Load Report ---")
	print("broken under 15 kg : %s (expect false)" % str(_broken_under_15))
	print("broken under 60 kg : %s (expect true) %s" %
		[str(broken_final), str(names)])
	var ok: bool = (not _broken_under_15) and broken_final
	print("=== Arm Load: %s ===" % ("PASS" if ok else "FAIL"))
