# ============================================================
# test_thumb_opposition.gd — 拇指到底往哪个方向弯
# ============================================================
# 运行：godot --headless --path . scenes/test_thumb_opposition.tscn
#
# 诊断用，不是判据。把右手的拇指三节从 0° 开到 120°，每一步同时打印：
#   - 运动学参考骨架（_finger_pivots）的指骨位置
#   - 物理刚体（_finger_segments）的实际位置
#   - 尺寸/位置都在掌坐标系里（掌 x = 横跨手掌，掌 y = 掌背法线，
#     掌 z = 腕→指尖的反方向，掌面在 y = -0.011）
#
# 四指屈曲绕掌 x，在 y-z 平面里卷向掌面。拇指必须绕掌 y，弯在 x-z
# 平面里横跨掌心——方向与四指垂直，这才是对掌。如果拇指也绕掌 x，
# 它就只会在与四指平行的平面里点头，永远压不到对侧。
#
# 拇指的链：横着长出去（掌 -x）→ 第一关节转向掌面（-y）→ 第二关节
# 继续卷回（+x）。两节共 5.4 cm，只有两个关节。
#
# 当前实测（右手，指尖在掌坐标里的轨迹）：
#   0°   (-0.103, -0.007, -0.030)   横着伸出去，和四指垂直
#   30°  (-0.087, -0.043, -0.031)
#   60°  (-0.052, -0.054, -0.030)   压到掌面下方
#   90°  (-0.025, -0.038, -0.031)   第二节卷回掌心
# 判据：z 全程不变（弯曲平面就是 x-y），y 单调下压；绕掌 y 弯时
# 是 x-z 平面里横扫、z 走 10 cm，一眼就能分辨。
extends Node

const STEPS := [0.0, 30.0, 60.0, 90.0, 120.0]
const SETTLE_FRAMES := 200
const STEP_FRAMES := 90
const HAND := 1

var _controller: Node = null
var _palm: RigidBody3D = null
var _frames := 0
var _step := -1


func _ready() -> void:
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)
	_controller = scene.get_node_or_null("FirstPersonController")


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _controller == null:
		return
	if _frames == SETTLE_FRAMES:
		_palm = (_controller.get("_palm_bodies") as Array)[HAND]
		_palm.freeze = true
		_palm.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
		print("=== 拇指对掌诊断（右手）===")
	if _frames < SETTLE_FRAMES + 30:
		return
	var t := _frames - SETTLE_FRAMES - 30
	var s: int = t / STEP_FRAMES
	if s >= STEPS.size():
		get_tree().quit(0)
		return
	if s != _step:
		_step = s
		_drive(float(STEPS[s]))
	if t % STEP_FRAMES == STEP_FRAMES - 1:
		_report(float(STEPS[s]))


func _drive(deg: float) -> void:
	var angles: Array = _controller.get("_finger_angles")
	var actives: Array = _controller.get("_finger_active_until")
	var now := Time.get_ticks_msec()
	# 拇指三节（掌骨 / 近节 / 末节）一起开到 deg
	for j in range((angles[HAND][0] as Array).size()):
		angles[HAND][0][j] = deg
		actives[HAND][0][j] = now + 1000000
	# 四指合拢到握姿：CMC 内收（对掌）的目标角跟四指屈曲程度绑定，
	# 不把四指合上就看不出拇指到底能不能横跨到握持口袋。
	var grasp: Array = [90.0, 100.0, 70.0]
	for f in range(1, 5):
		for j in range((angles[HAND][f] as Array).size()):
			angles[HAND][f][j] = float(grasp[j])
			actives[HAND][f][j] = now + 1000000


func _report(deg: float) -> void:
	var inv: Transform3D = _palm.global_transform.affine_inverse()
	var pivots: Array = (_controller.get("_finger_pivots") as Array)[HAND][0]
	var segs: Array = (_controller.get("_finger_segments") as Array)[HAND][0]
	var lens: Array = (_controller.get("_finger_seg_lengths") as Array)[HAND][0]
	var kin := []
	var phy := []
	for j in range(segs.size()):
		var pl: Vector3 = inv * pivots[j].global_position
		var sl: Vector3 = inv * segs[j].global_position
		kin.append("(%+.3f %+.3f %+.3f)" % [pl.x, pl.y, pl.z])
		phy.append("(%+.3f %+.3f %+.3f)" % [sl.x, sl.y, sl.z])
	var last: int = segs.size() - 1
	var tip: Vector3 = inv * segs[last].global_transform.origin
	var seg_dir: Vector3 = (inv.basis
		* (segs[last].global_transform.basis * Vector3(0, 0, -1))).normalized()
	tip += seg_dir * (float(lens[last]) * 0.5)
	var flex: float = float(_controller.call("_finger_flex_deg", HAND, 0, 0))
	var add_deg := 0.0
	var adduct: Array = _controller.get("_thumb_adduct_joint")
	if adduct.size() > HAND:
		add_deg = rad_to_deg(float(_controller.call("_joint_angle", adduct[HAND])))
	print("拇指 %3.0f°  运动学 %s  物理 %s  指尖(%+.3f %+.3f %+.3f)  实测屈曲 %+.1f°  CMC内收 %+.1f°  τ=%.2f" % [
		deg, " ".join(kin), " ".join(phy), tip.x, tip.y, tip.z, flex, add_deg,
		float(_controller.call("_joint_torque", "thumb_cmc_adduct", true))])
	var cradles: Array = _controller.get("_thumb_cradle")
	if cradles.size() > HAND:
		var rel: Basis = _palm.global_transform.basis.orthonormalized().inverse() \
			* (cradles[HAND] as Node3D).global_transform.basis.orthonormalized()
		print("   cradle x=%s y=%s z=%s" % [
			str(rel.x.snapped(Vector3.ONE * 0.01)),
			str(rel.y.snapped(Vector3.ONE * 0.01)),
			str(rel.z.snapped(Vector3.ONE * 0.01))])
	# 四指指尖位置，用来判断拇指到底有没有伸进握持口袋
	var all_segs: Array = (_controller.get("_finger_segments") as Array)[HAND]
	var all_lens: Array = (_controller.get("_finger_seg_lengths") as Array)[HAND]
	var tips := []
	for f in range(1, 5):
		var seg_arr: Array = all_segs[f]
		var lens_arr: Array = all_lens[f]
		var li: int = seg_arr.size() - 1
		var t: Vector3 = inv * (seg_arr[li] as Node3D).global_transform.origin
		var d: Vector3 = (inv.basis * ((seg_arr[li] as Node3D).global_transform.basis
			* Vector3(0, 0, -1))).normalized()
		t += d * (float(lens_arr[li]) * 0.5)
		var flexs := ""
		for j in range(seg_arr.size()):
			flexs += "%+.0f " % float(_controller.call(
				"_finger_flex_deg", HAND, f, j))
		tips.append("(%+.3f %+.3f %+.3f|%s)" % [t.x, t.y, t.z, flexs.strip_edges()])
	print("   四指尖 %s" % " ".join(tips))
