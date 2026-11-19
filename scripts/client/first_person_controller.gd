# ============================================================
# FirstPersonController — 球面重力第一人称
# ============================================================
# 手动球面行走：位置始终锁定在星球表面，WASD绕球心旋转。
# ============================================================
class_name FirstPersonController
extends CharacterBody3D

# 接触力探针脚本：显式 preload，避免新 class_name 未进全局缓存
const ContactForceProbeScript = preload("res://scripts/client/contact_force_probe.gd")

@export var mouse_sensitivity: float = 0.002
@export var walk_speed: float = 6.0
@export var sprint_speed: float = 10.0
@export var jump_velocity: float = 6.0
@export var crouch_speed: float = 2.5
## 玩家接触推动力 N（Phase 1 简化；后续可由 PlayerBody 力量/姿势推导）
@export var push_force: float = 240.0
@export var standing_height: float = 1.8
@export var crouch_height: float = 0.9
@export var planet_radius: float = 3978.87

## 地形引用；有它时按真实地表高度行走，否则退回平均球面
var terrain: Terrain = null

## 可见地表网格的高度采样器（WorldRenderer 提供）；优先于精确噪声高度
var ground_sampler: Callable = Callable()

@onready var _camera: Camera3D = $Camera3D
@onready var _collision_shape: CollisionShape3D = $CollisionShape3D

var _yaw: float = 0.0
var _pitch: float = 0.0
var _is_sprinting: bool = false
var _is_crouching: bool = false
var _crouch_held: bool = false
var _crouch_amount: float = 0.0
var _leg_pivots: Array = []

var _body_root: Node3D = null
var _neck_pivot: Node3D = null
var _body_materials: Dictionary = {}
var _stuck_time: float = 0.0

# 手指/关节控制
var _hand_roots: Array = []
var _finger_pivots: Array = []      # [hand][finger] = [prox_pivot, mid_pivot, dist_pivot]
var _finger_angles: Array = []      # [hand][finger] = [prox_deg, mid_deg, dist_deg]
var _selected_fingers: Array = [[false, false, false, false, false], [false, false, false, false, false]]
var _selected_joint: int = 0
var _finger_hud: Label = null
var _hud_timer: float = 0.0

# 手臂关节控制
var _arm_pivots: Array = []         # [hand] = {shoulder, elbow, wrist}
var _arm_angles: Array = []         # [hand] = {shoulder_x, shoulder_z, elbow_x, wrist_x, wrist_y}
var _selected_arm_joint: int = 0
var _finger_seg_lengths: Array = []   # [hand][finger] = [prox_len, mid_len, dist_len]
var _palm_bodies: Array = []          # [hand] RigidBody3D 手掌（腕关节末端）
var _last_hand_ground_strike_ms: int = 0
var _finger_segments: Array = []      # [hand][finger] = [RigidBody3D x3]
## [hand] 拇指 CMC 的过渡刚体：掌骨与手掌之间多串一个无碰撞刚体，
## 两个铰链（内收 + 屈曲）合起来才是两自由度 CMC。见 [_build_fingers_for_hand]。
var _thumb_cradle: Array = []
## [hand] 拇指 CMC 内收铰链的描述（_joint_angle 用）
var _thumb_adduct_joint: Array = []
## [hand][finger][seg] = [{"p": 指腹采样点(骨局部坐标), "n": 指腹法线(骨局部)}]。
## 指骨是 5 mm 硬骨，外面还有 4 mm 可压缩的指腹软组织，见 [_update_finger_pads]。
var _pulp_pads: Array = []
## [hand] = {body_instance_id: true}：上一物理步被指腹软组织顶到的物体。
## 指腹把物体托住时硬胶囊可能完全没碰到它（差 3-4 mm），只看硬接触
## 会误判成「没握住」，所以接触判定要能查到这里。
var _pulp_touch: Array = []
var _finger_joints: Array = []        # [hand][finger] = [HingeJoint3D x3]
## [hand][finger][joint] = 屈曲轴在**父刚体局部坐标**里的固定向量。
## 关节的轴在建立约束那一刻就固化在两侧刚体的局部系里，运行时
## 必须按同一个局部向量还原，不能每个关节重新按世界方向推一遍。
var _finger_axis_local: Array = []
## [hand][finger][joint] = [参考向量在父刚体局部系, 在子刚体局部系]。
## 屈曲角必须绕轴量，而参考向量本身不能和轴平行。四指用掌 z 当参考，
## 拇指绕的就是掌 z——掌 z 在拇指这里退化了，得改用掌 x。参考向量在
## 关节建立时一次定死，运行时两侧各自按自己的刚体还原。
var _finger_ref_local: Array = []
var _hand_physics_root: Node3D = null
# 真物理手臂：肩锚点(运动学) → 上臂 → 前臂 → 手掌，全部由铰链+肌肉力矩驱动
var _shoulder_anchors: Array = []     # [hand] StaticBody3D，跟随躯干
var _shoulder_roll_bodies: Array = [] # [hand] RigidBody3D，肩部横滚中间体
var _arm_bodies: Array = []           # [hand] = {upper, forearm}
var _arm_joints: Array = []           # [hand] = [joint dict x4]
var _arm_active_until: Array = []     # [hand] = {key: msec} 最近主动控制时刻
var _finger_active_until: Array = []  # [hand][finger] = [msec x3]
## 指关节当前已建立的肌肉力矩（N·m）。肌肉张力不是开关，从零升到
## 满力要 ~0.1 s；直接给满力矩会像锤子一样把物体和手臂一起打飞。
var _finger_grip_force: Array = []    # [hand][finger] = [float x3]
## 骨骼断裂状态：骨头承受的载荷超过骨材料极限时，关节在受力点断开
var _arm_broken: Array = []             # [hand] = {joint_key: true}
var _finger_broken: Array = []          # [hand][finger] = [bool x3]
var _detached_from_torso: Dictionary = {}  # instance_id -> true，不再随躯干搬运
var _detached_from_palm: Dictionary = {}   # instance_id -> true，不再随手掌搬运
var _bone_message: String = ""
## 玩家身体属性：力量决定每个关节的支撑力矩与锻炼成长
var _player_body: PlayerBody = null
var _body_skin: StandardMaterial3D = null
# 连续皮肉层：所有骨骼段共享一张网格，由关节姿态每帧重扫掠
var _skin_mesh: MeshInstance3D = null
var _skin_im: ImmediateMesh = null
var _skin_material: StandardMaterial3D = null
const SKIN_RING_SEGMENTS := 10
const SKIN_CHAIN_SPACING := 0.045
## 真物理手：手掌为运动学锚点，指骨为刚体，由铰链约束
var _physical_hands_enabled: bool = true
const ARM_JOINT_LABELS := [
	"L shoulder pitch", "L shoulder roll", "L elbow", "L wrist pitch",
	"L wrist twist",
	"R shoulder pitch", "R shoulder roll", "R elbow", "R wrist pitch",
	"R wrist twist",
]
const ARM_JOINT_KEYS := [
	"shoulder_x", "shoulder_z", "elbow_x", "wrist_x", "wrist_y",
	"shoulder_x", "shoulder_z", "elbow_x", "wrist_x", "wrist_y",
]
const ARM_JOINTS_PER_HAND := 5


func _ready() -> void:
	# 本次轮回的身体：先天属性随机，力量 300 N × physique(0.7-1.3)
	_player_body = PlayerBody.new()
	_player_body.roll_innate_traits()
	var capsule := CapsuleShape3D.new()
	# 躯干半宽：肩关节在 ±0.28 m，手臂自然垂下时在胶囊外，不会出生即被弹开
	capsule.radius = 0.22
	capsule.height = standing_height
	_collision_shape.shape = capsule
	_collision_shape.position = Vector3(0, standing_height * 0.5, 0)

	floor_max_angle = deg_to_rad(80.0)
	floor_snap_length = 1.0
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	collision_layer = 8   # 玩家专用层，避免手部碰撞体与自身相撞
	collision_mask = 3 | 8    # 地形/物品 + 自己的手脚 layer 4（正常自身碰撞）

	_camera.near = 0.03
	_build_body()
	_apply_crouch_pose(0.0)
	_build_hud()
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func spawn_on_surface(surface_pos: Vector3, look_target = null) -> void:
	var sky := surface_pos.normalized()
	var ground_r := _ground_radius(surface_pos)
	position = sky * (ground_r + 0.3)
	velocity = Vector3.ZERO
	_yaw = 0.0
	_pitch = 0.0
	_update_orientation()
	if look_target is Vector3:
		look_toward(look_target)
	# 真物理手：必须等角色落到最终位置后再建，否则刚体会被瞬移甩飞
	if _physical_hands_enabled:
		_build_hand_physics()
	print("Player spawned at distance=", position.length(), " ground=", ground_r)


## 让镜头朝向世界坐标中的某点（出生时用来面向附近的树/物品）
func look_toward(target: Vector3) -> void:
	_update_orientation()
	var to_target := (target - _camera.global_position)
	if to_target.length() < 0.001:
		return
	to_target = to_target.normalized()

	var local_dir := transform.basis.inverse() * to_target
	_pitch = asin(clampf(local_dir.y, -1.0, 1.0))
	_yaw = atan2(-local_dir.x, -local_dir.z)
	_update_orientation()


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		# 按住右键时鼠标上下控制选中关节张合，否则控制视角
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT):
			_adjust_selected_joint(-event.relative.y * 0.5)
			return
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, deg_to_rad(-89), deg_to_rad(89))

	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_adjust_selected_arm_joint(-4.0)
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_adjust_selected_arm_joint(4.0)
			return

	if event is InputEventKey and event.pressed:
		var kc: int = event.keycode
		# 1-5 左手五根手指，6-0 右手五根手指
		if kc >= KEY_1 and kc <= KEY_5:
			_select_finger(0, int(kc - KEY_1))
			return
		if kc >= KEY_6 and kc <= KEY_9:
			_select_finger(1, int(kc - KEY_6))
			return
		if kc == KEY_0:
			_select_finger(1, 4)
			return
		# 1 左边的 ` 键切换手指关节
		if kc == KEY_QUOTELEFT or kc == KEY_ASCIITILDE:
			_selected_joint = (_selected_joint + 1) % 3
			_update_finger_hud()
			return
		# F 切换手臂关节
		if kc == KEY_F:
			_selected_arm_joint = (_selected_arm_joint + 1) % ARM_JOINT_LABELS.size()
			_update_finger_hud()
			return

	if event is InputEventKey:
		if event.pressed and event.keycode == KEY_ESCAPE:
			Input.set_mouse_mode(
				Input.MOUSE_MODE_VISIBLE if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
				else Input.MOUSE_MODE_CAPTURED)
		if event.keycode == KEY_SHIFT:
			_is_sprinting = event.pressed
		if event.pressed and event.keycode == KEY_C:
			_is_crouching = not _is_crouching


func _physics_process(delta: float) -> void:
	# 出生前位置可能在原点，等延迟出生完成后再跑物理
	if position.length() < 1.0:
		return
	# 供地面物品的防穿模射线判断「是否在玩家视野附近」
	ItemPhysicsBody.player_position = global_position
	_crouch_held = Input.is_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_CTRL)
	var crouch_target: float = 1.0 if (_crouch_held or _is_crouching) else 0.0
	_crouch_amount = move_toward(_crouch_amount, crouch_target, delta * 5.0)
	_apply_crouch_pose(_crouch_amount)

	var sky := position.normalized()
	up_direction = sky

	# 球心重力，大小随海拔按 g(h)=g0·(R/(R+h))² 衰减
	var altitude: float = maxf(position.length() - planet_radius, 0.0)
	var gravity: float = PhysicsConstants.get_gravity_at_altitude(altitude)
	velocity -= sky * gravity * delta

	# WASD 在相机切平面内移动
	var input := Vector2.ZERO
	if Input.is_action_pressed("move_forward"): input.y += 1
	if Input.is_action_pressed("move_backward"): input.y -= 1
	if Input.is_action_pressed("move_left"): input.x -= 1
	if Input.is_action_pressed("move_right"): input.x += 1

	var speed: float = sprint_speed if _is_sprinting else walk_speed
	if _crouch_amount > 0.5 or _is_crouching:
		speed = crouch_speed

	var vertical_speed: float = velocity.dot(sky)
	var tangent_velocity: Vector3 = velocity - sky * vertical_speed

	var move_dir := Vector3.ZERO
	if input.length() > 0.01 and _camera:
		var cam_fwd := -_camera.global_transform.basis.z
		var cam_rt := _camera.global_transform.basis.x
		var fwd := (cam_fwd - sky * cam_fwd.dot(sky)).normalized()
		var rgt := (cam_rt - sky * cam_rt.dot(sky)).normalized()
		var move := (fwd * input.y + rgt * input.x)
		if move.length() > 0.01:
			move_dir = move.normalized()
			tangent_velocity = move_dir * speed
	elif is_on_floor():
		tangent_velocity = tangent_velocity.move_toward(Vector3.ZERO, 25.0 * delta)

	if move_dir == Vector3.ZERO:
		var tangent := velocity - sky * velocity.dot(sky)
		if tangent.length() > 0.2:
			move_dir = tangent.normalized()

	velocity = tangent_velocity + sky * vertical_speed

	# 跳跃
	if Input.is_action_just_pressed("interact") and is_on_floor():
		velocity += sky * jump_velocity

	# 主要动作：用当前身体力量对前方近场地面施力（土→粒子，岩石→碎片）
	if Input.is_action_just_pressed("primary_action") and _camera != null:
		var renderer = get_node_or_null("../WorldRenderer")
		if renderer != null:
			var force_n: float = 600.0
			if _player_body != null:
				force_n = _player_body.get_max_force() * 2.0
			var hand_tool := MaterialDB.get_material("bone")
			renderer.strike_ground(global_position,
				-_camera.global_transform.basis.z, force_n, hand_tool)

	# 真正走物理碰撞：地形 + 树干都会挡住
	var position_before := global_position
	move_and_slide()

	# 玩家在接触点施力；刚体按质量/形状/摩擦自行决定滑动、滚动和距离
	_push_contacted_items(delta, move_dir)

	# 自动跨越低矮石头/倒木/地形台阶，避免平地被小物件卡死
	_try_step_over(move_dir, position_before, sky)

	# 落地后清掉继续向下的径向速度，避免重力累积
	if is_on_floor():
		var inward := velocity.dot(sky)
		if inward < 0.0:
			velocity -= sky * inward

	# 最后的兜底：完全没有滑动碰撞但仍然被卡住时，轻微抬升
	var horizontal_speed := (velocity - sky * velocity.dot(sky)).length()
	if input.length() > 0.01 and is_on_floor() and horizontal_speed < 0.25:
		_stuck_time += delta
		if _stuck_time > 0.8:
			global_position += sky * 0.12
			_stuck_time = 0.0
	else:
		_stuck_time = 0.0

	_update_orientation()
	_update_hand_physics()
	_check_hand_ground_contact()



