# ============================================================
# test_world.gd — 玩法系统集成测试
# ============================================================
extends Node

func _ready() -> void:
	if not MaterialDB.is_loaded:
		MaterialDB.load_from_file("res://scripts/shared/data/materials.json")
	if not ReactionRegistry.is_loaded:
		ReactionRegistry.load_from_file("res://scripts/shared/data/reactions.json")

	_test_world_generation()
	_test_climate()
	_test_ore_deposits()
	_test_tree_growth()
	_test_furnace_smelting()
	_test_forge_workflow()
	_test_construction()

	print("\n=== 玩法系统测试完成 ===")
	if OS.has_feature("headless"):
		get_tree().quit()

func _test_world_generation() -> void:
	print("\n[1] World Generation")
	var gen := WorldGenerator.new(42, 3978.87)
	gen.generate()
	print("  Generated: terrain=", gen.terrain != null, " soil=", gen.soil_grid != null)
	print("  Initial trees: ", gen.trees.size())

	# 查询几个位置
	var equator := gen.query_world(Vector3(gen.planet_radius, 0, 0))
	print("  Equator: elev=", equator["elevation"], " land=", equator["is_land"],
		" temp=", equator["temperature"], " ores=", equator["ores"].size())

	var pole := gen.query_world(Vector3(0, gen.planet_radius, 0))
	print("  North Pole: elev=", pole["elevation"], " land=", pole["is_land"],
		" temp=", pole["temperature"])

func _test_climate() -> void:
	print("\n[2] Climate & Seasons")
	var climate := Climate.new()
	climate.elapsed_days = 0
	print("  Day 0: season=", climate.get_season_name(), " temp@equator=", climate.get_temperature(0, 0))

	climate.elapsed_days = 4  # 夏至
	print("  Day 4: season=", climate.get_season_name(), " temp@equator=", climate.get_temperature(0, 0))

	climate.elapsed_days = 12  # 冬至
	print("  Day 12: season=", climate.get_season_name(), " temp@pole=", climate.get_temperature(80, 0))

	# 长冬
	climate.elapsed_days = 120
	print("  Day 120: is_eternal_winter=", climate.is_eternal_winter())

func _test_ore_deposits() -> void:
	print("\n[3] Ore Deposits")
	var terrain := Terrain.new(3978.87, 42)
	var ore_gen := OreVein.new(42)

	# 在随机陆地位置检查矿脉
	var found := {}
	for i in range(200):
		var dir := Vector3(randf()-0.5, randf()-0.5, randf()-0.5).normalized()
		var pos := dir * 3978.87
		if terrain.is_land(pos):
			var elev := terrain.get_elevation(pos)
			var ores := ore_gen.get_ore_deposits(pos, elev, terrain)
			for o in ores:
				var id: String = o["ore_id"]
				if not found.has(id):
					found[id] = 0
				found[id] += 1

	print("  Found ore types: ", found.keys())
	for k in found:
		print("    ", k, ": ", found[k], " deposits")

func _test_tree_growth() -> void:
	print("\n[4] Tree Growth")
	var tree := TreeGrowth.create_sapling("oak", 0)
	var soil := {"n": 0.8, "p": 0.5, "k": 0.6, "moisture": 0.7, "organic": 0.3, "ph": 6.5}

	print("  Day 0: biomass=", tree.biomass, " height=", tree.height, " dia=", tree.trunk_diameter)

	# 模拟 8 天生长（半个游戏年）
	var growth := tree.grow(8.0, soil, 0.8, 25.0)
	print("  Day 8: biomass=", tree.biomass, " height=", tree.height, " dia=", tree.trunk_diameter)

	# 再 8 天
	growth = tree.grow(16.0, soil, 0.8, 25.0)
	print("  Day 16: biomass=", tree.biomass, " height=", tree.height, " dia=", tree.trunk_diameter,
		" maturity=", tree.get_maturity())

	print("  Harvestable: ", tree.get_harvestable_mass(), " kg")

