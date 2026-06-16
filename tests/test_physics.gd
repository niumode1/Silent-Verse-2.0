# ============================================================
# test_physics.gd — 物理公式单元测试套件
# ============================================================
# 运行: godot --headless --script tests/test_physics.gd
# 依赖: 所有 autoload（PhysicsConstants, MaterialDB）
# ============================================================
extends Node

const EPSILON := 0.001  # 浮点比较容差
var _passed := 0
var _failed := 0
var _total := 0

func _ready() -> void:
	# 确保材料数据库已加载
	if not MaterialDB.is_loaded:
		MaterialDB.load_from_file("res://scripts/shared/data/materials.json")

	run_all_tests()

func assert_eq(actual: float, expected: float, test_name: String, tolerance: float = EPSILON) -> void:
	_total += 1
	if abs(actual - expected) < tolerance:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL: ", test_name, " — expected=", expected, " actual=", actual)

func assert_true(condition: bool, test_name: String) -> void:
	_total += 1
	if condition:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL: ", test_name)

func assert_gt(a: float, b: float, test_name: String) -> void:
	_total += 1
	if a > b:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL: ", test_name, " — expected ", a, " > ", b)

func assert_lt(a: float, b: float, test_name: String) -> void:
	_total += 1
	if a < b:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL: ", test_name, " — expected ", a, " < ", b)

func run_all_tests() -> void:
	print("=== Physics Unit Tests ===\n")

	test_kinematics()
	test_energy_momentum()
	test_friction()
	test_simple_machines()
	test_material_mechanics()
	test_collision()
	test_rotation()
	test_fluid()
	test_thermal()
	test_tool_formulas()
	test_strike_damage()
	test_bite_damage()
	test_fall_damage()

	print("\n=== Results: ", _passed, "/", _total, " passed, ", _failed, " failed ===")
	if OS.has_feature("headless"):
		if _failed > 0:
			get_tree().quit(1)
		else:
			get_tree().quit(0)

# ============================================================
# 运动学
# ============================================================

func test_kinematics() -> void:
	print("[Kinematics]")

	# 自由落体: v = √(2gh)
	assert_eq(PhysicsCalc.free_fall_velocity(10.0), 14.007, "free_fall 10m")

	# 落体时间: t = √(2h/g)
	assert_eq(PhysicsCalc.free_fall_time(10.0), 1.428, "free_fall_time 10m")

	# 终端速度
	var v_term := PhysicsCalc.terminal_velocity(80.0, 1.2, 0.7)
	assert_eq(v_term, 39.056, "terminal_velocity 80kg human")

	# 斜抛最大射程 (45°, 真空)
	var range_45 := PhysicsCalc.projectile_range(20.0, deg_to_rad(45.0))
	assert_eq(range_45, 40.775, "projectile_range 20m/s @45°", 0.01)

	# 30° 射程应该小于 45°
	var range_30 := PhysicsCalc.projectile_range(20.0, deg_to_rad(30.0))
	assert_lt(range_30, range_45, "range 30° < 45°")

func test_energy_momentum() -> void:
	print("[Energy & Momentum]")

	var ek := PhysicsCalc.kinetic_energy(2.0, 10.0)
	assert_eq(ek, 100.0, "kinetic_energy 2kg @10m/s = 100J")

	var ep := PhysicsCalc.potential_energy(50.0, 5.0)
	assert_eq(ep, 2452.5, "potential_energy 50kg @5m")

	var p := PhysicsCalc.momentum(5.0, 3.0)
	assert_eq(p, 15.0, "momentum")

	var j := PhysicsCalc.impulse(100.0, 2.0)
	assert_eq(j, 200.0, "impulse 100N × 2s = 200 Ns")

	var f := PhysicsCalc.force_from_impulse(20.0, 0.01)
	assert_eq(f, 2000.0, "force_from_impulse 20Ns / 0.01s")

