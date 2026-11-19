# ============================================================
# test_thumb_range.gd — 拇指每个关节的可用范围
# ============================================================
# 运行：godot --headless --path . scenes/test_thumb_range.tscn
#
# 验证两件事：
#   1. 控制层给每个关节的上限 = 肌肉层实际下达的目标角上限。
#      以前这里统一夹到 95°，HUD 能转到 95°，关节却在 55°/80° 停住，
#      看起来就是「后两个关节的范围不对」。
#   2. 冻结手掌后逐个把 CMC/MCP/IP 驱动到各自上限，实际测得的
#      相对屈曲角必须到得了上限（允许 5° 静差），且不受上游关节影响。
#
# 拇指解剖范围：CMC 80° / MCP 55° / IP 80°。MCP 不能沿用四指的
# 90-100°，否则切到第二个关节时会折出一个比 CMC 还大的角。
extends Node

const HAND := 1
const SETTLE := 220
const RESET_FRAMES := 45
const DRIVE_FRAMES := 120
const TOL_DEG := 5.0

var _controller: Node = null
var _palm: RigidBody3D = null
var _frozen := false
var _phase := 0
var _frames := 0
var _joint := 0
var _phase_frame := 0
var _pass := 0
var _fail := 0


func _ready() -> void:
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)
	_controller = scene.get_node_or_null("FirstPersonController")


func _limits() -> Array:
	var script: Script = _controller.get_script()
	var map: Dictionary = script.get_script_constant_map()
	return map.get("THUMB_JOINT_LIMITS_DEG", [80.0, 55.0, 80.0])


func _set_all_thumb(deg: float) -> void:
	var angles: Array = _controller.get("_finger_angles")
	var actives: Array = _controller.get("_finger_active_until")
	if angles.size() <= HAND:
		return
	var now := Time.get_ticks_msec()
	for j in range(3):
		angles[HAND][0][j] = deg
		actives[HAND][0][j] = now + 1000000


func _freeze() -> void:
	_frozen = true
	_palm = (_controller.get("_palm_bodies") as Array)[HAND]
	_controller.set_physics_process(false)
	var joints_all: Array = _controller.get("_arm_joints")
	var angles_all: Array = _controller.get("_arm_angles")
	var actives_all: Array = _controller.get("_arm_active_until")
	var now := Time.get_ticks_msec()
	for hh in range(joints_all.size()):
		for jd in joints_all[hh]:
			var key: String = jd["key"]
			angles_all[hh][key] = rad_to_deg(
				float(_controller.call("_joint_angle", jd)))
			actives_all[hh][key] = now + 100000
	_palm.freeze = true
	_palm.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_check_control_clamps()


## 控制层：把选中关节的目标角推过上限，必须停在该关节的解剖上限。
func _check_control_clamps() -> void:
	var selected: Array = _controller.get("_selected_fingers")
	var angles: Array = _controller.get("_finger_angles")
	for h in range(2):
		for f in range(5):
			selected[h][f] = false
	selected[HAND][0] = true
	var limits: Array = _limits()
	for j in range(3):
		_controller.set("_selected_joint", j)
		angles[HAND][0][j] = 0.0
		_controller.call("_adjust_selected_joint", 200.0)
		var got := float(angles[HAND][0][j])
		var want := float(limits[j])
		_check(absf(got - want) < 0.01,
			"控制层关节 %d 上限 %.0f°（实际 %.1f°）" % [j, want, got])
		angles[HAND][0][j] = 0.0
	_controller.set("_selected_joint", 0)
	_controller.call("_apply_finger_pose")


func _drive() -> void:
	var fore: RigidBody3D = (_controller.get("_arm_bodies")[HAND]
		as Dictionary)["forearm"]
	_controller.call("_update_finger_muscles", HAND, _palm, fore, true,
		Time.get_ticks_msec(), get_physics_process_delta_time())


func _measure() -> void:
	var limits: Array = _limits()
	var got := float(_controller.call("_finger_flex_deg", HAND, 0, _joint))
	var want := float(limits[_joint])
	_check(absf(got - want) <= TOL_DEG,
		"关节 %d 相对上一节能到 %.0f°（实际 %.1f°）" % [_joint, want, got])
	_joint += 1
	_phase = 0
	_phase_frame = 0
	if _joint >= 3:
		_finish()


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _controller == null or _controller.get("_finger_segments").size() < 2:
		return
	if _frames < SETTLE:
		_set_all_thumb(0.0)
		return
	if not _frozen:
		_freeze()
		return
	if _phase == 0:
		_set_all_thumb(0.0)
		_phase_frame += 1
		if _phase_frame < RESET_FRAMES:
			_drive()
			return
		var angles: Array = _controller.get("_finger_angles")
		var actives: Array = _controller.get("_finger_active_until")
		var limits: Array = _limits()
		var now := Time.get_ticks_msec()
		# 远端关节测试时，上游关节保持在自己的上限，模拟真实已经弯好的
		# 拇指；控制远端关节不能把上游关节一起带跑。
		for j in range(_joint):
			angles[HAND][0][j] = float(limits[j])
			actives[HAND][0][j] = now + 1000000
		angles[HAND][0][_joint] = float(limits[_joint])
		actives[HAND][0][_joint] = now + 1000000
		_phase = 1
		_phase_frame = 0
		_drive()
		return
	_phase_frame += 1
	if _phase_frame >= DRIVE_FRAMES:
		_measure()
		return
	_drive()


func _finish() -> void:
	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: ", label)
	else:
		_fail += 1
		print("  FAIL: ", label)
