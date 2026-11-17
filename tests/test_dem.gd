# ============================================================
# test_dem.gd — 土颗粒 DEM 小样
# ============================================================
# 运行：godot --headless --path . scenes/test_dem.tscn
# 验证：
#   · 粒子数量/总质量守恒
#   · 干砂、湿黏土、压实土在同一推板下反力不同
#   · 同种子同初始状态 → 同结果（确定性）
#   · 测量 GDScript 下的 DEM 粒子预算
# ============================================================
extends Node

const COUNT := 1000
const RADIUS := 0.01
const DT := 1.0 / 240.0

var _pass := 0
var _fail := 0


func _ready() -> void:
	print("[DEM] count=", COUNT, " radius=", RADIUS, " m")
	var dry := _make("dry")
	var wet := _make("wet")
	var compact := _make("compact")

	_test_initial(dry)
	_test_settle(dry)
	_test_determinism()
	_test_press(dry, wet, compact)
	_test_performance()

	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _make(kind: String) -> SoilDEM:
	var params := {
		"density": 1600.0,
		"cohesion_pa": 0.0,
		"friction": 0.50,
		"stiffness": 2500.0,
		"damping_ratio": 0.20,
		"rolling_resistance": 0.02,
	}
	if kind == "wet":
		params = {
			"density": 1900.0,
			"cohesion_pa": 1500.0,
			"friction": 0.65,
			"stiffness": 6000.0,
			"damping_ratio": 0.35,
			"rolling_resistance": 0.05,
		}
	elif kind == "compact":
		params = {
			"density": 2100.0,
			"cohesion_pa": 800.0,
			"friction": 0.70,
			"stiffness": 9000.0,
			"damping_ratio": 0.40,
			"rolling_resistance": 0.04,
		}
	return SoilDEM.create(COUNT, RADIUS, params, 42)


func _test_initial(dem: SoilDEM) -> void:
	print("[Initial]")
	_check(dem.positions.size() == COUNT, "particle count = %d" % COUNT)
	var mass := dem.total_mass()
	_check(mass > 0.0, "total mass > 0 (%.3f kg)" % mass)
	var finite := true
	for p in dem.positions:
		if not p.is_finite():
			finite = false
			break
	_check(finite, "all positions finite")


func _test_settle(dem: SoilDEM) -> void:
	print("[Settle]")
	var before := dem.total_mass()
	var e_before := dem.total_kinetic_energy()
	for i in range(120):
		dem.step(DT)
	var after := dem.total_mass()
	var e_after := dem.total_kinetic_energy()
	_check(absf(after - before) < 1.0e-6, "mass conserved while settling")
	_check(e_after < 5.0 and is_finite(e_after),
		"kinetic energy stays bounded (%.6f → %.6f)"
		% [e_before, e_after])
	var inside := true
	for p in dem.positions:
		if p.y < -0.01 or p.y > 0.30:
			inside = false
			break
	_check(inside, "particles stay in the box")


func _test_determinism() -> void:
	print("[Determinism]")
	var a := _make("dry")
	var b := _make("dry")
	for i in range(20):
		a.step(DT)
		b.step(DT)
	var same := a.positions[0].distance_to(b.positions[0]) < 1.0e-6
	_check(same, "same seed + same state → same particle position")


func _test_press(dry: SoilDEM, wet: SoilDEM,
		compact: SoilDEM) -> void:
	print("[Press]")
	var f_dry := _press_force(dry)
	var f_wet := _press_force(wet)
	var f_compact := _press_force(compact)
	print("  tool force: dry=%.1f N wet=%.1f N compact=%.1f N"
		% [f_dry, f_wet, f_compact])
	_check(f_dry > 0.0 and f_wet > 0.0 and f_compact > 0.0,
		"tool feels resistance from all three soils")
	_check(f_wet > f_dry * 1.1,
		"wet clay resists more than dry sand")
	_check(f_compact > f_dry * 1.1,
		"compacted soil resists more than dry sand")


func _press_force(dem: SoilDEM) -> float:
	# 沉降阶段把推板移开，避免把第一次接触耗在未计量的阶段
	dem.tool_x = 0.25
	for i in range(60):
		dem.step(DT)
	dem.tool_x = 0.151
	var peak := 0.0
	for i in range(120):
		dem.step(DT)
		peak = maxf(peak, dem.tool_force)
	return peak


func _test_performance() -> void:
	print("[Performance]")
	var dem := _make("dry")
	var start := Time.get_ticks_msec()
	for i in range(60):
		dem.step(DT)
	var elapsed: float = float(Time.get_ticks_msec() - start) / 1000.0
	var steps_per_s: float = 60.0 / maxf(elapsed, 0.001)
	var particles_per_s: float = steps_per_s * float(COUNT)
	print("  60 steps in %.2f s → %.1f steps/s, %.0f particle-updates/s"
		% [elapsed, steps_per_s, particles_per_s])
	_check(steps_per_s > 0.1, "solver is progressing")


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: ", label)
	else:
		_fail += 1
		print("  FAIL: ", label)