func _finger_closed_count(hand: int) -> int:
	var count := 0
	for f in range(5):
		var avg := (float(_finger_angles[hand][f][0]) + float(_finger_angles[hand][f][1])) * 0.5
		if avg > 35.0:
			count += 1
	return count


func _item_step_height(item: ItemEntity) -> float:
	if item == null:
		return 0.0
	var dims := item.dimensions
	match item.shape:
		"fiber":
			return float(dims.get("diameter", dims.get("width", 0.2)))
		"sphere":
			return float(dims.get("radius", 0.2)) * 2.0
		_:
			return float(dims.get("height", 0.2))


func _try_step_over(move_dir: Vector3, position_before: Vector3, sky: Vector3) -> void:
	if move_dir.length() < 0.01 or not is_on_floor():
		return

	var moved := global_position - position_before
	var horizontal_moved := (moved - sky * moved.dot(sky)).length()
	if horizontal_moved > 0.03:
		return

	var step_height := 0.0
	var blocked := false
	for i in range(get_slide_collision_count()):
		var collision := get_slide_collision(i)
		var collider = collision.get_collider()
		if collider is ItemPhysicsBody:
			var item: ItemEntity = collider.item
			var h := _item_step_height(item)
			if h <= 0.0 or h > 0.60:
				return  # 太高/未知物体，不跨
			step_height = maxf(step_height, h + 0.10)
			blocked = true
		elif collider is StaticBody3D:
			# 地形/树干不在这里自动跨；交给最后的兜底自救
			return
		else:
			return

	if blocked and step_height > 0.0:
		global_position += sky * step_height
		_stuck_time = 0.0


func _push_contacted_items(delta: float, push_dir: Vector3) -> void:
	if push_dir.length() < 0.01:
		return
	for i in range(get_slide_collision_count()):
		var collision := get_slide_collision(i)
		var collider = collision.get_collider()
		if not (collider is ItemPhysicsBody):
			continue
		var normal: Vector3 = collision.get_normal()
		if push_dir.dot(normal) >= 0.0:
			continue
		# 推东西的超不过自己走的速度：物品已经跟上来就不再施力。
		# 否则每一物理帧都补一份冲量，轻的木棍会被推到几十 m/s
		# 直接钻进三角网地形里。
		var dir_n: Vector3 = push_dir.normalized()
		var my_speed: float = velocity.dot(dir_n)
		if collider.linear_velocity.dot(dir_n) >= maxf(my_speed, 0.0):
			continue
		# 接触点相对刚体原点的偏移 → 产生平移 + 转矩（推走 / 翻倒 / 滚动）
		var contact_offset: Vector3 = collision.get_position() - collider.global_position
		var impulse: Vector3 = dir_n * push_force * delta
		collider.apply_central_impulse(impulse)
		collider.apply_torque_impulse(contact_offset.cross(impulse))


func _ground_radius(at_position: Vector3) -> float:
	if ground_sampler.is_valid():
		return float(ground_sampler.call(at_position))
	if terrain != null:
		return terrain.get_surface_radius(at_position)
	return planet_radius


func _update_orientation() -> void:
	if not _camera:
		return

	var sky := position.normalized()
	if sky.length() < 0.01:
		return

	# body: 脚朝球心、头朝天空
	var ref := Vector3(0, 1, 0)
	if abs(sky.dot(ref)) > 0.99:
		ref = Vector3(1, 0, 0)
	var east := ref.cross(sky).normalized()
	var north := sky.cross(east).normalized()
	transform.basis = Basis(east, sky, -north)

	# 身体跟随水平朝向；头/颈承担一部分俯仰，镜头承担剩余部分
	if _body_root != null:
		_body_root.rotation.y = _yaw
	if _neck_pivot != null:
		var neck_pitch: float = clampf(_pitch * 0.65, deg_to_rad(-50.0), deg_to_rad(50.0))
		_neck_pivot.rotation.x = neck_pitch
		_camera.rotation = Vector3(_pitch - neck_pitch, 0.0, 0.0)
	else:
		_camera.rotation = Vector3(_pitch, 0.0, 0.0)


func _apply_crouch_pose(amount: float) -> void:
	var capsule: CapsuleShape3D = _collision_shape.shape
	capsule.height = lerpf(standing_height, crouch_height, amount)
	_collision_shape.position = Vector3(0, capsule.height * 0.5, 0)
	if _body_root != null:
		_body_root.scale = Vector3(1.0, lerpf(1.0, 0.55, amount), 1.0)
	_apply_leg_pose(amount)


func _apply_leg_pose(amount: float) -> void:
	for leg in _leg_pivots:
		var hip: Node3D = leg["hip"]
		var knee: Node3D = leg["knee"]
		var ankle: Node3D = leg["ankle"]
		hip.rotation.x = deg_to_rad(-55.0) * amount
		knee.rotation.x = deg_to_rad(95.0) * amount
		ankle.rotation.x = deg_to_rad(-40.0) * amount


# ============================================================
# 第一人称可见身体
# ============================================================

func _build_body() -> void:
	_body_root = Node3D.new()
	_body_root.name = "BodyRoot"
	add_child(_body_root)

	var skin := _body_mat(Color(0.72, 0.55, 0.42))
	_body_skin = skin
	var boots := _body_mat(Color(0.12, 0.10, 0.08))

	# 髋/膝/踝可动腿
	_build_legs()
	# 肩/肘/腕可动的手臂 + 手指
	_build_arms(skin)
	# 颈部枢轴（颈和头由连续皮肤网格扫掠出来）
	_neck_pivot = Node3D.new()
	_neck_pivot.name = "NeckPivot"
	_neck_pivot.position = Vector3(0.0, 1.31, 0.05)
	_body_root.add_child(_neck_pivot)
	# 面部标记，让抬头/低头的头部朝向可见（眼睛在镜头后方，不挡视野）
	var eye_l := _add_sphere(0.018, Vector3(-0.035, 0.235, -0.105), boots, _neck_pivot)
	eye_l.name = "EyeLeft"
	var eye_r := _add_sphere(0.018, Vector3(0.035, 0.235, -0.105), boots, _neck_pivot)
	eye_r.name = "EyeRight"
	var nose := _add_sphere(0.024, Vector3(0.0, 0.205, -0.115), skin, _neck_pivot)
	nose.name = "Nose"

	# 一整张皮肉网格包住所有骨骼（不再由分段胶囊拼装）
	_build_body_skin()

	# 镜头放在两眼之间中点（头部前方表面）。头部网格保留，
	# 相机在面部表面，头在相机后方，不会挡视线。
	# 未来 VR：在同一 _neck_pivot 下加左右眼两个 Camera3D（间距约 0.064m）。
	var old_parent := _camera.get_parent()
	if old_parent != null:
		old_parent.remove_child(_camera)
	_neck_pivot.add_child(_camera)
	_camera.position = Vector3(0.0, 0.24, -0.11)
	_camera.rotation = Vector3.ZERO


# ============================================================
# 连续皮肤网格
# ============================================================
# 现实里人是一层连续的皮肉包着骨头，不是一节节分开的。控制仍然
# 按关节/骨骼做（pivot 层级），但可见表面由一条条沿骨链扫掠的管状
# 曲面生成：躯干、颈+头、双臂、双腿连成同一张网格。相邻部分互相
# 插入对方内部，接缝被不透明表面盖住，看起来就是一整片皮肉。
# ============================================================

func _build_body_skin() -> void:
	if _body_root == null:
		return
	_skin_material = StandardMaterial3D.new()
	_skin_material.albedo_color = Color.WHITE
	_skin_material.vertex_color_use_as_albedo = true
	_skin_material.roughness = 0.9
	# 双面渲染，避免某些弯曲角度下背面剔除露出内壁
	_skin_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	_skin_im = ImmediateMesh.new()
	_skin_mesh = MeshInstance3D.new()
	_skin_mesh.name = "BodySkin"
	_skin_mesh.mesh = _skin_im
	_skin_mesh.material_override = _skin_material
	_body_root.add_child(_skin_mesh)
	_rebuild_body_skin()


func _rebuild_body_skin() -> void:
	if _skin_im == null or _body_root == null:
		return
	_skin_tri_count = 0
	_skin_step_count = 0
	_skin_im.clear_surfaces()
	_skin_im.surface_begin(Mesh.PRIMITIVE_TRIANGLES)

	var skin_col := Color(0.72, 0.55, 0.42)
	var shirt_col := Color(0.28, 0.34, 0.40)
	var pants_col := Color(0.20, 0.19, 0.18)
	var boots_col := Color(0.12, 0.10, 0.08)

	# 躯干：骨盆 → 腰 → 胸廓 → 颈根
	_skin_chain([
		[Vector3(0.0, 0.80, 0.02), 0.16, pants_col],
		[Vector3(0.0, 0.90, 0.01), 0.15, pants_col],
		[Vector3(0.0, 0.98, 0.0), 0.145, shirt_col],
		[Vector3(0.0, 1.12, -0.02), 0.19, shirt_col],
		[Vector3(0.0, 1.25, 0.01), 0.16, shirt_col],
		[Vector3(0.0, 1.31, 0.05), 0.07, shirt_col],
	])

	# 颈 + 头：跟随颈部枢轴一起俯仰
	if _neck_pivot != null:
		var nb: Transform3D = _neck_pivot.transform
		_skin_chain([
			[nb * Vector3(0.0, 0.0, 0.0), 0.065, skin_col],
			[nb * Vector3(0.0, 0.10, -0.005), 0.055, skin_col],
			[nb * Vector3(0.0, 0.16, 0.0), 0.075, skin_col],
			[nb * Vector3(0.0, 0.22, 0.0), 0.10, skin_col],
			[nb * Vector3(0.0, 0.30, 0.0), 0.055, skin_col],
		])

	# 双臂：从胸腔内部穿出肩关节，一直到手掌。
	# 真物理手臂的皮肤跟随刚体实际位姿；否则用运动学 pivot 参考。
	for h in range(_arm_pivots.size()):
		if h >= _hand_roots.size():
			continue
		var side: float = -1.0 if h == 0 else 1.0
		if _physical_hands_enabled and h < _arm_bodies.size():
			var upper: RigidBody3D = _arm_bodies[h]["upper"]
			var fore: RigidBody3D = _arm_bodies[h]["forearm"]
			var palm_body: RigidBody3D = _palm_bodies[h]
			# 掌面扁平方向 = 手掌局部 Y，换算到 BodyRoot 局部系
			var palm_normal_local: Vector3 = (
				_body_root.global_transform.basis.inverse()
				* palm_body.global_transform.basis.y).normalized()
			var half_u: float = UPPER_ARM_LENGTH * 0.5
			var half_f: float = FOREARM_LENGTH * 0.5
			var shoulder_w: Vector3 = upper.global_transform * Vector3(0.0, half_u, 0.0)
			# 断端分别取各自骨头的端点：骨折后两段会随刚体分开
			var elbow_upper_w: Vector3 = upper.global_transform * Vector3(0.0, -half_u, 0.0)
			var elbow_fore_w: Vector3 = fore.global_transform * Vector3(0.0, half_f, 0.0)
			var wrist_w: Vector3 = fore.global_transform * Vector3(0.0, -half_f, 0.0)
			var wrist_palm_w: Vector3 = palm_body.global_transform * Vector3(0.0, 0.0, 0.045)
			var palm_w: Vector3 = palm_body.global_transform * Vector3(0.0, 0.0, -0.02)
			var knuckle_w: Vector3 = palm_body.global_transform * Vector3(0.0, 0.0, -0.06)
			var broken: Dictionary = _arm_broken[h] if h < _arm_broken.size() else {}
			var shoulder_broken: bool = bool(broken.get("shoulder_x", false)) \
				or bool(broken.get("shoulder_z", false))
			var elbow_broken: bool = bool(broken.get("elbow_x", false))
			var wrist_broken: bool = bool(broken.get("wrist_x", false)) \
				or bool(broken.get("wrist_y", false))

			var pieces: Array = []
			var cur: Array = []
			if not shoulder_broken:
				cur.append([Vector3(0.14 * side, 1.22, -0.01), 0.075, skin_col])
			cur.append([_body_root.to_local(shoulder_w), 0.065, skin_col])
			cur.append([_body_root.to_local(elbow_upper_w), 0.048, skin_col])
			if elbow_broken:
				pieces.append(cur)
				cur = [[_body_root.to_local(elbow_fore_w), 0.048, skin_col]]
				cur.append([_body_root.to_local(wrist_w), 0.034, skin_col])
			else:
				cur.append([_body_root.to_local(wrist_w), 0.034, skin_col])
			if wrist_broken:
				pieces.append(cur)
				cur = [[_body_root.to_local(wrist_palm_w), 0.024, skin_col, 0.7]]
			# 掌段沿手掌法线压扁：宽度保持，厚度收到约 1/3，
			# 是原来的连续皮肉变扁，不是额外插一块板
			cur.append([_body_root.to_local(palm_w), 0.026, skin_col, 0.35])
			cur.append([_body_root.to_local(knuckle_w), 0.022, skin_col, 0.5])
			pieces.append(cur)
			for piece in pieces:
				_skin_chain(piece, palm_normal_local)
		else:
			var arm: Dictionary = _arm_pivots[h]
			var shoulder: Node3D = arm["shoulder"]
			var elbow: Node3D = arm["elbow"]
			var wrist: Node3D = arm["wrist"]
			var hand: Node3D = _hand_roots[h]
			var hand_normal_local: Vector3 = (
				_body_root.global_transform.basis.inverse()
				* hand.global_transform.basis.y).normalized()
			_skin_chain([
				[Vector3(0.14 * side, 1.22, -0.01), 0.075, skin_col],
				[_body_root.to_local(shoulder.global_position), 0.065, skin_col],
				[_body_root.to_local(elbow.global_position), 0.048, skin_col],
				[_body_root.to_local(wrist.global_position), 0.034, skin_col],
				[_body_root.to_local(hand.global_transform * Vector3(0.0, 0.0, -0.02)),
					0.045, skin_col, 0.35],
				[_body_root.to_local(hand.global_transform * Vector3(0.0, 0.0, -0.06)),
					0.04, skin_col, 0.5],
			], hand_normal_local)

	# 手指：真物理指骨是刚体，位姿每帧由物理决定；皮肉同样沿整根
	# 手指一次扫掠，指节处不会露出分段的碰撞胶囊。
	if _physical_hands_enabled and _finger_segments.size() > 0:
		for h in range(_finger_segments.size()):
			if h >= _hand_roots.size() or h >= _palm_bodies.size():
				continue
			var palm_body: RigidBody3D = _palm_bodies[h]
			var knuckle_l := _body_root.to_local(
				palm_body.global_transform * Vector3(0.0, 0.0, -0.05))
			for f in range(_finger_segments[h].size()):
				var segs: Array = _finger_segments[h][f]
				if segs.is_empty():
					continue
				var ctrl: Array = [[knuckle_l, 0.011, skin_col]]
				for j in range(segs.size()):
					var seg: RigidBody3D = segs[j]
					var seg_len: float = float(_finger_seg_lengths[h][f][j])
					var start_l := _body_root.to_local(
						seg.global_transform * Vector3(0.0, 0.0, seg_len * 0.5))
					ctrl.append([start_l, 0.0095, skin_col])
				var last_idx: int = segs.size() - 1
				var last_seg: RigidBody3D = segs[last_idx]
				var last_len: float = float(_finger_seg_lengths[h][f][last_idx])
				var tip_l := _body_root.to_local(
					last_seg.global_transform * Vector3(0.0, 0.0, -last_len * 0.5))
				ctrl.append([tip_l, 0.008, skin_col])
				# 指骨断了就在断点把皮肉分成两段，别把断开的指节拉回原位
				var flags: Array = [false, false, false]
				if h < _finger_broken.size() and f < _finger_broken[h].size():
					flags = _finger_broken[h][f]
				var start: int = 1 if bool(flags[0]) else 0
				var pieces: Array = []
				var cur: Array = [ctrl[start]]
				for i in range(start + 1, ctrl.size()):
					var jd_idx: int = i - 1
					var cut: bool = jd_idx < flags.size() and bool(flags[jd_idx])
					if cut:
						# 断口近侧的皮肉必须收在**近侧骨节自己的远端**。
						# 直接把 ctrl[i]（断口另一侧的起点）接到这一段上，
						# 两段骨头分开掉落后，皮肉会被拉成一根几米长的
						# 管子，每帧扫掠的采样点数随距离无限增长。
						var near_i: int = i - 2
						if near_i >= 0:
							var near_seg: RigidBody3D = segs[near_i]
							var near_len: float = float(_finger_seg_lengths[h][f][near_i])
							cur.append([_body_root.to_local(
								near_seg.global_transform * Vector3(0.0, 0.0, -near_len * 0.5)),
								0.0095, skin_col])
						pieces.append(cur)
						cur = [ctrl[i]]
					else:
						cur.append(ctrl[i])
				pieces.append(cur)
				for piece in pieces:
					_skin_chain(piece)

	# 双腿：从骨盆内部穿出髋关节，经膝到脚
	for leg in _leg_pivots:
		var hip: Node3D = leg["hip"]
		var knee: Node3D = leg["knee"]
		var ankle: Node3D = leg["ankle"]
		var hip_l := _body_root.to_local(hip.global_position)
		var knee_l := _body_root.to_local(knee.global_position)
		var ankle_l := _body_root.to_local(ankle.global_position)
		var toe_l := _body_root.to_local(ankle.global_transform * Vector3(0.0, -0.02, -0.14))
		_skin_chain([
			[hip_l + Vector3(0.0, 0.03, 0.0), 0.095, pants_col],
			[hip_l, 0.09, pants_col],
			[knee_l, 0.06, pants_col],
			[ankle_l, 0.042, pants_col],
			[toe_l, 0.05, boots_col],
		])

	_skin_im.surface_end()


