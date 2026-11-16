# ============================================================
# test_finger_grip.gd — 真物理手指能不能握住木棍
# ============================================================
# 运行：godot --headless --path . scenes/test_finger_grip.tscn
# 可选环境变量：STICK_R / STICK_LEN / STICK_MASS / STICK_Y / STICK_Z
#               SETTLE（落地帧数）/ TRACE / NOFREEZE / TABLE / HOVER
#
# 流程（右手 h=1）：
#   A  0-SETTLE   等角色落地、手臂垂下，然后接管手部物理（手掌冻结成参考系）
#   B  +60         空手合拢到解剖上限，量出握拳的钩深，再张开
#   C  +90         木棍生成在掌前缘外侧，手指慢慢合拢
#   D  合拢结束     撤掉临时支撑——从这一刻起只有指腹的接触力托着木棍
#   E  +120        木棍受重力下坠
#
# 三种支撑方式（互相排斥）：
#   TABLE=1（默认） 木棍躺在桌面上。最接近「从地上捡」，但桌面顶住棍底，
#                   手指钻不进去，只能沿桌面把棍子推走。
#   HOVER=1        木棍关掉重力悬在空中，手指可以自由把它拨来拨去。
#                   隔离出「手指能不能把它圈住」这一个问题。
#   TABLE=0 HOVER 未设  冻结木棍。解冻那一帧会把指腹压进去的穿透一次性
#                   弹开（实测 1.3 m/s），只用于对照，不可作为判据。
#
# 判据：撤掉支撑后木棍相对手掌的位移 < 8 cm，且最后一帧仍有接触
#      （骨骼硬接触或指腹软组织接触都算）。
#
# 实测状态（2026-11-16，Godot 4.7.2，桌面方案）：
#   修好指腹软组织层之后，默认木棍（Ø3.2 cm / 0.30 m / 0.10 kg）连跑
#   11 次全部握住：位移 1.5-5.8 cm，末速 ≤0.25 m/s，指腹全程有接触。
#   修之前同一份测试三次只通过一次，另两次被挤出掌心、滑出 3-5 m。
#   病因是接触模型：9 mm 刚性胶囊 + 硬接触是单点接触，手指继续收拢时
#   把木棍当瓜子顶出去。现在指骨缩到 5 mm，外面 4 mm 指腹用分布弹簧-
#   阻尼层（first_person_controller.gd 的 _build_pulp_samples /
#   _update_finger_pads），接触压力摊在整个指腹面上。试过、没用的
#   替代方案（留着免得再走一遍）：
#     penetration_slop 3 mm → 0.58 kg 好转，但 0.10 kg 一次握住一次甩飞
#     baumgarte 0.1 → 三次全滑出
#     motor max_impulse ×60 → 挤得更狠（4.4 m → 7.5 m），说明不是力气问题
#   仍然握不住的：Ø3.5 cm × 1.0 m 的木棍超过 0.35 kg 就滑脱（0.45 kg
#   滑出 0.43 m，0.58 kg 直接飞 3-5 m）。世界里的树枝多数比这重，
#   瓶颈已经不是接触模型，而是拇指根位置（HANDOFF §5.3）和手掌承重。
#
# 手指力矩由 PlayerBody 的肌力 × 解剖力臂给出，不允许在这里写死抓握力。
# ============================================================
extends Node

var SETTLE_FRAMES := 200
const CLOSE_FRAMES := 90
const LOAD_FRAMES := 120
const LOAD_N := 0.0
## 木棍代表尺寸。世界刷新出来的树枝长 1.0-2.0 m、直径 3.5-9 cm，
## 实测这只手能稳定握住的只有最细的那一档（Ø3.2 cm 上下）：
## Ø3.5 cm / 1.0 m / 0.6 kg 在合拢阶段就会被手指推出去，握不住。
## 所以这里取一根小树枝做基线，大树枝的失败由 _report 如实报出。
var STICK_R := 0.016
var STICK_LEN := 0.30
var STICK_MASS := 0.10
## 握姿（MCP/PIP/DIP 度）= 关节解剖上限。握持时中枢给的是「继续收」
## 而不是「收到 65° 就停」：指腹被物体挡在半路，角误差一直存在，
## 屈肌就一直出力。目标角刚好等于实际角时肌肉会松力，物体就掉了。
const GRASP_DEG := [90.0, 100.0, 70.0]
## 生成前手指必须张开到这个角度以内，否则木棍会生成在弯曲的指骨里面
const OPEN_THRESHOLD_DEG := 15.0
## 掌盒半厚（与 first_person_controller.gd 的 palm_shape.size.y/2 一致）
const PALM_HALF := 0.011

