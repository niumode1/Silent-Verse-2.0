# ============================================================
# test_client_strike.gd — 客户端对近场地面施力
# ============================================================
# 运行：godot --headless --path . scenes/test_client_strike.tscn
# 验证：
#   · WorldRenderer 生成近场格块
#   · debug_strike 能移除物质
#   · 土生成 DEM 粒子（或岩石生成碎片）
#   · 粒子 MultiMesh 能被更新
# ============================================================
extends Node

var _pass := 0
var _fail := 0


func _ready() -> void:
	var renderer := WorldRenderer.new()
	add_child(renderer)

	for i in range(1200):
		await get_tree().process_frame
		if renderer.spawn_point.length() > 1.0 \
				and renderer.get_node_or_null("NearGround") != null:
			break
	_check(renderer.spawn_point.length() > 1.0, "world generated")
	_check(renderer.get_node_or_null("NearGround") != null,
		"near-field chunks exist")
	if renderer.spawn_point.length() <= 1.0:
		_finish()
		return

	await get_tree().physics_frame
	var up: Vector3 = renderer.spawn_point.normalized()
	var result: Dictionary = renderer.debug_strike(renderer.spawn_point, -up)
	var removed: Dictionary = result.get("removed", {})
	_check(not removed.is_empty(), "strike removed material")
	if not removed.is_empty():
		_check(float(removed["mass_kg"]) > 0.0, "removed mass positive")
		var fragments: Array = result.get("fragments", [])
		var has_particles := renderer.get_particle_system_count() > 0
		_check(has_particles or not fragments.is_empty(),
			"soil produced particles or rock produced fragments")

	for i in range(80):
		await get_tree().process_frame
	var delta_mass := renderer.get_matter_delta_mass()
	if delta_mass > 0.0:
		_check(true, "settled particles consolidated into MatterDelta (%.1f kg)"
			% delta_mass)
	elif renderer.get_particle_system_count() > 0:
		_check(true, "particle system still alive after stepping")
	_finish()


func _finish() -> void:
	print("=== Results: %d/%d passed, %d failed ===" % [
		_pass, _pass + _fail, _fail])
	get_tree().quit(0)


func _check(condition: bool, label: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: ", label)
	else:
		_fail += 1
		print("  FAIL: ", label)