## 把控制点细分后扫掠成管状曲面；控制点格式 [位置, 半径, 颜色]
func _skin_chain(ctrl: Array, flatten_dir: Vector3 = Vector3.ZERO) -> void:
	if ctrl.size() < 2:
		return
	var pts: Array = []
	var radii: Array = []
	var colors: Array = []
	var flats: Array = []
	for i in range(ctrl.size() - 1):
		var p0: Vector3 = ctrl[i][0]
		var p1: Vector3 = ctrl[i + 1][0]
		var r0: float = ctrl[i][1]
		var r1: float = ctrl[i + 1][1]
		var c0: Color = ctrl[i][2]
		var c1: Color = ctrl[i + 1][2]
		# 可选第 4 项：该点在 flatten_dir 方向上的厚度缩放（1=圆管，0.35=扁）
		var f0: float = float(ctrl[i][3]) if ctrl[i].size() > 3 else 1.0
		var f1: float = float(ctrl[i + 1][3]) if ctrl[i + 1].size() > 3 else 1.0
		var steps: int = maxi(1, int(ceil(p0.distance_to(p1) / SKIN_CHAIN_SPACING)))
		# 跨度异常（断骨飞出去、姿态撕裂）时步数会爆炸，每帧几万个
		# 顶点把主线程拖死。封顶 16 步 = 0.72 m，正常肢体远够。
		steps = mini(steps, 16)
		_skin_step_count += steps
		for s in range(steps):
			var t: float = float(s) / float(steps)
			pts.append(p0.lerp(p1, t))
			radii.append(lerpf(r0, r1, t))
			colors.append(c0.lerp(c1, t))
			flats.append(lerpf(f0, f1, t))
	pts.append(ctrl[-1][0])
	radii.append(ctrl[-1][1])
	colors.append(ctrl[-1][2])
	flats.append(float(ctrl[-1][3]) if ctrl[-1].size() > 3 else 1.0)
	_sweep_tube(pts, radii, colors, flats, flatten_dir)


func _sweep_tube(pts: Array, radii: Array, colors: Array,
		flats: Array = [], flatten_dir: Vector3 = Vector3.ZERO) -> void:
	var n: int = pts.size()
	if n < 2:
		return

	# 每个采样点的切线
	var tangents: Array = []
	for i in range(n):
		var t: Vector3
		if i == 0:
			t = (pts[1] - pts[0]).normalized()
		elif i == n - 1:
			t = (pts[n - 1] - pts[n - 2]).normalized()
		else:
			t = (pts[i + 1] - pts[i - 1]).normalized()
		tangents.append(t)

	# 平行传输坐标系，避免管体扭转
	var u: Vector3 = Vector3.UP
	if absf(tangents[0].dot(u)) > 0.99:
		u = Vector3.RIGHT
	u = (u - tangents[0] * u.dot(tangents[0])).normalized()

	var rings: Array = []
	for i in range(n):
		if i > 0:
			var from_t: Vector3 = tangents[i - 1]
			var to_t: Vector3 = tangents[i]
			var q := Quaternion(from_t, to_t)
			u = q * u
		u = (u - tangents[i] * u.dot(tangents[i])).normalized()
		var v: Vector3 = u.cross(tangents[i]).normalized()
		var ring: Array = []
		var ring_normals: Array = []
		var r: float = radii[i]
		var flat: float = float(flats[i]) if i < flats.size() else 1.0
		var fdir := flatten_dir.normalized() if flatten_dir.length() > 0.001 \
			else Vector3.ZERO
		for j in range(SKIN_RING_SEGMENTS):
			var ang: float = TAU * float(j) / float(SKIN_RING_SEGMENTS)
			var dir: Vector3 = (u * cos(ang) + v * sin(ang)).normalized()
			var offset: Vector3 = dir * r
			if fdir != Vector3.ZERO and flat < 0.999:
				# 只压扁沿 flatten_dir 的厚度分量，宽度不变：手掌从圆管
				# 变成扁掌，而不是插一块平板
				var comp: Vector3 = fdir * offset.dot(fdir)
				offset -= comp * (1.0 - flat)
			ring.append(pts[i] + offset)
			ring_normals.append(offset.normalized() if offset.length() > 0.0001
				else dir)
		rings.append({"pts": ring, "normals": ring_normals})

	for i in range(n - 1):
		var a: Array = rings[i]["pts"]
		var b: Array = rings[i + 1]["pts"]
		var an: Array = rings[i]["normals"]
		var bn: Array = rings[i + 1]["normals"]
		var c0: Color = colors[i]
		var c1: Color = colors[i + 1]
		for j in range(SKIN_RING_SEGMENTS):
			var j2: int = (j + 1) % SKIN_RING_SEGMENTS
			_add_skin_tri(a[j], c0, an[j], b[j2], c1, bn[j2], a[j2], c0, an[j2])
			_add_skin_tri(a[j], c0, an[j], b[j], c1, bn[j], b[j2], c1, bn[j2])

	# 两端封口，避免露出管体内壁
	var t0: Vector3 = tangents[0]
	var start_center: Vector3 = pts[0] - t0 * radii[0] * 0.35
	var tn: Vector3 = tangents[n - 1]
	var end_center: Vector3 = pts[n - 1] + tn * radii[n - 1] * 0.35
	var c_start: Color = colors[0]
	var c_end: Color = colors[n - 1]
	for j in range(SKIN_RING_SEGMENTS):
		var j2: int = (j + 1) % SKIN_RING_SEGMENTS
		_add_skin_tri(start_center, c_start, -t0, rings[0]["pts"][j2], c_start, -t0,
			rings[0]["pts"][j], c_start, -t0)
		_add_skin_tri(end_center, c_end, tn, rings[n - 1]["pts"][j], c_end, tn,
			rings[n - 1]["pts"][j2], c_end, tn)


var _skin_tri_count: int = 0
var _skin_step_count: int = 0


func _add_skin_tri(p0: Vector3, c0: Color, n0: Vector3,
		p1: Vector3, c1: Color, n1: Vector3,
		p2: Vector3, c2: Color, n2: Vector3) -> void:
	_skin_tri_count += 1
	_skin_im.surface_set_color(c0)
	_skin_im.surface_set_normal(n0)
	_skin_im.surface_add_vertex(p0)
	_skin_im.surface_set_color(c1)
	_skin_im.surface_set_normal(n1)
	_skin_im.surface_add_vertex(p1)
	_skin_im.surface_set_color(c2)
	_skin_im.surface_set_normal(n2)
	_skin_im.surface_add_vertex(p2)


func _process(delta: float) -> void:
	# 关节姿态随时变化，皮肉网格每帧按骨骼当前位置重新扫掠
	_rebuild_body_skin()
	_hud_timer += delta
	if _hud_timer >= 0.3:
		_hud_timer = 0.0
		_update_finger_hud()


func _build_legs() -> void:
	_leg_pivots.clear()
	for side in range(2):
		var x: float = -0.11 if side == 0 else 0.11
		var hip := Node3D.new()
		hip.name = "LeftHip" if side == 0 else "RightHip"
		hip.position = Vector3(x, 0.90, 0.0)
		_body_root.add_child(hip)

		var knee := Node3D.new()
		knee.name = "LeftKnee" if side == 0 else "RightKnee"
		knee.position = Vector3(0.0, -0.40, 0.0)
		hip.add_child(knee)

		var ankle := Node3D.new()
		ankle.name = "LeftAnkle" if side == 0 else "RightAnkle"
		ankle.position = Vector3(0.0, -0.38, 0.0)
		knee.add_child(ankle)

		_leg_pivots.append({"hip": hip, "knee": knee, "ankle": ankle})


func _build_arms(skin) -> void:
	_hand_roots.clear()
	_finger_pivots.clear()
	_finger_angles.clear()
	_arm_pivots.clear()
	_arm_angles.clear()
	_finger_seg_lengths.clear()
	_selected_fingers = [[true, true, true, true, true], [true, true, true, true, true]]

	for h in range(2):
		var side: float = -1.0 if h == 0 else 1.0
		var shoulder := Node3D.new()
		shoulder.name = "LeftShoulder" if h == 0 else "RightShoulder"
		shoulder.position = Vector3(0.28 * side, 1.30, 0.02)
		_body_root.add_child(shoulder)

		var elbow := Node3D.new()
		elbow.name = "LeftElbow" if h == 0 else "RightElbow"
		elbow.position = Vector3(0.0, -0.28, 0.0)
		shoulder.add_child(elbow)

		var wrist := Node3D.new()
		wrist.name = "LeftWrist" if h == 0 else "RightWrist"
		wrist.position = Vector3(0.0, -0.26, 0.0)
		elbow.add_child(wrist)

		_arm_pivots.append({"shoulder": shoulder, "elbow": elbow, "wrist": wrist})
		_arm_angles.append({
			"shoulder_x": 0.0,
			"shoulder_z": 0.0,
			"elbow_x": 0.0,
			"wrist_x": 0.0,
			"wrist_y": 0.0,
		})

		var hand_root := Node3D.new()
		hand_root.name = "LeftHand" if h == 0 else "RightHand"
		hand_root.position = Vector3(0.0, -0.02, -0.12)
		hand_root.rotation.x = deg_to_rad(-18.0)
		wrist.add_child(hand_root)
		_hand_roots.append(hand_root)
		_build_fingers_on_hand(hand_root, h, skin)

	_apply_arm_pose()
	_apply_finger_pose()


