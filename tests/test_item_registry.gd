# ============================================================
# test_item_registry.gd — 物品注册表与唯一位置索引测试
# ============================================================
# 运行：godot --headless --path . scenes/test_item_registry.tscn
# 依赖：MaterialDB autoload
# ============================================================
extends Node

var _passed := 0
var _failed := 0
var _total := 0
var _registry: ItemRegistry

func _ready() -> void:
	if not MaterialDB.is_loaded:
		MaterialDB.load_from_file("res://scripts/shared/data/materials.json")

	_registry = ItemRegistry.new()
	add_child(_registry)

	run_all_tests()

	print("\n=== Results: ", _passed, "/", _total, " passed, ", _failed, " failed ===")
	if OS.has_feature("headless"):
		if _failed > 0:
			get_tree().quit(1)
		else:
			get_tree().quit(0)

# ============================================================
# 断言
# ============================================================

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

func assert_ok(result: Dictionary, test_name: String) -> void:
	assert_true(result.get("ok", false), test_name + " (error: " + str(result.get("error", "")) + ")")

func assert_fail(result: Dictionary, test_name: String) -> void:
	assert_true(not result.get("ok", true), test_name)

# ============================================================
# 测试入口
# ============================================================

func run_all_tests() -> void:
	print("=== ItemRegistry Unit Tests ===\n")
	test_spawn_and_ids()
	test_hand_occupancy()
	test_hand_to_world()
	test_attachments()
	test_inside_cavity()
	test_containment_cycle()
	test_holder_load()
	test_total_mass_conservation()
	test_world_near_query()
	test_remove()
	test_remove_container_with_contents()
	test_validation_catches_corruption()
	test_duplicate_item_id()

# ============================================================
# 测试
# ============================================================

func _reset_registry() -> void:
	if _registry != null:
		remove_child(_registry)
		_registry.free()
	_registry = ItemRegistry.new()
	add_child(_registry)

func _make_item(material_id: String = "granite", side: float = 0.1) -> ItemEntity:
	var item := ItemEntity.new()
	item.material_id = material_id
	item.shape = "block"
	item.dimensions = {"length": side, "width": side, "height": side}
	item.set_in_world(Transform3D.IDENTITY)
	return item

func _spawn(item: ItemEntity) -> ItemEntity:
	var result := _registry.spawn(item)
	assert_ok(result, "spawn " + item.material_id)
	return item

func test_spawn_and_ids() -> void:
	_reset_registry()
	print("[Spawn / ID Assignment]")
	var a := _spawn(_make_item("granite"))
	var b := _spawn(_make_item("oak_wood"))

	assert_true(a.item_id > 0, "spawn assigns positive id")
	assert_true(b.item_id > 0, "second spawn assigns positive id")
	assert_true(a.item_id != b.item_id, "ids are unique")
	assert_true(_registry.get_item(a.item_id) == a, "get_item returns same instance")
	assert_true(_registry.count_items() == 2, "registry counts two items")
	assert_true(_registry.validate()["valid"], "registry valid after spawn")

func test_hand_occupancy() -> void:
	_reset_registry()
	print("[Hand Occupancy]")
	var a := _spawn(_make_item("granite"))
	var b := _spawn(_make_item("oak_wood"))

	assert_ok(_registry.move_to_hand(a.item_id, 100, "left"), "move a to left hand")
	assert_true(_registry.get_hand_item(100, "left") == a, "left hand resolves to a")
	assert_fail(_registry.move_to_hand(b.item_id, 100, "left"), "left hand rejects second item")
	assert_true(_registry.get_hand_item(100, "left") == a, "left hand still holds a")
	assert_true(b.is_in_world(), "rejected item stays in world")
	assert_true(_registry.validate()["valid"], "registry valid after hand rejection")

