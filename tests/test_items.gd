# ============================================================
# test_items.gd — ItemEntity 质量/几何/序列化单元测试
# ============================================================
# 运行：godot --headless --path . scenes/test_items.tscn
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

# ============================================================
# 断言
# ============================================================

func assert_eq(actual: float, expected: float, test_name: String, tolerance: float = 1e-6) -> void:
	_total += 1
	if absf(actual - expected) <= tolerance:
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

# ============================================================
# 测试入口
# ============================================================

func run_all_tests() -> void:
	print("=== ItemEntity Unit Tests ===\n")
	test_primitive_volume_mass()
	test_sphere_volume()
	test_assembly_mass_and_com()
	test_grip_lever()
	test_surface_state()
	test_serialization()
	test_invalid_material()
	test_material_microstructure()
	test_legacy_material_fields()
	test_volume_override()
	test_custom_mesh_collision()

# ============================================================
# 测试
# ============================================================

func test_primitive_volume_mass() -> void:
	print("[Primitive Volume / Mass]")
	var mat := MaterialDB.get_material("oak_wood")
	var item := ItemEntity.new()
	item.item_id = 1
	item.material_id = "oak_wood"
	item.shape = "plank"
	item.dimensions = {"length": 0.5, "width": 0.1, "height": 0.04}

	var expected_volume := 0.5 * 0.1 * 0.04
	assert_eq(item.get_volume_m3(), expected_volume, "oak plank volume = L×W×H")
	assert_eq(item.get_mass_kg(), mat.density * expected_volume, "oak plank mass = density×volume")
	assert_true(item.validate()["valid"], "valid primitive item")

func test_sphere_volume() -> void:
	print("[Sphere Volume]")
	var mat := MaterialDB.get_material("pure_iron")
	var item := ItemEntity.new()
	item.item_id = 2
	item.material_id = "pure_iron"
	item.shape = "sphere"
	item.dimensions = {"radius": 0.05}

	var expected_volume: float = (4.0 / 3.0) * PI * pow(0.05, 3)
	assert_eq(item.get_volume_m3(), expected_volume, "iron sphere volume = 4/3πr³")
	assert_eq(item.get_mass_kg(), mat.density * expected_volume, "iron sphere mass = density×volume")

func test_assembly_mass_and_com() -> void:
	print("[Assembly Mass / Center of Mass]")
	var oak := MaterialDB.get_material("oak_wood")
	var granite := MaterialDB.get_material("granite")

	var rod_dims := {"length": 0.5, "width": 0.04, "height": 0.04}
	var block_dims := {"length": 0.15, "width": 0.1, "height": 0.1}
	var rod_mass: float = oak.density * 0.5 * 0.04 * 0.04
	var block_mass: float = granite.density * 0.15 * 0.1 * 0.1

	var item := ItemEntity.new()
	item.item_id = 3
	item.parts = [
		{"material_id": "oak_wood", "shape": "rod", "dimensions": rod_dims, "position": [-0.2, 0.0, 0.0]},
		{"material_id": "granite", "shape": "block", "dimensions": block_dims, "position": [0.2, 0.0, 0.0]},
	]

	assert_eq(item.get_mass_kg(), rod_mass + block_mass, "assembly mass = sum of parts")
	var com := item.get_center_of_mass_local()
	# 两件质量不同，质心应偏向更重的花岗岩（+x）
	assert_gt(com.x, 0.0, "assembly COM shifts toward heavier part")

func test_grip_lever() -> void:
	print("[Grip Lever]")
	var item := ItemEntity.new()
	item.item_id = 4
	item.material_id = "oak_wood"
	item.shape = "rod"
	item.dimensions = {"length": 0.5, "width": 0.04, "height": 0.04}
	item.grip_point_local = Vector3(-0.25, 0.0, 0.0)

	assert_eq(item.get_grip_lever_m(), 0.25, "grip at rod end → lever = half length")

func test_surface_state() -> void:
	print("[Surface State]")
	var oak := MaterialDB.get_material("oak_wood")
	var item := ItemEntity.new()
	item.item_id = 5
	item.material_id = "oak_wood"

	var default_surface := item.get_surface_state()
	assert_eq(default_surface["roughness_um"], oak.surface_roughness_um,
		"surface uses material default roughness")

	item.surface_roughness_um = 5.0
	item.wetness = 0.8
	item.oil_film = 0.2
	var overridden := item.get_surface_state()
	assert_eq(overridden["roughness_um"], 5.0, "item roughness overrides material default")
	assert_eq(overridden["wetness"], 0.8, "wetness propagates to surface state")
	assert_eq(overridden["oil_film"], 0.2, "oil film propagates to surface state")