## 上臂/前臂长度与质量（成人解剖近似）
const UPPER_ARM_LENGTH := 0.28
const FOREARM_LENGTH := 0.26
const UPPER_ARM_MASS := 2.0
const FOREARM_MASS := 1.4
const PALM_MASS := 0.40
## 主动发力后保持满力的时间窗口 ms（之后退回静力支撑）
const ACTIVE_HOLD_MS := 600
## 指关节解剖活动范围（度）：MCP / PIP / DIP。三段合计约 260°，
## 这个范围才是手指能绕住一根棍子的原因；超出就是关节脱位。
const FINGER_JOINT_LIMITS_DEG := [90.0, 100.0, 70.0]
## 拇指三节：掌骨（CMC）+ 近节（MCP）+ 末节（IP）。掌骨是拇指能对掌的
## 关键——少了它，拇指从腕根到指尖只有 5.4 cm，够不到四指围出的握持
## 口袋（离腕根 5.5-7.8 cm）。真人拇指从 CMC 到指尖约 10 cm，其中掌骨
## 占 4-5 cm。
const THUMB_JOINT_LIMITS_DEG := [80.0, 90.0, 80.0]
## 拇指 CMC 内收（对掌）的最大角度。内收轴是掌 y，只能把这根拇指
## 在水平面里从 −x 摆到 ±z：45° 只到掌前，够不到对侧；要横跨到四指
## 根部得转过 ~110°。但实测这两种幅度都会在合拢时贴着木棍高度横扫，
## 把木棍推出掌心（0,2 段接触力 60-117N），所以暂时关掉内收（=0），
## 只保留两自由度机构和几何，等握持控制改成「按物体半径收指」再启用。
const THUMB_ADDUCT_MAX_DEG := 0.0
## 手指目标角速度（rad/s）。只在张开/自由屈曲时用于估算角速度。
const FINGER_CLOSE_SPEED := 4.0
## 指屈肌最大收缩角速度（rad/s）。健康手指空载全屈约 0.3-0.4 s，
## 12 rad/s 与这个速度相符；超过它肌肉就发不出力（Hill 力—速度关系）。
const FINGER_MUSCLE_MAX_RATE := 12.0
## 指屈肌从零到满张力的时间（s）。肌电到力峰约 80-150 ms。
const FINGER_GRIP_RAMP_TIME := 0.12
## 肌肉协同控制的死区（度）：偏离目标这么多就出满力。
## 关节到目标角 ±该值以内按比例减力，形成稳定的位置维持。
const FINGER_CTRL_BAND_DEG := 12.0
## 指关节的粘性阻尼（N·m·s/rad）。肌腱的串联弹性、关节液的黏滞和
## 屈伸肌共同收缩都会吸收角速度；不建模的话，肌肉力矩作用在只有
## 几克重的指骨上会在接触面上来回弹，把物体从手里抖出去。
const FINGER_JOINT_DAMPING := 0.05
## 伸肌比屈肌弱得多（指伸总肌的生理横断面积约为指深屈肌的三分之一）。
## 目标角被物体顶过时，伸肌只能出三成力，不会把已经抓住的东西主动
## 松开；同时这也让「被顶过目标角」变成稳定的抗阻状态而不是失控回弹。
const FINGER_EXTENSOR_RATIO := 0.35
## 关节止挡（骨-骨接触）的角刚度与阻尼。真实骨面接触接近刚性，
## 这里用有限刚度是因为刚体求解器里无限刚度会抖。超限 5° 就出
## 1.7 N·m，和肌肉同级；超限 20° 出 7 N·m，任何握力都压不过去。
const FINGER_STOP_STIFFNESS := 5.0
const FINGER_STOP_DAMPING := 0.1
## 指骨半径与皮肉半径。指骨是硬接触（刚体胶囊），外面的皮下脂肪 +
## 真皮是可压缩层：真人指腹 3-5 mm 厚，压陷 1 mm 约需 0.5-1 N，
## 压陷 3 mm 约 5-15 N——正好是一只手的握力量级。
const FINGER_BONE_RADIUS := 0.005
const FINGER_FLESH_RADIUS := 0.009
## 指腹软组织的等效厚度与整节指骨的等效压缩刚度（N/m）。
## 刚度不是抓取力：它只描述「指腹被压进去多少、顶回来多少」，
## 握力仍然只来自肌力 × 力臂。
const PULP_THICKNESS := 0.004
const PULP_STIFFNESS := 2600.0
const PULP_DAMPING := 14.0
## 皮肉对接触物体的切向摩擦系数（干燥皮肤 - 木/骨面量级）
const PULP_FRICTION := 1.1
## 切向摩擦的粘性系数（N·s/m）：只用来在没有相对滑动时给出静摩擦
## 的「预压量」，超过 μ·Fn 就饱和成库仑摩擦。取大值是为了让
## 慢速滑动（几 cm/s）也能拿到接近 μ·Fn 的摩擦力——否则物体沿指腹
## 慢慢往下溜时，粘性项太小，握持会像涂了油。
const PULP_TANGENT_DAMPING := 300.0


func _build_hand_physics() -> void:
	_palm_bodies.clear()
	_finger_segments.clear()
	_thumb_cradle.clear()
	_thumb_adduct_joint.clear()
	_pulp_pads.clear()
	_pulp_touch.clear()
	_finger_joints.clear()
	_finger_axis_local.clear()
	_finger_ref_local.clear()
	_shoulder_anchors.clear()
	_shoulder_roll_bodies.clear()
	_arm_bodies.clear()
	_arm_joints.clear()
	_arm_active_until.clear()
	_finger_active_until.clear()
	_arm_broken.clear()
	_finger_broken.clear()
	_detached_from_torso.clear()
	_detached_from_palm.clear()
	_bone_message = ""
	if _hand_physics_root != null:
		_hand_physics_root.queue_free()
	_hand_physics_root = Node3D.new()
	_hand_physics_root.name = "PhysicalHands"
	var scene_root := get_tree().current_scene
	if scene_root == null:
		scene_root = self
	scene_root.add_child(_hand_physics_root)

	for h in range(2):
		var palm := _build_arm_rig(h)
		_palm_bodies.append(palm)
		var active := {}
		for key in ["shoulder_x", "shoulder_z", "elbow_x", "wrist_x", "wrist_y"]:
			active[key] = 0
		_arm_active_until.append(active)
		var broken := {}
		for key in ["shoulder_x", "shoulder_z", "elbow_x", "wrist_x", "wrist_y"]:
			broken[key] = false
		_arm_broken.append(broken)
		_build_fingers_for_hand(h, palm)

	_update_hand_physics()


## 每根手指的关节数按解剖表建（四指三节、拇指三节）。容器按实际长度建。
static func _zeros(n: int) -> Array:
	var a: Array = []
	a.resize(n)
	a.fill(0)
	return a


static func _zeros_f(n: int) -> Array:
	var a: Array = []
	a.resize(n)
	a.fill(0.0)
	return a


static func _bools(n: int) -> Array:
	var a: Array = []
	a.resize(n)
	a.fill(false)
	return a


static func _zeros_vec3(n: int) -> Array:
	var a: Array = []
	a.resize(n)
	a.fill(Vector3.ZERO)
	return a


## 建立一条真物理手臂：肩锚点(静态，随躯干) → 上臂 → 前臂 → 手掌。
## 各段由铰链连接，关节力矩由肌肉力量限制，返回手掌刚体。
func _build_arm_rig(h: int) -> RigidBody3D:
	var shoulder_pivot: Node3D = _arm_pivots[h]["shoulder"]
	var elbow_pivot: Node3D = _arm_pivots[h]["elbow"]
	var wrist_pivot: Node3D = _arm_pivots[h]["wrist"]
	var hand_root: Node3D = _hand_roots[h]

	# 肩锚点只跟躯干；手臂控制角由铰链电机实现，不在这里施加
	var root_tf := _body_root.global_transform
	var shoulder_basis := root_tf.basis.orthonormalized()
	var shoulder_tf := Transform3D(shoulder_basis, root_tf * shoulder_pivot.position)

	var anchor := StaticBody3D.new()
	anchor.name = "LeftShoulderAnchor" if h == 0 else "RightShoulderAnchor"
	anchor.collision_layer = 0
	anchor.collision_mask = 0
	var anchor_col := CollisionShape3D.new()
	var anchor_shape := SphereShape3D.new()
	anchor_shape.radius = 0.01
	anchor_col.shape = anchor_shape
	anchor.add_child(anchor_col)
	_hand_physics_root.add_child(anchor)
	anchor.global_transform = shoulder_tf
	_shoulder_anchors.append(anchor)

	# 肩部横滚中间体：pitch 与 roll 两个铰链串联
	var roll := RigidBody3D.new()
	roll.name = "ShoulderRoll_%d" % h
	roll.mass = 0.10
	# Jolt 的铰链电机冲量上限会按「另一端刚体的转动惯量」缩放：中间体
	# 只有一颗 0.02 m 小球的惯量（~4e-5）时，肩部电机几乎使不出力矩，
	# 大臂永远抬不起来。横滚体代表肩关节座（现实里是躯干），给它一个
	# 与上臂同量级的惯量，电机才正常出力。
	roll.inertia = Vector3(0.05, 0.05, 0.05)
	roll.gravity_scale = 0.0
	roll.can_sleep = false
	roll.collision_layer = 0
	roll.collision_mask = 0
	roll.linear_damp = 0.4
	roll.angular_damp = 0.4
	var roll_col := CollisionShape3D.new()
	var roll_shape := SphereShape3D.new()
	roll_shape.radius = 0.02
	roll_col.shape = roll_shape
	roll.add_child(roll_col)
	_hand_physics_root.add_child(roll)
	roll.global_transform = shoulder_tf
	_shoulder_roll_bodies.append(roll)

	var elbow_tf := elbow_pivot.global_transform
	var upper := _make_arm_body(h, "UpperArm", UPPER_ARM_MASS, 0.045,
		shoulder_tf, UPPER_ARM_LENGTH)
	var fore := _make_arm_body(h, "Forearm", FOREARM_MASS, 0.035,
		elbow_tf, FOREARM_LENGTH)

	# 腕部旋转（旋前/旋后）：前臂 → 腕旋转体 → 手掌，两个铰链串联。
	# 和肩部横滚体同理，中间体要有正常转动惯量，Jolt 电机才出得了力矩。
	var wrist_tf := wrist_pivot.global_transform
	var twist := RigidBody3D.new()
	twist.name = "WristTwist_%d" % h
	twist.mass = 0.08
	twist.inertia = Vector3(0.02, 0.02, 0.02)
	twist.gravity_scale = 0.0
	twist.can_sleep = false
	twist.collision_layer = 0
	twist.collision_mask = 0
	twist.linear_damp = 0.4
	twist.angular_damp = 0.4
	var twist_col := CollisionShape3D.new()
	var twist_shape := SphereShape3D.new()
	twist_shape.radius = 0.02
	twist_col.shape = twist_shape
	twist.add_child(twist_col)
	_hand_physics_root.add_child(twist)
	twist.global_transform = wrist_tf

	# 手掌是动态刚体，挂在前臂的腕铰链上；手指再从手掌长出去
	var palm: RigidBody3D = ContactForceProbeScript.new()
	palm.name = "LeftPalmBody" if h == 0 else "RightPalmBody"
	palm.mass = PALM_MASS
	palm.gravity_scale = 0.0
	palm.can_sleep = false
	palm.linear_damp = 0.2
	palm.angular_damp = 0.4
	palm.collision_layer = 4
	palm.collision_mask = 3 | 128
	var palm_phys := PhysicsMaterial.new()
	palm_phys.friction = 0.9
	palm_phys.bounce = 0.0
	palm.physics_material_override = palm_phys
	var palm_col := CollisionShape3D.new()
	var palm_shape := BoxShape3D.new()
	# 掌厚 1.6 cm（掌心面 y=-0.008）。真实掌骨部约 2.2 cm，但掌盒越厚，
	# 合拢后的指骨到掌面就越挤；薄一档，四指和拇指才有空间把粗树枝
	# 包进掌心，而不是被掌盒顶着只能夹在掌外。
	palm_shape.size = Vector3(0.10, 0.016, 0.11)
	palm_col.shape = palm_shape
	palm.add_child(palm_col)
	_hand_physics_root.add_child(palm)
	# 先摆到出生姿态，再建关节，否则关节会按原点建立后被撕裂
	palm.global_transform = hand_root.global_transform

	# 关节轴 = 对应控制角的正转轴：
	# 肩 pitch 绕 +X、肩 roll 绕 +Z、肘绕 -X（pivot 用 rotation.x 取负）、腕绕 +X
	var joints: Array = []
	joints.append(_make_muscle_hinge(anchor, roll, shoulder_tf.origin,
		shoulder_basis.x, "shoulder", "shoulder_x",
		deg_to_rad(-150.0), deg_to_rad(150.0)))
	# 侧举轴左右镜像：控制角正方向永远是「向外抬起」。同向绕躯干前方
	# 轴旋转时，两只手会一起甩向身体右侧，左臂就变成横穿胸前。
	var lift_axis: Vector3 = shoulder_basis.z if h == 1 else -shoulder_basis.z
	joints.append(_make_muscle_hinge(roll, upper, shoulder_tf.origin,
		lift_axis, "shoulder", "shoulder_z",
		deg_to_rad(-30.0), deg_to_rad(150.0)))
	joints.append(_make_muscle_hinge(upper, fore, elbow_tf.origin,
		-elbow_tf.basis.x.normalized(), "elbow", "elbow_x",
		deg_to_rad(-5.0), deg_to_rad(150.0)))
	# 腕旋转轴 = 前臂长轴（本地 Y），腕屈伸轴 = 腕部本地 X
	joints.append(_make_muscle_hinge(fore, twist, wrist_tf.origin,
		wrist_tf.basis.y.normalized(), "wrist", "wrist_y",
		deg_to_rad(-90.0), deg_to_rad(90.0)))
	joints.append(_make_muscle_hinge(twist, palm, wrist_tf.origin,
		wrist_tf.basis.x.normalized(), "wrist", "wrist_x",
		deg_to_rad(-60.0), deg_to_rad(60.0)))

	_arm_joints.append(joints)
	_arm_bodies.append({"upper": upper, "forearm": fore, "twist": twist})
	# 玩家全权控制身体：不做自身碰撞例外，手脚能撞到身体任何部位
	return palm


## 沿关节本地 -Y 方向生成一段肢体胶囊刚体
func _make_arm_body(h: int, label: String, mass: float, radius: float,
		joint_tf: Transform3D, length: float) -> RigidBody3D:
	var body: RigidBody3D = ContactForceProbeScript.new()
	body.name = "%s_%d" % [label, h]
	body.mass = mass
	# 球面星球上世界重力方向不对，统一由 _update_hand_physics 施加径向重力
	body.gravity_scale = 0.0
	body.can_sleep = false
	body.linear_damp = 0.1
	body.angular_damp = 0.1
	body.continuous_cd = true
	body.collision_layer = 4
	body.collision_mask = 3 | 128   # 物品/地形 + 玩家身体 layer 8
	var mat := PhysicsMaterial.new()
	mat.friction = 0.7
	mat.bounce = 0.0
	body.physics_material_override = mat
	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = radius
	shape.height = length
	col.shape = shape
	body.add_child(col)
	_hand_physics_root.add_child(body)
	body.global_transform = Transform3D(joint_tf.basis,
		joint_tf.origin + joint_tf.basis * Vector3(0.0, -length * 0.5, 0.0))
	return body


