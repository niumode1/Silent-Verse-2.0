# ============================================================
# ItemPhysicsBody — 地面物品的球心重力刚体
# ============================================================
# 石头/倒木/矿石在世界里是动态刚体：受指向球心的重力，
# 与地形、树干、其他物品和玩家发生碰撞，最终静止并休眠。
# Phase 1 暂时运行在客户端；后续由服务端权威模拟并同步状态。
# ============================================================
class_name ItemPhysicsBody
extends RigidBody3D

## 对应的物品数据；物理位置会回写到 ItemEntity.transform
var item: ItemEntity = null

## 星球半径，用于 g(h)=g0·(R/(R+h))²
var planet_radius: float = 3978.87

var _still_time: float = 0.0

## 掉穿地形时的回退位置（由渲染层设置为可见地表附近）
var fallback_position: Vector3 = Vector3.ZERO


func _ready() -> void:
	# 关闭 Godot 默认的 uniform 重力，改用球心重力
	gravity_scale = 0.0
	can_sleep = true
	contact_monitor = true
	max_contacts_reported = 2


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var origin: Vector3 = state.transform.origin
	if origin.length() < 1.0:
		return
	var sky: Vector3 = origin.normalized()
	var altitude: float = maxf(origin.length() - planet_radius, 0.0)
	var gravity: float = PhysicsConstants.get_gravity_at_altitude(altitude)
	state.apply_central_force(-sky * gravity * mass)


func _physics_process(delta: float) -> void:
	if item != null:
		item.transform = global_transform

	# 极少数长条/陡坡情况可能穿过三角网；兜底回地表并休眠
	var min_radius: float = planet_radius - 20.0
	if fallback_position != Vector3.ZERO:
		min_radius = maxf(min_radius, fallback_position.length() - 25.0)
	if fallback_position != Vector3.ZERO and global_position.length() < min_radius:
		global_position = fallback_position
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		sleeping = true
		_still_time = 0.0
		if item != null:
			item.transform = global_transform
		return

	if sleeping:
		return

	# 摩擦功 → 热量：Q = μ·N·v·dt，ΔT = Q/(m·cp)
	if item != null and get_contact_count() > 0:
		var speed: float = linear_velocity.length() + angular_velocity.length() * 0.2
		if speed > 0.05:
			var mat = item.get_material()
			var mu: float = mat.kinetic_friction if mat != null else 0.5
			var alt: float = maxf(global_position.length() - planet_radius, 0.0)
			var gravity: float = PhysicsConstants.get_gravity_at_altitude(alt)
			var heat_j: float = mu * mass * gravity * speed * delta
			var cp: float = mat.specific_heat if mat != null else 1000.0
			item.temperature_c += heat_j / (maxf(mass, 0.1) * maxf(cp, 1.0))
			item.temperature_c = move_toward(item.temperature_c, 20.0, 0.01 * delta)
	if linear_velocity.length() < 0.08 and angular_velocity.length() < 0.08:
		_still_time += delta
		if _still_time > 1.0:
			sleeping = true
	else:
		_still_time = 0.0