func test_hand_to_world() -> void:
	_reset_registry()
	print("[Hand → World]")
	var a := _spawn(_make_item("granite"))
	_registry.move_to_hand(a.item_id, 101, "right")
	assert_ok(_registry.move_to_world(a.item_id, Transform3D(Basis.IDENTITY, Vector3(3, 4, 5))),
		"move a from hand to world")
	assert_true(_registry.get_hand_item(101, "right") == null, "hand index cleared")
	assert_eq(a.transform.origin.x, 3.0, "world transform applied")
	assert_true(_registry.validate()["valid"], "registry valid after drop")

func test_attachments() -> void:
	_reset_registry()
	print("[Attachments]")
	var a := _spawn(_make_item("granite"))
	var b := _spawn(_make_item("oak_wood"))

	assert_ok(_registry.move_to_attached(a.item_id, 200, 0), "attach a at index 0")
	assert_true(_registry.get_attached_item(200, 0) == a, "attachment index resolves to a")
	assert_fail(_registry.move_to_attached(b.item_id, 200, 0), "same attachment point rejected")
	assert_ok(_registry.move_to_attached(b.item_id, 200, 1), "attach b at index 1")
	assert_true(_registry.get_holder_attachments(200).size() == 2, "holder has two attachments")
	assert_true(_registry.validate()["valid"], "registry valid after attachments")

func test_inside_cavity() -> void:
	_reset_registry()
	print("[Inside Cavity]")
	var assembly := _spawn(_make_item("oak_wood", 0.3))
	var s1 := _spawn(_make_item("granite", 0.08))
	var s2 := _spawn(_make_item("granite", 0.06))
	var s3 := _spawn(_make_item("granite", 0.04))

	assert_ok(_registry.move_to_inside(s1.item_id, assembly.item_id, 0), "put s1 in cavity 0")
	assert_ok(_registry.move_to_inside(s2.item_id, assembly.item_id, 0), "put s2 in same cavity")
	assert_ok(_registry.move_to_inside(s3.item_id, assembly.item_id, 1), "put s3 in cavity 1")

	assert_true(_registry.get_inside_items(assembly.item_id, 0).size() == 2, "cavity 0 has two items")
	assert_true(_registry.get_inside_items(assembly.item_id, 1).size() == 1, "cavity 1 has one item")
	assert_true(_registry.get_inside_items_for_assembly(assembly.item_id).size() == 3,
		"assembly has three contents")
	assert_true(_registry.validate()["valid"], "registry valid after placing inside")

	var expected: float = assembly.get_mass_kg() + s1.get_mass_kg() + s2.get_mass_kg() + s3.get_mass_kg()
	assert_eq(_registry.get_item_total_mass_kg(assembly.item_id), expected,
		"assembly total mass includes contents")

func test_containment_cycle() -> void:
	_reset_registry()
	print("[Containment Cycle Rejection]")
	var a := _spawn(_make_item("oak_wood", 0.3))
	var b := _spawn(_make_item("oak_wood", 0.25))

	assert_fail(_registry.move_to_inside(a.item_id, a.item_id, 0), "item cannot contain itself")
	assert_ok(_registry.move_to_inside(a.item_id, b.item_id, 0), "put a inside b")
	assert_fail(_registry.move_to_inside(b.item_id, a.item_id, 0), "b inside a would create a cycle")
	assert_true(_registry.validate()["valid"], "registry valid after cycle rejection")

func test_holder_load() -> void:
	_reset_registry()
	print("[Holder Load]")
	var holder_id := 300
	var stone := _spawn(_make_item("granite", 0.1))
	var container := _spawn(_make_item("oak_wood", 0.2))
	var content := _spawn(_make_item("granite", 0.05))
	var attached := _spawn(_make_item("granite", 0.04))

	_registry.move_to_hand(stone.item_id, holder_id, "left")
	_registry.move_to_hand(container.item_id, holder_id, "right")
	_registry.move_to_inside(content.item_id, container.item_id, 0)
	_registry.move_to_attached(attached.item_id, holder_id, 0)

	var expected: float = stone.get_mass_kg() \
		+ container.get_mass_kg() + content.get_mass_kg() \
		+ attached.get_mass_kg()
	assert_eq(_registry.get_holder_load_kg(holder_id), expected,
		"holder load = hands + attachments + container contents")