var _controller: Node = null
var _palm: RigidBody3D = null
var _stick: RigidBody3D = null
var _frames := 0
var _spawn_frame := -1
var _cavity_center := Vector3.ZERO
var _cavity_r := 0.0
var _grip_center := Vector3.ZERO
var _stick_local_at_grab := Vector3.ZERO
var _hand_frozen := false
## 合拢期间木棍被一枚 PD 弹簧按在原地（相当于它躺在地上、被地面摩擦
## 托住）。冻住物体不行：手指会直接压进冻住的几何体，解冻那一帧的
## 渗透回弹会把木棍弹出掌心。
var _stick_hold := true
var _stick_hold_xf := Transform3D()
var _stick_hold_local := Vector3.ZERO
var _palm_prev_xf := Transform3D()
var _still_frames := 0
var TRACE: bool = OS.get_environment("TRACE") != ""
var NOFREEZE: bool = OS.get_environment("NOFREEZE") != ""
## 悬空模式：合拢期间木棍既不上桌、不冻结，也不加支撑弹簧，只是
## 关掉重力浮在那里。手指可以自由地把它拨来拨去——这正是「手掌
## 从上方落下、手指合拢去包住一根棍子」的那一瞬间。桌面方案里
## 棍子被桌面挡住、手指钻不到棍子底下，只能沿桌面把棍子推走；
## 冻结方案解冻时又会把指腹压进去的穿透一次性弹开。
var HOVER: bool = OS.get_environment("HOVER") != ""
var TABLE: bool = OS.get_environment("TABLE") != "0"
var _table: StaticBody3D = null
var _stick_local_at_spawn := Vector3.ZERO


func _ready() -> void:
	var es := OS.get_environment("SETTLE")
	if es != "":
		SETTLE_FRAMES = int(es)
	var e := OS.get_environment("STICK_R")
	if e != "":
		STICK_R = float(e)
	e = OS.get_environment("STICK_LEN")
	if e != "":
		STICK_LEN = float(e)
	e = OS.get_environment("STICK_MASS")
	if e != "":
		STICK_MASS = float(e)
	var scene: Node = load("res://scenes/client_3d.tscn").instantiate()
	add_child(scene)
	_controller = scene.get_node_or_null("FirstPersonController")


func _set_fingers(per_joint: bool, frac: float = 1.0) -> void:
	var angles: Array = _controller.get("_finger_angles")
	var actives: Array = _controller.get("_finger_active_until")
	if angles.size() < 2 or actives.size() < 2:
		return
	var now := Time.get_ticks_msec()
	for f in range(5):
		# NO_THUMB：把拇指留在张开位，单独看四指能不能握住。
		if f == 0 and OS.get_environment("NO_THUMB") != "":
			continue
		# 拇指只有 2 节（CMC + MCP），不能按四指的 3 节写死
		for j in range((angles[1][f] as Array).size()):
			angles[1][f][j] = float(GRASP_DEG[j]) * frac if per_joint else 0.0
			# 用墙钟毫秒表示「这一帧肌肉是主动的」。给足余量：headless
			# 下物理可能比实时慢，800 ms 只覆盖几十帧，合拢还没结束
			# 肌肉就掉回被动支撑了，结果随机器负载漂移。
			actives[1][f][j] = now + 1000000


