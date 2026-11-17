# ============================================================
# test_geology.gd — 地下矿脉与行星内部结构
# ============================================================
# 运行：godot --headless --path . scenes/test_geology.tscn
# 验证：
#   · 同种子 + 同位置 + 同深度 → 同矿脉（确定性）
#   · 每种矿都能在它的深度带内出现，且不会越界
#   · 浅层没有深层矿，深层没有浅层矿
#   · 地壳/地幔/外核/内核的组成总和为 1，层序正确
#   · 温度、压力随深度单调上升
# ============================================================
extends Node

var _pass := 0
var _fail := 0
var _terrain: Terrain
var _interior: PlanetInterior
var _ore: OreVein


func _ready() -> void:
	print("[Geology] 生成地形与内部结构……")
	_terrain = Terrain.new(3978.87, 42)
	_terrain.build()
	_interior = PlanetInterior.new(3978.87, _terrain)
	_ore = OreVein.new(42)

	_test_determinism()
	_test_ore_depth_bands()
	_test_depth_separation()
	_test_interior_layers()
	_test_interior_profiles()

	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


# ============================================================
# 测试
# ============================================================

func _test_determinism() -> void:
	print("[Determinism]")
	var other := OreVein.new(42)
	var rng := RandomNumberGenerator.new()
	rng.seed = 9001
	var same := true
	var found: Dictionary = {}
	for i in range(1200):
		var dir := _random_dir(rng)
		var depth: float = rng.randf_range(0.0, 1700.0)
		var pos := dir * (3978.87 - depth)
		var a := _ore.get_ore_deposits_at_depth(pos, depth, _terrain)
		var b := other.get_ore_deposits_at_depth(pos, depth, _terrain)
		if a != b:
			same = false
		for entry in a:
			var id := String(entry["ore_id"])
			found[id] = int(found.get(id, 0)) + 1

	_check(same, "same seed + position + depth = same veins")
	for def in _ore.get_ore_definitions():
		var id := String(def["id"])
		var count := int(found.get(id, 0))
		_check(count > 0, "%s appears somewhere (hit %d)" % [id, count])


func _test_ore_depth_bands() -> void:
	print("[Depth Bands]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var defs := _ore.get_ore_definitions()
	var bad := 0
	var checked := 0
	for i in range(1500):
		var depth: float = rng.randf_range(0.0, 1700.0)
		var pos := _random_dir(rng) * (3978.87 - depth)
		for entry in _ore.get_ore_deposits_at_depth(pos, depth, _terrain):
			checked += 1
			var id := String(entry["ore_id"])
			var def := _find_def(defs, id)
			if def.is_empty():
				bad += 1
				continue
			if depth + 0.001 < float(def["min_depth"]) \
					or depth - 0.001 > float(def["max_depth"]):
				bad += 1
	_check(checked > 0, "ore samples were produced (%d)" % checked)
	_check(bad == 0, "all ores stay inside their depth bands (%d bad)" % bad)


func _test_depth_separation() -> void:
	print("[Depth Separation]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 77
	var shallow_deep := 0
	var deep_shallow := 0
	for i in range(800):
		var dir := _random_dir(rng)
		var shallow := _ore.get_ore_deposits_at_depth(
			dir * (3978.87 - 10.0), 10.0, _terrain)
		for entry in shallow:
			var id := String(entry["ore_id"])
			if id == "gold_ore" or id == "iron_ore_hematite" \
					or id == "iron_ore_magnetite" or id == "tin_ore_cassiterite":
				shallow_deep += 1
		var deep := _ore.get_ore_deposits_at_depth(
			dir * (3978.87 - 1000.0), 1000.0, _terrain)
		for entry in deep:
			var id := String(entry["ore_id"])
			if id == "coal" or id == "flint":
				deep_shallow += 1
	_check(shallow_deep == 0, "no deep ores at 10 m (%d)" % shallow_deep)
	_check(deep_shallow == 0, "no shallow ores at 1000 m (%d)" % deep_shallow)


func _test_interior_layers() -> void:
	print("[Interior Layers]")
	var bounds := _interior.get_layer_boundaries()
	_check(float(bounds["crust_thickness_m"]) > 1000.0,
		"crust covers terrain relief (%.1f m)" % float(bounds["crust_thickness_m"]))
	_check(float(bounds["mantle_thickness_m"]) > 0.0, "mantle exists")
	_check(float(bounds["outer_core_thickness_m"]) > 0.0, "outer core exists")
	_check(float(bounds["inner_core_radius_m"]) > 0.0, "inner core exists")

	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var dir := _random_dir(rng)
	var radii := {
		"crust": 3978.87 - 10.0,
		"mantle": (float(bounds["crust_bottom_r"]) + float(bounds["mantle_bottom_r"])) * 0.5,
		"outer_core": (float(bounds["mantle_bottom_r"]) + float(bounds["outer_core_bottom_r"])) * 0.5,
		"inner_core": float(bounds["outer_core_bottom_r"]) * 0.5,
	}
	for expected in radii:
		var r: float = float(radii[expected])
		var state := _interior.get_state_at(dir * r)
		_check(String(state["layer"]) == expected,
			"layer at r=%.0f is %s" % [r, expected])
		var comp: Array = state["composition"]
		var total := 0.0
		for part in comp:
			total += float(part["fraction"])
		_check(absf(total - 1.0) < 0.001,
			"%s composition sums to 1 (%.4f)" % [expected, total])


func _test_interior_profiles() -> void:
	print("[Interior Profiles]")
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var dir := _random_dir(rng)
	var last_temp := -INF
	var last_pressure := -INF
	var monotonic := true
	for depth in [0.0, 100.0, 500.0, 1500.0, 2000.0, 3000.0, 3800.0]:
		var state := _interior.get_state_at(dir * (3978.87 - depth))
		var temp := float(state["temperature_c"])
		var pressure := float(state["pressure_pa"])
		if temp < last_temp - 0.001 or pressure < last_pressure - 0.001:
			monotonic = false
		last_temp = temp
		last_pressure = pressure
	_check(monotonic, "temperature and pressure increase with depth")
	var deep := _interior.get_state_at(dir * (3978.87 - 3800.0))
	_check(float(deep["temperature_c"]) > 4000.0,
		"inner core is hot (%.0f C)" % float(deep["temperature_c"]))
	_check(float(deep["pressure_pa"]) > 5.0e7,
		"inner core is under high pressure (%.0f Pa)"
		% float(deep["pressure_pa"]))


# ============================================================
# 辅助
# ============================================================

func _check(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: ", label)
	else:
		_fail += 1
		print("  FAIL: ", label)


func _random_dir(rng: RandomNumberGenerator) -> Vector3:
	var theta: float = rng.randf() * TAU
	var phi: float = acos(2.0 * rng.randf() - 1.0)
	return Vector3(sin(phi) * cos(theta), cos(phi),
		sin(phi) * sin(theta))


func _find_def(defs: Array, id: String) -> Dictionary:
	for def in defs:
		if String(def["id"]) == id:
			return def
	return {}