func test_total_mass_conservation() -> void:
	_reset_registry()
	print("[Total Mass Conservation]")
	var before := _registry.get_total_mass_kg()

	var a := _spawn(_make_item("granite", 0.1))
	var b := _spawn(_make_item("iron_ore_hematite", 0.08))
	var c := _spawn(_make_item("oak_wood", 0.06))
	var after_spawn := _registry.get_total_mass_kg()
	assert_true(after_spawn > before, "spawning increases total mass")

	_registry.move_to_hand(a.item_id, 400, "left")
	_registry.move_to_attached(b.item_id, 400, 0)
	_registry.move_to_inside(c.item_id, a.item_id, 0)

	assert_eq(_registry.get_total_mass_kg(), after_spawn,
		"moving items does not change total mass")

func test_world_near_query() -> void:
	_reset_registry()
	print("[World Near Query]")
	var near_item := _make_item("granite")
	near_item.transform = Transform3D(Basis.IDENTITY, Vector3(1, 0, 0))
	_spawn(near_item)

	var far_item := _make_item("granite")
	far_item.transform = Transform3D(Basis.IDENTITY, Vector3(10, 0, 0))
	_spawn(far_item)

	assert_true(_registry.get_world_items_near(Vector3.ZERO, 5.0).size() == 1,
		"radius 5 finds only near item")
	assert_true(_registry.get_world_items_near(Vector3.ZERO, 15.0).size() == 2,
		"radius 15 finds both")

func test_remove() -> void:
	_reset_registry()
	print("[Remove]")
	var a := _spawn(_make_item("granite"))
	_registry.move_to_hand(a.item_id, 500, "left")

	assert_ok(_registry.remove(a.item_id), "remove item from hand")
	assert_true(_registry.get_item(a.item_id) == null, "removed item no longer resolvable")
	assert_true(_registry.get_hand_item(500, "left") == null, "hand index cleared on remove")
	assert_true(_registry.validate()["valid"], "registry valid after remove")
	assert_fail(_registry.remove(a.item_id), "removing missing item fails")

func test_remove_container_with_contents() -> void:
	_reset_registry()
	print("[Remove Container With Contents]")
	var container := _spawn(_make_item("oak_wood", 0.2))
	var content := _spawn(_make_item("granite", 0.05))
	_registry.move_to_inside(content.item_id, container.item_id, 0)

	assert_fail(_registry.remove(container.item_id), "container with contents cannot be removed")
	assert_ok(_registry.move_to_world(content.item_id), "empty container first")
	assert_ok(_registry.remove(container.item_id), "remove emptied container")
	assert_true(_registry.validate()["valid"], "registry valid after container removal")

func test_validation_catches_corruption() -> void:
	_reset_registry()
	print("[Validation Catches Corruption]")
	var a := _spawn(_make_item("granite"))

	# 绕过注册表直接改 location，索引会与物品状态不一致
	a.set_in_hand(600, "left")
	var broken := _registry.validate()
	assert_true(not broken["valid"], "validation detects location/index mismatch")

	# move_to_world 会清理旧索引并恢复一致
	assert_ok(_registry.move_to_world(a.item_id), "repair corrupted item via move_to_world")
	assert_true(_registry.validate()["valid"], "registry valid after repair")

func test_duplicate_item_id() -> void:
	_reset_registry()
	print("[Duplicate Item ID]")
	var a := _spawn(_make_item("granite"))
	var duplicate := _make_item("oak_wood")
	duplicate.item_id = a.item_id

	assert_fail(_registry.spawn(duplicate), "duplicate item_id rejected")
	assert_true(_registry.count_items() == 1, "duplicate did not increase item count")