## 建一个受肌肉力矩限制、带角度测量的铰链。
## Godot 铰链绕本地 Z 旋转，且正角对应绕 -Z 旋转；设 Z=-desired_axis，
## 则铰链正角就是绕 desired_axis 正转，与运动学控制角符号一致。
func _make_muscle_hinge(a: PhysicsBody3D, b: PhysicsBody3D, world_pos: Vector3,
		desired_axis: Vector3, muscle: String, key: String,
		lower: float, upper: float) -> Dictionary:
	var joint := HingeJoint3D.new()
	_hand_physics_root.add_child(joint)
	var axis := desired_axis.normalized()
	var z := -axis
	var x := z.cross(Vector3.UP)
	if x.length() < 0.01:
		x = z.cross(Vector3.RIGHT)
	x = x.normalized()
	var y := z.cross(x).normalized()
	# Joint3D 在设置 node_a/node_b 时才按当时变换建立约束，顺序不能反
	joint.global_transform = Transform3D(Basis(x, y, z), world_pos)
	joint.node_a = joint.get_path_to(a)
	joint.node_b = joint.get_path_to(b)
	joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
	joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, lower)
	joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, upper)
	joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)

	var a_basis := a.global_transform.basis.orthonormalized()
	var b_basis := b.global_transform.basis.orthonormalized()
	return {
		"joint": joint,
		"a": a,
		"b": b,
		# 零位参考：两侧刚体在建立时相对旋转为 0
		"axis_local_a": a_basis.inverse() * axis,
		"ref_local_a": a_basis.inverse() * x,
		"ref_local_b": b_basis.inverse() * x,
		"muscle": muscle,
		"key": key,
		"lower": lower,
		"upper": upper,
	}


## 测量指关节屈曲角（弧度，正 = 屈曲）。
## 指骨铰链按 z = +axis 建立，Godot 正角绕 -Z → 屈曲角 = 绕 -axis 的转角。
## 轴按关节取（拇指的轴是掌 z，见 [_finger_axis]），不能写死掌 x。
func _finger_flex_angle(parent_body: Node3D, seg: Node3D,
		axis: Vector3 = Vector3.ZERO,
		ref_a_local: Vector3 = Vector3.ZERO,
		ref_b_local: Vector3 = Vector3.ZERO) -> float:
	var pa: Basis = parent_body.global_transform.basis.orthonormalized()
	var sb: Basis = seg.global_transform.basis.orthonormalized()
	var ax: Vector3 = axis.normalized() if axis != Vector3.ZERO \
		else pa.x.normalized()
	var ref_a: Vector3
	var ref_b: Vector3
	if ref_a_local != Vector3.ZERO and ref_b_local != Vector3.ZERO:
		ref_a = (pa * ref_a_local).normalized()
		ref_b = (sb * ref_b_local).normalized()
	else:
		# 没给参考向量时退回父系的 z：轴和 z 平行会退化，只能当兜底
		ref_a = (pa.z - ax * pa.z.dot(ax)).normalized()
		ref_b = (sb.z - ax * sb.z.dot(ax)).normalized()
	return -atan2(ax.dot(ref_a.cross(ref_b)), ref_a.dot(ref_b))


## 某个指关节的父刚体。拇指的 j0 挂在 CMC 过渡体上（两自由度），
## 其余手指的 j0 挂在手掌上，j>0 挂上一节指骨。
func _finger_parent_body(h: int, f: int, j: int) -> Node3D:
	if j > 0:
		return _finger_segments[h][f][j - 1]
	if f == 0 and h < _thumb_cradle.size():
		return _thumb_cradle[h]
	return _palm_bodies[h]


## 某个指关节的屈曲角（度），正 = 屈曲。和肌肉用的是同一套测量。
func _finger_flex_deg(h: int, f: int, j: int) -> float:
	var parent_body: Node3D = _finger_parent_body(h, f, j)
	var seg: Node3D = _finger_segments[h][f][j]
	var axis: Vector3 = _finger_axis(h, f, j, parent_body)
	var refs: Array = ((_finger_ref_local[h] as Array)[f] as Array)[j]
	return rad_to_deg(_finger_flex_angle(parent_body, seg, axis,
		refs[0], refs[1]))


## 每根手指每个关节的屈曲轴（屈曲 = 绕 -axis 为正）。
##
## 四指绕自己的局部 x（= 掌 x）屈曲，弯在 y-z 平面里卷向掌面。
## 拇指的基座建立时把局部 x 对准了**掌 z**（见 [_build_fingers_on_hand]），
## 所以它绕掌 z 屈曲，弯在 x-y 平面里——从横着伸出去转到压向掌面。
## 两个弯曲平面的法线互相垂直：四指卷在 y-z，拇指压进 x-y。
## 拇指如果也绕掌 x，就只会在和四指平行的平面里点头，从四指外侧
## 划过去，永远压不到对侧，C 形握口合不拢。
##
## 轴按父刚体的局部坐标取（构造时算好存进 _finger_axis_local），
## 而不是每次按世界方向重推：远端关节的父刚体会随上游关节转动，
## 每帧重推会让同一个关节的轴跟着上游漂。
func _finger_axis(h: int, f: int, j: int, parent_body: Node3D) -> Vector3:
	if h < _finger_axis_local.size() \
			and f < (_finger_axis_local[h] as Array).size() \
			and j < ((_finger_axis_local[h] as Array)[f] as Array).size():
		var local: Vector3 = ((_finger_axis_local[h] as Array)[f] as Array)[j]
		if local != Vector3.ZERO:
			return (parent_body.global_transform.basis * local).normalized()
	return parent_body.global_transform.basis.x.normalized()


## 测量铰链当前角度（绕 desired_axis 的右手正角）
func _joint_angle(jd: Dictionary) -> float:
	var a: Node3D = jd["a"]
	var b: Node3D = jd["b"]
	var axis: Vector3 = (a.global_transform.basis * jd["axis_local_a"]).normalized()
	var va: Vector3 = (a.global_transform.basis * jd["ref_local_a"]).normalized()
	var vb: Vector3 = (b.global_transform.basis * jd["ref_local_b"]).normalized()
	return atan2(axis.dot(va.cross(vb)), va.dot(vb))


# ============================================================
# 骨骼受力与骨折
# ============================================================
# 骨头不是不可破坏的运动学约束。每段骨有材料属性（见 PlayerBody），
# 受力点承受的外载力矩超过 σ·W 就在该处断开。外载 = 远端各刚体的
# 重力 + 与其他物体的接触力；肌肉力矩是关节内力，不直接计入。

const BONE_OF_ARM_JOINT := {
	"shoulder_x": "humerus", "shoulder_z": "humerus",
	"elbow_x": "radius_ulna", "wrist_x": "radius_ulna",
	"wrist_y": "radius_ulna",
}
const BONE_FRACTURE_LABELS := {
	"shoulder_x": "肩部肱骨", "shoulder_z": "肩部肱骨",
	"elbow_x": "肘部桡尺骨", "wrist_x": "腕部桡尺骨",
	"wrist_y": "腕部桡尺骨",
}


## 每物理帧检查一次骨骼载荷；同一只手只断最危险的一处（最弱截面先失效）
func _update_bone_fractures(sky: Vector3, g: float) -> void:
	if _player_body == null:
		return
	var half_u: float = UPPER_ARM_LENGTH * 0.5
	var half_f: float = FOREARM_LENGTH * 0.5
	for h in range(_arm_bodies.size()):
		if h >= _palm_bodies.size() or h >= _arm_broken.size():
			continue
		var upper: RigidBody3D = _arm_bodies[h]["upper"]
		var fore: RigidBody3D = _arm_bodies[h]["forearm"]
		var palm: RigidBody3D = _palm_bodies[h]
		var fingers := _all_finger_bodies(h)
		# 载荷只沿仍然相连的骨链传递：肘断了，前臂和手就不再压在肩关节上
		var wrist_ok: bool = not bool(_arm_broken[h].get("wrist_x", false)) \
			and not bool(_arm_broken[h].get("wrist_y", false))
		var elbow_ok: bool = not bool(_arm_broken[h].get("elbow_x", false))
		var hand_chain: Array = [palm] + fingers if wrist_ok else []
		var fore_chain: Array = [fore] + hand_chain
		var upper_chain: Array = [upper] + (fore_chain if elbow_ok else [])
		var chains := {
			"shoulder_x": upper_chain,
			"shoulder_z": upper_chain,
			"elbow_x": fore_chain,
			"wrist_x": hand_chain,
			"wrist_y": hand_chain,
		}
		var pivots := {
			"shoulder_x": upper.global_transform * Vector3(0.0, half_u, 0.0),
			"shoulder_z": upper.global_transform * Vector3(0.0, half_u, 0.0),
			"elbow_x": fore.global_transform * Vector3(0.0, half_f, 0.0),
			"wrist_x": fore.global_transform * Vector3(0.0, -half_f, 0.0),
			"wrist_y": fore.global_transform * Vector3(0.0, -half_f, 0.0),
		}
		var worst: Dictionary = {}
		for jd in _arm_joints[h]:
			var key: String = jd["key"]
			if bool(_arm_broken[h].get(key, false)):
				continue
			var bone: String = String(BONE_OF_ARM_JOINT.get(key, "phalanx"))
			var limit: float = _player_body.get_bone_fracture_moment(bone)
			var load: float = _load_moment(pivots[key], chains[key], sky, g)
			if load > limit and (worst.is_empty() or load / limit > float(worst["ratio"])):
				worst = {
					"ratio": load / limit, "load": load, "limit": limit,
					"kind": "arm", "hand": h, "joint": jd, "key": key,
					"label": String(BONE_FRACTURE_LABELS.get(key, key)),
				}
		if h < _finger_broken.size():
			for f in range(5):
				var segs: Array = _finger_segments[h][f]
				var lens: Array = _finger_seg_lengths[h][f]
				for j in range(lens.size()):
					if bool(_finger_broken[h][f][j]):
						continue
					var distal: Array = []
					for k in range(j, lens.size()):
						distal.append(segs[k])
					var joint_pos: Vector3
					if j == 0:
						joint_pos = segs[0].global_transform * Vector3(0.0, 0.0, float(lens[0]) * 0.5)
					else:
						joint_pos = segs[j - 1].global_transform * Vector3(0.0, 0.0, -float(lens[j - 1]) * 0.5)
					var bone: String = "metacarpal" if j == 0 else "phalanx"
					var limit: float = _player_body.get_bone_fracture_moment(bone)
					var load: float = _load_moment(joint_pos, distal, sky, g)
					if load > limit and (worst.is_empty() or load / limit > float(worst["ratio"])):
						worst = {
							"ratio": load / limit, "load": load, "limit": limit,
							"kind": "finger", "hand": h, "finger": f, "index": j,
							"label": "指骨",
						}
		if not worst.is_empty():
			_break_bone(worst)


## 计算远端刚体组对关节的合力矩 N·m
func _load_moment(joint_pos: Vector3, bodies: Array, sky: Vector3, g: float) -> float:
	var moment := Vector3.ZERO
	for node in bodies:
		if node == null or not is_instance_valid(node):
			continue
		var rb: RigidBody3D = node
		var force: Vector3 = -sky * rb.mass * g
		var contact: Variant = rb.get("contact_force")
		if contact is Vector3:
			force += contact
		moment += (rb.global_position - joint_pos).cross(force)
	return moment.length()


func _all_finger_bodies(h: int) -> Array:
	var bodies: Array = []
	if h >= _finger_segments.size():
		return bodies
	for finger in _finger_segments[h]:
		for seg in finger:
			bodies.append(seg)
	return bodies


## 断点以近的关节仍受肌肉控制；断点以远的肢体已经和身体分离，
## 玩家的力传不过去，必须彻底失去控制。返回值越小断得越近。
func _control_cut(h: int) -> int:
	if h < 0 or h >= _arm_broken.size():
		return 3
	var broken: Dictionary = _arm_broken[h]
	if bool(broken.get("shoulder_x", false)) or bool(broken.get("shoulder_z", false)):
		return 0
	if bool(broken.get("elbow_x", false)):
		return 1
	if bool(broken.get("wrist_x", false)) or bool(broken.get("wrist_y", false)):
		return 2
	return 3


## 关节在骨链上的层级：肩 0 → 肘 1 → 腕 2 → 手指 3
func _joint_level(key: String) -> int:
	match key:
		"shoulder_x", "shoulder_z":
			return 0
		"elbow_x":
			return 1
		"wrist_x", "wrist_y":
			return 2
	return 3


func _break_bone(c: Dictionary) -> void:
	var h: int = int(c["hand"])
	if String(c["kind"]) == "arm":
		var key: String = String(c["key"])
		# 肱骨是肩关节这一段骨：断在肩上就是整根上臂失去连接，两个肩铰链
		# 必须一起断开。只断一个的话，另一个还连着被躯干搬运的肩座，
		# 断臂照样能被电机驱动——玩家会发现「断了还能控制」。
		var broken_keys: Array = [key]
		if key == "shoulder_x" or key == "shoulder_z":
			broken_keys = ["shoulder_x", "shoulder_z"]
		for jd in _arm_joints[h]:
			if String(jd["key"]) in broken_keys:
				_arm_broken[h][String(jd["key"])] = true
				_disable_joint(jd["joint"])
		var detached: Array = []
		match key:
			"shoulder_x", "shoulder_z":
				detached = [_arm_bodies[h]["upper"], _arm_bodies[h]["forearm"], _palm_bodies[h]]
			"elbow_x":
				detached = [_arm_bodies[h]["forearm"], _palm_bodies[h]]
			_:
				detached = [_palm_bodies[h]]
		for body in detached:
			_detached_from_torso[(body as Node).get_instance_id()] = true
		# 手掌已经离开躯干：指骨不能再被「跟随手掌」的瞬移带着走，
		# 否则每帧都在手动搬一串带铰链的刚体，关节求解器会被推翻，
		# 掉落过程既抖又慢。让手掌和指骨靠铰链自己跟。
		if h < _finger_segments.size():
			for f in range(_finger_segments[h].size()):
				for seg in _finger_segments[h][f]:
					_detached_from_palm[(seg as Node).get_instance_id()] = true
		_bone_message = "骨折：%s（%.0f / %.0f N·m）" % [c["label"], c["load"], c["limit"]]
	else:
		var f: int = int(c["finger"])
		var j: int = int(c["index"])
		_finger_broken[h][f][j] = true
		_disable_joint(_finger_joints[h][f][j])
		for k in range(j, _finger_segments[h][f].size()):
			_detached_from_palm[_finger_segments[h][f][k].get_instance_id()] = true
		_bone_message = "骨折：指骨（%.1f / %.1f N·m）" % [c["load"], c["limit"]]
	print("[Bone] ", _bone_message)


