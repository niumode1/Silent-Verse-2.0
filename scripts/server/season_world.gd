# ============================================================
# SeasonWorld — 赛季世界种子与持久化（仅服务端）
# ============================================================
# 地形/资源只在赛季开始时生成一次。种子由服务端随机生成并保存在
# 服务端 user:// 目录，不发送给客户端，也不打印到日志。
# 管理员用 --new-season 启动服务端才会重置世界。
# ============================================================
class_name SeasonWorld
extends RefCounted

const SAVE_PATH := "user://season_world.json"
const SAVE_VERSION := 1

var season_id: String = ""
var seed_value: int = 0
var created_unix: int = 0

## 加载已有赛季；不存在或 force_new 时创建新赛季
func load_or_create(force_new: bool = false) -> bool:
	if not force_new and FileAccess.file_exists(SAVE_PATH):
		if _load():
			return true
	return create_new()


func create_new() -> bool:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	seed_value = rng.randi_range(1, 2_000_000_000)
	created_unix = int(Time.get_unix_time_from_system())
	season_id = "S" + str(created_unix) + "-" + str(seed_value % 100000)
	return save()


func reset() -> bool:
	return create_new()


func save() -> bool:
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		printerr("SeasonWorld: cannot write ", SAVE_PATH)
		return false
	var data := {
		"version": SAVE_VERSION,
		"season_id": season_id,
		"seed": seed_value,
		"created_unix": created_unix,
	}
	file.store_string(JSON.stringify(data, "  "))
	file.close()
	return true


func _load() -> bool:
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return false
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		printerr("SeasonWorld: invalid save, starting a new season")
		return false
	var data: Dictionary = parsed
	if int(data.get("version", 0)) != SAVE_VERSION:
		printerr("SeasonWorld: save version mismatch, starting a new season")
		return false
	var saved_seed := int(data.get("seed", 0))
	if saved_seed <= 0:
		printerr("SeasonWorld: invalid seed in save")
		return false
	seed_value = saved_seed
	season_id = String(data.get("season_id", "S" + str(seed_value % 100000)))
	created_unix = int(data.get("created_unix", 0))
	return true
