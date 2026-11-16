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

## 掉穿地形时的回退位置（由渲染层设置为出生点附近的可见地表）
var fallback_position: Vector3 = Vector3.ZERO

## 地表半径采样 Callable(pos) -> float（由渲染层注入）。
## 物品被挤进地形时，按它当前所在的方向重新放回本地地表，
## 而不是瞬移回出生点——否则玩家会看到木棍「钻地后闪到树下」。
var ground_radius_sampler: Callable = Callable()

## 回位后的静默期。视觉网格与碰撞三角网在陡坡上可能有几米高差，
## 刚放回物理地表就再拿网格高度判定，会陷入「一帧回位一次」的抖动。
var _recover_until_ms: int = 0


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

	# 极少数长条/陡坡情况可能穿过三角网。判定两种掉穿：
	#   1. 埋到本地地表 3 m 以下（贴着脚下就发现，不用等掉下去）
	#   2. 掉到星球半径以下很深（采样不可用时的兜底）
	# 回位一律按当前方向重新落到本地地表，保留玩家把它推到的地方。
	var radius: float = global_position.length()
	var underground := false
	# 地表采样不便宜（场上几百件物品），醒着的每帧查，睡着的 1 秒查一次
	var check_ground: bool = not sleeping \
		or (Engine.get_physics_frames() + get_instance_id()) % 60 == 0
	if check_ground and Time.get_ticks_msec() >= _recover_until_ms \
			and ground_radius_sampler.is_valid() and radius > 1.0:
		var surface: float = float(ground_radius_sampler.call(global_position))
		underground = radius < surface - 3.0
	var min_radius: float = planet_radius - 20.0
	if fallback_position != Vector3.ZERO:
		min_radius = maxf(min_radius, fallback_position.length() - 25.0)
	var fell_out: bool = fallback_position != Vector3.ZERO and radius < min_radius
	if underground or fell_out:
		var dir: Vector3 = global_position.normalized()
		if dir.length_squared() < 0.25:
			# 退化到球心时没有「当前方向」，只能回出生点方向
			dir = fallback_position.normalized()
		var place_radius: float = fallback_position.length()
		# 落点用物理射线实测地表：视觉网格和碰撞三角网的采样网格不完全一致，
		# 按网格高度放回可能会卡进地形或悬空。射线从球外打进本地地表。
		var placed := false
		var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
		if space != null and planet_radius > 0.0:
			var query := PhysicsRayQueryParameters3D.create(
				dir * (planet_radius + 1000.0), dir * (planet_radius - 1000.0), 2)
			var hit: Dictionary = space.intersect_ray(query)
			if not hit.is_empty():
				place_radius = (hit["position"] as Vector3).length() + 0.2
				placed = true
		if not placed and ground_radius_sampler.is_valid():
			place_radius = float(ground_radius_sampler.call(dir)) + 0.2
		global_position = dir * place_radius
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		# 放在物理地表上方 0.2 m，交给重力自己落稳（不锁死，避免悬空）
		sleeping = false
		_still_time = 0.0
		# 静默 3 秒：视觉网格和碰撞面有高差时不要立刻再判一次
		_recover_until_ms = Time.get_ticks_msec() + 3000
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