## 断开关节约束：两端刚体各自按物理继续运动（骨头断了，皮肉也分离）
func _disable_joint(joint: HingeJoint3D) -> void:
	joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, false)
	joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, false)
	joint.node_a = NodePath()
	joint.node_b = NodePath()


func _build_fingers_for_hand(h: int, palm: RigidBody3D) -> void:
	var hand_segments: Array = []
	# 先把本手容器挂进去，循环内才能回头引用已建好的相邻指骨
	_finger_segments.append(hand_segments)
	var hand_pads: Array = []
	_pulp_pads.append(hand_pads)
	_pulp_touch.append({})
	var finger_actives: Array = []
	_finger_active_until.append(finger_actives)
	var hand_broken: Array = []
	_finger_broken.append(hand_broken)
	var hand_grip: Array = []
	_finger_grip_force.append(hand_grip)

	# 拇指 CMC 的两自由度：手掌 ↔ 过渡刚体（内收/外展）↔ 掌骨（屈曲）。
	# 过渡体只做约束载体，不带碰撞形状——CMC 埋在掌侧皮肉里，加碰撞体
	# 只会和掌盒一直打架。质量给得很小，惯量照手指那样抬高保证 60 Hz 稳定。
	var cradle := RigidBody3D.new()
	cradle.name = "ThumbCmc_%d" % h
	cradle.mass = 0.02
	cradle.gravity_scale = 0.0
	cradle.can_sleep = false
	cradle.inertia = Vector3(1e-3, 1e-3, 1e-3)
	_hand_physics_root.add_child(cradle)
	var cmc_pos: Vector3 = _finger_pivots[h][0][0].global_transform.origin
	cradle.global_transform = Transform3D(
		palm.global_transform.basis.orthonormalized(), cmc_pos)
	_thumb_cradle.append(cradle)
	var palm_b: Basis = palm.global_transform.basis.orthonormalized()
	var add_joint := HingeJoint3D.new()
	_hand_physics_root.add_child(add_joint)
	# 内收轴 = 掌 y（竖直）：绕它转，拇指在水平面里从横向扫向四指根部。
	var add_axis: Vector3 = palm_b.y.normalized()
	var az := add_axis
	var ax := az.cross(Vector3.UP)
	if ax.length() < 0.01:
		ax = az.cross(Vector3.RIGHT)
	ax = ax.normalized()
	var ay := az.cross(ax).normalized()
	add_joint.global_transform = Transform3D(Basis(ax, ay, az), cmc_pos)
	add_joint.node_a = add_joint.get_path_to(palm)
	add_joint.node_b = add_joint.get_path_to(cradle)
	add_joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, false)
	add_joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
	add_joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
	add_joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)
	var add_ref: Vector3 = palm_b.z.normalized()
	_thumb_adduct_joint.append({
		"joint": add_joint,
		"a": palm,
		"b": cradle,
		"axis_local_a": (palm_b.inverse() * add_axis).normalized(),
		"ref_local_a": (palm_b.inverse() * add_ref).normalized(),
		"ref_local_b": (cradle.global_transform.basis.orthonormalized().inverse()
			* add_ref).normalized(),
	})

	for f in range(5):
		var finger_segments: Array = []
		var joint_count: int = (_finger_seg_lengths[h][f] as Array).size()
		finger_actives.append(_zeros(joint_count))
		hand_grip.append(_zeros_f(joint_count))
		hand_broken.append(_bools(joint_count))
		# 先挂容器，j>0 时才能引用同一根手指的上一节
		hand_segments.append(finger_segments)
		var finger_pads: Array = []
		hand_pads.append(finger_pads)
		for j in range(joint_count):
			var pivot: Node3D = _finger_pivots[h][f][j]
			var seg_len: float = float(_finger_seg_lengths[h][f][j])
			var basis := pivot.global_transform.basis
			var center: Vector3 = pivot.global_transform * Vector3(0.0, 0.0, -seg_len * 0.5)

			var seg: RigidBody3D = ContactForceProbeScript.new()
			seg.name = "Finger_%d_%d_%d" % [h, f, j]
			seg.mass = 0.02
			# 重力由 _update_hand_physics 按径向施加，不走世界 -Y
			seg.gravity_scale = 0.0
			seg.collision_layer = 4
			# 手指必须和手掌、相邻手指正常碰撞。少了 4 这一层，手指会
			# 直接卷进掌心的碰撞体里，握拳时空腔只剩 1.5 cm——比任何
			# 一根树枝都细，手指永远合不到物体周围。
			seg.collision_mask = 3 | 4 | 128
			seg.linear_damp = 0.15
			seg.angular_damp = 0.35
			# 指骨几何惯量只有 ~4e-6 kg·m²。60 Hz 下这个惯量配肌肉力矩
			# 会在一步内被加速到几千 rad/s，关节限位都会被冲开；5e-4 是
			# 把肌腱/指腹的等效力学折进来的有效惯量，让关节在 60 Hz 下
			# 稳定，同时不改变肌肉按「肌力 × 力臂」出力的结论。
			seg.inertia = Vector3(1e-3, 1e-3, 1e-3)
			seg.continuous_cd = true
			# Jolt 刚体休眠后不响应关节马达；手指必须始终可控
			seg.can_sleep = false
			var seg_phys := PhysicsMaterial.new()
			seg_phys.friction = 0.9
			seg_phys.bounce = 0.0
			seg.physics_material_override = seg_phys
			_hand_physics_root.add_child(seg)
			seg.global_transform = Transform3D(basis, center)

			# 指节胶囊只做碰撞；可见的皮肉由 _rebuild_body_skin 沿
			# 整根手指连续扫掠，避免关节处露出分段。
			var col := CollisionShape3D.new()
			var shape := CapsuleShape3D.new()
			# 硬接触只到骨面（5 mm）；外面 4 mm 的指腹由
			# [_update_finger_pads] 的分布弹簧层负责。
			shape.radius = FINGER_BONE_RADIUS
			shape.height = seg_len
			col.shape = shape
			col.rotation.x = PI * 0.5
			seg.add_child(col)

			finger_segments.append(seg)
			finger_pads.append(_build_pulp_samples(h, seg_len, basis,
				j == joint_count - 1))

	var hand_joints: Array = []
	# 同上，先挂容器再填充
	_finger_joints.append(hand_joints)
	var hand_axes: Array = []
	_finger_axis_local.append(hand_axes)
	var inner_hand: float = 1.0 if h == 0 else -1.0
	var hand_refs: Array = []
	_finger_ref_local.append(hand_refs)
	for f in range(5):
		hand_axes.append(_zeros_vec3((_finger_seg_lengths[h][f] as Array).size()))
		hand_refs.append([null, null, null].slice(
			0, (_finger_seg_lengths[h][f] as Array).size()))
	for f in range(5):
		var finger_joints: Array = []
		for j in range((_finger_seg_lengths[h][f] as Array).size()):
			var pivot: Node3D = _finger_pivots[h][f][j]
			var parent_body: Node3D
			if j > 0:
				parent_body = _finger_segments[h][f][j - 1]
			elif f == 0:
				parent_body = _thumb_cradle[h]  # 拇指掌骨挂在 CMC 过渡体上
			else:
				parent_body = palm
			var seg: RigidBody3D = _finger_segments[h][f][j]
			var joint := HingeJoint3D.new()
			_hand_physics_root.add_child(joint)

			var joint_pos: Vector3 = pivot.global_transform.origin
			# 轴必须和肌肉用的轴一致，否则马达在别的轴上出力，测量和
			# 驱动对不上。轴先按世界方向定出来，再折进父刚体的局部系
			# 存起来，运行时 [_finger_axis] 用同一个局部向量还原。
			var pb_bind: Basis = parent_body.global_transform.basis.orthonormalized()
			var palm_bind: Basis = _palm_bodies[h].global_transform.basis.orthonormalized()
			# 四指绕自己的局部 x（= 掌 x）屈曲。拇指的局部 x 是建基座
			# 时对齐到掌 z*inner 的（见 [_build_fingers_on_hand]），所以
			# j0 要从掌系取；j1 起父刚体的 x 已经是同一根轴。
			var axis_world: Vector3
			if f == 0 and j == 0:
				axis_world = palm_bind.z.normalized() * inner_hand
			else:
				axis_world = pb_bind.x.normalized()
			((_finger_axis_local[h] as Array)[f] as Array)[j] = \
				(pb_bind.inverse() * axis_world).normalized()
			# 参考向量：优先父刚体的 z 轴；它和屈曲轴平行时（拇指）
			# 换成父刚体的 x 轴。轴建立时两侧刚体的夹角就是 0°。
			var ref_world: Vector3 = pb_bind.z.normalized()
			if absf(ref_world.dot(axis_world.normalized())) > 0.9:
				ref_world = pb_bind.x.normalized()
			var sb_bind: Basis = seg.global_transform.basis.orthonormalized()
			((_finger_ref_local[h] as Array)[f] as Array)[j] = [
				(pb_bind.inverse() * ref_world).normalized(),
				(sb_bind.inverse() * ref_world).normalized(),
			]
			var axis: Vector3 = axis_world
			var z := axis
			var x := z.cross(Vector3.UP)
			if x.length() < 0.01:
				x = z.cross(Vector3.RIGHT)
			x = x.normalized()
			var y := z.cross(x).normalized()
			# 顺序很重要：Joint3D 在设置 node_a/node_b 时才按当时的
			# 变换建立约束。先设变换，再连节点，否则约束会建在原点失效。
			joint.global_transform = Transform3D(Basis(x, y, z), joint_pos)
			joint.node_a = joint.get_path_to(parent_body)
			joint.node_b = joint.get_path_to(seg)

			joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, false)
			joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
			joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
			joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.02)
			finger_joints.append(joint)
		hand_joints.append(finger_joints)


## 整条肢体随躯干刚性搬运：刚体之间相对位姿不变，铰链没有误差可修。
## 只瞬移远端、让求解器逐帧追，走路时会滞后几十厘米（皮肉被拉长）。
func _carry_body(body: RigidBody3D, delta: Transform3D,
		skip: Dictionary) -> void:
	if skip.has(body.get_instance_id()):
		return
	if delta.is_equal_approx(Transform3D.IDENTITY):
		return
	body.global_transform = delta * body.global_transform
	# 速度一律不碰。位姿被 delta 转过一次后，物理步会按新位姿继续积分；
	# 再手写 linear/angular_velocity 会覆盖求解器刚给出的速度（关节电机
	# 每步积累的角速度被冲掉），大臂就永远抬不起来。位移速度由下一物理
	# 步自然跟随，不需要在这里补。


## 某个肌肉关节当前可用力矩：主动控制时满力，静止时只有静力支撑
func _joint_torque(muscle: String, active: bool) -> float:
	if _player_body == null:
		return 0.0
	if active:
		return _player_body.get_joint_max_torque(muscle)
	return _player_body.get_joint_passive_torque(muscle)


## 只驱动一只手的手指肌肉，不搬运手掌、不施加手臂重力。
## 物理测试需要固定手掌姿态（手掌是测量参考系），但又必须让手指
## 真的按肌力出力，所以把这一段单独摘出来。
func _update_finger_muscles(h: int, palm: RigidBody3D, fore: RigidBody3D,
		fingers_alive: bool, now_ms: int, dt: float) -> void:
	# 拇指 CMC 内收（对掌）：目标角跟着四指的屈曲程度走——抓握动作本身
	# 就带着对掌，不需要另设按键。手断了（fingers_alive=false）就不出力。
	if h < _thumb_adduct_joint.size():
		var jd: Dictionary = _thumb_adduct_joint[h]
		var joint: HingeJoint3D = jd["joint"]
		if not fingers_alive:
			joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)
		else:
			var grip := 0.0
			for f in range(1, 5):
				var angs: Array = _finger_angles[h][f]
				for j in range(angs.size()):
					var lim: float = float(FINGER_JOINT_LIMITS_DEG[j])
					grip = maxf(grip, clampf(float(angs[j]) / lim, 0.0, 1.0))
			# 内收轴是掌 +y，正向旋转把拇指从侧向甩向腕侧（掌 +z）；
			# 对掌要往指尖侧（掌 -z）扫到四指根部的握持口袋，所以取负。
			var target: float = -deg_to_rad(grip * THUMB_ADDUCT_MAX_DEG)
			var torque: float = _joint_torque("thumb_cmc_adduct", true)
			joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, torque * dt)
			joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY,
				clampf(-(target - _joint_angle(jd)) * 8.0, -6.0, 6.0))
	for f in range(5):
		var limits: Array = THUMB_JOINT_LIMITS_DEG if f == 0 \
			else FINGER_JOINT_LIMITS_DEG
		for j in range((_finger_joints[h][f] as Array).size()):
			if not fingers_alive:
				continue
			if h < _finger_broken.size() and f < _finger_broken[h].size() \
					and bool(_finger_broken[h][f][j]):
				continue  # 指骨已断
			var limit_deg: float = float(limits[j])
			var target_deg: float = clampf(
				float(_finger_angles[h][f][j]), 0.0, limit_deg)
			var joint: HingeJoint3D = _finger_joints[h][f][j]
			var active: bool = int(_finger_active_until[h][f][j]) > now_ms
			var muscle_key := "finger_mcp" if j == 0 else (
				"finger_pip" if j == 1 else "finger_dip")
			var torque: float = _joint_torque(muscle_key, active)
			# 不用 Jolt 的铰链限位。它在「静止位正好落在限位边界上」时
			# 表现得像个把关节拉回 0° 的软弹簧：限位设 [0,+limit] 时屈曲
			# 方向完全不设防（PIP 能到 -11°、MCP 到 -15°）；设成
			# [-limit,0] 又把手指粘在 0° 附近，满肌力六十帧只卷到 15°。
			# 解剖活动范围改由中枢指令夹紧（target ∈ [0, limit]）+ 等长
			# 收缩的马达维持：物体要压过关节，必须强过肌肉本身——
			# 这本来就是真实的力学关系。
			joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, false)
			# 肌力矩必须走关节马达，不能直接 apply_torque。Jolt 的无上限
			# 速度马达会无视负载、把关节顶过限位；但 PARAM_MOTOR_MAX_IMPULSE
			# 把它变成「每步最多给 τ·dt 冲量」的力矩源——堵住时它就以满
			# 力矩持续顶着（等长收缩），这正是握持需要的。更关键的是马达
			# 在约束求解器内部，铰链限位/锚点是硬约束，永远压得住它；直接
			# apply_torque 是求解器外的外力，几克重的指骨一帧就被推过
			# 上限（实测 MCP 能到 113°、PIP 到 134°），手指卷过头就从木棍
			# 上滑过去了。
			joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
			_apply_finger_muscle(h, f, j, palm, fore, torque, target_deg,
				limit_deg, dt)
	# 肌力矩下完之后再上指腹：软组织力是接触力，和肌肉是两条独立的
	# 传力路径（肌肉拉骨，指腹被物体压回去）。
	_update_finger_pads(h)


