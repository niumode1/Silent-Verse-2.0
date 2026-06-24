# ============================================================
# Soil — 土壤 NPK 网格
# ============================================================
# 管理行星表面的土壤肥力数据。
# 懒加载：只在玩家靠近时才初始化对应区块。
# ============================================================
class_name SoilGrid
extends RefCounted

## 区块大小 m
const CHUNK_SIZE: float = 100.0

## 已加载的区块 {chunk_key: SoilChunk}
var _chunks: Dictionary = {}

## 季节对土壤的影响系数
var seasonal_factor: float = 1.0

class SoilChunk:
	var grid: Array = []       # 10×10 网格，每个单元格 {n, p, k, moisture, organic, ph}
	var center: Vector3        # 区块中心的世界坐标
	var last_updated: float    # 上次更新时间戳

	func _init(pos: Vector3, biome_n: float = 0.5, biome_p: float = 0.3, biome_k: float = 0.4) -> void:
		center = pos
		last_updated = Time.get_unix_time_from_system()
		for y in range(10):
			var row: Array = []
			for x in range(10):
				row.append({
					"n": biome_n + (randf() - 0.5) * 0.2,
					"p": biome_p + (randf() - 0.5) * 0.15,
					"k": biome_k + (randf() - 0.5) * 0.2,
					"moisture": clampf(0.3 + randf() * 0.4, 0.0, 1.0),
					"organic": clampf(0.1 + randf() * 0.3, 0.0, 0.5),
					"ph": clampf(6.0 + randf() * 2.0, 4.5, 8.5)
				})
			grid.append(row)

## 获取指定位置的土壤数据
func get_soil_at(world_pos: Vector3) -> Dictionary:
	var key: String = _chunk_key(world_pos)

	if not _chunks.has(key):
		# 懒初始化
		_chunks[key] = SoilChunk.new(_chunk_center(world_pos))

	var chunk: SoilChunk = _chunks[key]
	var local: Vector2 = _world_to_local(world_pos)
	var gx: int = clampi(int(local.x / CHUNK_SIZE * 10), 0, 9)
	var gy: int = clampi(int(local.y / CHUNK_SIZE * 10), 0, 9)

	return chunk.grid[gy][gx]

## 更新土壤养分（植物消耗/有机物分解）
func modify_nutrients(world_pos: Vector3, delta_n: float, delta_p: float, delta_k: float) -> void:
	var key: String = _chunk_key(world_pos)
	if not _chunks.has(key):
		get_soil_at(world_pos)

	var chunk: SoilChunk = _chunks[key]
	var local: Vector2 = _world_to_local(world_pos)
	var gx: int = clampi(int(local.x / CHUNK_SIZE * 10), 0, 9)
	var gy: int = clampi(int(local.y / CHUNK_SIZE * 10), 0, 9)

	var cell = chunk.grid[gy][gx]
	cell["n"] = clampf(cell["n"] + delta_n, 0.0, 1.0)
	cell["p"] = clampf(cell["p"] + delta_p, 0.0, 1.0)
	cell["k"] = clampf(cell["k"] + delta_k, 0.0, 1.0)
	chunk.last_updated = Time.get_unix_time_from_system()

## 雨水补充土壤水分
func add_moisture(world_pos: Vector3, amount: float) -> void:
	var key: String = _chunk_key(world_pos)
	if not _chunks.has(key):
		get_soil_at(world_pos)

	var chunk: SoilChunk = _chunks[key]
	var local: Vector2 = _world_to_local(world_pos)
	var gx: int = clampi(int(local.x / CHUNK_SIZE * 10), 0, 9)
	var gy: int = clampi(int(local.y / CHUNK_SIZE * 10), 0, 9)
	chunk.grid[gy][gx]["moisture"] = clampf(chunk.grid[gy][gx]["moisture"] + amount, 0.0, 1.0)

## 阳光蒸发
func evaporate(world_pos: Vector3, amount: float) -> void:
	add_moisture(world_pos, -amount)

func _chunk_key(pos: Vector3) -> String:
	var cx: int = floori(pos.x / CHUNK_SIZE)
	var cz: int = floori(pos.z / CHUNK_SIZE)
	return "%d_%d" % [cx, cz]

func _chunk_center(pos: Vector3) -> Vector3:
	var cx: int = floori(pos.x / CHUNK_SIZE)
	var cz: int = floori(pos.z / CHUNK_SIZE)
	return Vector3(cx * CHUNK_SIZE + CHUNK_SIZE / 2.0, 0, cz * CHUNK_SIZE + CHUNK_SIZE / 2.0)

func _world_to_local(pos: Vector3) -> Vector2:
	var cx: int = floori(pos.x / CHUNK_SIZE)
	var cz: int = floori(pos.z / CHUNK_SIZE)
	return Vector2(pos.x - cx * CHUNK_SIZE, pos.z - cz * CHUNK_SIZE)

## 获取活跃区块数
func get_active_chunk_count() -> int:
	return _chunks.size()

## 清理远离玩家的旧区块
func cleanup(max_chunks: int = 100) -> void:
	if _chunks.size() <= max_chunks:
		return
	var _now: float = Time.get_unix_time_from_system()
	var keys: Array = _chunks.keys()
	keys.sort_custom(func(a, b): return _chunks[a].last_updated < _chunks[b].last_updated)
	while _chunks.size() > max_chunks:
		_chunks.erase(keys.pop_front())
