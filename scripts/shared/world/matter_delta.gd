# ============================================================
# MatterDelta — 物质场的稀疏增量
# ============================================================
# 世界基底由 MatterField 纯函数给出；玩家造成的变化（挖走/堆积/倒伏）
# 只记录增量。这个类目前记录「堆积」：脱落粒子静止合并后，按质量、
# 组成、状态写到对应位置。
#
# 真值是增量列表，不是格子；读取时按距离聚合。
# ============================================================
class_name MatterDelta
extends RefCounted

## {position, composition, state, mass_kg, volume_m3}
var _deposits: Array = []

## 被挖走/推走的物质：{position, volume_m3, radius_m, composition, mass_kg}
var _removals: Array = []


func deposit(position: Vector3, composition: Array, state: Dictionary,
		mass_kg: float, volume_m3: float) -> void:
	if mass_kg <= 0.0 or composition.is_empty():
		return
	_deposits.append({
		"position": position,
		"composition": composition.duplicate(true),
		"state": state.duplicate(true),
		"mass_kg": mass_kg,
		"volume_m3": maxf(volume_m3, 0.0),
	})


func get_deposit_count() -> int:
	return _deposits.size()


func get_total_mass() -> float:
	var total: float = 0.0
	for deposit in _deposits:
		total += float(deposit["mass_kg"])
	return total


func get_total_volume() -> float:
	var total: float = 0.0
	for deposit in _deposits:
		total += float(deposit["volume_m3"])
	return total


func get_deposits() -> Array:
	return _deposits.duplicate(true)


## 记录一次移除（挖走/推走）。半径按半球体积 V=2/3πr³ 反推。
func remove_volume(position: Vector3, volume_m3: float,
		composition: Array = [], mass_kg: float = 0.0) -> void:
	if volume_m3 <= 0.0:
		return
	var radius: float = pow(3.0 * volume_m3 / (2.0 * PI), 1.0 / 3.0)
	_removals.append({
		"position": position,
		"volume_m3": volume_m3,
		"radius_m": radius,
		"composition": composition.duplicate(true),
		"mass_kg": mass_kg,
	})


func get_removal_count() -> int:
	return _removals.size()


func get_total_removed_volume() -> float:
	var total: float = 0.0
	for removal in _removals:
		total += float(removal["volume_m3"])
	return total


## 某点处被挖走造成的表面下陷（m，径向）。按半球坑：d=√(r²-dist²)。
func get_removal_depth_at(position: Vector3) -> float:
	var depth: float = 0.0
	for removal in _removals:
		var radius: float = float(removal["radius_m"])
		if radius <= 0.0:
			continue
		var distance: float = Vector3(removal["position"]).distance_to(position)
		if distance < radius:
			depth = maxf(depth, sqrt(maxf(radius * radius
				- distance * distance, 0.0)))
	return depth


## 地表净变化：堆积抬高 - 挖走下陷。
func get_surface_offset(position: Vector3) -> float:
	return get_height_at(position) - get_removal_depth_at(position)


## 某点处堆积物造成的地表抬升（m，径向）。
## 每个 deposit 按休止角堆成一个圆锥：V = πR³tanφ/3，h(d)=max(0,(R-d)tanφ)。
func get_height_at(position: Vector3) -> float:
	var height: float = 0.0
	for deposit in _deposits:
		var volume: float = float(deposit["volume_m3"])
		if volume <= 0.0:
			continue
		var state: Dictionary = deposit["state"]
		var repose: float = deg_to_rad(clampf(
			float(state.get("angle_of_repose_deg", 32.0)), 5.0, 60.0))
		var radius: float = pow(3.0 * volume / (PI * tan(repose)),
			1.0 / 3.0)
		var distance: float = Vector3(deposit["position"]).distance_to(position)
		if distance < radius:
			height += (radius - distance) * tan(repose)
	return height


## 某点附近堆积物的总质量（kg）。
func get_mass_near(position: Vector3, radius_m: float) -> float:
	var total: float = 0.0
	for deposit in _deposits:
		if Vector3(deposit["position"]).distance_to(position) <= radius_m:
			total += float(deposit["mass_kg"])
	return total


## 某点附近的堆积物组成（按质量加权，总和 = 1）；没有则返回空数组。
func get_composition_near(position: Vector3, radius_m: float) -> Array:
	var acc: Dictionary = {}
	var total_mass: float = 0.0
	for deposit in _deposits:
		if Vector3(deposit["position"]).distance_to(position) > radius_m:
			continue
		var mass: float = float(deposit["mass_kg"])
		for entry in deposit["composition"]:
			var id := String(entry["material_id"])
			acc[id] = float(acc.get(id, 0.0)) \
				+ float(entry["fraction"]) * mass
		total_mass += mass
	if total_mass <= 0.0:
		return []
	var out: Array = []
	for id in acc:
		out.append({"material_id": String(id),
			"fraction": float(acc[id]) / total_mass})
	out.sort_custom(func(a, b):
		return float(a["fraction"]) > float(b["fraction"]))
	return out
