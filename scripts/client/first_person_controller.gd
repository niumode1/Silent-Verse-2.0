# ============================================================
# FirstPersonController — 球面重力第一人称
# ============================================================
# 手动球面行走：位置始终锁定在星球表面，WASD绕球心旋转。
# ============================================================
class_name FirstPersonController
extends CharacterBody3D

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
var _arm_angles: Array = []         # [hand] = {shoulder_x, shoulder_z, elbow_x, wrist_x}
var _selected_arm_joint: int = 0
var _finger_seg_lengths: Array = []   # [hand][finger] = [prox_len, mid_len, dist_len]
var _palm_bodies: Array = []          # AnimatableBody3D palm anchor per hand
var _finger_segments: Array = []      # [hand][finger] = [RigidBody3D x3]
var _finger_joints: Array = []        # [hand][finger] = [HingeJoint3D x3]
var _hand_physics_root: Node3D = null
var _body_skin: StandardMaterial3D = null
const ARM_JOINT_LABELS := [
	"L shoulder pitch", "L shoulder roll", "L elbow", "L wrist",
	"R shoulder pitch", "R shoulder roll", "R elbow", "R wrist",
]
const ARM_JOINT_KEYS := [
	"shoulder_x", "shoulder_z", "elbow_x", "wrist_x",
	"shoulder_x", "shoulder_z", "elbow_x", "wrist_x",
]


func _ready() -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.32
	capsule.height = standing_height
	_collision_shape.shape = capsule
	_collision_shape.position = Vector3(0, standing_height * 0.5, 0)

	floor_max_angle = deg_to_rad(80.0)
	floor_snap_length = 1.0
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	collision_layer = 8   # 玩家专用层，避免手部碰撞体与自身相撞
	collision_mask = 3    # 地形层(2) + 树/物品(1)

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
	# 物理手原型暂未通过稳定性验证，先保持可见手指与运动学控制。
	# 隔离测试通过后再接入 _build_hand_physics()。
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
		# 接触点相对刚体原点的偏移 → 产生平移 + 转矩（推走 / 翻倒 / 滚动）
		var contact_offset: Vector3 = collision.get_position() - collider.global_position
		var impulse: Vector3 = push_dir.normalized() * push_force * delta
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
	var shirt := _body_mat(Color(0.28, 0.34, 0.40))
	var pants := _body_mat(Color(0.20, 0.19, 0.18))
	var boots := _body_mat(Color(0.12, 0.10, 0.08))

	# 髋/膝/踝可动腿
	_build_legs(pants, boots)
	# 髋 / 胸廓（宽扁胶囊，胸部略微后移，镜头在头部前方）
	_add_box(Vector3(0.34, 0.18, 0.22), Vector3(0.0, 0.82, 0.04), pants)
	var chest := _add_capsule(0.17, 0.55, Vector3(0.0, 1.06, -0.02), shirt)
	chest.scale = Vector3(1.25, 0.95, 0.95)
	# 腰带
	_add_box(Vector3(0.34, 0.07, 0.22), Vector3(0.0, 0.90, -0.02), boots)
	# 肩/肘/腕可动的手臂 + 手指
	_build_arms(skin)
	# 颈部枢轴 + 颈 + 头（头部在本地相机层之外）
	_neck_pivot = Node3D.new()
	_neck_pivot.name = "NeckPivot"
	_neck_pivot.position = Vector3(0.0, 1.31, 0.05)
	_body_root.add_child(_neck_pivot)
	var neck := _add_capsule(0.055, 0.14, Vector3(0.0, 0.07, 0.0), skin, _neck_pivot)
	neck.name = "Neck"
	var head := _add_sphere(0.11, Vector3(0.0, 0.21, 0.0), skin, _neck_pivot)
	head.name = "Head"
	# 面部标记，让抬头/低头的头部朝向可见（眼睛在镜头后方，不挡视野）
	var eye_l := _add_sphere(0.018, Vector3(-0.035, 0.235, -0.105), boots, _neck_pivot)
	eye_l.name = "EyeLeft"
	var eye_r := _add_sphere(0.018, Vector3(0.035, 0.235, -0.105), boots, _neck_pivot)
	eye_r.name = "EyeRight"
	var nose := _add_sphere(0.024, Vector3(0.0, 0.205, -0.115), skin, _neck_pivot)
	nose.name = "Nose"

	# 镜头放在两眼之间中点（头部前方表面）。头部网格保留，
	# 相机在面部表面，头在相机后方，不会挡视线。
	# 未来 VR：在同一 _neck_pivot 下加左右眼两个 Camera3D（间距约 0.064m）。
	var old_parent := _camera.get_parent()
	if old_parent != null:
		old_parent.remove_child(_camera)
	_neck_pivot.add_child(_camera)
	_camera.position = Vector3(0.0, 0.24, -0.11)
	_camera.rotation = Vector3.ZERO


