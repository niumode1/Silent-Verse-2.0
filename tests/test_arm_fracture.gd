# ============================================================
# test_arm_fracture.gd — 骨折后：断端失去控制、且不拖慢物理
# ============================================================
# 运行：godot --headless --path . scenes/test_arm_fracture.tscn
#
# 两个回归点：
#   1. 肱骨断在肩上时两个肩铰链必须一起断开。只断一个的话，另一条
#      铰链还连着被躯干搬运的肩座，断臂照旧能被电机驱动。
#   2. 断点以远的关节（肘断 → 腕、腕断 → 手指）不再输出肌肉力矩。
#   3. 骨折后物理帧耗时不应该明显变差（断开的刚体继续按物理下落）。
# ============================================================
extends Node

const WARMUP := 60
const BASELINE_END := 120
const BROKEN_MEASURE := 90

var _controller: Node = null
var _frames := 0
var _base_time := 0.0
var _base_samples := 0
var _broken_time := 0.0
var _broken_samples := 0
var _snapshot: Dictionary = {}
var _reported := false
var _proc_base := 0.0
var _proc_broken := 0.0
var _proc_samples := 0
var _proc_broken_samples := 0
var _tri_base := 0
var _tri_broken := 0
var _sum_skin_usec := 0.0
var _last_us := 0
var _frame_base := 0.0
var _frame_broken := 0.0


func _ready() -> void:
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)
	_controller = scene.get_node_or_null("FirstPersonController")


func _process(_delta: float) -> void:
	var now_us: int = Time.get_ticks_usec()
	if _last_us > 0:
		var dt_us: float = float(now_us - _last_us)
		if _frames >= WARMUP and _frames < BASELINE_END:
			_frame_base += dt_us
		elif _frames > BASELINE_END + 2:
			_frame_broken += dt_us
	_last_us = now_us
	if _controller == null or _reported:
		return
	var t: float = float(Performance.get_monitor(Performance.TIME_PROCESS))
	var tris: int = int(_controller.get("_skin_tri_count")) + int(_controller.get("_skin_step_count"))
	if _frames >= WARMUP and _frames < BASELINE_END:
		_proc_base += t
		_tri_base += tris
		_proc_samples += 1
	elif _frames > BASELINE_END + 2:
		_proc_broken += t
		_tri_broken += tris
		_proc_broken_samples += 1


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _controller == null or _reported:
		return
	var physics_time: float = float(
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS))
	if _frames > WARMUP and _frames <= BASELINE_END:
		_base_time += physics_time
		_base_samples += 1
	if _frames == BASELINE_END:
		_break_all()
	elif _frames > BASELINE_END:
		_broken_time += physics_time
		_broken_samples += 1
	if _frames == BASELINE_END + BROKEN_MEASURE:
		_reported = true
		_report()


func _break_all() -> void:
	if OS.get_environment("FRACTURE_MODE") == "finger":
		_controller.call("_break_bone", {
			"hand": 1, "kind": "finger", "finger": 1, "index": 1,
			"load": 0.0, "limit": 0.0,
		})
		print("[Fracture] 只断右手食指中节")
		return
	var joints_all: Array = _controller.get("_arm_joints")
	var bodies: Array = _controller.get("_arm_bodies")
	for h in range(joints_all.size()):
		var upper: RigidBody3D = bodies[h]["upper"]
		_snapshot[upper.get_instance_id()] = upper.global_position
		for jd in joints_all[h]:
			_controller.call("_break_bone", {
				"hand": h, "kind": "arm", "key": String(jd["key"]),
				"joint": jd, "label": String(jd["key"]),
				"load": 0.0, "limit": 0.0,
			})
	print("[Fracture] 双臂已断；断点=%s" % str(_cuts()))


func _report() -> void:
	var joints_all: Array = _controller.get("_arm_joints")
	var bodies: Array = _controller.get("_arm_bodies")
	var detached: Dictionary = _controller.get("_detached_from_torso")
	var cuts: Array = _cuts()

	var ok := true
	# 1. 断点以远的关节必须断开
	var expect_level := [0, 0, 1, 2]
	for h in range(joints_all.size()):
		for jd in joints_all[h]:
			var key: String = String(jd["key"])
			var joint: HingeJoint3D = jd["joint"]
			var should_off: bool = int(expect_level[_index_of(key)]) >= int(cuts[h])
			var off: bool = joint.node_a.is_empty() and joint.node_b.is_empty()
			if should_off and not off:
				ok = false
				print("  ✗ hand %d %s 应断开但仍有约束" % [h, key])

	# 2. 断臂不再随躯干搬运，且真的在下落
	for h in range(bodies.size()):
		var upper: RigidBody3D = bodies[h]["upper"]
		if not detached.has(upper.get_instance_id()):
			ok = false
			print("  ✗ hand %d 上臂仍在 _detached_from_torso 之外" % h)
			continue
		var moved: float = upper.global_position.distance_to(
			Vector3(_snapshot[upper.get_instance_id()]))
		print("  hand %d 上臂断后位移 %.2f m" % [h, moved])
		if moved < 0.05:
			ok = false
			print("  ✗ hand %d 上臂没有脱离躯干（位移过小）" % h)

	# 3. 物理耗时
	var base: float = _base_time / maxf(float(_base_samples), 1.0)
	var broken: float = _broken_time / maxf(float(_broken_samples), 1.0)
	var ratio: float = broken / maxf(base, 1e-6)
	print("[Fracture] 物理帧耗时 基准=%.3f ms 骨折后=%.3f ms (×%.2f)" %
		[base * 1000.0, broken * 1000.0, ratio])
	var pb: float = _proc_base / maxf(float(_proc_samples), 1.0)
	var pr: float = _proc_broken / maxf(float(_proc_broken_samples), 1.0)
	var tb: float = float(_tri_base) / maxf(float(_proc_samples), 1.0)
	var tr: float = float(_tri_broken) / maxf(float(_proc_broken_samples), 1.0)
	print("[Fracture] 皮肉重建耗时 基准=%.3f ms 骨折后=%.3f ms (×%.2f)  三角+步数 基准=%.0f 骨折后=%.0f (×%.2f)" %
		[pb * 1000.0, pr * 1000.0, pr / maxf(pb, 1e-6), tb, tr, tr / maxf(tb, 1.0)])
	var n_base: float = float(BASELINE_END - WARMUP)
	var n_broken: float = float(_proc_samples)
	print("[Fracture] 实际帧间隔 基准=%.2f ms 骨折后=%.2f ms" %
		[_frame_base / maxf(n_base, 1.0) / 1000.0,
		_frame_broken / maxf(n_broken, 1.0) / 1000.0])
	if ratio > 3.0:
		ok = false
		print("  ✗ 骨折后物理开销暴涨")

	print("=== Arm Fracture: %s (断点 %s) ===" %
		["PASS" if ok else "FAIL", str(cuts)])
	get_tree().quit(0)


func _cuts() -> Array:
	var out: Array = []
	for h in range(2):
		out.append(int(_controller.call("_control_cut", h)))
	return out


func _index_of(key: String) -> int:
	match key:
		"shoulder_x", "shoulder_z":
			return 0
		"elbow_x":
			return 1
		"wrist_x":
			return 2
	return 3
