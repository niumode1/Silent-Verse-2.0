# ============================================================
# test_fracture.gd — 凸多面体破裂原型
# ============================================================
# 运行：godot --headless --path . scenes/test_fracture.tscn
# 验证：
#   · 一个长方体被切成 N 块凸碎片
#   · 体积总和 = 原体积（质量守恒）
#   · 同种子同结果
#   · 每块能生成网格和凸碰撞体
# ============================================================
extends Node

var _pass := 0
var _fail := 0


func _ready() -> void:
	var size := Vector3(0.5, 0.4, 0.3)
	var volume := size.x * size.y * size.z
	var density := 2700.0
	var fragments := FractureGenerator.fracture_box(size, 8, 42)
	print("[Fracture] %d fragments, target volume %.4f m³"
		% [fragments.size(), volume])
	_check(fragments.size() == 8, "produced 8 fragments")
	var total_volume := 0.0
	var total_mass := 0.0
	var all_valid := true
	for fragment in fragments:
		var v: float = float(fragment["volume"])
		total_volume += v
		total_mass += v * density
		if v <= 0.0 or (fragment["faces"] as Array).is_empty():
			all_valid = false
	_check(all_valid, "every fragment has positive volume and faces")
	_check(absf(total_volume - volume) < volume * 0.01,
		"volumes sum to original (%.4f vs %.4f)" % [total_volume, volume])
	_check(absf(total_mass - volume * density) < volume * density * 0.01,
		"masses sum to original (%.1f kg)" % total_mass)

	var again := FractureGenerator.fracture_box(size, 8, 42)
	var deterministic := again.size() == fragments.size()
	if deterministic:
		for i in range(fragments.size()):
			if absf(float(again[i]["volume"])
					- float(fragments[i]["volume"])) > 1.0e-6:
				deterministic = false
				break
	_check(deterministic, "same seed → same fragments")

	var mesh := FractureGenerator.build_mesh(fragments[0])
	_check(mesh != null and mesh.get_surface_count() > 0,
		"fragment mesh generated")
	var shape := ConvexPolygonShape3D.new()
	shape.points = fragments[0]["vertices"]
	_check((shape.points as PackedVector3Array).size() >= 4,
		"convex collision shape has >= 4 points")
	print("  volumes: ",
		fragments.map(func(f): return snapped(float(f["volume"]), 0.0001)))

	_test_item_fragments(size, volume)
	_test_preferred_normals(size)

	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _test_item_fragments(size: Vector3, volume: float) -> void:
	print("[Item fragments]")
	var granite := MaterialDB.get_material("granite")
	var items := FractureGenerator.make_item_fragments(size, 8, 42,
		"granite", Transform3D.IDENTITY)
	_check(items.size() == 8, "8 ItemEntity fragments")
	var total_mass := 0.0
	var all_meshes := true
	var all_shapes := true
	for item in items:
		total_mass += item.get_mass_kg()
		if item.custom_mesh == null:
			all_meshes = false
		var shapes := ItemCollision.build_shapes(item, item.custom_mesh)
		if shapes.is_empty():
			all_shapes = false
	_check(all_meshes, "every fragment has its own mesh")
	_check(all_shapes, "every fragment has its own collision shape")
	var expected := volume * granite.density
	_check(absf(total_mass - expected) < expected * 0.01,
		"fragment masses sum to parent (%.1f vs %.1f kg)"
		% [total_mass, expected])


func _test_preferred_normals(size: Vector3) -> void:
	print("[Preferred normals]")
	var preferred := Vector3.UP
	var aligned := FractureGenerator.fracture_box(size, 8, 42, preferred, 10.0)
	var spread := FractureGenerator.fracture_box(size, 8, 42, preferred, 180.0)
	var aligned_avg := _normal_alignment(aligned, preferred)
	var spread_avg := _normal_alignment(spread, preferred)
	_check(aligned_avg > 0.9,
		"narrow spread follows preferred normal (avg |dot| %.2f)"
		% aligned_avg)
	_check(spread_avg < 0.9,
		"wide spread is not locked to preferred normal (avg |dot| %.2f)"
		% spread_avg)
	_check(aligned_avg > spread_avg,
		"anisotropic fracturing is more aligned than isotropic")


func _normal_alignment(fragments: Array, preferred: Vector3) -> float:
	var total := 0.0
	var count := 0
	for fragment in fragments:
		for normal in fragment["split_normals"]:
			total += absf((normal as Vector3).normalized().dot(preferred))
			count += 1
	return total / maxf(float(count), 1.0)


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: ", label)
	else:
		_fail += 1
		print("  FAIL: ", label)