func _process(delta: float) -> void:
	_hud_timer += delta
	if _hud_timer >= 0.3:
		_hud_timer = 0.0
		_update_finger_hud()


func _build_legs(pants, boots) -> void:
	_leg_pivots.clear()
	for side in range(2):
		var x: float = -0.11 if side == 0 else 0.11
		var hip := Node3D.new()
		hip.name = "LeftHip" if side == 0 else "RightHip"
		hip.position = Vector3(x, 0.90, 0.0)
		_body_root.add_child(hip)
		_add_capsule(0.075, 0.40, Vector3(0.0, -0.20, 0.0), pants, hip)

		var knee := Node3D.new()
		knee.name = "LeftKnee" if side == 0 else "RightKnee"
		knee.position = Vector3(0.0, -0.40, 0.0)
		hip.add_child(knee)
		_add_capsule(0.06, 0.38, Vector3(0.0, -0.19, 0.0), pants, knee)

		var ankle := Node3D.new()
		ankle.name = "LeftAnkle" if side == 0 else "RightAnkle"
		ankle.position = Vector3(0.0, -0.38, 0.0)
		knee.add_child(ankle)
		_add_box(Vector3(0.15, 0.09, 0.25), Vector3(0.0, -0.02, -0.06), boots, ankle)

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
		_add_capsule(0.05, 0.28, Vector3(0.0, -0.14, 0.0), skin, shoulder)

		var elbow := Node3D.new()
		elbow.name = "LeftElbow" if h == 0 else "RightElbow"
		elbow.position = Vector3(0.0, -0.28, 0.0)
		shoulder.add_child(elbow)
		_add_capsule(0.045, 0.26, Vector3(0.0, -0.13, 0.0), skin, elbow)

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
		})

		var hand_root := Node3D.new()
		hand_root.name = "LeftHand" if h == 0 else "RightHand"
		hand_root.position = Vector3(0.0, -0.02, -0.12)
		hand_root.rotation.x = deg_to_rad(-18.0)
		wrist.add_child(hand_root)
		_hand_roots.append(hand_root)
		_add_box(Vector3(0.10, 0.035, 0.11), Vector3.ZERO, skin, hand_root)
		_build_fingers_on_hand(hand_root, h, skin)

	_apply_arm_pose()
	_apply_finger_pose()