func _test_furnace_smelting() -> void:
	print("\n[5] Furnace Smelting")
	var furnace := Furnace.new()
	furnace.wall_material = "brick"
	furnace.internal_volume = 0.5

	# 装料
	furnace.add_material("iron_ore_hematite", 5.0)
	furnace.add_material("charcoal", 2.0)
	furnace.add_material("limestone", 1.0)
	print("  Loaded: ", furnace.get_contents_summary())

	# 点火
	furnace.ignite()
	furnace.set_bellows(2.0)  # 鼓风
	print("  Ignited, temp=", furnace.temperature, " atmo=", furnace.atmosphere)

	# 模拟 30 分钟冶炼（3600 ticks）
	for i in range(1800):
		var result := furnace.tick(1.0)
		if i % 300 == 0:
			print("  t=", i, "s temp=", furnace.temperature, " rxns=", result["reactions"].size(), " atmo=", furnace.atmosphere)

	print("  Final temp: ", furnace.temperature)
	print("  Contents: ", furnace.get_contents_summary())

	# 出铁
	var metal := furnace.tap_metal("pure_iron")
	var total_iron := 0.0
	for m in metal:
		total_iron += m["mass_kg"]
	print("  Iron tapped: ", total_iron, " kg")

func _test_forge_workflow() -> void:
	print("\n[6] Forge Workflow")
	var forge := Forge.new()
	forge.load_ingot("pure_iron", 2.0, 0.9)
	print("  Loaded: ", forge.state, " hardness=", forge.current_hardness)

	# 加热到锻造温度
	forge.heat_in_furnace(1200.0, 100.0)
	print("  Heated: ", forge.state, " temp=", forge.workpiece_temperature)

	# 锤击 ×5
	for i in range(5):
		var strike := forge.hammer_strike(2.0, 8.0, 0.001)
		if strike["success"]:
			print("  Strike ", i+1, ": hardness=", strike["hardness"],
				" toughness=", strike["toughness"], " progress=", strike["progress"])

	# 淬火
	if forge.state == "forging":
		forge.workpiece_temperature = 800.0
	var quench := forge.quench("water")
	print("  Quenched: ", quench["success"], " hardness=", quench["hardness"])

	# 回火
	var temper := forge.temper(250.0)
	print("  Tempered: hardness=", temper["hardness"], " toughness=", temper["toughness"])

	# 磨刃
	var whetstone := MaterialDB.get_material("flint")  # flint Mohs 7 > quenched iron
	if whetstone:
		var sharpen := forge.sharpen(whetstone, 60.0, 10.0)
		if sharpen["success"]:
			print("  Sharpened: tip_radius=", sharpen["tip_radius"])
		else:
			print("  Sharpen failed: ", sharpen.get("reason", ""))

	forge.finish()
	print("  Tool properties: ", forge.get_tool_properties())

func _test_construction() -> void:
	print("\n[7] Construction Validation")
	# 石斧 = 木棍 + 燧石刃 + 藤蔓绑扎
	var parts := [
		{"material_id": "oak_wood", "shape": "rod", "mass_kg": 0.5, "dimensions": {"length": 0.6, "width": 0.04, "height": 0.04}},
		{"material_id": "flint", "shape": "wedge", "mass_kg": 0.3, "dimensions": {"length": 0.15, "width": 0.08, "height": 0.02}},
	]
	var connections := [
		{"type": "binding", "part_a_idx": 0, "part_b_idx": 1, "binding_material": "vine", "wraps": 4, "tension": 200.0},
	]

	var result := ConstructionValidator.evaluate(parts, connections)
	print("  Valid: ", result["valid"])
	if result["valid"]:
		print("  Tool type: ", result["tool_type"])
		print("  Mass: ", result["total_mass"], " kg")
		print("  Hardness: ", result["max_hardness"])
		print("  Has sharp edge: ", result["has_sharp_edge"])
		print("  Tip radius: ", result["tip_radius"], " m")

	# 石锤 = 木棍 + 花岗岩块
	var parts2 := [
		{"material_id": "pine_wood", "shape": "rod", "mass_kg": 0.4, "dimensions": {"length": 0.5, "width": 0.04, "height": 0.04}},
		{"material_id": "granite", "shape": "block", "mass_kg": 2.0, "dimensions": {"length": 0.15, "width": 0.1, "height": 0.1}},
	]
	var result2 := ConstructionValidator.evaluate(parts2, connections)
	print("\n  Hammer test: valid=", result2["valid"], " type=", result2["tool_type"])