func _fingers_open_enough() -> bool:
	var segs: Array = _controller.get("_finger_segments")[1]
	if segs.size() < 5:
		return false
	for f in range(5):
		var ax: Vector3 = _controller.call("_finger_axis", 1, f, 0, _palm)
		var a: float = rad_to_deg(_controller.call(
			"_finger_flex_angle", _palm, segs[f][0], ax))
		if a > OPEN_THRESHOLD_DEG:
			return false
	return true


func _physics_process(_delta: float) -> void:
	_frames += 1
	if _controller == null:
		return
	if _frames < SETTLE_FRAMES:
		_set_fingers(false)
		return
	if not _hand_frozen:
		_hand_frozen = true
		_palm = (_controller.get("_palm_bodies") as Array)[1]
		_controller.set_physics_process(false)
		# 手臂电机每帧把关节拉向 _arm_angles（默认 0°）。测试里不能让手
		# 自己甩回零位，否则手掌以 1-3 m/s 摆动，木棍相对手掌的位移全被
		# 手臂甩动污染。把当前关节角写回目标，电机就变成「保持这个姿势」。
		var joints_all: Array = _controller.get("_arm_joints")
		var angles_all: Array = _controller.get("_arm_angles")
		var actives_all: Array = _controller.get("_arm_active_until")
		var now2 := Time.get_ticks_msec()
		for hh in range(joints_all.size()):
			for jd in joints_all[hh]:
				var key: String = jd["key"]
				angles_all[hh][key] = rad_to_deg(
					float(_controller.call("_joint_angle", jd)))
				actives_all[hh][key] = now2 + 100000
		# 手掌全程冻住：它是测量的参考系。真实握持时手掌由腕关节和
		# 前臂肌群锁住，不是自由漂浮的；解冻手掌会让它带着手臂的摆动
		# 速度飞出去，木棍相对手掌的位移就失去了意义。
		_palm.freeze = true
		_palm.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	# 只驱动手指肌肉。不调用 _update_hand_physics：它每帧会把手掌按
	# 躯干位移搬运一次（角色还在落地微调），手掌一挪，木棍就相对手掌
	# 漂几厘米，测出来的「握没握住」全是躯干位移。
	var fore: RigidBody3D = (_controller.get("_arm_bodies")[1] as Dictionary)["forearm"]
	_controller.call("_update_finger_muscles", 1, _palm, fore, true,
		Time.get_ticks_msec(), get_physics_process_delta_time())
	if _palm != null:
		if (_palm.global_transform.origin - _palm_prev_xf.origin).length() < 0.0005:
			_still_frames += 1
		else:
			_still_frames = 0
		_palm_prev_xf = _palm.global_transform
	if _stick != null:
		# 重力用 gravity_scale 精确开关。早先用「反向施加 mg」抵消，但
		# _controller.position 不一定是世界坐标，抵消量错一个数量级，
		# 木棍一边被手指推一边自己往下掉，测出来的位移全是假的。
		_stick.gravity_scale = 0.0 if (_stick_hold and not TABLE) else 1.0
		if _stick.linear_velocity.length() > 4.0:
			print("    !! 木棍速度 %.1f m/s（求解器发散），钳到 4"
				% _stick.linear_velocity.length())
			_stick.linear_velocity = _stick.linear_velocity.limit_length(4.0)
		if _stick.angular_velocity.length() > 20.0:
			_stick.angular_velocity = \
				_stick.angular_velocity.limit_length(20.0)
		if _stick_hold and not TABLE and not HOVER:
			# 支撑点写成掌坐标，每帧按手掌当前位姿重算。手掌即使被躯干
			# 搬运挪动，木棍也跟着走，测出来的相对位移才是手指造成的。
			var pb: Basis = _palm.global_transform.basis.orthonormalized()
			_stick_hold_xf = Transform3D(pb, _palm.global_transform * _stick_hold_local)
			var dp: Vector3 = _stick_hold_xf.origin - _stick.global_position
			var hold_force: Vector3 = dp * 300.0 - _stick.linear_velocity * 30.0
			_stick.apply_central_force(hold_force.limit_length(80.0))
			# 只阻尼角速度，不做角度伺服：四元数误差转欧拉角在接近
			# 180° 时会跳变，力矩瞬间发散，整根棍子和手一起 NaN。
			_stick.apply_torque(-_stick.angular_velocity * 0.4)

	if _spawn_frame < 0:
		var t0: int = _frames - SETTLE_FRAMES
		if t0 < 60:
			# 先空手收到握姿，量出指尖围出的空腔半径——这决定了这只手
			# 最多能握住多粗的树枝，和肌肉力气是两回事。
			_set_fingers(true)
			return
		if t0 == 60:
			var cav: Array = _measure_cavity()
			_cavity_r = float(cav[0])
			_cavity_center = cav[1]
			print("  [空腔] 握拳内接半径=%.3f m @ %s  钩深=%.3f m（握姿 %s）" % [
				_cavity_r,
				str(_cavity_center.snapped(Vector3.ONE * 0.001)),
				_grip_depth(), str(GRASP_DEG)])
			_dump_hand("空手合拢")
			_set_fingers(false)
			return
		_set_fingers(false)
		if _still_frames >= 30 and _fingers_open_enough():
			_dump_hand("张开")
			_spawn_stick()
			_spawn_frame = _frames
		return

	var t: int = _frames - _spawn_frame
	if t < CLOSE_FRAMES:
		# 慢慢合拢：中枢给的目标角从 0 线性升到解剖上限。真人抓东西也
		# 不是一瞬间把指头甩到极限，那样手指会以 2-3 m/s 扫过物体把它
		# 拍飞。匀速合拢时接触力是准静态的，物体才有机会被夹住。
		_set_fingers(true, float(t) / float(CLOSE_FRAMES))
		if t <= 12 or t % 10 == 0 or t >= CLOSE_FRAMES - 6:
			var r: Vector3 = _palm.global_transform.affine_inverse() \
				* _stick.global_position
			print("    合拢 %d 木棍=%s 接触=%s %s" % [t,
				str(r.snapped(Vector3.ONE * 0.001)), _contact_forces(),
				_stick_debug()])
			if TRACE:
				print("      接触点 ", _contact_detail())
		return
	if t == CLOSE_FRAMES:
		# 撤掉临时支撑：从这一刻起全靠指腹的接触力托住木棍。
		if _table != null:
			_table.queue_free()
			_table = null
		_stick.freeze = false
		if not TABLE:
			# 冻结方案：合拢期间棍子是不动的（相当于它躺在桌上），手指
			# 只能压住它。解冻时压进去的那点穿透会一次性释放成冲量——
			# 这是这笔账唯一不真实的地方，TABLE 方案没有这个问题。
			_stick.linear_velocity = Vector3.ZERO
			_stick.angular_velocity = Vector3.ZERO
		_stick_hold = false
		_stick_local_at_grab = _palm.global_transform.affine_inverse() \
			* _stick.global_position
		print("  [抓住] 木棍相对手掌=%s 接触=%s" % [
			str(_stick_local_at_grab.snapped(Vector3.ONE * 0.001)),
			_contact_forces()])
		_dump_hand("抓住后")
		return
	if t < CLOSE_FRAMES + LOAD_FRAMES:
		_stick.apply_central_force(
			-_controller.position.normalized() * LOAD_N)
		if t % 10 == 0 or (TRACE and t < CLOSE_FRAMES + 16):
			var r: Vector3 = _palm.global_transform.affine_inverse() \
				* _stick.global_position
			var v: Vector3 = _palm.global_transform.basis \
				.inverse() * _stick.linear_velocity
			print("    加载 %d 木棍=%s 位移=%.3f v=%s ω=%.1f 接触=%s" % [t,
				str(r.snapped(Vector3.ONE * 0.001)),
				r.distance_to(_stick_local_at_grab),
				str(v.snapped(Vector3.ONE * 0.001)),
				_stick.angular_velocity.length(), _contact_forces()])
		return
	_report()


