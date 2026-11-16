# ============================================================
# test_contact_probe.gd — 接触力探针单元测试
# ============================================================
# 运行：godot --headless --path . scenes/test_contact_probe.tscn
#
# 探针必须在 _integrate_forces 里读到接触冲量，否则骨骼受力判定
# 只能看到重力，玩家手里抬着的重物不会压在骨头上。
# 本测试让一个 10 kg 刚体静止在地面上，验证探针记录到的接触力
# 约等于 mg（允许 25% 误差）。
# ============================================================
extends Node

const ProbeScript = preload("res://scripts/client/contact_force_probe.gd")

var _probe: RigidBody3D = null
var _frames := 0


func _ready() -> void:
	var floor_body := StaticBody3D.new()
	floor_body.name = "Floor"
	floor_body.collision_layer = 1
	floor_body.collision_mask = 0
	var floor_col := CollisionShape3D.new()
	var floor_shape := BoxShape3D.new()
	floor_shape.size = Vector3(4.0, 0.4, 4.0)
	floor_col.shape = floor_shape
	floor_body.add_child(floor_col)
	add_child(floor_body)
	floor_body.global_position = Vector3(0.0, -0.2, 0.0)

	_probe = ProbeScript.new()
	_probe.name = "ProbeBody"
	_probe.mass = 10.0
	_probe.collision_layer = 1
	_probe.collision_mask = 1
	var col := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = Vector3(0.2, 0.2, 0.2)
	col.shape = shape
	_probe.add_child(col)
	add_child(_probe)
	_probe.global_position = Vector3(0.0, 1.0, 0.0)


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _frames != 180:
		return
	var weight: float = _probe.mass * 9.81
	var force: Variant = _probe.get("contact_force")
	var measured: float = (force as Vector3).length() if force is Vector3 else -1.0
	var ok: bool = absf(measured - weight) < weight * 0.25
	print("contact_force=%.1f N  expected≈%.1f N" % [measured, weight])
	print("=== Contact Probe: %s ===" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0 if ok else 1)