## 指腹采样点：沿指骨长度取 4 站、掌侧 ±46° 取 3 条，共 12 个点。
## 每个点是骨面外侧、即皮肉表面的位置，和它向外的法线。运行时每个点
## 各撑一根弹簧：物体压进哪几个点，反力就分布在哪个面上，而不是像
## 硬胶囊那样只压在一条接触线上。
func _build_pulp_samples(h: int, seg_len: float,
		basis: Basis, is_tip: bool = false) -> Array:
	var palmar := Vector3.ZERO
	if h < _hand_roots.size():
		# 掌侧 = 手掌根节点的 -y：四指与拇指的指腹都朝这一侧
		palmar = -(_hand_roots[h].global_transform.basis.y).normalized()
	var axis := basis.z.normalized()
	var n_world: Vector3 = palmar - axis * palmar.dot(axis)
	if n_world.length() < 0.05:
		# 指骨与掌侧向量平行时（四指在掌前缘直伸），退回到关节屈曲
		# 平面里的掌侧方向
		n_world = -basis.y.normalized()
	n_world = n_world.normalized()
	var n_local: Vector3 = (basis.inverse() * n_world).normalized()
	var out: Array = []
	for t in [-0.45, -0.15, 0.15, 0.45]:
		var z: float = seg_len * float(t)
		for a in [-0.8, 0.0, 0.8]:
			var dir: Vector3 = n_local.rotated(Vector3.BACK, float(a)).normalized()
			out.append({
				"p": dir * FINGER_BONE_RADIUS + Vector3(0.0, 0.0, z),
				"n": dir,
			})
	if is_tip:
		# 末节远端是半球（骨头自己的胶囊端帽）。物体被手指卷到指尖
		# 外侧时，接触发生在这一圈，只取沿骨轴的采样点会漏掉。
		var tip_center := Vector3(0.0, 0.0, -seg_len * 0.5)
		for a in [-0.6, 0.0, 0.6]:
			var d: Vector3 = (Vector3(0.0, 0.0, -1.0)
				+ n_local.rotated(Vector3.BACK, float(a))).normalized()
			out.append({"p": tip_center + d * FINGER_BONE_RADIUS, "n": d})
	return out


## 指腹软组织接触层。
##
## 为什么不用硬接触：9 mm 刚性胶囊压在一根圆柱上，接触是单点（求解器
## 里是 1-2 个接触点），继续收拢时指尖像楔子一样把物体从掌心里顶出去
## （test_finger_grip 实测 0.10 kg 木棍被甩飞 3-5 m）。真实指腹有 3-5 mm
## 皮下脂肪，压力摊在整个指腹面上，接触合力矩把物体往掌心里带。
##
## 这里每个采样点是一根单侧弹簧-阻尼：物体压进皮肉多少就顶回多少，
## 力作用在真实接触点上（因此会自动产生绕关节的力矩）。力的大小由
## 软组织刚度决定；指腹只能推、不能拉，所以是单侧的。
func _update_finger_pads(h: int) -> void:
	if h >= _pulp_pads.size() or h >= _finger_segments.size():
		return
	var space := get_world_3d().direct_space_state
	if space == null:
		return
	if h < _pulp_touch.size():
		(_pulp_touch[h] as Dictionary).clear()
	for f in range(5):
		if f >= (_pulp_pads[h] as Array).size():
			continue
		for j in range((_pulp_pads[h][f] as Array).size()):
			if h < _finger_broken.size() and f < _finger_broken[h].size() \
					and bool(_finger_broken[h][f][j]):
				continue  # 断开的骨节没有肌肉带着，也没有指腹了
			var pts: Array = _pulp_pads[h][f][j]
			if pts.is_empty():
				continue
			var seg: RigidBody3D = _finger_segments[h][f][j]
			# 整节指骨的刚度平均摊到各采样点
			var k: float = PULP_STIFFNESS / float(pts.size())
			var c: float = PULP_DAMPING / float(pts.size())
			var xf := seg.global_transform
			for pt in pts:
				var p_world: Vector3 = xf * (pt["p"] as Vector3)
				var n_world: Vector3 = (xf.basis * (pt["n"] as Vector3)).normalized()
				# 从皮肉面外侧朝骨面打一条短射线：只关心物体有没有
				# 压进这 4 mm 的软组织层。
				var q := PhysicsRayQueryParameters3D.create(
					p_world + n_world * PULP_THICKNESS,
					p_world - n_world * 0.002, 1)
				q.exclude = [seg.get_rid()]
				var hit: Dictionary = space.intersect_ray(q)
				if hit.is_empty():
					continue
				var hp: Vector3 = hit["position"]
				var depth: float = PULP_THICKNESS - (hp - p_world).dot(n_world)
				if depth <= 0.0:
					continue
				depth = minf(depth, PULP_THICKNESS + 0.003)
				var off_seg: Vector3 = hp - seg.global_position
				var v_seg: Vector3 = seg.linear_velocity \
					+ seg.angular_velocity.cross(off_seg)
				var other := hit["collider"] as RigidBody3D
				var v_other := Vector3.ZERO
				var off_other := Vector3.ZERO
				if other != null:
					off_other = hp - other.global_position
					if not other.freeze:
						v_other = other.linear_velocity \
							+ other.angular_velocity.cross(off_other)
				var rel: Vector3 = v_other - v_seg
				var vn: float = rel.dot(n_world)
				var fn: float = k * depth + c * maxf(-vn, 0.0)
				# 一点指腹压到极限也就几十牛；上界防止采样点插进
				# 几何内部时给出天文数字把物体弹飞
				fn = clampf(fn, 0.0, 250.0)
				var vt: Vector3 = rel - n_world * vn
				var ft := Vector3.ZERO
				if vt.length() > 1e-4:
					ft = -vt.normalized() * minf(PULP_FRICTION * fn,
						vt.length() * PULP_TANGENT_DAMPING)
				var force: Vector3 = n_world * fn + ft
				seg.apply_force(-force, off_seg)
				if other != null:
					if h < _pulp_touch.size():
						(_pulp_touch[h] as Dictionary)[other.get_instance_id()] = true
					if not other.freeze:
						other.apply_force(force, off_other)


## M2b：手掌/手指真正接触地面时，按接触力自动对近场地面施力。
## 不需要按键；每 300 ms 最多触发一次。
func _check_hand_ground_contact() -> void:
	if _palm_bodies.is_empty():
		return
	var now: int = Time.get_ticks_msec()
	if now < _last_hand_ground_strike_ms + 300:
		return
	var renderer = get_node_or_null("../WorldRenderer")
	if renderer == null:
		return
	for body in _palm_bodies:
		var probe := body as ContactForceProbe
		if probe == null or probe.contact_body == null:
			continue
		var collider = probe.contact_body
		if not (collider is Node):
			continue
		var collider_name: String = (collider as Node).name
		if collider_name != "TerrainBody" and collider_name != "GroundCollision":
			continue
		var force_n: float = probe.contact_force.length()
		if force_n < 50.0:
			continue
		var point: Vector3 = probe.contact_point
		if point.length() < 1.0:
			continue
		var tool := MaterialDB.get_material("bone")
		renderer.strike_ground(point, -point.normalized(), force_n, tool,
			point)
		_last_hand_ground_strike_ms = now
		print("[hand] ground contact strike, force=", snapped(force_n, 0.1), " N")
		return


func _update_hand_physics() -> void:
	if _arm_joints.is_empty() or _player_body == null:
		return
	var dt: float = get_physics_process_delta_time()
	var sky := position.normalized()
	var altitude: float = maxf(position.length() - planet_radius, 0.0)
	var g: float = PhysicsConstants.get_gravity_at_altitude(altitude)
	var now_ms := Time.get_ticks_msec()
	var training_load := 0.0

	for h in range(_palm_bodies.size()):
		if h >= _arm_bodies.size():
			continue
		var anchor: StaticBody3D = _shoulder_anchors[h]
		var root_tf := _body_root.global_transform
		var shoulder_local: Vector3 = _arm_pivots[h]["shoulder"].position
		var anchor_tf := Transform3D(root_tf.basis.orthonormalized(),
			root_tf * shoulder_local)

		var delta := anchor_tf * anchor.global_transform.affine_inverse()

		var palm: RigidBody3D = _palm_bodies[h]
		var palm_old: Transform3D = palm.global_transform
		var upper: RigidBody3D = _arm_bodies[h]["upper"]
		var fore: RigidBody3D = _arm_bodies[h]["forearm"]
		var twist: RigidBody3D = _arm_bodies[h]["twist"]
		var roll: RigidBody3D = _shoulder_roll_bodies[h]

		# 上臂/前臂/手掌一起随躯干搬运；骨折断开的远端不再跟随
		_carry_body(roll, delta, _detached_from_torso)
		_carry_body(upper, delta, _detached_from_torso)
		_carry_body(fore, delta, _detached_from_torso)
		_carry_body(twist, delta, _detached_from_torso)
		_carry_body(palm, delta, _detached_from_torso)
		anchor.global_transform = anchor_tf

		# 手指跟随手掌（含刚做的躯干搬运）
		var palm_delta := palm.global_transform * palm_old.affine_inverse()
		if not palm_delta.is_equal_approx(Transform3D.IDENTITY):
			if h < _thumb_cradle.size():
				_carry_body(_thumb_cradle[h], palm_delta, _detached_from_palm)
			for f in range(5):
				for j in range((_finger_segments[h][f] as Array).size()):
					_carry_body(_finger_segments[h][f][j], palm_delta, _detached_from_palm)

		# 径向重力（球面星球；世界 -Y 只在赤道朝下）
		for body in [roll, upper, fore, twist, palm]:
			(body as RigidBody3D).apply_central_force(-sky * (body as RigidBody3D).mass * g)
		for f in range(5):
			for j in range((_finger_segments[h][f] as Array).size()):
				var seg: RigidBody3D = _finger_segments[h][f][j]
				seg.apply_central_force(-sky * seg.mass * g)
		if h < _thumb_cradle.size():
			var cradle: RigidBody3D = _thumb_cradle[h]
			cradle.apply_central_force(-sky * cradle.mass * g)

		# 手臂关节：目标角 → 电机速度；力矩上限 = 肌力 × 力臂
		var angles: Dictionary = _arm_angles[h]
		var active_map: Dictionary = _arm_active_until[h]
		var cut: int = _control_cut(h)
		for jd in _arm_joints[h]:
			var key: String = jd["key"]
			# 断点以远的关节一律不再出力：肢体已经和身体分离，
			# 玩家的肌肉力传不过去（近端关节仍可正常活动）
			if _joint_level(key) >= cut:
				continue
			var target: float = deg_to_rad(float(angles[key]))
			var angle: float = _joint_angle(jd)
			var active: bool = int(active_map.get(key, 0)) > now_ms
			var torque: float = _joint_torque(jd["muscle"], active)
			var joint: HingeJoint3D = jd["joint"]
			# 肌力上限换算成每步冲量：τ·dt。Jolt 的 max impulse 是单步
			# 冲量而不是力矩，直接传 τ 会让力矩小 dt 倍。
			joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, torque * dt)
			joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY,
				clampf((target - angle) * 8.0, -6.0, 6.0))
			# 主动发力却顶不住外载（角度被压离目标）→ 肌肉做功，力量成长
			if active:
				var err: float = absf(target - angle)
				if err > deg_to_rad(8.0):
					training_load += clampf(err / deg_to_rad(60.0), 0.0, 1.0)

		# 手指关节：屈肌/伸肌成对出力，铰链限位是解剖活动范围，不随目标变。
		# 手臂断在腕以上时，手掌已经离开身体，手指也不受控制
		_update_finger_muscles(h, palm, fore, cut >= 3, now_ms, dt)

	# 骨骼受力判定：外载力矩超过骨材料抗弯极限 → 在受力点骨折
	_update_bone_fractures(sky, g)

	# 持续对抗外载 → 力量缓慢增长（锻炼系统，受智力和先天上限约束）
	if training_load > 0.0:
		_player_body.exercise_strength(clampf(training_load * 0.5, 0.0, 1.0), dt)


