# ============================================================
# test_particle_budget.gd — 活跃粒子预算与静止粒子合并
# ============================================================
# 运行：godot --headless --path . scenes/test_particle_budget.tscn
# 验证：
#   · 给定质量/密度/预算能反推出粒径，粒子数不超过预算
#   · 静止粒子能被移除并返回质量
#   · 移除前后总质量守恒
# ============================================================
extends Node

var _pass := 0
var _fail := 0


func _ready() -> void:
	var cls = ClassDB.instantiate("SoilDEMKernel")
	if cls == null:
		print("=== Results: 0/1 passed, 1 failed ===")
		print("  FAIL: SoilDEMKernel not registered (build the GDExtension first)")
		get_tree().quit(0)
		return

	var mass := 191.7
	var density := 1534.0
	var budget := 5000
	var radius := SoilParticleBudget.radius_for_budget(mass, density, budget)
	var expected := mass / (density * (4.0 / 3.0) * PI * pow(radius, 3.0))
	print("[Budget] mass=%.1f kg density=%.0f budget=%d → r=%.4f m, expect ~%.0f particles"
		% [mass, density, budget, radius, expected])
	_check(radius > 0.002, "radius is usable")
	_check(expected <= float(budget) * 1.05,
		"particle count fits budget (%.0f <= %d)" % [expected, budget])

	var small_radius := SoilParticleBudget.radius_for_budget(mass, density, 1000)
	_check(small_radius > radius, "smaller budget → larger particles")

	var center := Vector3(0.0, 0.0, 3978.87)
	var kernel = ClassDB.instantiate("SoilDEMKernel")
	kernel.setup_material(radius, density, 0.0, 0.5, 2500.0, 0.2)
	kernel.set_bounds(center - Vector3(1.0, 1.0, 1.0),
		center + Vector3(1.0, 1.0, 1.0))
	kernel.set_spherical_gravity(3978.87, 9.81)
	var spawned: int = kernel.spawn_from_mass(mass,
		center + Vector3(0.0, 0.0, 0.3), 0.08, 5)
	print("  spawned %d particles × %.4f kg"
		% [spawned, float(kernel.get_particle_mass())])
	_check(spawned <= budget, "spawned within budget (%d)" % spawned)
	var total_before := float(kernel.get_total_mass())
	_check(absf(total_before - mass) <= float(kernel.get_particle_mass()),
		"spawned mass matches target within one particle")

	# 初始速度为 0：全部应被判定为静止
	var consolidated := SoilParticleBudget.consolidate_slow(kernel, 0.05)
	_check(int(consolidated["count"]) == spawned,
		"all initially still particles consolidated")
	_check(absf(float(consolidated["mass_kg"]) - total_before) < 1.0e-6,
		"consolidated mass equals kernel mass")
	_check(kernel.get_particle_count() == 0,
		"kernel empty after consolidation")

	# 再生成一批，推进后只合并静止的那部分
	var spawned2: int = kernel.spawn_from_mass(10.0,
		center + Vector3(0.0, 0.0, 0.3), 0.08, 6)
	for i in range(30):
		kernel.step(1.0 / 240.0)
	var before2 := float(kernel.get_total_mass())
	var part := SoilParticleBudget.consolidate_slow(kernel, 0.05)
	var after2 := float(kernel.get_total_mass())
	_check(absf((after2 + float(part["mass_kg"])) - before2) < 1.0e-6,
		"mass conserved across partial consolidation")
	_check(int(part["count"]) <= spawned2,
		"consolidated count within spawned particles")
	var finite := true
	for p in kernel.get_positions():
		if not p.is_finite():
			finite = false
			break
	_check(finite, "remaining positions finite")

	_test_delta_writeback(radius, density, center)

	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _test_delta_writeback(radius: float, density: float,
		center: Vector3) -> void:
	print("[Delta writeback]")
	var kernel = ClassDB.instantiate("SoilDEMKernel")
	kernel.setup_material(radius, density, 0.0, 0.5, 2500.0, 0.2)
	kernel.set_bounds(center - Vector3(1.0, 1.0, 1.0),
		center + Vector3(1.0, 1.0, 1.0))
	kernel.set_spherical_gravity(3978.87, 9.81)
	var target_mass := 3.0
	var spawned: int = kernel.spawn_from_mass(target_mass,
		center + Vector3(0.0, 0.0, 0.3), 0.05, 9)
	var delta := MatterDelta.new()
	var composition := [
		{"material_id": "topsoil", "fraction": 0.6},
		{"material_id": "clay", "fraction": 0.4},
	]
	var state := {"density": density}
	var result := SoilParticleBudget.consolidate_slow(kernel, 0.05, delta,
		center + Vector3(0.0, 0.0, 0.3), composition, state)
	_check(int(result["count"]) == spawned, "all particles consolidated")
	_check(absf(delta.get_total_mass() - float(result["mass_kg"])) < 1.0e-6,
		"delta mass equals consolidated mass")
	_check(absf(delta.get_total_mass() - target_mass)
		<= float(kernel.get_particle_mass()), "delta mass matches target")
	var near := delta.get_composition_near(
		center + Vector3(0.0, 0.0, 0.3), 0.5)
	_check(not near.is_empty(), "deposit composition readable near position")
	if not near.is_empty():
		_check(absf(float(near[0]["fraction"]) - 0.6) < 0.01,
			"deposit composition preserved (topsoil 0.6)")


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: ", label)
	else:
		_fail += 1
		print("  FAIL: ", label)
