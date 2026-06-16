# ============================================================
# test_reactions.gd — 化学反应系统单元测试
# ============================================================
# 运行: godot --headless --script tests/test_reactions.gd
# ============================================================
extends Node

const EPSILON := 0.01
var _passed := 0
var _failed := 0
var _total := 0

func _ready() -> void:
	if not MaterialDB.is_loaded:
		MaterialDB.load_from_file("res://scripts/shared/data/materials.json")
	if not ReactionRegistry.is_loaded:
		ReactionRegistry.load_from_file("res://scripts/shared/data/reactions.json")

	run_all_tests()

func assert_true(condition: bool, test_name: String) -> void:
	_total += 1
	if condition:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL: ", test_name)

func assert_eq(actual: float, expected: float, test_name: String, tolerance: float = EPSILON) -> void:
	_total += 1
	if abs(actual - expected) < tolerance:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL: ", test_name, " — expected=", expected, " actual=", actual)

func assert_gt(a: float, b: float, test_name: String) -> void:
	_total += 1
	if a > b:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL: ", test_name, " — expected ", a, " > ", b)

func assert_not_empty(dict_or_array, test_name: String) -> void:
	_total += 1
	if dict_or_array is Dictionary:
		if not dict_or_array.is_empty():
			_passed += 1
		else:
			_failed += 1
			printerr("  FAIL: ", test_name, " — empty dictionary")
	else:
		if dict_or_array.size() > 0:
			_passed += 1
		else:
			_failed += 1
			printerr("  FAIL: ", test_name, " — empty array")

func run_all_tests() -> void:
	print("=== Reaction System Tests ===\n")

	test_loading()
	test_combustion()
	test_smelting()
	test_thermal_decomposition()
	test_dissolution()
	test_fermentation()
	test_matching()
	test_mass_conservation()

	print("\n=== Results: ", _passed, "/", _total, " passed, ", _failed, " failed ===")
	if OS.has_feature("headless"):
		if _failed > 0:
			get_tree().quit(1)
		else:
			get_tree().quit(0)

func test_loading() -> void:
	print("[Loading]")
	assert_true(ReactionRegistry.is_loaded, "ReactionRegistry loaded")
	assert_gt(ReactionRegistry.get_all_reactions().size(), 10, ">10 reactions loaded")

	var smelt := ReactionRegistry.get_reaction("smelt_iron_hematite")
	assert_not_empty(smelt, "smelt_iron_hematite exists")
	assert_eq(smelt["temperature_min"], 1200.0, "smelt_iron temp_min=1200")

	var burn := ReactionRegistry.get_reaction("burn_wood")
	assert_not_empty(burn, "burn_wood exists")
	assert_true(burn.has("incomplete_combustion"), "burn_wood has incomplete combustion")

func test_combustion() -> void:
	print("[Combustion]")

	var burn := ReactionRegistry.get_reaction("burn_wood")
	var inputs := [{"material_id": "oak_wood", "mass_kg": 10.0}]

	# 完全燃烧
	var result := ReactionRegistry.evaluate_reaction(burn, inputs, 600.0, "oxygen", 3600.0, true)
	assert_true(result["mass_conservation_ok"], "burn wood mass conservation")
	assert_gt(result["heat_released_j"], 0.0, "burn wood produces heat")
	assert_gt(result["reaction_progress"], 0.0, "burn wood progresses at 600°C")

	# 温度不足 → 不反应
	var cold := ReactionRegistry.evaluate_reaction(burn, inputs, 200.0, "oxygen", 3600.0, true)
	assert_eq(cold["reaction_progress"], 0.0, "no burn at 200°C", 0.01)

	# 不完全燃烧（缺氧）
	var incomplete := ReactionRegistry.evaluate_reaction(burn, inputs, 600.0, "oxygen", 3600.0, false)
	assert_true(incomplete["incomplete_combustion"], "incomplete combustion when O₂ depleted")

	# 木炭燃烧产生更多热
	var charcoal := ReactionRegistry.get_reaction("burn_charcoal")
	var c_result := ReactionRegistry.evaluate_reaction(charcoal,
		[{"material_id": "charcoal", "mass_kg": 1.0}], 800.0, "oxygen", 3600.0, true)
	assert_gt(c_result["heat_released_j"] / 1e6, 25.0, "charcoal > 25MJ/kg")  # ~27MJ

func test_smelting() -> void:
	print("[Smelting]")

	var smelt := ReactionRegistry.get_reaction("smelt_iron_hematite")
	var inputs := [
		{"material_id": "iron_ore_hematite", "mass_kg": 5.5},
		{"material_id": "charcoal", "mass_kg": 2.0},
		{"material_id": "limestone", "mass_kg": 1.0}
	]

	var result := ReactionRegistry.evaluate_reaction(smelt, inputs, 1350.0, "reducing", 3600.0, true)
	assert_true(result["mass_conservation_ok"], "smelt iron mass conservation")

	# 检查是否产出了铁
	var has_iron := false
	for p in result["products"]:
		if p["material_id"] == "pure_iron" and p["mass_kg"] > 0.0:
			has_iron = true
			break
	assert_true(has_iron, "smelt produces iron")

	# 温度不足 → 不反应
	var cold := ReactionRegistry.evaluate_reaction(smelt, inputs, 800.0, "reducing", 3600.0, true)
	assert_eq(cold["reaction_progress"], 0.0, "no smelting at 800°C", 0.01)

	# 铜冶炼温度更低
	var cu := ReactionRegistry.get_reaction("smelt_copper_malachite")
	var cu_inputs := [{"material_id": "copper_ore_malachite", "mass_kg": 6.0},
					   {"material_id": "charcoal", "mass_kg": 1.5}]
	var cu_result := ReactionRegistry.evaluate_reaction(cu, cu_inputs, 1000.0, "reducing", 1200.0, true)
	var has_copper := false
	for p in cu_result["products"]:
		if p["material_id"] == "pure_copper" and p["mass_kg"] > 0.0:
			has_copper = true
			break
	assert_true(has_copper, "copper smelt at 1000°C")

