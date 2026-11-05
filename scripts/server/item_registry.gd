# ============================================================
# ItemRegistry — 服务端物品实体注册表与唯一位置索引
# ============================================================
# 职责：保存世界中所有 ItemEntity，并保证每个 item_id 在任意时刻
# 只存在于一个位置：世界 / 左手 / 右手 / 绑扎点 / 某个构造物空腔。
#
# 这里不做「背包」，也不做槽位容量。手位占用、绑扎点占用只是物理
# 约束的索引；空腔是否装得下由 ContainmentEvaluator 判定。
#
# 所有移动都是原子的：先解除旧索引，再写入新索引；失败则回滚。
# ============================================================
class_name ItemRegistry
extends Node

signal item_added(item: ItemEntity)
signal item_removed(item_id: int)
signal item_moved(item: ItemEntity, from_location: Dictionary, to_location: Dictionary)

const VALID_HANDS := ["left", "right"]

## item_id -> ItemEntity
var _items: Dictionary = {}

## "holder_id:hand" -> item_id
var _hand_index: Dictionary = {}

## "holder_id:attachment_index" -> item_id
var _attachment_index: Dictionary = {}

## "assembly_id:cavity_id" -> Array[item_id]
var _inside_index: Dictionary = {}

var _next_item_id: int = 1

# ============================================================
# 增删
# ============================================================

## 注册一件物品。item_id <= 0 时由注册表分配。
## 返回 {ok, error, item_id}
func spawn(item: ItemEntity) -> Dictionary:
	if item == null:
		return _fail("item is null")

	if item.item_id <= 0:
		item.item_id = _allocate_id()
	if _items.has(item.item_id):
		return _fail("duplicate item_id: %d" % item.item_id)

	var validation := item.validate()
	if not validation["valid"]:
		return _fail("invalid item: " + str(validation["errors"]))

	if item.location.is_empty():
		item.set_in_world(item.transform)

	_items[item.item_id] = item
	var index_error := _index_item(item)
	if index_error != "":
		_items.erase(item.item_id)
		return _fail(index_error)

	item_added.emit(item)
	return _ok({"item_id": item.item_id})

## 移除一件物品。仍有内容物的构造物不能直接移除。
func remove(item_id: int) -> Dictionary:
	var item: ItemEntity = _get_item_or_null(item_id)
	if item == null:
		return _fail("item not found: %d" % item_id)

	if not get_inside_items_for_assembly(item_id).is_empty():
		return _fail("assembly still contains items: %d" % item_id)

	_unindex(item)
	_items.erase(item_id)
	item_removed.emit(item_id)
	return _ok()

# ============================================================
# 位置移动
# ============================================================

func move_to_world(item_id: int, new_transform = null) -> Dictionary:
	return _move(item_id, {"kind": "world"}, new_transform)

func move_to_hand(item_id: int, holder_id: int, hand: String) -> Dictionary:
	if not VALID_HANDS.has(hand):
		return _fail("invalid hand: " + hand)
	return _move(item_id, {"kind": "hand", "holder_id": holder_id, "hand": hand})

func move_to_attached(item_id: int, holder_id: int, attachment_index: int) -> Dictionary:
	if attachment_index < 0:
		return _fail("attachment_index must be >= 0")
	return _move(item_id, {
		"kind": "attached",
		"holder_id": holder_id,
		"attachment_index": attachment_index
	})

func move_to_inside(item_id: int, assembly_id: int, cavity_id: int) -> Dictionary:
	if assembly_id == item_id:
		return _fail("item cannot contain itself")
	if not _items.has(assembly_id):
		return _fail("assembly not found: %d" % assembly_id)
	if _would_create_cycle(item_id, assembly_id):
		return _fail("containment cycle")
	return _move(item_id, {
		"kind": "inside",
		"assembly_id": assembly_id,
		"cavity_id": cavity_id
	})

# ============================================================
# 查询
# ============================================================

func get_item(item_id: int) -> ItemEntity:
	return _get_item_or_null(item_id)

func get_all_items() -> Array:
	var result: Array = []
	for item in _items.values():
		result.append(item)
	return result

