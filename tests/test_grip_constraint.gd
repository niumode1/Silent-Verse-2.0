# ============================================================
# test_grip_constraint.gd — E 握紧后的临时握持约束
# ============================================================
# 运行：godot --headless --path . scenes/test_grip_constraint.tscn
# 验证：指腹已接触一个可动物品 + E 握紧时，手掌和物品之间建立
# PinJoint3D；松开 E 后约束释放。
extends Node

var _controller: Node = null
var _renderer: Node = null
var _frames := 0
var _pass := 0
var _fail := 0


func _ready() -> void:
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)
	_controller = scene.get_node_or_null("FirstPersonController")
	_renderer = scene.get_node_or_null("WorldRenderer")


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _controller == null or _renderer == null:
		return
	if _frames < 240:
		return
	var sticks: Array = _renderer.get("_test_vertical_sticks")
	if sticks.is_empty() or _controller.get("_palm_bodies").size() < 2:
		return
	var stick: RigidBody3D = sticks[0]
	stick.freeze = false
	_controller.set_physics_process(false)

	var touch: Array = _controller.get("_pulp_touch")
	touch[1] = {stick.get_instance_id(): true}
	_controller.set("_grip_assist_closed", true)
	_controller.call("_update_grip_constraints")
	var joints: Array = _controller.get("_grip_joints")
	_check(joints[1] is PinJoint3D, "right hand grip joint created")
	if joints[1] is PinJoint3D:
		_check((joints[1] as PinJoint3D).node_b == (joints[1] as Node).get_path_to(stick),
			"grip joint attached to test stick")

	_controller.set("_grip_assist_closed", false)
	_controller.call("_update_grip_constraints")
	_check(joints[1] == null, "grip joint released when grip opens")

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
