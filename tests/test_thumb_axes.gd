# ============================================================
# test_thumb_axes.gd — 拇指三组轴不互换
# ============================================================
# 运行：godot --headless --path . scenes/test_thumb_axes.tscn
# 验证：
#   · CMC 对掌轴 = 手掌 +Y
#   · CMC 屈曲轴 = 手掌 ±Z（左右手镜像）
#   · 拇指 MCP/IP 屈曲轴 = 拇指父节局部 X
# ============================================================
extends Node

var _pass := 0
var _fail := 0


func _ready() -> void:
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)

	for i in range(600):
		await get_tree().process_frame
		var c = scene.get_node_or_null("FirstPersonController")
		if c != null and c.get("_thumb_adduct_joint").size() > 0:
			break

	var controller = scene.get_node_or_null("FirstPersonController")
	if controller == null:
		_finish()
		return

	var adduct: Array = controller.get("_thumb_adduct_joint")
	var axis_local: Array = controller.get("_finger_axis_local")
	var palm_bodies: Array = controller.get("_palm_bodies")
	var cradles: Array = controller.get("_thumb_cradle")
	var segments: Array = controller.get("_finger_segments")

	_check(adduct.size() > 0, "thumb adduction joint exists")
	_check(axis_local.size() > 0, "finger axes recorded")

	for h in range(mini(adduct.size(), palm_bodies.size())):
		var palm: RigidBody3D = palm_bodies[h]
		var palm_b: Basis = palm.global_transform.basis.orthonormalized()
		var jd: Dictionary = adduct[h]
		var a: Node3D = jd["a"]
		var axis_world: Vector3 = (a.global_transform.basis
			* (jd["axis_local_a"] as Vector3)).normalized()
		var adduct_dot: float = axis_world.dot(palm_b.y.normalized())
		_check(adduct_dot > 0.95,
			"hand %d CMC opposition axis = palm +Y (dot %.3f)"
			% [h, adduct_dot])

		var cradle: RigidBody3D = cradles[h]
		var cradle_b: Basis = cradle.global_transform.basis.orthonormalized()
		var cmc_local: Vector3 = ((axis_local[h] as Array)[0] as Array)[0]
		var cmc_world: Vector3 = (cradle_b * cmc_local).normalized()
		var cmc_dot: float = absf(cmc_world.dot(palm_b.z.normalized()))
		_check(cmc_dot > 0.95,
			"hand %d CMC flexion axis = palm Z (dot %.3f)"
			% [h, cmc_dot])

		for j in range(1, 3):
			var thumb_segs: Array = (segments[h] as Array)[0]
			if j >= thumb_segs.size():
				continue
			var parent: RigidBody3D = thumb_segs[j - 1]
			var pb: Basis = parent.global_transform.basis.orthonormalized()
			var ax_local: Vector3 = ((axis_local[h] as Array)[0] as Array)[j]
			var ax_world: Vector3 = (pb * ax_local).normalized()
			var dot: float = ax_world.dot(pb.x.normalized())
			_check(absf(dot) > 0.95,
				"hand %d thumb joint %d axis = parent local X (dot %.3f)"
				% [h, j, dot])

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
