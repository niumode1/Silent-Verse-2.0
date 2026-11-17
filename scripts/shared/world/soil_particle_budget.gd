# ============================================================
# SoilParticleBudget — 活跃粒子预算
# ============================================================
# 一次移除 0.125 m³ 表土会产生 2.7 万个 2 cm 粒子。真实游戏里必须给
# 活跃粒子设上限：超过预算时用更大的等效颗粒表示同样的质量，而不是
# 丢弃物质。
#
# 静止粒子（速度低于阈值）可以移除并合并回物质场；这个类提供：
#   · radius_for_budget：按质量/密度/预算反推粒径
#   · consolidate_slow：找出静止粒子、移除并返回它们的质量
# ============================================================
class_name SoilParticleBudget
extends RefCounted


## 在 max_particles 个粒子内表示 mass_kg 的物质，需要多大的粒径。
static func radius_for_budget(mass_kg: float, density: float,
		max_particles: int) -> float:
	if mass_kg <= 0.0 or density <= 0.0 or max_particles <= 0:
		return 0.005
	var volume: float = mass_kg / density
	var per_particle: float = volume / float(max_particles)
	return maxf(pow(3.0 * per_particle / (4.0 * PI), 1.0 / 3.0), 0.002)


## 移除速度低于阈值的粒子，返回 {count, mass_kg, particle_mass}。
static func consolidate_slow(kernel, speed_threshold: float = 0.05) -> Dictionary:
	if kernel == null:
		return {"count": 0, "mass_kg": 0.0, "particle_mass": 0.0}
	var velocities: PackedVector3Array = kernel.get_velocities()
	var indices := PackedInt32Array()
	for i in range(velocities.size()):
		if velocities[i].length() < speed_threshold:
			indices.append(i)
	var particle_mass: float = float(kernel.get_particle_mass())
	var mass: float = float(indices.size()) * particle_mass
	if indices.size() > 0:
		kernel.remove_particles(indices)
	return {
		"count": indices.size(),
		"mass_kg": mass,
		"particle_mass": particle_mass,
	}