func _build_hand_physics(skin) -> void:
	_palm_bodies.clear()
	_finger_segments.clear()
	_finger_joints.clear()
	if _hand_physics_root != null:
		_hand_physics_root.queue_free()
	_hand_physics_root = Node3D.new()
	_hand_physics_root.name = "PhysicalHands"
	var scene_root := get_tree().current_scene
	if scene_root == null:
		scene_root = self
	scene_root.add_child(_hand_physics_root)

	for h in range(2):
		var palm := AnimatableBody3D.new()
		palm.name = "LeftPalmBody" if h == 0 else "RightPalmBody"
		palm.sync_to_physics = true
		palm.collision_layer = 4
		palm.collision_mask = 1
		var palm_phys := PhysicsMaterial.new()
		palm_phys.friction = 0.9
		palm_phys.bounce = 0.0
		palm.physics_material_override = palm_phys
		var palm_col := CollisionShape3D.new()
		var palm_shape := BoxShape3D.new()
		palm_shape.size = Vector3(0.10, 0.035, 0.11)
		palm_col.shape = palm_shape
		palm.add_child(palm_col)
		_hand_physics_root.add_child(palm)
		_palm_bodies.append(palm)

		var hand_segments: Array = []
		for f in range(5):
			var finger_segments: Array = []
			for j in range(3):
				var pivot: Node3D = _finger_pivots[h][f][j]
				var seg_len: float = float(_finger_seg_lengths[h][f][j])
				var basis := pivot.global_transform.basis
				var center: Vector3 = pivot.global_transform * Vector3(0.0, 0.0, -seg_len * 0.5)

				var seg := RigidBody3D.new()
				seg.name = "Finger_%d_%d_%d" % [h, f, j]
				seg.mass = 0.02
				seg.gravity_scale = 1.0
				seg.collision_layer = 4
				seg.collision_mask = 1
				seg.linear_damp = 0.15
				seg.angular_damp = 0.35
				seg.continuous_cd = true
				var seg_phys := PhysicsMaterial.new()
				seg_phys.friction = 0.9
				seg_phys.bounce = 0.0
				seg.physics_material_override = seg_phys
				_hand_physics_root.add_child(seg)
				seg.global_transform = Transform3D(basis, center)

				var mi := MeshInstance3D.new()
				var cap := CapsuleMesh.new()
				cap.radius = 0.009
				cap.height = seg_len
				mi.mesh = cap
				mi.material_override = skin
				mi.rotation.x = PI * 0.5
				seg.add_child(mi)

				var col := CollisionShape3D.new()
				var shape := CapsuleShape3D.new()
				shape.radius = 0.009
				shape.height = seg_len
				col.shape = shape
				col.rotation.x = PI * 0.5
				seg.add_child(col)

				finger_segments.append(seg)
			hand_segments.append(finger_segments)
		_finger_segments.append(hand_segments)

		var hand_joints: Array = []
		for f in range(5):
			var finger_joints: Array = []
			for j in range(3):
				var pivot: Node3D = _finger_pivots[h][f][j]
				var parent_body: Node3D = palm if j == 0 else _finger_segments[h][f][j - 1]
				var seg: RigidBody3D = _finger_segments[h][f][j]
				var joint := HingeJoint3D.new()
				_hand_physics_root.add_child(joint)
				joint.node_a = joint.get_path_to(parent_body)
				joint.node_b = joint.get_path_to(seg)

				var joint_pos: Vector3 = pivot.global_transform.origin
				var axis: Vector3 = parent_body.global_transform.basis.x.normalized()
				var z := axis
				var x := z.cross(Vector3.UP)
				if x.length() < 0.01:
					x = z.cross(Vector3.RIGHT)
				x = x.normalized()
				var y := z.cross(x).normalized()
				joint.global_transform = Transform3D(Basis(x, y, z), joint_pos)

				joint.set_flag(HingeJoint3D.FLAG_USE_LIMIT, true)
				joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, 0.0)
				joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(30.0))
				joint.set_flag(HingeJoint3D.FLAG_ENABLE_MOTOR, true)
				joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 0.0)
				joint.set_param(HingeJoint3D.PARAM_MOTOR_MAX_IMPULSE, 0.2)
				finger_joints.append(joint)
			hand_joints.append(finger_joints)
		_finger_joints.append(hand_joints)

	_update_hand_physics()