func test_friction() -> void:
	print("[Friction]")

	# 最大静摩擦
	var fs := PhysicsCalc.max_static_friction(500.0, 0.6)
	assert_eq(fs, 300.0, "max_static_friction 500N × 0.6")

	# 动摩擦
	var fk := PhysicsCalc.kinetic_friction_force(500.0, 0.4)
	assert_eq(fk, 200.0, "kinetic_friction 500N × 0.4")

	# 滚动阻力
	var frr := PhysicsCalc.rolling_resistance_force(500.0, 0.05)
	assert_eq(frr, 25.0, "rolling_resistance 500N × 0.05")

	# 斜面静止条件: tan θ ≤ μs
	assert_true(PhysicsCalc.slope_stable(deg_to_rad(20.0), 0.6), "20° slope μs=0.6 stable")
	assert_true(not PhysicsCalc.slope_stable(deg_to_rad(35.0), 0.6), "35° slope μs=0.6 unstable")

	# 斜面上推力: F = mg(sinθ + μk·cosθ)
	var push := PhysicsCalc.slope_push_force(50.0, deg_to_rad(20.0), 0.5)
	assert_eq(push, 398.22, "slope_push 50kg 20° μk=0.5", 0.01)

	# Capstan 方程
	var capstan := PhysicsCalc.capstan_max_load(100.0, 0.9, 3.0 * PhysicsConstants.TWO_PI)
	assert_gt(capstan, 1e6, "capstan_max_load 100N 3wraps μs=0.9 > 1MN")

	# Capstan 最小缠绕
	var wraps := PhysicsCalc.capstan_min_wraps(10000.0, 100.0, 0.9)
	assert_eq(wraps, 1, "capstan_min_wraps 10000/100 μs=0.9 = 1")

func test_simple_machines() -> void:
	print("[Simple Machines]")

	# 杠杆 MA
	assert_eq(PhysicsCalc.lever_ma(2.0, 0.2), 10.0, "lever_ma 2m/0.2m = 10")
	assert_eq(PhysicsCalc.lever_output_force(300.0, 2.0, 0.2), 3000.0, "lever_output 300N×10 = 3000N")

	# 滑轮组
	assert_eq(PhysicsCalc.pulley_pull_force(100.0, 4), 245.25, "pulley 100kg 4ropes")
	assert_eq(PhysicsCalc.pulley_pull_force(100.0, 6), 163.5, "pulley 100kg 6ropes")
	assert_lt(PhysicsCalc.pulley_pull_force(100.0, 6), PhysicsCalc.pulley_pull_force(100.0, 4),
			  "more ropes = less force")

	# 斜面 MA
	var ma := PhysicsCalc.inclined_plane_ma(deg_to_rad(20.0), 0.4)
	assert_gt(ma, 1.0, "inclined_plane MA > 1")

	# 楔子
	var wedge := PhysicsCalc.wedge_split_force(500.0, deg_to_rad(10.0), 0.3)
	assert_gt(wedge, 500.0, "wedge_split multiplies force")

	# 轮轴
	assert_eq(PhysicsCalc.wheel_axle_ma(0.3, 0.1), 3.0, "wheel_axle MA = 3")

func test_material_mechanics() -> void:
	print("[Material Mechanics]")

	assert_eq(PhysicsCalc.stress(1000.0, 0.01), 100000.0, "stress 1000N/0.01m²")
	assert_eq(PhysicsCalc.strain(0.002, 1.0), 0.002, "strain 2mm/1m = 0.002")
	assert_true(PhysicsCalc.can_scratch(7.0, 4.0), "hardness 7 scratches 4")
	assert_true(not PhysicsCalc.can_scratch(4.0, 7.0), "hardness 4 cannot scratch 7")
	assert_true(PhysicsCalc.is_yielding(300.0, 250.0), "stress 300 > yield 250")
	assert_true(not PhysicsCalc.is_yielding(200.0, 250.0), "stress 200 < yield 250")

	var tip_area := PhysicsCalc.tip_contact_area(0.001)
	assert_gt(tip_area, 3e-6, "tip_contact_area 1mm radius")
	assert_lt(PhysicsCalc.tip_contact_area(0.0001), tip_area, "smaller tip = smaller area")

