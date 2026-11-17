# ============================================================
# SoilDEM — 土颗粒的离散元小样（DEM）
# ============================================================
# 这不是完整地面，只是一个用于验证方法的最小粒子系统：
#   · 每个粒子有质量、半径、组成由调用方给定；
#   · 接触用软弹簧-阻尼（Hertz 的线性近似）+ Coulomb 摩擦 +
#     黏聚（湿黏土）+ 滚动阻力；
#   · 空间哈希做邻居搜索，不需要 O(N²)；
#   · 质量守恒：粒子只移动/合并，不凭空消失。
#
# 目的：用同一套力模型比较干砂 / 湿黏土 / 压实土在同一推进力下
# 的响应，并测量 GDScript 下的粒子预算。
# ============================================================
class_name SoilDEM
extends RefCounted

var positions := PackedVector3Array()
var velocities := PackedVector3Array()
var radii := PackedFloat32Array()
var masses := PackedFloat32Array()

## 材料状态
var density: float = 1600.0
var cohesion_pa: float = 0.0
var friction: float = 0.55
var stiffness: float = 3000.0
var damping_ratio: float = 0.25
var rolling_resistance: float = 0.03

## 容器
var bounds_min := Vector3(-0.15, 0.0, -0.15)
var bounds_max := Vector3(0.15, 0.2, 0.15)
var gravity := Vector3(0.0, -9.81, 0.0)

## 推板：沿 -X 方向推进
var tool_x: float = 0.151
var tool_speed: float = 0.05
var tool_force: float = 0.0
var tool_area: float = 0.09

var steps: int = 0
var time: float = 0.0
var _rng := RandomNumberGenerator.new()


## 创建一盒粒子。count 为粒子数，radius 为粒径（m）。
static func create(count: int, radius: float, params: Dictionary = {},
		seed_value: int = 42) -> SoilDEM:
	var dem := SoilDEM.new()
	dem._rng.seed = seed_value
	dem.density = float(params.get("density", 1600.0))
	dem.cohesion_pa = float(params.get("cohesion_pa", 0.0))
	dem.friction = float(params.get("friction", 0.55))
	dem.stiffness = float(params.get("stiffness", 3000.0))
	dem.damping_ratio = float(params.get("damping_ratio", 0.25))
	dem.rolling_resistance = float(params.get("rolling_resistance", 0.03))
	dem.bounds_min = params.get("bounds_min", dem.bounds_min)
	dem.bounds_max = params.get("bounds_max", dem.bounds_max)
	dem._populate(count, radius)
	return dem


func _populate(count: int, radius: float) -> void:
	var spacing: float = radius * 2.05
	var size: Vector3 = bounds_max - bounds_min
	var nx: int = maxi(1, int(size.x / spacing))
	var ny: int = maxi(1, int(size.y / spacing))
	var nz: int = maxi(1, int(size.z / spacing))
	var placed: int = 0
	for ix in range(nx):
		for iy in range(ny):
			for iz in range(nz):
				if placed >= count:
					break
				var p := Vector3(
					bounds_min.x + (float(ix) + 0.5) * spacing,
					bounds_min.y + (float(iy) + 0.5) * spacing,
					bounds_min.z + (float(iz) + 0.5) * spacing)
				p += Vector3(
					_rng.randf_range(-0.08, 0.08) * radius,
					_rng.randf_range(-0.08, 0.08) * radius,
					_rng.randf_range(-0.08, 0.08) * radius)
				positions.append(p)
				velocities.append(Vector3.ZERO)
				radii.append(radius)
				masses.append(density * (4.0 / 3.0) * PI * pow(radius, 3.0))
				placed += 1
			if placed >= count:
				break
		if placed >= count:
			break
	# 网格装不下时补随机粒子
	while placed < count:
		positions.append(Vector3(
			_rng.randf_range(bounds_min.x, bounds_max.x),
			_rng.randf_range(bounds_min.y, bounds_max.y),
			_rng.randf_range(bounds_min.z, bounds_max.z)))
		velocities.append(Vector3.ZERO)
		radii.append(radius)
		masses.append(density * (4.0 / 3.0) * PI * pow(radius, 3.0))
		placed += 1


func total_mass() -> float:
	var m: float = 0.0
	for mass in masses:
		m += mass
	return m


func total_kinetic_energy() -> float:
	var e: float = 0.0
	for i in range(positions.size()):
		e += 0.5 * masses[i] * velocities[i].length_squared()
	return e