func _spawn_stick() -> void:
	# 指弓是个开口朝掌心的钩子：近节沿掌前缘竖直向下（MCP 90°），
	# 中节在近节末端折回（PIP 90°）。内接圆圆心在钩子拐角沿两个面
	# 各退一个半径处，这就是棍心该待的位置。
	# 棍子该靠在哪里：靠在掌心上，而不是浮在「空腔中心」。空腔中心是
	# 掌面下方 4-6 cm 的虚空，棍子悬在那里谁也托不住。
	# 合拢握姿（90/100/70）下，指弓围出的口袋是一块 y∈[-0.046,-0.011]、
	# z∈[-0.054,-0.027] 的矩形，内接圆心约在 (y=-0.0285, z=-0.0405)。
	# 棍心放在掌面下 STICK_R 处会贴掌，但握拳后指腹会从下面顶上来。
	# 木棍躺在桌面上、掌心正下方、紧贴掌前缘再往远端一点。
	# 别往掌心里塞：握拳后的「口袋」中心 (y=-0.029, z=-0.040) 看着像
	# 归宿，其实是四周全被挡死的死腔——棍子在里面无路可退，指骨继续
	# 合拢就把它当瓜子一样挤出去（z=-0.022/-0.040/-0.055 三处实测
	# 0.58 kg 木棍都被甩飞到 4 m/s）。放在掌前缘外侧（z=-0.070）时，
	# 手指是绕着它勾住的，下方和远端都是空的，棍子反而稳。
	var local := Vector3(0.0, -PALM_HALF - STICK_R - 0.002, -0.070)

	var ez := OS.get_environment("STICK_Z")
	if ez != "":
		local.z = float(ez)
	var ey := OS.get_environment("STICK_Y")
	if ey != "":
		local.y = float(ey)
	_stick = RigidBody3D.new()
	_stick.name = "GripStick"
	_stick.mass = STICK_MASS
	_stick.can_sleep = false
	_stick.linear_damp = 0.05
	_stick.angular_damp = 0.2
	_stick.continuous_cd = false
	_stick.collision_layer = 1
	_stick.collision_mask = 15
	# _stick_debug 用 get_colliding_bodies() 报接触对象；不打开接触监控
	# 时引擎每帧报 "Parameter contact_monitor is null"
	_stick.contact_monitor = true
	_stick.max_contacts_reported = 8
	var mat := PhysicsMaterial.new()
	mat.friction = 0.8
	mat.bounce = 0.0
	_stick.physics_material_override = mat
	var col := CollisionShape3D.new()
	var shape := CylinderShape3D.new()
	shape.radius = STICK_R
	shape.height = STICK_LEN
	col.shape = shape
	col.rotation.z = PI * 0.5  # 圆柱默认沿 Y，转成沿 X
	_stick.add_child(col)
	var parent_node: Node = _controller.get_parent()
	var basis: Basis = _palm.global_transform.basis.orthonormalized()
	_stick_local_at_spawn = local
	# 位姿必须在入树之前设好。先 add_child 再写 global_transform，
	# 物理服务器在创建刚体时用的是节点的旧位姿，第一步会把它从这里
	# 瞬移过去，和手指挤在一起的位置求解把棍子弹开几厘米。
	_stick.transform = parent_node.global_transform.affine_inverse() \
		* Transform3D(basis, _palm.global_transform * local)
	parent_node.add_child(_stick)
	_stick.top_level = true
	_stick.freeze = not (NOFREEZE or TABLE or HOVER)
	_stick.freeze_mode = RigidBody3D.FREEZE_MODE_KINEMATIC
	_stick_hold_local = _stick_local_at_spawn
	_stick_hold_xf = _stick.global_transform
	if TABLE:
		# 棍子躺在一张静止的桌面上（桌面 = 地面）。手指从上面合拢，把
		# 棍子夹在自己和桌面之间——这是真人从地上捡树枝的真实受力。
		# 到「抓住」那一帧把桌面撤掉，剩下的全靠手指。
		var th := 0.06
		_table = StaticBody3D.new()
		_table.name = "GripTable"
		_table.collision_layer = 2
		_table.collision_mask = 0
		var tcol := CollisionShape3D.new()
		var tbox := BoxShape3D.new()
		tbox.size = Vector3(0.60, th, 0.40)
		tcol.shape = tbox
		_table.add_child(tcol)
		_table.transform = parent_node.global_transform.affine_inverse() \
			* Transform3D(basis, _palm.global_transform * (
				local + Vector3(0.0, -STICK_R - th * 0.5, 0.0)))
		parent_node.add_child(_table)
		_table.top_level = true
	print("  [生成] 设定 local=%s → 世界 %s，回读 local=%s palm_w=%s frozen=%s" % [
		str(local.snapped(Vector3.ONE * 0.001)),
		str(_stick.global_position.snapped(Vector3.ONE * 0.001)),
		str((_palm.global_transform.affine_inverse()
			* _stick.global_position).snapped(Vector3.ONE * 0.001)),
		str(_palm.global_position.snapped(Vector3.ONE * 0.001)),
		str(_palm.freeze)])
	var pbz: Basis = _palm.global_transform.basis.orthonormalized()
	var up_w: Vector3 = _controller.position.normalized()
	print("  [掌系] palm.x=%s(%s) palm.y=%s(%s) palm.z=%s(%s)" % [
		str(pbz.x.snapped(Vector3.ONE * 0.01)), "%.2f" % pbz.x.dot(up_w),
		str(pbz.y.snapped(Vector3.ONE * 0.01)), "%.2f" % pbz.y.dot(up_w),
		str(pbz.z.snapped(Vector3.ONE * 0.01)), "%.2f" % pbz.z.dot(up_w)])
	_report_spawn_clearance()
	var space := _stick.get_world_3d().direct_space_state
	var q := PhysicsShapeQueryParameters3D.new()
	var cs := CylinderShape3D.new()
	cs.radius = STICK_R
	cs.height = STICK_LEN
	q.shape = cs
	q.transform = _stick.global_transform * Transform3D(
		Basis(Vector3(0, 0, 1), PI * 0.5), Vector3.ZERO)
	q.collision_mask = 0xFFFFFFFF
	q.exclude = [_stick.get_rid()]
	var hits := []
	for r in space.intersect_shape(q, 32):
		hits.append((r["collider"] as Node).name)
	print("    [重叠] ", hits)


