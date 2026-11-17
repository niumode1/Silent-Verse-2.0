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

## 玩家当前位置，由 FirstPersonController 每帧写入。
## 只用于把防穿模射线的精度限制在看得见的范围内——物理模拟本身对所有
## 物品照常进行，不因远近而改变。
static var player_position: Vector3 = Vector3.ZERO


## 掉穿地形时的回退位置（由渲染层设置为出生点附近的可见地表）
var fallback_position: Vector3 = Vector3.ZERO

## 地表半径采样 Callable(pos) -> float（由渲染层注入）。
## 物品被挤进地形时，按它当前所在的方向重新放回本地地表，
## 而不是瞬移回出生点——否则玩家会看到木棍「钻地后闪到树下」。
var ground_radius_sampler: Callable = Callable()

## 回位后的静默期。视觉网格与碰撞三角网在陡坡上可能有几米高差，
## 刚放回物理地表就再拿网格高度判定，会陷入「一帧回位一次」的抖动。
var _recover_until_ms: int = 0

## 防穿模硬校正后的短暂静默期，避免和接触求解互相打架。
var _guard_until_ms: int = 0

## 球心重力的刷新时间（毫秒）。用 constant_force 让物理服务器每步自动
## 施力，避免每个刚体都走 _integrate_forces 的 GDScript 回调——上千个
## 常醒物品时这是主要开销。
var _gravity_refresh_ms: int = 0


func _ready() -> void:
	# 关闭 Godot 默认的 uniform 重力，改用球心重力（constant_force）
	gravity_scale = 0.0
	# 物品永远参与物理模拟，不允许睡眠/被冻结
	can_sleep = false
	contact_monitor = true
	max_contacts_reported = 2


## 按当前位置刷新球心重力。方向随物品移动缓慢变化，250 ms 一次足够。
func _refresh_gravity() -> void:
	var origin: Vector3 = global_position
	if origin.length() < 1.0:
		return
	var sky: Vector3 = origin.normalized()
	var altitude: float = maxf(origin.length() - planet_radius, 0.0)
	var gravity: float = PhysicsConstants.get_gravity_at_altitude(altitude)
	constant_force = -sky * gravity * mass


## 沿 dir 方向从球外打射线，返回地形碰撞面的半径；没命中返回 -1。
## 试验台的台面不算「地表」——它只是让样品有地方站，不能拿它当地面高度。
func _probe_surface_radius(dir: Vector3) -> float:
	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space == null or planet_radius <= 0.0:
		return -1.0
	var query := PhysicsRayQueryParameters3D.create(
		dir * (planet_radius + 1000.0), dir * (planet_radius - 1000.0), 2)
	var hit: Dictionary = space.intersect_ray(query)
	if hit.is_empty():
		return -1.0
	var collider = hit.get("collider")
	if collider is Node and (collider as Node).name == "TestYardPad":
		return -1.0
	return (hit["position"] as Vector3).length()


## 滚动阻力：物理引擎的接触摩擦不产生滚动阻力，圆形状会一直滚。
## 按材料的 rolling_resistance 施加 Crr·N 的阻力与阻力矩。
func _apply_rolling_resistance(delta: float) -> void:
	if item == null or delta <= 0.0:
		return
	var mat: MaterialProperty = item.get_material()
	if mat == null:
		return
	var crr: float = clampf(mat.rolling_resistance, 0.0, 1.0)
	if crr <= 0.0:
		return
	var altitude: float = maxf(global_position.length() - planet_radius, 0.0)
	var gravity: float = PhysicsConstants.get_gravity_at_altitude(altitude)
	var resistance: float = crr * mass * gravity

	var speed: float = linear_velocity.length()
	if speed > 0.001:
		var force: float = minf(resistance, speed * mass / delta)
		apply_central_force(-linear_velocity.normalized() * force)

	if item.shape == "fiber" or item.shape == "sphere":
		var radius: float = maxf(_resting_height(), 0.005)
		var spin: float = angular_velocity.length()
		if spin > 0.001:
			var inertia: float = mass * radius * radius
			var torque: float = minf(resistance * radius, spin * inertia / delta)
			apply_torque(-angular_velocity.normalized() * torque)


## 物品中心在径向方向上离地表的静止高度（半厚/半径）。


