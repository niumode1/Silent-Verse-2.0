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