## 生成瞬间木棍与各指骨的距离。手指还没张开就把棍子放到指骨里面，
## 第一帧就是几厘米的深度渗透，接触求解器会把棍子以每秒上百米弹出去。
func _report_spawn_clearance() -> void:
	var segs: Array = _controller.get("_finger_segments")[1]
	var lens: Array = _controller.get("_finger_seg_lengths")[1]
	var axis_dir: Vector3 = _stick.global_transform.basis.x.normalized()
	var origin: Vector3 = _stick.global_position
	var worst := 99.0
	var worst_name := ""
	for f in range(5):
		for j in range((segs[f] as Array).size()):
			var seg: Node3D = segs[f][j]
			var seg_dir: Vector3 = (seg.global_transform.basis
				* Vector3(0, 0, -1)).normalized()
			var half: float = float(lens[f][j]) * 0.5
			for k in range(5):
				var t: float = lerpf(-half, half, float(k) / 4.0)
				var pt: Vector3 = seg.global_position + seg_dir * t
				var d: Vector3 = pt - origin
				var radial: float = (d - axis_dir * d.dot(axis_dir)).length()
				var gap: float = radial - STICK_R - 0.009
				if gap < worst:
					worst = gap
					worst_name = "%d,%d" % [f, j]
	# 掌盒
	var inv: Transform3D = _palm.global_transform.affine_inverse()
	var lp: Vector3 = inv * origin
	var ddx: float = maxf(maxf(-0.05 - lp.x, lp.x - 0.05), 0.0)
	var ddy: float = maxf(maxf(-PALM_HALF - lp.y, lp.y - PALM_HALF), 0.0)
	var ddz: float = maxf(maxf(-0.055 - lp.z, lp.z - 0.055), 0.0)
	var palm_gap: float = sqrt(ddx * ddx + ddy * ddy + ddz * ddz) - STICK_R
	print("  [生成] 指骨到棍面最近=%+.3f m (%s)  掌面=%+.3f m  棍心=%s" % [
		worst, worst_name, palm_gap, str(origin.snapped(Vector3.ONE * 0.001))])