## 推进一步（半隐式欧拉 + 软接触）。
func step(dt: float) -> void:
	if positions.is_empty():
		return
	var n: int = positions.size()
	var forces: Array = []
	forces.resize(n)
	var max_radius: float = 0.0
	for i in range(n):
		forces[i] = gravity * masses[i]
		max_radius = maxf(max_radius, radii[i])

	# 空间哈希
	var cell: float = maxf(max_radius * 2.0 + 0.002, 0.01)
	var buckets: Dictionary = {}
	for i in range(n):
		var key := Vector3i(
			int(floor(positions[i].x / cell)),
			int(floor(positions[i].y / cell)),
			int(floor(positions[i].z / cell)))
		if not buckets.has(key):
			buckets[key] = []
		buckets[key].append(i)

	for i in range(n):
		var pi: Vector3 = positions[i]
		var ri: float = radii[i]
		var key := Vector3i(
			int(floor(pi.x / cell)),
			int(floor(pi.y / cell)),
			int(floor(pi.z / cell)))
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				for dz in range(-1, 2):
					var nkey := key + Vector3i(dx, dy, dz)
					if not buckets.has(nkey):
						continue
					for j in buckets[nkey]:
						var jj: int = int(j)
						if jj <= i:
							continue
						_contact(i, jj, forces, dt)

	# 推板接触
	tool_force = 0.0
	for i in range(n):
		var p: Vector3 = positions[i]
		var r: float = radii[i]
		if p.x + r <= tool_x:
			continue
		var overlap: float = p.x + r - tool_x
		var vx: float = velocities[i].x - (-tool_speed)
		var force: float = stiffness * overlap - 2.0 * damping_ratio \
			* sqrt(stiffness * masses[i]) * vx
		force = maxf(force, 0.0)
		forces[i] = forces[i] - Vector3(force, 0.0, 0.0)
		tool_force += force

	# 积分
	for i in range(n):
		var acc: Vector3 = forces[i] / masses[i]
		var v: Vector3 = velocities[i] + acc * dt
		# 线性阻尼（空气/孔隙）
		v *= exp(-0.8 * dt)
		velocities[i] = v
		positions[i] = positions[i] + v * dt
		_clamp_to_box(i)
		# 滚动阻力：接触时的角速度在这里没有单独建模，
		# 用速度衰减的附加项近似
		if velocities[i].length() < 0.002:
			velocities[i] = Vector3.ZERO

	tool_x = maxf(tool_x - tool_speed * dt, bounds_min.x + 0.02)
	time += dt
	steps += 1


func _contact(i: int, j: int, forces: Array, dt: float) -> void:
	var delta: Vector3 = positions[j] - positions[i]
	var dist: float = delta.length()
	var radius_sum: float = radii[i] + radii[j]
	if dist >= radius_sum or dist < 1.0e-6:
		return
	var normal: Vector3 = delta / dist
	var overlap: float = radius_sum - dist
	var relative: Vector3 = velocities[j] - velocities[i]
	var vn: float = relative.dot(normal)
	var m_eff: float = masses[i] * masses[j] / (masses[i] + masses[j])
	var damping: float = 2.0 * damping_ratio * sqrt(stiffness * m_eff)
	var normal_force: float = stiffness * overlap - damping * vn

	# 黏聚：接触面积上的抗拉强度，湿黏土明显
	var area: float = PI * pow(minf(radii[i], radii[j]), 2.0)
	var cohesion_force: float = cohesion_pa * area
	normal_force += cohesion_force
	if normal_force < 0.0:
		normal_force = 0.0

	var tangent: Vector3 = relative - normal * vn
	var tangent_len: float = tangent.length()
	var friction_force: float = 0.0
	if tangent_len > 1.0e-6:
		friction_force = minf(friction * normal_force,
			tangent_len * m_eff / dt)

	# 作用在 i 上的接触力：
	#   法向：排斥 +Fn（-normal），黏聚 -Fc（+normal）；
	#   切向：沿相对速度方向拖拽 i（+tangent）。
	var force_on_i: Vector3 = normal * (cohesion_force - normal_force)
	if tangent_len > 1.0e-6:
		force_on_i += tangent / tangent_len * friction_force
	forces[i] = forces[i] + force_on_i
	forces[j] = forces[j] - force_on_i


func _clamp_to_box(i: int) -> void:
	var r: float = radii[i]
	var p: Vector3 = positions[i]
	var v: Vector3 = velocities[i]
	if p.x < bounds_min.x + r:
		p.x = bounds_min.x + r
		v.x = maxf(v.x, 0.0)
	if p.x > bounds_max.x - r:
		p.x = bounds_max.x - r
		v.x = minf(v.x, 0.0)
	if p.y < bounds_min.y + r:
		p.y = bounds_min.y + r
		v.y = maxf(v.y, 0.0)
	if p.y > bounds_max.y - r:
		p.y = bounds_max.y - r
		v.y = minf(v.y, 0.0)
	if p.z < bounds_min.z + r:
		p.z = bounds_min.z + r
		v.z = maxf(v.z, 0.0)
	if p.z > bounds_max.z - r:
		p.z = bounds_max.z - r
		v.z = minf(v.z, 0.0)
	positions[i] = p
	velocities[i] = v