func count_items() -> int:
	return _items.size()

func get_hand_item(holder_id: int, hand: String) -> ItemEntity:
	return _get_item_or_null(_hand_index.get(_hand_key(holder_id, hand), 0))

func get_attached_item(holder_id: int, attachment_index: int) -> ItemEntity:
	return _get_item_or_null(_attachment_index.get(_attachment_key(holder_id, attachment_index), 0))

func get_holder_attachments(holder_id: int) -> Array:
	var result: Array = []
	for key in _attachment_index:
		var parts: PackedStringArray = String(key).split(":")
		if parts.size() >= 2 and int(parts[0]) == holder_id:
			var item := _get_item_or_null(int(_attachment_index[key]))
			if item != null:
				result.append(item)
	return result

func get_inside_items(assembly_id: int, cavity_id: int) -> Array:
	var ids: Array = _inside_index.get(_inside_key(assembly_id, cavity_id), [])
	var result: Array = []
	for item_id in ids:
		var item := _get_item_or_null(int(item_id))
		if item != null:
			result.append(item)
	return result

## 某个构造物所有空腔里的内容物
func get_inside_items_for_assembly(assembly_id: int) -> Array:
	var result: Array = []
	for key in _inside_index:
		var parts: PackedStringArray = String(key).split(":")
		if parts.size() >= 1 and int(parts[0]) == assembly_id:
			for item_id in _inside_index[key]:
				var item := _get_item_or_null(int(item_id))
				if item != null:
					result.append(item)
	return result

func get_world_items() -> Array:
	var result: Array = []
	for item in _items.values():
		if item is ItemEntity and item.is_in_world():
			result.append(item)
	return result

func get_world_items_near(position: Vector3, radius: float) -> Array:
	var result: Array = []
	for item in _items.values():
		if item is ItemEntity and item.is_in_world():
			if item.transform.origin.distance_to(position) <= radius:
				result.append(item)
	return result

# ============================================================
# 质量
# ============================================================

## 某个持有者（手 + 绑扎）的总负载，包含容器内容物
func get_holder_load_kg(holder_id: int) -> float:
	var total: float = 0.0
	for hand in VALID_HANDS:
		var held := get_hand_item(holder_id, hand)
		if held != null:
			total += get_item_total_mass_kg(held.item_id)
	for attached in get_holder_attachments(holder_id):
		total += get_item_total_mass_kg(attached.item_id)
	return total

## 单件物品的总质量，递归包含它内部空腔里的内容物
func get_item_total_mass_kg(item_id: int) -> float:
	return _total_mass_recursive(item_id, {})

## 全系统总质量：只统计顶层物品，避免内容物重复计数
func get_total_mass_kg() -> float:
	var total: float = 0.0
	for item in _items.values():
		if not (item is ItemEntity):
			continue
		if item.location.get("kind", "") == "inside":
			continue
		total += get_item_total_mass_kg(item.item_id)
	return total

func _total_mass_recursive(item_id: int, visited: Dictionary) -> float:
	if visited.has(item_id):
		return 0.0
	visited[item_id] = true

	var item := _get_item_or_null(item_id)
	if item == null:
		return 0.0

	var total: float = item.get_mass_kg()
	for key in _inside_index:
		var parts: PackedStringArray = String(key).split(":")
		if parts.size() >= 1 and int(parts[0]) == item_id:
			for child_id in _inside_index[key]:
				total += _total_mass_recursive(int(child_id), visited)
	return total

# ============================================================
# 一致性校验
# ============================================================