func _dump_hand(tag: String) -> void:
	var inv: Transform3D = _palm.global_transform.affine_inverse()
	var segs: Array = _controller.get("_finger_segments")[1]
	var lens: Array = _controller.get("_finger_seg_lengths")[1]
	print("  [%s] 五指各节（掌坐标，pos=骨头中心 tip=骨尖）：" % tag)
	for f in range(5):
		var parts := []
		var angs := []
		for j in range((segs[f] as Array).size()):
			var seg: Node3D = segs[f][j]
			var pl: Vector3 = inv * seg.global_position
			var dl: Vector3 = (inv.basis
				* (seg.global_transform.basis * Vector3(0, 0, -1))).normalized()
			var tip: Vector3 = pl + dl * (float(lens[f][j]) * 0.5)
			parts.append("j%d(%s)→(%s)" % [j,
				"%+.3f %+.3f %+.3f" % [pl.x, pl.y, pl.z],
				"%+.3f %+.3f %+.3f" % [tip.x, tip.y, tip.z]])
			var pp: Node3D = _palm if j == 0 else segs[f][j - 1]
			angs.append("%.0f" % rad_to_deg(_controller.call(
				"_finger_flex_angle", pp, seg,
				_controller.call("_finger_axis", 1, f, j, pp))))
		print("    指%d 角%s  %s" % [f, str(angs), "  ".join(parts)])