func test_thermal_decomposition() -> void:
	print("[Thermal Decomposition]")

	# 烧石灰岩
	var calcine := ReactionRegistry.get_reaction("calcinate_limestone")
	var inputs := [{"material_id": "limestone", "mass_kg": 10.0}]
	var result := ReactionRegistry.evaluate_reaction(calcine, inputs, 1000.0, "any", 7200.0, true)
	assert_true(result["mass_conservation_ok"], "calcinate limestone mass conservation")

	var has_quicklime := false
	for p in result["products"]:
		if p["material_id"] == "quicklime" and p["mass_kg"] > 0.0:
			has_quicklime = true
			break
	assert_true(has_quicklime, "calcination produces quicklime")

	# 温度不足
	var cold := ReactionRegistry.evaluate_reaction(calcine, inputs, 500.0, "any", 7200.0, true)
	assert_eq(cold["reaction_progress"], 0.0, "no calcination at 500°C", 0.01)

	# 烧砖
	var brick := ReactionRegistry.get_reaction("fire_clay_to_brick")
	var b_result := ReactionRegistry.evaluate_reaction(brick,
		[{"material_id": "clay", "mass_kg": 5.0}], 1000.0, "any", 7200.0, true)
	var has_brick := false
	for p in b_result["products"]:
		if p["material_id"] == "brick" and p["mass_kg"] > 0.0:
			has_brick = true
			break
	assert_true(has_brick, "firing produces brick")

func test_dissolution() -> void:
	print("[Dissolution]")

	# 生石灰熟化
	var slake := ReactionRegistry.get_reaction("slake_lime")
	var inputs := [
		{"material_id": "quicklime", "mass_kg": 6.0},
		{"material_id": "water", "mass_kg": 4.0}
	]
	var result := ReactionRegistry.evaluate_reaction(slake, inputs, 25.0, "any", 600.0, true)
	assert_true(result["mass_conservation_ok"], "slake lime mass conservation")
	assert_gt(result["heat_released_j"], 0.0, "slake lime exothermic")

	var has_slaked := false
	for p in result["products"]:
		if p["material_id"] == "slaked_lime" and p["mass_kg"] > 0.0:
			has_slaked = true
			break
	assert_true(has_slaked, "slaking produces slaked_lime")

func test_fermentation() -> void:
	print("[Fermentation]")

	var ferment := ReactionRegistry.get_reaction("ferment_grain_to_alcohol")
	var inputs := [
		{"material_id": "wheat_grain", "mass_kg": 6.0},
		{"material_id": "water", "mass_kg": 4.0}
	]
	var result := ReactionRegistry.evaluate_reaction(ferment, inputs, 25.0, "anaerobic", 259200.0, true)
	assert_true(result["mass_conservation_ok"], "ferment mass conservation")

	# 温度过低不发酵
	var cold := ReactionRegistry.evaluate_reaction(ferment, inputs, 5.0, "anaerobic", 259200.0, true)
	assert_eq(cold["reaction_progress"], 0.0, "no fermentation at 5°C", 0.01)

func test_matching() -> void:
	print("[Matching]")

	# 高炉条件下的反应匹配
	var furnace_inputs := [
		{"material_id": "iron_ore_hematite", "mass_kg": 5.5},
		{"material_id": "charcoal", "mass_kg": 3.0},
		{"material_id": "limestone", "mass_kg": 1.0}
	]
	var matches := ReactionRegistry.find_possible_reactions(furnace_inputs, 1350.0, "reducing")
	assert_gt(matches.size(), 0, "finds smelting reactions at 1350°C reducing")

	# 应该匹配到铁冶炼
	var found_iron_smelt := false
	for m in matches:
		if m["reaction"]["id"] == "smelt_iron_hematite":
			found_iron_smelt = true
			assert_gt(m["match_quality"], 0.0, "smelt match quality > 0")
			break
	assert_true(found_iron_smelt, "matches smelt_iron_hematite")

	# 常温下不应匹配高温反应
	var cold_matches := ReactionRegistry.find_possible_reactions(furnace_inputs, 25.0, "oxygen")
	assert_eq(cold_matches.size(), 0, "no high-temp reactions at 25°C")

func test_mass_conservation() -> void:
	print("[Mass Conservation]")

	# 遍历所有反应，验证配方的质量守恒（理论值）
	var all_rxns := ReactionRegistry.get_all_reactions()
	var all_ok := true
	for rxn in all_rxns:
		# 检查 outputs 的 mass_ratio 之和是否 ≈ 1.0
		var total_out := 0.0
		for out in rxn.get("outputs", []):
			total_out += out.get("mass_ratio", 0.0)

		if abs(total_out - 1.0) > 0.02:
			all_ok = false
			printerr("  mass balance FAIL: ", rxn["id"], " outputs sum to ", total_out)

	assert_true(all_ok, "all reactions have mass ratio sum ≈ 1.0")