func _resting_height() -> float:
	if item == null:
		return 0.1
	var dims: Dictionary = item.dimensions
	if item.shape == "fiber":
		return float(dims.get("diameter", 0.05)) * 0.5
	if item.shape == "sphere":
		return float(dims.get("radius", 0.2))
	return float(dims.get("height", 0.2)) * 0.5


func _physics_process(delta: float) -> void:
	if item != null:
		item.transform = global_transform

	# 球心重力用 constant_force 交给物理服务器，定期刷新方向即可
	if Time.get_ticks_msec() >= _gravity_refresh_ms:
		_refresh_gravity()
		_gravity_refresh_ms = Time.get_ticks_msec() + 250

	# 掉穿 / 埋入地形的回位判定。
	#
	# 不能用「比出生点低 25 m」当掉穿：在丘陵和悬崖上，物品顺着坡滑到
	# 低处是完全合法的物理结果。用它判定会把物品反复瞬移回原地，表现
	# 就是「抽搐一下、消失、又刷新回来」。
	#
	# 现在只在两种情况下回位：
	#   1. 真的埋进地形——先用便宜的地表采样粗判，再用物理射线实测确认；
	#   2. 掉到星球半径以下很深（绝对兜底）。
	var radius: float = global_position.length()
	var dir: Vector3 = global_position.normalized()
	var rough_surface: float = -1.0
	if ground_radius_sampler.is_valid() and radius > 1.0:
		rough_surface = float(ground_radius_sampler.call(global_position))

	# 硬性防穿模：贴近地表的物品，用物理射线确认中心是否已经低于地表。
	# 低于就立刻抬回地表上方，清掉向下的径向速度。这是最后一道保险，
	# 正常情况下 Jolt 的接触求解不应该让它触发。校正后短暂静默，
	# 避免和接触求解互相打架产生抖动。
	if rough_surface > 0.0 and radius < rough_surface + 0.10 \
			and Time.get_ticks_msec() >= _guard_until_ms \
			and (player_position == Vector3.ZERO
				or global_position.distance_to(player_position) < 80.0) \
			and (Engine.get_physics_frames() % 2 == 0
				or radius < rough_surface - 0.25):
		var exact_guard: float = _probe_surface_radius(dir)
		if exact_guard > 0.0 and radius < exact_guard - 0.03:
			var target: float = exact_guard + _resting_height() + 0.02
			global_position = dir * target
			var inward: float = linear_velocity.dot(dir)
			if inward < 0.0:
				linear_velocity -= dir * inward
			radius = target
			_guard_until_ms = Time.get_ticks_msec() + 250
			if item != null:
				item.transform = global_transform

	var underground := false
	if Time.get_ticks_msec() >= _recover_until_ms \
			and rough_surface > 0.0 and radius < rough_surface - 2.0:
		var exact: float = _probe_surface_radius(dir)
		underground = exact > 0.0 and radius < exact - 2.0
	var fell_out: bool = radius < planet_radius - 20.0
	if underground or fell_out:
		dir = global_position.normalized()
		if dir.length_squared() < 0.25:
			# 退化到球心时没有「当前方向」，只能回出生点方向
			dir = fallback_position.normalized()
		var place_radius: float = planet_radius
		if fallback_position != Vector3.ZERO:
			place_radius = fallback_position.length()
		# 落点用物理射线实测地表：采样网格和碰撞三角网不完全一致，
		# 按网格高度放回可能卡进地形或悬空。
		var surface_radius: float = _probe_surface_radius(dir)
		if surface_radius <= 0.0 and ground_radius_sampler.is_valid():
			surface_radius = float(ground_radius_sampler.call(dir))
		if surface_radius > 0.0:
			place_radius = surface_radius + 0.4
		global_position = dir * place_radius
		linear_velocity = Vector3.ZERO
		angular_velocity = Vector3.ZERO
		# 放在物理地表上方 0.4 m，交给物理自己落稳
		# 静默 2.5 秒：不要在同一处反复判定
		_recover_until_ms = Time.get_ticks_msec() + 2500
		if item != null:
			item.transform = global_transform
		return

	if item != null and get_contact_count() > 0:
		_apply_rolling_resistance(delta)

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
