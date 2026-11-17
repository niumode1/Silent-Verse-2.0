# ============================================================
# test_dem_cpp.gd — C++ GDExtension 里的 DEM 内核
# ============================================================
# 运行前需要先构建 gdextension（见 gdextension/CMakeLists.txt）。
# 验证：
#   · 原生内核能创建粒子并推进
#   · 质量守恒、状态差异、确定性
#   · 1000 / 5000 粒子的原生性能
# ============================================================
extends Node

const DT := 1.0 / 240.0
var _pass := 0
var _fail := 0


func _ready() -> void:
	var cls = ClassDB.instantiate("SoilDEMKernel")
	if cls == null:
		print("=== Results: 0/1 passed, 1 failed ===")
		print("  FAIL: SoilDEMKernel not registered (build the GDExtension first)")
		get_tree().quit(0)
		return

	print("[DEM-CPP] GDExtension loaded")
	_test_basic(cls)
	_test_determinism()
	_test_states()
	_test_spherical_gravity()
	_test_ground_plane()
	_test_threads()
	_benchmark(1000)
	_benchmark(5000)

	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _new_kernel(count: int, density: float, cohesion: float,
		friction: float, stiffness: float, damping: float, seed: int):
	var k = ClassDB.instantiate("SoilDEMKernel")
	k.set_bounds(Vector3(-0.15, 0.0, -0.15), Vector3(0.15, 0.2, 0.15))
	k.configure(count, 0.01, density, cohesion, friction, stiffness,
		damping, seed)
	return k


func _test_basic(cls) -> void:
	print("[Basic]")
	var k = _new_kernel(1000, 1600.0, 0.0, 0.5, 2500.0, 0.2, 42)
	_check(k.get_particle_count() == 1000, "particle count = 1000")
	_check(k.get_total_mass() > 1.0, "total mass positive")
	for i in range(120):
		k.step(DT)
	_check(k.get_step_count() == 120, "step count advanced")
	var positions: PackedVector3Array = k.get_positions()
	var finite := true
	for p in positions:
		if not p.is_finite():
			finite = false
			break
	_check(finite, "positions finite after 120 steps")


func _test_determinism() -> void:
	print("[Determinism]")
	var a = _new_kernel(1000, 1600.0, 0.0, 0.5, 2500.0, 0.2, 42)
	var b = _new_kernel(1000, 1600.0, 0.0, 0.5, 2500.0, 0.2, 42)
	for i in range(20):
		a.step(DT)
		b.step(DT)
	var same: bool = a.get_positions()[0].distance_to(b.get_positions()[0]) < 1e-6
	_check(same, "same seed + same state → same position")


func _test_states() -> void:
	print("[States]")
	var dry = _make_state("dry")
	var wet = _make_state("wet")
	var compact = _make_state("compact")
	var f_dry := _press_peak(dry)
	var f_wet := _press_peak(wet)
	var f_compact := _press_peak(compact)
	print("  tool force: dry=%.1f N wet=%.1f N compact=%.1f N"
		% [f_dry, f_wet, f_compact])
	_check(f_dry > 0.0 and f_wet > 0.0 and f_compact > 0.0,
		"tool feels all three states")
	_check(f_wet > f_dry * 1.1, "wet clay resists more than dry sand")
	_check(f_compact > f_dry * 1.1, "compacted soil resists more than dry")


func _test_spherical_gravity() -> void:
	print("[Spherical Gravity]")
	var k = ClassDB.instantiate("SoilDEMKernel")
	k.setup_material(0.01, 1600.0, 0.0, 0.5, 2500.0, 0.2)
	var surface := Vector3(0.0, 0.0, 3978.87)
	k.set_bounds(surface - Vector3(0.6, 0.6, 0.6),
		surface + Vector3(0.6, 0.6, 0.6))
	k.set_spherical_gravity(3978.87, 9.81)
	var spawned = k.spawn_from_mass(3.0, surface + Vector3(0.0, 0.0, 0.2),
		0.05, 11)
	_check(int(spawned) > 0, "particles spawned near surface")
	var before := _mean_radius(k)
	var mass_before := float(k.get_total_mass())
	for i in range(60):
		k.step(DT)
	var after := _mean_radius(k)
	var finite := true
	for p in k.get_positions():
		if not p.is_finite():
			finite = false
			break
	_check(finite, "positions finite under spherical gravity")
	_check(after < before - 0.02,
		"particles fall toward planet center (%.2f → %.2f m)"
		% [before, after])
	_check(absf(float(k.get_total_mass()) - mass_before) < 1e-6,
		"mass conserved under spherical gravity")