## 校验索引与物品自身 location 完全一致、无重复、无环。
func validate() -> Dictionary:
	var errors: Array[String] = []

	var expected_hands: Dictionary = {}
	var expected_attachments: Dictionary = {}
	var expected_inside: Dictionary = {}

	for id in _items:
		var item = _items[id]
		if not (item is ItemEntity):
			errors.append("non-ItemEntity registered at id %d" % id)
			continue
		if item.item_id != id:
			errors.append("item_id mismatch: key=%d item=%d" % [id, item.item_id])

		var loc: Dictionary = item.location
		var kind: String = loc.get("kind", "")
		match kind:
			"world":
				pass
			"hand":
				var hand: String = loc.get("hand", "")
				if not VALID_HANDS.has(hand):
					errors.append("item %d has invalid hand: %s" % [id, hand])
					continue
				var key := _hand_key(int(loc.get("holder_id", 0)), hand)
				if expected_hands.has(key):
					errors.append("two items claim hand %s: %d, %d" % [key, expected_hands[key], id])
				expected_hands[key] = id
			"attached":
				var key := _attachment_key(int(loc.get("holder_id", 0)), int(loc.get("attachment_index", -1)))
				if expected_attachments.has(key):
					errors.append("two items claim attachment %s" % key)
				expected_attachments[key] = id
			"inside":
				var assembly_id: int = int(loc.get("assembly_id", 0))
				if assembly_id == id:
					errors.append("item %d contains itself" % id)
				if not _items.has(assembly_id):
					errors.append("item %d inside missing assembly %d" % [id, assembly_id])
				var key := _inside_key(assembly_id, int(loc.get("cavity_id", 0)))
				if not expected_inside.has(key):
					expected_inside[key] = []
				expected_inside[key].append(id)
			_:
				errors.append("item %d has invalid location kind: %s" % [id, kind])

	_compare_hand_index(expected_hands, errors)
	_compare_attachment_index(expected_attachments, errors)
	_compare_inside_index(expected_inside, errors)
	_check_cycles(errors)

	return {"valid": errors.is_empty(), "errors": errors}

# ============================================================
# 内部：索引维护
# ============================================================

func _move(item_id: int, new_location: Dictionary, new_transform = null) -> Dictionary:
	var item := _get_item_or_null(item_id)
	if item == null:
		return _fail("item not found: %d" % item_id)

	var old_location: Dictionary = item.location.duplicate(true)
	var old_transform: Transform3D = item.transform

	_unindex(item)
	item.location = new_location.duplicate(true)
	if new_transform is Transform3D:
		item.transform = new_transform

	var index_error := _index_item(item)
	if index_error != "":
		# 回滚到旧位置
		item.location = old_location
		item.transform = old_transform
		_index_item(item)
		return _fail(index_error)

	item_moved.emit(item, old_location, new_location.duplicate(true))
	return _ok()

func _index_item(item: ItemEntity) -> String:
	var loc: Dictionary = item.location
	var kind: String = loc.get("kind", "")

	match kind:
		"world":
			return ""
		"hand":
			var hand: String = loc.get("hand", "")
			if not VALID_HANDS.has(hand):
				return "invalid hand: " + hand
			var key := _hand_key(int(loc.get("holder_id", 0)), hand)
			if _hand_index.has(key):
				return "hand already occupied: " + key
			_hand_index[key] = item.item_id
			return ""
		"attached":
			var key := _attachment_key(int(loc.get("holder_id", 0)), int(loc.get("attachment_index", -1)))
			if _attachment_index.has(key):
				return "attachment point already occupied: " + key
			_attachment_index[key] = item.item_id
			return ""
		"inside":
			var assembly_id: int = int(loc.get("assembly_id", 0))
			if assembly_id == item.item_id:
				return "item cannot contain itself"
			if not _items.has(assembly_id):
				return "assembly not found: %d" % assembly_id
			if _would_create_cycle(item.item_id, assembly_id):
				return "containment cycle"
			var key := _inside_key(assembly_id, int(loc.get("cavity_id", 0)))
			if not _inside_index.has(key):
				_inside_index[key] = []
			if _inside_index[key].has(item.item_id):
				return "item already inside: %d" % item.item_id
			_inside_index[key].append(item.item_id)
			return ""
		_:
			return "invalid location kind: " + kind

func _unindex(item: ItemEntity) -> void:
	var loc: Dictionary = item.location
	match loc.get("kind", ""):
		"hand":
			_hand_index.erase(_hand_key(int(loc.get("holder_id", 0)), String(loc.get("hand", ""))))
		"attached":
			_attachment_index.erase(_attachment_key(
				int(loc.get("holder_id", 0)), int(loc.get("attachment_index", -1))))
		"inside":
			var key := _inside_key(int(loc.get("assembly_id", 0)), int(loc.get("cavity_id", 0)))
			if _inside_index.has(key):
				var ids: Array = _inside_index[key]
				ids.erase(item.item_id)
				if ids.is_empty():
					_inside_index.erase(key)