## 指关节的肌肉力矩。
## 张力 = 肌力 × 解剖力臂，与关节转不转无关——等长收缩（顶住不动）
## 时肌肉照样出满力。这一点必须保住，否则手一碰到东西就松。
##
## 屈肌和伸肌由同一条中枢指令驱动：离目标角越远出力越大，到位后
## 共同收缩维持。不是「到了目标就断电」——抓握时手指停在物体表面，
## 角度永远达不到目标，但肌肉也绝不会因此松力。
##
## 力矩通过关节马达施加，冲量上限 = τ·dt（见 _update_finger_muscles）。
## 马达在约束求解器里，铰链限位和锚点是硬约束：骨端顶住就是顶住，
## 外力再大也推不过解剖范围。反作用也由求解器自动配对，不用手算。
func _apply_finger_muscle(h: int, f: int, j: int, palm: RigidBody3D,
		fore: RigidBody3D, torque: float, target_deg: float,
		limit_deg: float, dt: float) -> void:
	var joint: HingeJoint3D = _finger_joints[h][f][j]
	if torque <= 0.0:
		joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.0)
		return
	var seg: RigidBody3D = _finger_segments[h][f][j]
	var parent_body: Node3D = _finger_parent_body(h, f, j)
	var axis: Vector3 = _finger_axis(h, f, j, parent_body)
	var refs: Array = ((_finger_ref_local[h] as Array)[f] as Array)[j]
	var flex_deg: float = rad_to_deg(
		_finger_flex_angle(parent_body, seg, axis, refs[0], refs[1]))
	var err_deg: float = target_deg - flex_deg
	var want: float = torque * clampf(
		err_deg / FINGER_CTRL_BAND_DEG, -1.0, 1.0)
	if want < 0.0:
		want *= FINGER_EXTENSOR_RATIO
	# 力—速度关系（Hill）：肌肉正在主动收缩方向快速缩短时出不了满力，
	# 缩短速度到上限就归零。没有这一项，肌力加在近无质量的指骨上会
	# 变成一记锤击，碰到什么就把什么打飞。
	var parent_omega := Vector3.ZERO
	if parent_body is RigidBody3D:
		parent_omega = (parent_body as RigidBody3D).angular_velocity
	var rate: float = -(seg.angular_velocity - parent_omega).dot(axis)
	# 力—速度关系只作用于肌肉主动收缩方向：缩短越快，能出的力越小。
	var shorten: float = rate if want >= 0.0 else -rate
	var fv: float = clampf(
		1.0 - maxf(shorten, 0.0) / FINGER_MUSCLE_MAX_RATE, 0.0, 1.0)
	want *= fv
	# 关节黏性：与角速度成正比的阻力，方向永远和运动相反。它不经过
	# 力—速度关系（那是主动收缩的损耗，不是被动阻力）。
	want -= FINGER_JOINT_DAMPING * rate
	# 激活动力学：横桥从零建立到满张力需要约 0.1 s，张力也只能按这个
	# 速率变化。没有这一项，满力矩会在一帧内把手指变成锤子。
	var ramp: float = torque * dt / FINGER_GRIP_RAMP_TIME
	var state: float = float((_finger_grip_force[h][f] as Array)[j])
	var out: float = move_toward(state, want, ramp)
	(_finger_grip_force[h][f] as Array)[j] = out
	# 屈曲 = 绕 -axis，即铰链 z 轴的负向。目标角速度只由几何误差决定
	# （不是由 out 的符号决定，否则阻尼项会在目标附近来回翻符号）。
	joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, absf(out) * dt)
	joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY,
		clampf(err_deg * 8.0 * 0.0174533, -6.0, 6.0))


func _exit_tree() -> void:
	if _hand_physics_root != null and is_instance_valid(_hand_physics_root):
		_hand_physics_root.queue_free()


func _build_fingers_on_hand(hand_root: Node3D, h: int, skin) -> void:
	var spread: Array = [-0.03, -0.01, 0.01, 0.03]
	var hand_pivots: Array = []
	var hand_angles: Array = []
	var hand_lengths: Array = []

	for f in range(5):
		var base := Node3D.new()
		if f == 0:
			var inner: float = 1.0 if h == 0 else -1.0
			# 拇指根（CMC）长在掌骨桡侧边缘。
			# y=-0.013：掌面在 -0.008，指骨半径 5 mm，中心再低 5 mm 才
			# 不会和掌盒的碰撞体打架。
			# z=+0.008：CMC 退到掌的近端（腕侧），离四指指根（z=-0.055）
			# 拉开 6 cm。握口因此变大——拇指和四指像两把钳口，能把正常
			# 粗细（Ø3.5-5 cm）的树枝夹在中间，而不是被四指指根挤出去。
			base.position = Vector3(0.054 * inner, -0.013, 0.008)
			# 拇指**横着长**：基准生长方向垂直于四指（四指沿 -z 长，
			# 拇指沿 ±x 长），再靠 CMC 内收扫向前方（见
			# [_build_fingers_for_hand] 的 CMC 过渡体）。屈曲轴取掌 z，
			# 绕它转拇指压向掌面。四指卷在 y-z 平面，拇指压在 x-y 平面，
			# 两个弯曲平面互相垂直。
			#
			# 基座局部系：局部 -z = 生长方向，局部 x = 屈曲轴。
			# 这样 [_apply_finger_pose] 的 rotation.x 和铰链的
			# 局部 x 轴都直接对上，不用给拇指开特例。
			var palm_frame: Basis = hand_root.global_transform.basis.orthonormalized()
			var grow: Vector3 = palm_frame * Vector3(inner, 0.0, 0.0)
			var bend_axis: Vector3 = palm_frame * Vector3(0.0, 0.0, inner)
			var thumb_basis := Basis(bend_axis,
				(-grow).cross(bend_axis).normalized(), -grow)
			base.basis = palm_frame.inverse() * thumb_basis
		else:
			base.position = Vector3(spread[f - 1], 0.0, -0.055)
		hand_root.add_child(base)

		# 四指近节 4.6 cm / 中节 2.6 / 末节 2.0 = 9.2 cm，接近真人食指。
		# 近节太短（3.4 cm）时，合拢后的钩子围出的内径只有 1.6 cm。
		# 拇指三节（掌骨 3.0 + 近节 2.2 + 末节 1.6 = 6.8 cm）。真人拇指
		# 从 CMC 到指尖约等于掌宽（10 cm）的 0.65-0.7；之前 9.9 cm 和
		# 掌宽一样长，对掌时指尖会甩到掌外 9 cm 才折回，永远够不到
		# 掌前的握持口袋。
		var lengths: Array = [0.046, 0.026, 0.020] if f > 0 else [0.030, 0.022, 0.016]
		var pivots: Array = []
		var parent: Node3D = base
		for j in range(lengths.size()):
			pivots.append(parent)
			var seg_len: float = lengths[j]
			var mi := MeshInstance3D.new()
			var cap := CapsuleMesh.new()
			cap.radius = 0.008
			cap.height = seg_len
			mi.mesh = cap
			mi.material_override = skin
			mi.position = Vector3(0.0, 0.0, -seg_len * 0.5)
			mi.rotation.x = PI * 0.5
			# 真物理手启用时，运动学指骨只作为位姿参考；
			# 可见皮肉由刚体的实际位姿在 _rebuild_body_skin 里扫掠出来
			mi.visible = not _physical_hands_enabled
			parent.add_child(mi)
			var next := Node3D.new()
			next.position = Vector3(0.0, 0.0, -seg_len)
			parent.add_child(next)
			parent = next

		hand_pivots.append(pivots)
		hand_angles.append([0.0, 0.0, 0.0].slice(0, lengths.size()))
		hand_lengths.append(lengths)

	_finger_pivots.append(hand_pivots)
	_finger_angles.append(hand_angles)
	_finger_seg_lengths.append(hand_lengths)


func _apply_arm_pose() -> void:
	for h in range(_arm_pivots.size()):
		var pivots: Dictionary = _arm_pivots[h]
		var angles: Dictionary = _arm_angles[h]
		var shoulder: Node3D = pivots["shoulder"]
		# 侧举角与关节轴一样左右镜像
		var lift_sign: float = 1.0 if h == 1 else -1.0
		shoulder.rotation = Vector3(
			deg_to_rad(float(angles["shoulder_x"])), 0.0,
			deg_to_rad(float(angles["shoulder_z"])) * lift_sign)
		var elbow: Node3D = pivots["elbow"]
		elbow.rotation.x = -deg_to_rad(float(angles["elbow_x"]))
		var wrist: Node3D = pivots["wrist"]
		# 腕屈伸绕本地 X；旋转（旋前/旋后）绕前臂长轴 Y
		wrist.rotation = Vector3(
			deg_to_rad(float(angles["wrist_x"])),
			deg_to_rad(float(angles["wrist_y"])), 0.0)


func _apply_finger_pose() -> void:
	for h in range(_finger_pivots.size()):
		for f in range(_finger_pivots[h].size()):
			var pivots: Array = _finger_pivots[h][f]
			var angles: Array = _finger_angles[h][f]
			for j in range(pivots.size()):
				var pivot: Node3D = pivots[j]
				pivot.rotation.x = -deg_to_rad(float(angles[j]))


func _select_finger(hand: int, finger: int) -> void:
	_selected_fingers[hand][finger] = not _selected_fingers[hand][finger]
	_update_finger_hud()


func _adjust_selected_joint(delta_deg: float) -> void:
	if _finger_angles.is_empty():
		return
	var active_until: int = Time.get_ticks_msec() + ACTIVE_HOLD_MS
	for h in range(2):
		for f in range(5):
			if _selected_fingers[h][f]:
				var angles: Array = _finger_angles[h][f]
				# 不同手指关节数不同（拇指三节、四指三节），选中号可能越界
				var sel: int = mini(_selected_joint, angles.size() - 1)
				angles[sel] = clampf(
					float(angles[sel]) + delta_deg, -15.0, 95.0)
				# 主动发力窗口：期间肌肉出满力，之后退回静力支撑
				if _finger_active_until.size() > h and _finger_active_until[h].size() > f:
					_finger_active_until[h][f][sel] = active_until
	_apply_finger_pose()
	_update_finger_hud()


func _adjust_selected_arm_joint(delta_deg: float) -> void:
	if _arm_angles.is_empty():
		return
	var hand: int = 0 if _selected_arm_joint < ARM_JOINTS_PER_HAND else 1
	var key: String = ARM_JOINT_KEYS[_selected_arm_joint]
	var angles: Dictionary = _arm_angles[hand]

	var min_value := -180.0
	var max_value := 180.0
	match key:
		"shoulder_x":
			min_value = -150.0
			max_value = 150.0
		"shoulder_z":
			min_value = -30.0
			max_value = 150.0
		"elbow_x":
			min_value = -5.0
			max_value = 150.0
		"wrist_x":
			min_value = -60.0
			max_value = 60.0
		"wrist_y":
			# 旋前/旋后：正常成人约 ±90°
			min_value = -90.0
			max_value = 90.0

	angles[key] = clampf(float(angles[key]) + delta_deg, min_value, max_value)
	# 主动发力窗口：期间肌肉出满力，之后退回静力支撑
	if _arm_active_until.size() > hand:
		_arm_active_until[hand][key] = Time.get_ticks_msec() + ACTIVE_HOLD_MS
	_apply_arm_pose()
	_update_finger_hud()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "DeveloperHUD"
	add_child(layer)
	_finger_hud = Label.new()
	_finger_hud.position = Vector2(18.0, 14.0)
	_finger_hud.add_theme_font_size_override("font_size", 14)
	_finger_hud.add_theme_color_override("font_color", Color(0.90, 0.96, 1.0))
	_finger_hud.add_theme_color_override("font_shadow_color", Color(0.0, 0.0, 0.0, 0.8))
	_finger_hud.add_theme_constant_override("shadow_offset_x", 1)
	_finger_hud.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(_finger_hud)
	_update_finger_hud()


func _update_finger_hud() -> void:
	if _finger_hud == null:
		return
	var hands := ["L", "R"]
	var fingers := ["thumb", "index", "middle", "ring", "pinky"]
	var joints := ["prox", "mid", "dist"]

	var selected_names: Array = []
	var finger_angle_sum: float = 0.0
	var finger_count: int = 0
	for h in range(2):
		for f in range(5):
			if _selected_fingers[h][f]:
				selected_names.append(hands[h] + "-" + fingers[f])
				var fa: Array = _finger_angles[h][f]
				finger_angle_sum += float(fa[mini(_selected_joint, fa.size() - 1)])
				finger_count += 1
	var selected_text := "none"
	if not selected_names.is_empty():
		selected_text = ""
		for n in selected_names:
			if selected_text != "":
				selected_text += ","
			selected_text += String(n)
	var finger_angle: float = finger_angle_sum / float(finger_count) if finger_count > 0 else 0.0

	var arm_hand: int = 0 if _selected_arm_joint < ARM_JOINTS_PER_HAND else 1
	var arm_key: String = ARM_JOINT_KEYS[_selected_arm_joint]
	var arm_angle: float = 0.0
	if not _arm_angles.is_empty():
		arm_angle = float(_arm_angles[arm_hand][arm_key])
	var terrain_line := "Terrain: -"
	if terrain != null and position.length() > 1.0:
		var province := terrain.get_province(position)
		var flags: int = int(province.get("flags", 0))
		var name := "ocean/other"
		if (flags & Terrain.PROV_RIVER) != 0:
			name = "river"
		elif (flags & Terrain.PROV_VOLCANIC) != 0:
			name = "volcanic"
		elif (flags & Terrain.PROV_METAMORPHIC) != 0:
			name = "metamorphic"
		elif (flags & Terrain.PROV_GRANITE) != 0:
			name = "granite"
		elif (flags & Terrain.PROV_SEDIMENTARY) != 0:
			name = "sedimentary"
		elif (flags & Terrain.PROV_COASTAL) != 0:
			name = "coastal"
		var elev: float = terrain.get_elevation(position)
		terrain_line = "Terrain: %s | elev %.0fm" % [name, elev]

	var strength_line := "Strength: -"
	if _player_body != null:
		strength_line = "Strength: %.0f/%.0f N (physique %.2f)" % [
			_player_body.current_strength, _player_body.max_strength,
			_player_body.physique]
		if _player_body.osteoporosis > 0.0:
			strength_line += " | osteo %.2f" % _player_body.osteoporosis
	if _bone_message != "":
		strength_line += " | " + _bone_message

	_finger_hud.text = (
		"Fingers: %s | joint %s %.0f deg | ` cycle\n"
		+ "Arm: %s %.0f deg | F cycle | wheel\n"
		+ "1-5/6-0 toggle | wheel arm | Ctrl hold crouch / C toggle\n%s\n%s"
	) % [selected_text, joints[_selected_joint], finger_angle,
		ARM_JOINT_LABELS[_selected_arm_joint], arm_angle, terrain_line, strength_line]


func _body_mat(color: Color) -> StandardMaterial3D:
	var key := "%.2f%.2f%.2f" % [color.r, color.g, color.b]
	if _body_materials.has(key):
		return _body_materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	_body_materials[key] = mat
	return mat


func _add_sphere(radius: float, pos: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	(parent if parent != null else _body_root).add_child(mi)
	return mi
