# ============================================================
# test_item_fallback.gd — 物品掉进地形后的回位
# ============================================================
# 运行：godot --headless --path . scenes/test_item_fallback.tscn
# 把一根木棍人为压到本地地表以下 12 m，模拟推挤/长条穿模。
# 期望：它按自己当前的方向重新落回本地地表，而不是瞬移回出生点
# （出生点常常在树根下，看起来像「钻地后闪到树下」）。
# ============================================================
extends Node

var _scene: Node = null
var _body: ItemPhysicsBody = null
var _frames := 0
var _dir0 := Vector3.ZERO
var _surface := 0.0
var _started := false


func _ready() -> void:
	_scene = load("res://scenes/client_3d.tscn").instantiate()
	add_child(_scene)


func _physics_process(_delta: float) -> void:
	_frames += 1
	if not _started:
		if _frames < 120:
			return
		_body = _find_item()
		if _body == null:
			return
		if not _body.ground_radius_sampler.is_valid():
			print("=== Item Fallback: FAIL (采样器未注入) ===")
			get_tree().quit(0)
			return
		# 先沿地表挪开约 16 m，再压下去：这样「回位到当前方向」和
		# 「瞬移回出生点」会明显不同，测出来的才是回位逻辑
		var base: Vector3 = _body.global_position.normalized()
		var tangent: Vector3 = base.cross(Vector3.UP).normalized()
		_dir0 = (base + tangent * 0.004).normalized()
		_surface = float(_body.ground_radius_sampler.call(_dir0 * base.length()))
		_body.global_position = _dir0 * (_surface - 12.0)
		_started = true
		print("[Item] 压到地表下 12 m（本地地表半径 %.1f）" % _surface)
		return

	# 给兜底逻辑几帧时间
	if _frames == 180:
		_report()
		get_tree().quit(0)


func _find_item() -> ItemPhysicsBody:
	var items_root: Node = _scene.get_node_or_null("WorldRenderer/WorldItems")
	if items_root == null:
		items_root = _scene.find_child("WorldItems", true, false)
	if items_root == null or items_root.get_child_count() == 0:
		return null
	for child in items_root.get_children():
		if child is ItemPhysicsBody:
			return child as ItemPhysicsBody
	return null


func _report() -> void:
	if _body == null or not is_instance_valid(_body):
		print("=== Item Fallback: FAIL (物品已被释放) ===")
		return
	var pos: Vector3 = _body.global_position
	var radius: float = pos.length()
	var dir: Vector3 = pos.normalized()
	var surface_now: float = float(_body.ground_radius_sampler.call(pos))
	var above: bool = radius > surface_now - 0.5
	var same_place: bool = dir.dot(_dir0) > 0.999
	var moved_from_spawn: float = pos.distance_to(_body.fallback_position)
	print("[Item] 回位半径=%.1f 地表=%.1f 同方向=%s 距出生点=%.1f m" %
		[radius, surface_now, str(same_place), moved_from_spawn])
	var ok: bool = above and (same_place or moved_from_spawn < 2.0)
	print("=== Item Fallback: %s ===" % ("PASS" if ok else "FAIL"))
