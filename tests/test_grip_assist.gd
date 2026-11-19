# ============================================================
# test_grip_assist.gd — E 键握持辅助的角度目标
# ============================================================
# 运行：godot --headless --path . scenes/test_grip_assist.tscn
# 只验证控制层：按 E 后所有手指到握姿上限，再按 E 回 0°。
# 实际出力仍由 _update_finger_muscles 的肌肉模型负责。
extends Node

const TOL := 0.6

var _controller: Node = null
var _frames := 0
var _pass := 0
var _fail := 0
var _done := false


func _ready() -> void:
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)
	_controller = scene.get_node_or_null("FirstPersonController")


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _controller == null or _done:
		return
	if _frames < 240:
		return
	if (_controller.get("_finger_angles") as Array).size() < 2:
		return
	_done = true
	_controller.set_physics_process(false)
	var angles: Array = _controller.get("_finger_angles")
	var limits: Dictionary = _controller.get_script().get_script_constant_map()

	# 合拢
	_controller.set("_grip_assist_closed", true)
	_controller.set("_grip_assist_engaged", true)
	for i in range(40):
		_controller.call("_update_grip_assist", 0.1)
	var four: Array = limits["FINGER_GRASP_DEG"]
	var thumb: Array = limits["THUMB_GRASP_DEG"]
	for h in range(2):
		for j in range(3):
			_check(absf(float(angles[h][1][j]) - float(four[j])) <= TOL,
				"hand %d index joint %d closed to %.0f°" % [h, j, four[j]])
			_check(absf(float(angles[h][0][j]) - float(thumb[j])) <= TOL,
				"hand %d thumb joint %d closed to %.0f°" % [h, j, thumb[j]])

	# 张开
	_controller.set("_grip_assist_closed", false)
	_controller.set("_grip_assist_engaged", true)
	for i in range(40):
		_controller.call("_update_grip_assist", 0.1)
	for h in range(2):
		for f in range(5):
			for j in range(3):
				_check(absf(float(angles[h][f][j])) <= TOL,
					"hand %d finger %d joint %d open" % [h, f, j])
	_finish()


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
