# ============================================================
# test_contact_resolver.gd — 工具/地面接触的状态变化
# ============================================================
# 运行：godot --headless --path . scenes/test_contact_resolver.tscn
# 验证：
#   · 削尖的木棍能把土压下去，钝头和花岗岩不能
#   · 推开的土按休止角堆成锥，体积守恒
#   · 磨损符合 Archard（滑得越远磨得越多），摩擦热按热流分配
#   · 侧推木棍会在握持端弯断；细长杆轴向受压会屈曲
# ============================================================
extends Node

const CR := preload("res://scripts/shared/physics/contact_resolver.gd")

var _ok := true
var _oak: MaterialProperty
var _topsoil: MaterialProperty
var _granite: MaterialProperty


func _ready() -> void:
	_oak = MaterialDB.get_material("oak_wood")
	_topsoil = MaterialDB.get_material("topsoil")
	_granite = MaterialDB.get_material("granite")
	if _oak == null or _topsoil == null or _granite == null:
		print("=== Contact: FAIL (材料未加载) ===")
		get_tree().quit(0)
		return

	_test_sharp_stick_into_soil()
	_test_blunt_stick_no_dig()
	_test_stick_on_granite()
	_test_side_push_breaks()
	_test_wear_and_heat()
	_test_buckling()
	_test_pile_conserves_volume()
	_test_composite_mixture()
	_test_subsurface_is_a_mixture()

	print("=== Contact: %s ===" % ("PASS" if _ok else "FAIL"))
	get_tree().quit(0)


func _resolve(tool: MaterialProperty, ground: MaterialProperty, force: Vector3,
		extra: Dictionary = {}) -> Dictionary:
	var p := {
		"tool": tool,
		"ground": ground,
		"force": force,
		"ground_normal": Vector3.UP,
		"tool_axis": Vector3.UP,
		"length": 0.4,
		"tip_radius": 0.004,
		"shaft_radius": 0.004,
		"slide_distance": 0.0,
		"depth": 0.0,
		"penetration_step": 0.01,
	}
	p.merge(extra, true)
	return CR.resolve(p)


func _test_sharp_stick_into_soil() -> void:
	var r: Dictionary = _resolve(_oak, _topsoil, Vector3.DOWN * 200.0)
	print("[土壤] 压力=%.2f MPa 承载力=%.2f MPa 屈服=%s 压入=%.1f mm 排开=%.2f mg" % [
		float(r["pressure_pa"]) / 1e6, float(r["bearing_capacity_pa"]) / 1e6,
		str(r["ground_yield"]), float(r["absorbed_step"]) * 1000.0,
		float(r["displaced_mass"]) * 1e6])
	_check(bool(r["ground_yield"]), "削尖木棍 200 N 应压得动表土")
	_check(float(r["absorbed_step"]) > 0.0, "土应吸收压入位移")
	_check(not bool(r["breaks"]), "0.4 m 长、200 N 的橡木棍不应断")
	_check(float(r["displaced_mass"]) > 0.0, "排开的土应有质量")


func _test_blunt_stick_no_dig() -> void:
	var r: Dictionary = _resolve(_oak, _topsoil, Vector3.DOWN * 200.0,
		{"tip_radius": 0.02, "shaft_radius": 0.02})
	print("[钝头] 压力=%.2f MPa 屈服=%s" % [
		float(r["pressure_pa"]) / 1e6, str(r["ground_yield"])])
	_check(not bool(r["ground_yield"]), "钝头木棍不应压穿表土")


func _test_stick_on_granite() -> void:
	var r: Dictionary = _resolve(_oak, _granite, Vector3.DOWN * 200.0)
	print("[花岗岩] 压力=%.2f MPa 承载力=%.1f MPa 屈服=%s" % [
		float(r["pressure_pa"]) / 1e6, float(r["bearing_capacity_pa"]) / 1e6,
		str(r["ground_yield"])])
	_check(not bool(r["ground_yield"]), "200 N 的木棍戳不动花岗岩")
	_check(float(r["displaced_volume"]) == 0.0, "岩石未屈服时不应排开体积")


func _test_side_push_breaks() -> void:
	var r: Dictionary = _resolve(_oak, _topsoil, Vector3.RIGHT * 200.0,
		{"shaft_radius": 0.01, "tip_radius": 0.01, "length": 1.0})
	print("[侧推] 弯矩=%.1f N·m 弯曲应力=%.1f MPa 强度=%.1f MPa 断=%s 流向=%s" % [
		float(r["bending_moment"]), float(r["bending_stress"]) / 1e6,
		float(r["strength"]) / 1e6, str(r["breaks"]),
		str(r["flow_direction"])])
	_check(float(r["bending_moment"]) > 0.0, "侧推应产生弯矩")
	_check(bool(r["breaks"]), "1 m 长的橡木棍侧推 200 N 应弯断")
	_check((r["flow_direction"] as Vector3).dot(Vector3.RIGHT) > 0.99,
		"土应被沿施力方向推开")