func test_collision() -> void:
	print("[Collision]")

	# 弹性碰撞：m1=1 v1=10, m2=3 v2=0
	var v1_e := PhysicsCalc.elastic_collision_v1(1.0, 10.0, 3.0, 0.0)
	assert_eq(v1_e, -5.0, "elastic v1: 1kg→3kg, v1=-5")
	var v2_e := PhysicsCalc.elastic_collision_v2(1.0, 10.0, 3.0, 0.0)
	assert_eq(v2_e, 5.0, "elastic v2: 1kg→3kg, v2=5")

	# 完全非弹性
	var v_in := PhysicsCalc.perfectly_inelastic_velocity(1.0, 10.0, 3.0, 0.0)
	assert_eq(v_in, 2.5, "perfectly_inelastic: = 2.5")

func test_rotation() -> void:
	print("[Rotation]")

	var tau := PhysicsCalc.torque(100.0, 0.3, PI / 2.0)
	assert_eq(tau, 30.0, "torque 100N × 0.3m = 30")

	var i_rod := PhysicsCalc.moment_of_inertia_rod_end(2.0, 1.0)
	assert_eq(i_rod, 0.6667, "inertia rod end 2kg 1m", 0.001)

	var i_cyl := PhysicsCalc.moment_of_inertia_cylinder(3.0, 0.1)
	assert_eq(i_cyl, 0.015, "inertia cylinder 3kg 0.1m")

	assert_eq(PhysicsCalc.rotational_kinetic_energy(0.5, 4.0), 4.0, "rotational E_k")

	assert_eq(PhysicsCalc.angular_momentum(0.5, 4.0), 2.0, "angular_momentum")

func test_fluid() -> void:
	print("[Fluid]")

	var buoy := PhysicsCalc.buoyancy_force(1000.0, 0.212)
	assert_eq(buoy, 2079.72, "buoyancy 0.212m³ water")

	assert_true(PhysicsCalc.can_float(750.0, 1000.0), "wood floats")
	assert_true(not PhysicsCalc.can_float(7870.0, 1000.0), "iron sinks")

	# 水压 10m 深
	var press := PhysicsCalc.hydrostatic_pressure(1000.0, 10.0)
	assert_gt(press, PhysicsConstants.p0, "hydrostatic > atmospheric at 10m")

func test_thermal() -> void:
	print("[Thermal]")

	# 热传导
	var q := PhysicsCalc.heat_conduction_rate(1.0, 1.0, 1200.0, 20.0, 0.1)
	assert_eq(q, 11800.0, "heat_conduction 1m² clay wall Δ1180°C")

	# 熔化能
	var melt := PhysicsCalc.melting_energy(1.0, 247.0)
	assert_eq(melt, 247000.0, "melting 1kg iron = 247kJ")

	# 燃烧产热
	var burn := PhysicsCalc.combustion_heat(1.0, 30.0, 0.9)
	assert_eq(burn, 27e6, "burn 1kg charcoal = 27MJ @90%")

	# 温度变化
	var dT := PhysicsCalc.temperature_change(531000.0, 1.0, 450.0)
	assert_eq(dT, 1180.0, "heat 531kJ → 1kg iron +1180°C")

