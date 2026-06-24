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
@export var standing_height: float = 1.8
@export var crouch_height: float = 0.9
@export var planet_radius: float = 3978.87
@export var surface_gravity: float = 9.81

@onready var _camera: Camera3D = $Camera3D
@onready var _collision_shape: CollisionShape3D = $CollisionShape3D

var _yaw: float = 0.0
var _pitch: float = 0.0
var _is_sprinting: bool = false
var _is_crouching: bool = false
var _fall_speed: float = 0.0  # 下落速度 m/s（正=朝球心落）


func _ready() -> void:
	var capsule := CapsuleShape3D.new()
	capsule.radius = 0.4
	capsule.height = standing_height
	_collision_shape.shape = capsule

	# 可见身体（Phase 1 临时胶囊，后续替换为角色模型）
	var body_mesh := MeshInstance3D.new()
	body_mesh.name = "BodyMesh"
	var cap_mesh := CapsuleMesh.new()
	cap_mesh.radius = 0.35
	cap_mesh.height = standing_height * 0.8
	body_mesh.mesh = cap_mesh
	body_mesh.position = Vector3(0, standing_height * 0.45, 0)
	var body_mat := StandardMaterial3D.new()
	body_mat.albedo_color = Color(0.7, 0.55, 0.4)
	body_mesh.material_override = body_mat
	add_child(body_mesh)

	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func spawn_on_surface(surface_pos: Vector3) -> void:
	var sky := surface_pos.normalized()
	position = sky * (planet_radius + 1.8)
	_fall_speed = 0.0
	_yaw = 0.0
	_pitch = 0.0
	print("Player spawned at distance=", position.length())


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * mouse_sensitivity
		_pitch -= event.relative.y * mouse_sensitivity
		_pitch = clampf(_pitch, deg_to_rad(-89), deg_to_rad(89))

	if event is InputEventKey:
		if event.pressed and event.keycode == KEY_ESCAPE:
			Input.set_mouse_mode(
				Input.MOUSE_MODE_VISIBLE if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED
				else Input.MOUSE_MODE_CAPTURED)
		if event.keycode == KEY_SHIFT:
			_is_sprinting = event.pressed
		if event.pressed and event.keycode == KEY_C:
			_is_crouching = not _is_crouching
			var capsule: CapsuleShape3D = _collision_shape.shape
			capsule.height = crouch_height if _is_crouching else standing_height


func _physics_process(delta: float) -> void:
	var sky := position.normalized()
	var surface_r := planet_radius + 0.9
	var altitude := position.length() - surface_r

	# 重力（始终拉向球心）
	_fall_speed += surface_gravity * delta

	# 贴地检测
	var on_ground := altitude < 0.5 and _fall_speed >= 0.0
	if on_ground:
		_fall_speed = 0.0
		altitude = 0.0

	# 跳跃
	if Input.is_action_just_pressed("interact") and on_ground:
		_fall_speed = -jump_velocity  # 负=背离球心

	# 更新高度：下落速度减小 altitude
	altitude -= _fall_speed * delta
	if altitude < 0.0:
		altitude = 0.0

	# 应用径向位置
	position = sky * (surface_r + altitude)

	# 相机朝向
	_update_orientation()

	# WASD 沿球面移动
	var input := Vector2.ZERO
	if Input.is_action_pressed("move_forward"): input.y -= 1
	if Input.is_action_pressed("move_backward"): input.y += 1
	if Input.is_action_pressed("move_left"): input.x += 1
	if Input.is_action_pressed("move_right"): input.x -= 1

	if input.length() > 0.01 and _camera:
		# 相机切面方向
		var cam_fwd := -_camera.global_transform.basis.z
		var cam_rt := _camera.global_transform.basis.x
		var fwd := (cam_fwd - sky * cam_fwd.dot(sky)).normalized()
		var rgt := (cam_rt - sky * cam_rt.dot(sky)).normalized()
		var move := (fwd * input.y + rgt * input.x)
		if move.length() > 0.01:
			move = move.normalized()

			var speed: float = sprint_speed if _is_sprinting else walk_speed
			if _is_crouching:
				speed = crouch_speed

			# 绕球心旋转（在切平面内移动 = 沿大圆走）
			var axis := move.cross(sky).normalized()
			var angle := speed * delta / surface_r
			position = position.rotated(axis, angle)
			position = position.normalized() * (surface_r + altitude)


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

	# camera 本地旋转
	_camera.transform.origin = Vector3(0, standing_height * 0.45, 0)
	_camera.rotation = Vector3(_pitch, _yaw, 0)