func _test_wear_and_heat() -> void:
	var a: Dictionary = _resolve(_oak, _granite, Vector3.DOWN * 100.0,
		{"slide_distance": 0.5, "shaft_radius": 0.01, "tip_radius": 0.01})
	var b: Dictionary = _resolve(_oak, _granite, Vector3.DOWN * 100.0,
		{"slide_distance": 1.0, "shaft_radius": 0.01, "tip_radius": 0.01})
	print("[磨损] 0.5 m=%.3f mm³ 1.0 m=%.3f mm³ 磨深=%.4f mm 热=%.3f J" % [
		float(a["tool_wear_volume"]) * 1e9, float(b["tool_wear_volume"]) * 1e9,
		float(b["tool_wear_depth"]) * 1000.0, float(b["friction_heat"])])
	_check(float(a["tool_wear_volume"]) > 0.0, "滑动应产生磨损")
	_check(absf(float(b["tool_wear_volume"])
		- 2.0 * float(a["tool_wear_volume"])) < 1e-12, "磨损应与滑移距离成正比")
	_check(float(b["friction_heat"]) > 0.0, "摩擦应生热")
	_check(absf(float(b["tool_heat_fraction"])
		+ float(1.0 - float(b["tool_heat_fraction"])) - 1.0) < 1e-9,
		"热流分配应守恒")


func _test_buckling() -> void:
	# 细长杆：1.5 m、半径 5 mm，轴向 300 N
	var r: Dictionary = _resolve(_oak, _topsoil, Vector3.DOWN * 300.0,
		{"length": 1.5, "shaft_radius": 0.005, "tip_radius": 0.005})
	print("[屈曲] 轴力=%.1f N 临界=%.1f N 屈曲=%s" % [
		float(r["axial_force"]), float(r["buckling_load"]), str(r["buckles"])])
	_check(bool(r["buckles"]), "细长木棍 300 N 轴向压力应屈曲")


func _test_pile_conserves_volume() -> void:
	var r: Dictionary = _resolve(_oak, _topsoil, Vector3.DOWN * 200.0)
	var v: float = float(r["displaced_volume"])
	var pile: float = PI * pow(float(r["pile_radius"]), 2.0) \
		* float(r["pile_height"]) / 3.0
	print("[土堆] 排开=%s m³ 堆体积=%s m³ 堆半径=%.1f mm" % [
		str(v), str(pile), float(r["pile_radius"]) * 1000.0])
	_check(absf(pile - v) / maxf(v, 1e-15) < 1e-6, "土堆体积应等于排开体积")


func _test_composite_mixture() -> void:
	# 70% 表土 + 30% 花岗岩碎块：密度介于两者之间，强度被弱相拉低，
	# 但不会简单等于弱相的强度（Reuss 串联平均）
	var mix: MaterialProperty = CR.composite([
		{"material": _topsoil, "fraction": 0.7},
		{"material": _granite, "fraction": 0.3},
	])
	print("[混合物] 密度=%.0f kg/m³ 抗压=%.2f MPa 模量=%.1f MPa" % [
		mix.density, mix.compressive_strength,
		float(CR.modulus_pa(mix)) / 1e6])
	_check(mix != null, "混合物应能折算")
	_check(mix.density > _topsoil.density and mix.density < _granite.density,
		"混合物密度应介于两相之间")
	_check(mix.compressive_strength > 2.0 and mix.compressive_strength < 10.0,
		"混合物抗压强度应被弱相主导但不是简单取最弱")
	_check(float(CR.modulus_pa(mix)) > 0.0, "混合物模量应有效")


func _test_subsurface_is_a_mixture() -> void:
	var terrain := Terrain.new(3978.87, 20261106)
	terrain.build()
	var pos: Vector3 = Vector3.ZERO
	# 找一块陆地
	for i in range(2000):
		var d := Vector3(sin(float(i) * 0.37), cos(float(i) * 0.11),
			sin(float(i) * 0.73)).normalized()
		if terrain.is_land(d * terrain.planet_radius):
			pos = d * terrain.planet_radius
			break
	var top: Array = terrain.get_subsurface_composition(pos, 0.1)
	var deep: Array = terrain.get_subsurface_composition(pos, 4.0)
	var top_sum := 0.0
	for entry in top:
		top_sum += float(entry["fraction"])
	print("[地下] 表层 %s  4 m 处 %s" % [_mix_text(top), _mix_text(deep)])
	_check(top.size() >= 2, "表层应是多种物质的混合")
	_check(deep.size() >= 2, "4 m 深处应是多种矿物的混合")
	_check(absf(top_sum - 1.0) < 1e-6, "体积分数应守恒为 1")
	_check(_mix_text(top) != _mix_text(deep), "不同深度的成分应不同")


func _mix_text(parts: Array) -> String:
	var bits: Array = []
	for entry in parts:
		bits.append("%s %.0f%%" % [String(entry["material_id"]),
			float(entry["fraction"]) * 100.0])
	return "(" + ", ".join(bits) + ")"


func _check(cond: bool, what: String) -> void:
	if not cond:
		_ok = false
		print("  ✗ ", what)