func _update_hand_physics() -> void:
	for h in range(_palm_bodies.size()):
		if h >= _hand_roots.size():
			continue
		var palm: AnimatableBody3D = _palm_bodies[h]
		palm.global_transform = _hand_roots[h].global_transform

		for f in range(5):
			for j in range(3):
				var target_deg: float = float(_finger_angles[h][f][j])
				var joint: HingeJoint3D = _finger_joints[h][f][j]
				joint.set_param(HingeJoint3D.PARAM_LIMIT_LOWER, 0.0)
				joint.set_param(HingeJoint3D.PARAM_LIMIT_UPPER, deg_to_rad(maxf(target_deg, 1.0)))
				joint.set_param(HingeJoint3D.PARAM_MOTOR_TARGET_VELOCITY, 4.0 if target_deg > 5.0 else -4.0)


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
			base.position = Vector3(0.055 * inner, -0.005, -0.025)
			base.rotation.y = deg_to_rad(-35.0 * inner)
			base.rotation.z = deg_to_rad(25.0 * inner)
		else:
			base.position = Vector3(spread[f - 1], 0.0, -0.055)
		hand_root.add_child(base)

		var lengths: Array = [0.034, 0.028, 0.022] if f > 0 else [0.028, 0.022, 0.018]
		var pivots: Array = []
		var parent: Node3D = base
		for j in range(3):
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
			mi.visible = true
			parent.add_child(mi)
			var next := Node3D.new()
			next.position = Vector3(0.0, 0.0, -seg_len)
			parent.add_child(next)
			parent = next

		hand_pivots.append(pivots)
		hand_angles.append([0.0, 0.0, 0.0])
		hand_lengths.append(lengths)

	_finger_pivots.append(hand_pivots)
	_finger_angles.append(hand_angles)
	_finger_seg_lengths.append(hand_lengths)


func _apply_arm_pose() -> void:
	for h in range(_arm_pivots.size()):
		var pivots: Dictionary = _arm_pivots[h]
		var angles: Dictionary = _arm_angles[h]
		var shoulder: Node3D = pivots["shoulder"]
		shoulder.rotation = Vector3(
			deg_to_rad(float(angles["shoulder_x"])), 0.0,
			deg_to_rad(float(angles["shoulder_z"])))
		var elbow: Node3D = pivots["elbow"]
		elbow.rotation.x = -deg_to_rad(float(angles["elbow_x"]))
		var wrist: Node3D = pivots["wrist"]
		wrist.rotation.x = deg_to_rad(float(angles["wrist_x"]))


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
	for h in range(2):
		for f in range(5):
			if _selected_fingers[h][f]:
				var angles: Array = _finger_angles[h][f]
				angles[_selected_joint] = clampf(
					float(angles[_selected_joint]) + delta_deg, -15.0, 95.0)
	_apply_finger_pose()
	_update_finger_hud()


func _adjust_selected_arm_joint(delta_deg: float) -> void:
	if _arm_angles.is_empty():
		return
	var hand: int = 0 if _selected_arm_joint < 4 else 1
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

	angles[key] = clampf(float(angles[key]) + delta_deg, min_value, max_value)
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
				finger_angle_sum += float(_finger_angles[h][f][_selected_joint])
				finger_count += 1
	var selected_text := "none"
	if not selected_names.is_empty():
		selected_text = ""
		for n in selected_names:
			if selected_text != "":
				selected_text += ","
			selected_text += String(n)
	var finger_angle: float = finger_angle_sum / float(finger_count) if finger_count > 0 else 0.0

	var arm_hand: int = 0 if _selected_arm_joint < 4 else 1
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

	_finger_hud.text = (
		"Fingers: %s | joint %s %.0f deg | ` cycle\n"
		+ "Arm: %s %.0f deg | F cycle | wheel\n"
		+ "1-5/6-0 toggle | wheel arm | Ctrl hold crouch / C toggle\n%s"
	) % [selected_text, joints[_selected_joint], finger_angle,
		ARM_JOINT_LABELS[_selected_arm_joint], arm_angle, terrain_line]


func _body_mat(color: Color) -> StandardMaterial3D:
	var key := "%.2f%.2f%.2f" % [color.r, color.g, color.b]
	if _body_materials.has(key):
		return _body_materials[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	_body_materials[key] = mat
	return mat


func _add_box(size: Vector3, pos: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	(parent if parent != null else _body_root).add_child(mi)
	return mi


func _add_capsule(radius: float, height: float, pos: Vector3, mat: Material, parent: Node3D = null) -> MeshInstance3D:
	var mesh := CapsuleMesh.new()
	mesh.radius = radius
	mesh.height = height
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	(parent if parent != null else _body_root).add_child(mi)
	return mi


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