func test_serialization() -> void:
	print("[Serialization]")
	var item := ItemEntity.new()
	item.item_id = 42
	item.material_id = "high_carbon_steel"
	item.shape = "blade"
	item.dimensions = {"length": 0.3, "width": 0.04, "height": 0.005}
	item.transform = Transform3D(Basis.IDENTITY, Vector3(1.0, 2.0, 3.0))
	item.temperature_c = 850.0
	item.wetness = 0.3
	item.tip_radius_m = 0.0005
	item.set_in_hand(7, "right")

	var restored := ItemEntity.from_dict(item.to_dict())
	assert_true(restored.item_id == 42, "item_id roundtrip")
	assert_true(restored.material_id == "high_carbon_steel", "material_id roundtrip")
	assert_eq(restored.get_mass_kg(), item.get_mass_kg(), "mass roundtrip")
	assert_eq(restored.transform.origin.x, 1.0, "transform origin roundtrip")
	assert_true(restored.location.get("kind", "") == "hand", "location kind roundtrip")
	assert_true(restored.location.get("hand", "") == "right", "location hand roundtrip")
	assert_eq(restored.tip_radius_m, 0.0005, "tip radius roundtrip")

func test_invalid_material() -> void:
	print("[Invalid Material]")
	var item := ItemEntity.new()
	item.item_id = 6
	item.material_id = "not_a_real_material"
	item.dimensions = {"length": 0.1, "width": 0.1, "height": 0.1}

	assert_true(item.get_material() == null, "unknown material returns null")
	assert_eq(item.get_mass_kg(), 0.0, "unknown material mass is zero")
	assert_true(not item.validate()["valid"], "unknown material fails validation")

func test_material_microstructure() -> void:
	print("[Material Microstructure Fields]")
	var expected := {
		"oak_wood": "fibrous",
		"pure_iron": "crystalline",
		"slate": "lamellar",
		"glass": "amorphous",
		"sand": "granular",
		"pottery": "porous",
	}
	for mat_id in expected:
		var mat := MaterialDB.get_material(mat_id)
		assert_true(mat.microstructure == expected[mat_id],
			mat_id + " microstructure = " + expected[mat_id])

	var all_ok := true
	for mat in MaterialDB.get_all_materials():
		if mat.surface_roughness_um < 0.0:
			all_ok = false
			printerr("  roughness < 0: ", mat.material_id)
		if mat.friction_anisotropy < 1.0:
			all_ok = false
			printerr("  anisotropy < 1: ", mat.material_id)
		if not mat.validate()["valid"]:
			all_ok = false
			printerr("  invalid material: ", mat.material_id, " ", mat.validate()["errors"])
	assert_true(all_ok, "all 70 materials have valid surface/microstructure fields")

func test_legacy_material_fields() -> void:
	print("[Legacy Processed Material Normalization]")
	var slag := MaterialDB.get_material("slag")
	# 旧字段 elastic_modulus 0.3 应映射到 youngs_modulus
	assert_eq(slag.youngs_modulus, 0.3, "slag elastic_modulus → youngs_modulus")
	# 旧字段 latent_heat_fusion 200000 J/kg → 200 kJ/kg
	assert_eq(slag.heat_of_fusion, 200.0, "slag latent heat J/kg → kJ/kg")
	assert_eq(slag.damping_coefficient, 0.5, "slag damping → damping_coefficient")
	assert_eq(slag.oxidation_resistance, 0.9, "slag oxidization_resistance → oxidation_resistance")

func test_custom_mesh_collision() -> void:
	print("[Custom Mesh Collision]")
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.3, 0.2, 0.1)

	var cut_piece := ItemEntity.new()
	cut_piece.item_id = 8
	cut_piece.material_id = "granite"
	cut_piece.shape = "custom"
	cut_piece.custom_mesh = mesh
	var cut_shapes := ItemCollision.build_shapes(cut_piece, mesh)
	assert_true(cut_shapes.size() == 1, "custom mesh yields one collision shape")
	assert_true(cut_shapes[0] is ConvexPolygonShape3D,
		"cut piece collision comes from its actual mesh (convex hull)")

	var block := ItemEntity.new()
	block.item_id = 9
	block.material_id = "granite"
	block.shape = "block"
	block.dimensions = {"length": 0.2, "width": 0.15, "height": 0.1}
	var block_shapes := ItemCollision.build_shapes(block)
	assert_true(block_shapes.size() == 1, "primitive block yields one shape")
	assert_true(block_shapes[0] is BoxShape3D, "primitive block uses exact box shape")


func test_volume_override() -> void:
	print("[Explicit Volume Override]")
	var item := ItemEntity.new()
	item.item_id = 7
	item.material_id = "sand"
	item.shape = "granular"
	item.dimensions = {"volume_m3": 0.002}

	var sand := MaterialDB.get_material("sand")
	assert_eq(item.get_volume_m3(), 0.002, "explicit volume_m3 override")
	assert_eq(item.get_mass_kg(), sand.density * 0.002, "mass uses explicit volume")