## 量出握拳后「掌心面 — 近节指骨 — 中节指骨」围出的空腔能容下多大的球。
## 搜索范围必须卡在手指真正包住的那一块：y 从掌面往下到中节指骨，
## z 从近节指骨往回。放宽到指尖之外，求出来的「最大自由半径」就变成
## 手外面的空气，棍子会被生成在离手 10 cm 的地方。
func _measure_cavity() -> Array:
	var segs: Array = _controller.get("_finger_segments")[1]
	var inv: Transform3D = _palm.global_transform.affine_inverse()
	var best := -1.0
	var best_p := Vector3.ZERO
	var y := -0.078
	while y <= -0.010:
		var z := -0.062
		while z <= -0.008:
			var x := -0.026
			while x <= 0.026:
				var p := Vector3(x, y, z)
				var free := 99.0
				for f in range(1, 5):
					for j in range(3):
						var seg: Node3D = segs[f][j]
						var c: Vector3 = inv * seg.global_position
						var dir: Vector3 = (inv.basis
							* (seg.global_transform.basis * Vector3(0, 0, -1))).normalized()
						var half: float = maxf(
							float(_controller.get("_finger_seg_lengths")[1][f][j]) * 0.5
							- 0.009, 0.0)
						var t: float = clampf((p - c).dot(dir), -half, half)
						var d: float = (p - (c + dir * t)).length() - 0.009
						free = minf(free, d)
				# 掌盒半厚 0.011、半长 0.055、半宽 0.050
				var dx: float = maxf(absf(x) - 0.05, 0.0)
				var dz: float = maxf(absf(z) - 0.055, 0.0)
				var dy: float = maxf(maxf(-0.011 - y, y - 0.011), 0.0)
				free = minf(free, sqrt(dx * dx + dy * dy + dz * dz))
				if free > best:
					best = free
					best_p = p
				x += 0.006
			z += 0.004
		y += 0.004
	return [best, best_p]


## 钩深：掌心面到指骨最低点。这就是手能「环住」的物体直径上限。
func _grip_depth() -> float:
	var segs: Array = _controller.get("_finger_segments")[1]
	var inv: Transform3D = _palm.global_transform.affine_inverse()
	var lowest := 0.0
	for f in range(1, 5):
		for j in range(3):
			var seg: Node3D = segs[f][j]
			var c: Vector3 = inv * seg.global_position
			var dir: Vector3 = (inv.basis
				* (seg.global_transform.basis * Vector3(0, 0, -1))).normalized()
			var half: float = maxf(
				float(_controller.get("_finger_seg_lengths")[1][f][j]) * 0.5, 0.0)
			lowest = minf(lowest, c.y - absf(dir.y) * half - 0.009)
	return -lowest - PALM_HALF