## 把 item 放进 assembly 是否会形成包含环
func _would_create_cycle(item_id: int, assembly_id: int) -> bool:
	var current: int = assembly_id
	var guard: int = 0
	while current != 0 and guard < 10000:
		if current == item_id:
			return true
		var parent := _get_item_or_null(current)
		if parent == null:
			return false
		var loc: Dictionary = parent.location
		if loc.get("kind", "") != "inside":
			return false
		current = int(loc.get("assembly_id", 0))
		guard += 1
	return guard >= 10000

func _check_cycles(errors: Array[String]) -> void:
	for id in _items:
		var seen: Dictionary = {}
		var current: int = id
		var guard: int = 0
		while current != 0 and guard < 10000:
			if seen.has(current):
				errors.append("containment cycle involving item %d" % id)
				break
			seen[current] = true
			var item := _get_item_or_null(current)
			if item == null:
				break
			var loc: Dictionary = item.location
			if loc.get("kind", "") != "inside":
				break
			current = int(loc.get("assembly_id", 0))
			guard += 1

func _compare_hand_index(expected: Dictionary, errors: Array[String]) -> void:
	if expected.size() != _hand_index.size():
		errors.append("hand index size mismatch: expected %d actual %d"
			% [expected.size(), _hand_index.size()])
	for key in expected:
		if not _hand_index.has(key) or int(_hand_index[key]) != int(expected[key]):
			errors.append("hand index mismatch at %s" % key)
	for key in _hand_index:
		if not expected.has(key):
			errors.append("stale hand index at %s" % key)

func _compare_attachment_index(expected: Dictionary, errors: Array[String]) -> void:
	if expected.size() != _attachment_index.size():
		errors.append("attachment index size mismatch: expected %d actual %d"
			% [expected.size(), _attachment_index.size()])
	for key in expected:
		if not _attachment_index.has(key) or int(_attachment_index[key]) != int(expected[key]):
			errors.append("attachment index mismatch at %s" % key)
	for key in _attachment_index:
		if not expected.has(key):
			errors.append("stale attachment index at %s" % key)

func _compare_inside_index(expected: Dictionary, errors: Array[String]) -> void:
	if expected.size() != _inside_index.size():
		errors.append("inside index size mismatch: expected %d actual %d"
			% [expected.size(), _inside_index.size()])
	for key in expected:
		if not _inside_index.has(key):
			errors.append("missing inside index at %s" % key)
			continue
		var expected_ids: Array = expected[key]
		var actual_ids: Array = _inside_index[key]
		if expected_ids.size() != actual_ids.size():
			errors.append("inside index size mismatch at %s" % key)
		for id in expected_ids:
			if not actual_ids.has(id):
				errors.append("inside index missing item %d at %s" % [id, key])
	for key in _inside_index:
		if not expected.has(key):
			errors.append("stale inside index at %s" % key)

# ============================================================
# 内部：工具
# ============================================================

func _allocate_id() -> int:
	while _items.has(_next_item_id):
		_next_item_id += 1
	var assigned: int = _next_item_id
	_next_item_id += 1
	return assigned

func _get_item_or_null(item_id: int) -> ItemEntity:
	var item = _items.get(item_id)
	if item is ItemEntity:
		return item
	return null

func _hand_key(holder_id: int, hand: String) -> String:
	return "%d:%s" % [holder_id, hand]

func _attachment_key(holder_id: int, attachment_index: int) -> String:
	return "%d:%d" % [holder_id, attachment_index]

func _inside_key(assembly_id: int, cavity_id: int) -> String:
	return "%d:%d" % [assembly_id, cavity_id]

func _ok(extra: Dictionary = {}) -> Dictionary:
	var result := {"ok": true, "error": ""}
	result.merge(extra, true)
	return result

func _fail(message: String) -> Dictionary:
	return {"ok": false, "error": message}