func _test_ground_plane() -> void:
	print("[Ground Plane]")
	var k = ClassDB.instantiate("SoilDEMKernel")
	k.setup_material(0.01, 1600.0, 0.0, 0.5, 2500.0, 0.2)
	k.set_bounds(Vector3(-1.0, -1.0, -1.0), Vector3(1.0, 2.0, 1.0))
	k.set_planar_gravity(9.81)
	k.set_ground_plane(Vector3.UP, 0.0)
	var spawned = k.spawn_from_mass(3.0, Vector3(0.0, 1.0, 0.0), 0.1, 13)
	var mass_before := float(k.get_total_mass())
	for i in range(120):
		k.step(DT)
	var below := 0
	var lowest := INF
	for p in k.get_positions():
		lowest = minf(lowest, p.y)
		if p.y < -0.02:
			below += 1
	_check(int(spawned) > 0, "particles spawned above ground")
	_check(below == 0, "no particle below the ground plane (lowest %.3f m)"
		% lowest)
	_check(absf(float(k.get_total_mass()) - mass_before) < 1e-6,
		"mass conserved on ground plane")


func _mean_radius(k) -> float:
	var positions: PackedVector3Array = k.get_positions()
	if positions.is_empty():
		return 0.0
	var total := 0.0
	for p in positions:
		total += p.length()
	return total / float(positions.size())


func _test_threads() -> void:
	print("[Threads]")
	for threads in [1, 4]:
		var k = _new_kernel(5000, 1600.0, 0.0, 0.5, 2500.0, 0.2, 42)
		k.set_threads(threads)
		var mass_before := float(k.get_total_mass())
		var start := Time.get_ticks_usec()
		for i in range(40):
			k.step(DT)
		var elapsed: float = float(Time.get_ticks_usec() - start) / 1.0e6
		var steps_per_s: float = 40.0 / maxf(elapsed, 1e-6)
		print("  threads=%d: 40 steps in %.3f s → %.0f steps/s"
			% [threads, elapsed, steps_per_s])
		_check(int(k.get_thread_count()) == threads,
			"thread count set to %d" % threads)
		_check(absf(float(k.get_total_mass()) - mass_before) < 1e-6,
			"mass conserved with %d threads" % threads)
		var finite := true
		for p in k.get_positions():
			if not p.is_finite():
				finite = false
				break
		_check(finite, "positions finite with %d threads" % threads)


func _make_state(kind: String):
	if kind == "wet":
		return _new_kernel(1000, 1900.0, 1500.0, 0.65, 6000.0, 0.35, 42)
	if kind == "compact":
		return _new_kernel(1000, 2100.0, 800.0, 0.70, 9000.0, 0.40, 42)
	return _new_kernel(1000, 1600.0, 0.0, 0.50, 2500.0, 0.20, 42)


func _press_peak(k) -> float:
	k.set_tool(0.25, 0.0)
	for i in range(60):
		k.step(DT)
	k.set_tool(0.151, 0.05)
	var peak := 0.0
	for i in range(120):
		k.step(DT)
		peak = maxf(peak, float(k.get_tool_force()))
	return peak


func _benchmark(count: int) -> void:
	print("[Benchmark %d]" % count)
	var k = _new_kernel(count, 1600.0, 0.0, 0.5, 2500.0, 0.2, 42)
	var start := Time.get_ticks_usec()
	for i in range(60):
		k.step(DT)
	var elapsed_us: int = Time.get_ticks_usec() - start
	var seconds: float = float(elapsed_us) / 1.0e6
	var steps_per_s: float = 60.0 / maxf(seconds, 1e-6)
	var updates_per_s: float = steps_per_s * float(count)
	print("  60 steps in %.3f s → %.0f steps/s, %.0f particle-updates/s"
		% [seconds, steps_per_s, updates_per_s])
	_check(steps_per_s > 0.0, "benchmark completed")


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: ", label)
	else:
		_fail += 1
		print("  FAIL: ", label)