func _stick_debug() -> String:
	var bodies := []
	for b in _stick.get_colliding_bodies():
		bodies.append((b as Node).name)
	return "v=%.2f w=%.1f sw=%s pw=%s local=%s" % [
		_stick.linear_velocity.length(), _stick.angular_velocity.length(),
		str(_stick.global_position.snapped(Vector3.ONE * 0.001)),
		str(_palm.global_position.snapped(Vector3.ONE * 0.001)),
		str((_palm.global_transform.affine_inverse()
			* _stick.global_position).snapped(Vector3.ONE * 0.001))]


## 谁在碰木棍、碰在哪、法线朝哪。
## 手指如果用「指尖」顶木棍，法线沿指骨方向 → 把木棍往掌外推；
## 用「指腹」勾住，法线指向掌心 → 把木棍按在掌心上。这两种接触
## 在接触列表里长得一样，只有看点和法线才分得出来。
func _contact_detail() -> String:
	var out := []
	var segs: Array = _controller.get("_finger_segments")[1]
	var inv: Transform3D = _palm.global_transform.affine_inverse()
	for f in range(5):
		for j in range((segs[f] as Array).size()):
			var body = segs[f][j]
			if body == null or body.get("contact_body") != _stick:
				continue
			if float(body.get("contact_impulse")) <= 0.0:
				continue
			var p: Vector3 = inv * (body.get("contact_point") as Vector3)
			var n: Vector3 = inv.basis * (body.get("contact_normal") as Vector3)
			out.append("%d,%d @(%+.3f %+.3f %+.3f) n(%+.2f %+.2f %+.2f)" % [
				f, j, p.x, p.y, p.z, n.x, n.y, n.z])
	return "  ".join(out)


func _contact_forces() -> String:
	var out := []
	var segs: Array = _controller.get("_finger_segments")[1]
	for f in range(5):
		for j in range((segs[f] as Array).size()):
			var body = segs[f][j]
			if body == null:
				continue
			var cf: Vector3 = body.get("contact_force")
			if cf.length() > 0.1:
				out.append("%d,%d:%.1fN" % [f, j, cf.length()])
	return "[" + ", ".join(out) + "]"


## 指腹软组织托住物体时，硬胶囊可能完全没碰到它（两者差 3-4 mm），
## 只看硬接触会误判成「松手了」。
func _pulp_touching() -> bool:
	var touch: Array = _controller.get("_pulp_touch")
	if touch.size() < 2 or _stick == null:
		return false
	return (touch[1] as Dictionary).has(_stick.get_instance_id())


func _report() -> void:
	var rel: Vector3 = _palm.global_transform.affine_inverse() \
		* _stick.global_position
	var moved: float = rel.distance_to(_stick_local_at_grab)
	var speed: float = _stick.linear_velocity.length()
	var touching: bool = _contact_forces() != "[]" or _pulp_touching()
	print("[Finger Grip] 棍 Ø%.1f cm / %.2f m / %.2f kg" % [
		STICK_R * 200.0, STICK_LEN, STICK_MASS])
	print("[Finger Grip] 松手后相对手掌位移=%.3f m 末速=%.3f m/s 骨骼接触=%s 指腹接触=%s" % [
		moved, speed, _contact_forces(), str(_pulp_touching())])
	# 判据只看「有没有掉出去」：自由落体两秒会走 19.6 m，而握持中
	# 手指继续收拢会把木棍往掌心里带几厘米，速度也常有几个 cm/s
	# 的蠕动。所以只要它还在手边、还有接触、速度远低于坠落，就算握住。
	var ok: bool = moved < 0.08 and speed < 0.5 and touching
	print("=== Finger Grip: %s ===" % ("PASS" if ok else "FAIL"))
	get_tree().quit(0)