func test_tool_formulas() -> void:
	print("[Tool Formulas]")

	# 挥击动能
	var swing_ek := PhysicsCalc.swing_kinetic_energy(2.0, 10.0)
	assert_eq(swing_ek, 100.0, "swing_kinetic_energy")

	# 线速度
	var swing_v := PhysicsCalc.swing_linear_velocity(15.0, 0.8)
	assert_eq(swing_v, 12.0, "swing_linear_velocity 15rad/s × 0.8m")

	# 砍入深度（测试不崩溃，返回合理正值）
	var oak := MaterialDB.get_material("oak_wood")
	if oak:
		var depth := PhysicsCalc.chop_cut_depth(100.0, 0.005, oak.shear_strength, oak.youngs_modulus, 0.0)
		assert_gt(depth, 0.0, "chop_cut_depth positive")
		assert_lt(depth, 1.0, "chop_cut_depth < 1m per strike")  # 一次砍不了太深

	# 采矿判定
	var flint := MaterialDB.get_material("flint")
	var granite := MaterialDB.get_material("granite")
	if flint and granite:
		assert_true(PhysicsCalc.can_mine(flint.hardness_mohs, granite.hardness_mohs),
					"flint pick can mine granite")
		assert_true(not PhysicsCalc.can_mine(granite.hardness_mohs, flint.hardness_mohs),
					"granite pick cannot mine flint")
		var vol := PhysicsCalc.mine_volume_per_strike(2000.0, 1e-4, granite.compressive_strength,
													   granite.fracture_toughness)
		assert_gt(vol, 0.0, "mine_volume positive for strong pick")

	# 磨尖
	var sharpen_rate := PhysicsCalc.sharpen_wear_rate(1e-5, 10.0, 0.5, 550.0)
	assert_gt(sharpen_rate, 0.0, "sharpen_wear_rate positive")

func test_strike_damage() -> void:
	print("[Strike Damage]")

	var flint := MaterialDB.get_material("flint")
	var meat := MaterialDB.get_material("meat_raw")
	if not (flint and meat):
		return

	# 尖锐石斧 vs 肉体 → 穿透
	var result := PhysicsCalc.calculate_strike_damage(
		flint, 2.0, 15.0, 0.8, 0.002, meat, 1.0
	)
	assert_eq(result["damage_type"], "penetration", "sharp flint → penetration")
	assert_gt(result["base_damage"], 0.0, "strike damage positive")
	assert_gt(result["contact_pressure_mpa"], meat.yield_strength, "pressure exceeds flesh yield")

	# 钝木棍 vs 肉体 → 钝伤（尖端半径大）
	var oak := MaterialDB.get_material("oak_wood")
	if oak:
		var blunt := PhysicsCalc.calculate_strike_damage(
			oak, 1.5, 10.0, 0.5, 0.05, meat, 1.0
		)
		assert_eq(blunt["damage_type"], "blunt", "blunt stick → blunt damage")

func test_bite_damage() -> void:
	print("[Bite Damage]")

	var meat := MaterialDB.get_material("meat_raw")
	if not meat:
		return

	# 狼咬
	var wolf := AnimalBody.create_wolf()
	var wolf_bite := wolf.calculate_bite_damage(meat, 2.0)
	assert_eq(wolf_bite["damage_type"], "puncture", "wolf bite = puncture")
	assert_gt(wolf_bite["base_damage"], 0.0, "wolf bite damage positive")

	# 兔子咬
	var rabbit := AnimalBody.create_rabbit()
	var rabbit_bite := rabbit.calculate_bite_damage(meat, 1.0)
	assert_lt(rabbit_bite["base_damage"], wolf_bite["base_damage"], "rabbit bite < wolf bite")

func test_fall_damage() -> void:
	print("[Fall Damage]")

	var meat := MaterialDB.get_material("meat_raw")
	if not meat:
		return

	var result := PhysicsCalc.calculate_fall_damage(80.0, 5.0, 1.0, meat)
	assert_eq(result["damage_type"], "blunt", "fall 5m = blunt")
	assert_gt(result["base_damage"], 0.0, "fall damage positive")

	# 更高处坠落伤害更大
	var result_higher := PhysicsCalc.calculate_fall_damage(80.0, 20.0, 1.0, meat)
	assert_gt(result_higher["base_damage"], result["base_damage"], "higher fall = more damage")
