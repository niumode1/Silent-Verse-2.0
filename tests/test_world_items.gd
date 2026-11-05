# ============================================================
# test_world_items.gd — 世界生成产出的物品实体测试
# ============================================================
# 运行：godot --headless --path . scenes/test_world_items.tscn
# 依赖：MaterialDB autoload
# ============================================================
extends Node

var _passed := 0
var _failed := 0
var _total := 0

func _ready() -> void:
	if not MaterialDB.is_loaded:
		MaterialDB.load_from_file("res://scripts/shared/data/materials.json")

	run_all_tests()

	print("\n=== Results: ", _passed, "/", _total, " passed, ", _failed, " failed ===")
	if OS.has_feature("headless"):
		if _failed > 0:
			get_tree().quit(1)
		else:
			get_tree().quit(0)

func assert_true(condition: bool, test_name: String) -> void:
	_total += 1
	if condition:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL: ", test_name)

func assert_eq(actual: float, expected: float, test_name: String, tolerance: float = 1e-6) -> void:
	_total += 1
	if absf(actual - expected) <= tolerance:
		_passed += 1
	else:
		_failed += 1
		printerr("  FAIL: ", test_name, " — expected=", expected, " actual=", actual)

# ============================================================
# 测试入口
# ============================================================

func run_all_tests() -> void:
	print("=== World Item Spawner Tests ===\n")
	var world := _make_world()
	var items := WorldItemSpawner.generate(world)

	test_count(items)
	test_unique_ids(items)
	test_item_validity(items)
	test_placement_above_sea_level(world, items)
	test_type_coverage(items)
	test_log_orientation(world, items)
	test_determinism()
	test_registry_integration(items)

# ============================================================
# 测试
# ============================================================

func _make_world() -> WorldGenerator:
	var world := WorldGenerator.new(WorldGenerator.DEFAULT_SEED, WorldGenerator.DEFAULT_PLANET_RADIUS)
	world.max_elevation = WorldGenerator.DEFAULT_MAX_ELEVATION
	world.generate()
	return world

func test_count(items: Array) -> void:
	print("[Count]")
	assert_true(items.size() > 100, "spawns more than 100 world items")
	assert_true(items.size() < 5000, "spawn count stays bounded")

func test_unique_ids(items: Array) -> void:
	print("[Unique IDs]")
	var seen: Dictionary = {}
	var all_unique := true
	var all_positive := true
	for item in items:
		if item.item_id <= 0:
			all_positive = false
		if seen.has(item.item_id):
			all_unique = false
			printerr("  duplicate id: ", item.item_id)
		seen[item.item_id] = true
	assert_true(all_positive, "all items have positive ids")
	assert_true(all_unique, "all item ids are unique")

func test_item_validity(items: Array) -> void:
	print("[Item Validity]")
	var all_valid := true
	var all_world := true
	for item in items:
		if not item.validate()["valid"]:
			all_valid = false
			printerr("  invalid item ", item.item_id, ": ", item.validate()["errors"])
		if not item.is_in_world():
			all_world = false
		if item.get_volume_m3() <= 0.0 or item.get_mass_kg() <= 0.0:
			all_valid = false
	assert_true(all_valid, "all items have valid material / volume / mass")
	assert_true(all_world, "all spawned items start in the world")

func test_placement_above_sea_level(world: WorldGenerator, items: Array) -> void:
	print("[Placement Above Sea Level]")
	# 注意：地形噪声含 fract(sin(...))，对方向极微小变化敏感。
	# 用物品位置反推地形表面会引入噪声跳变，所以这里用径向壳层
	# 校验「不在水下、不超过最高海拔」，而不是重复采样地形。
	var all_above_sea := true
	var all_within_shell := true
	var max_radius: float = world.planet_radius + WorldGenerator.DEFAULT_MAX_ELEVATION + 5.0
	for item in items:
		var radius: float = item.transform.origin.length()
		if radius <= world.planet_radius:
			all_above_sea = false
			printerr("  item ", item.item_id, " at/below sea level radius: ", radius)
		if radius > max_radius:
			all_within_shell = false
			printerr("  item ", item.item_id, " above world shell: ", radius)
	assert_true(all_above_sea, "all items are above sea level radius")
	assert_true(all_within_shell, "all items stay within the terrain shell")

func test_type_coverage(items: Array) -> void:
	print("[Type Coverage]")
	var logs := 0
	var stones := 0
	var ores := 0
	var ore_ids := ["iron_ore_hematite", "iron_ore_magnetite", "copper_ore_malachite",
		"tin_ore_cassiterite", "gold_ore", "coal"]

	for item in items:
		if item.shape == "fiber":
			logs += 1
		elif ore_ids.has(item.material_id):
			ores += 1
		else:
			stones += 1

	assert_true(logs > 0, "world contains fallen logs")
	assert_true(stones > 0, "world contains surface stones")
	assert_true(ores > 0, "world contains ore outcrops")
	assert_true(logs < stones, "logs are rarer than stones")

func test_log_orientation(world: WorldGenerator, items: Array) -> void:
	print("[Log Orientation]")
	var found := false
	for item in items:
		if item.shape != "fiber":
			continue
		found = true
		var up_dir: Vector3 = item.transform.origin.normalized()
		var log_axis: Vector3 = item.transform.basis.y.normalized()
		assert_eq(absf(log_axis.dot(up_dir)), 0.0, "log axis is tangent to surface", 0.01)
		assert_true(item.grain_dir_local == Vector3.UP, "log grain follows local length axis")
		break
	assert_true(found, "found at least one log for orientation test")

func test_determinism() -> void:
	print("[Determinism]")
	var world_a := _make_world()
	var world_b := _make_world()
	var items_a := WorldItemSpawner.generate(world_a)
	var items_b := WorldItemSpawner.generate(world_b)

	assert_eq(float(items_a.size()), float(items_b.size()), "same seed → same item count")
	var same := items_a.size() == items_b.size()
	if same:
		for i in range(items_a.size()):
			var a: ItemEntity = items_a[i]
			var b: ItemEntity = items_b[i]
			if a.item_id != b.item_id or a.material_id != b.material_id or a.shape != b.shape:
				same = false
				printerr("  mismatch at ", i, ": ", a.item_id, "/", b.item_id)
				break
			if a.transform.origin.distance_to(b.transform.origin) > 0.001:
				same = false
				printerr("  position mismatch at ", i)
				break
	assert_true(same, "same seed → identical items, materials and positions")

func test_registry_integration(items: Array) -> void:
	print("[Registry Integration]")
	var registry := ItemRegistry.new()
	add_child(registry)

	var spawned := 0
	var all_ok := true
	for item in items:
		var result := registry.spawn(item)
		if result["ok"]:
			spawned += 1
		else:
			all_ok = false
			printerr("  spawn failed: ", result["error"])

	assert_true(all_ok, "all world items register successfully")
	assert_true(spawned == items.size(), "registry count matches generated items")
	assert_true(registry.validate()["valid"], "registry consistent after world item load")
	assert_true(registry.get_total_mass_kg() > 0.0, "world has positive total item mass")
	assert_true(registry.get_world_items().size() == items.size(), "all items query as world items")
