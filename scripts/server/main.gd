# ============================================================
# ServerMain — Headless 服务端启动入口
# ============================================================
# 运行: godot --headless --path . server_main.tscn
# ============================================================
extends Node

var _server: ENetServer = null
var _authority: Authority = null
var _world: WorldGenerator = null
var _item_registry: ItemRegistry = null
var _season: SeasonWorld = null

func _ready() -> void:
	print("=== Silent Verse Server ===")
	print("Starting services...")

	# 保证数据已加载
	if not MaterialDB.is_loaded:
		MaterialDB.load_from_file("res://scripts/shared/data/materials.json")
	if not ReactionRegistry.is_loaded:
		ReactionRegistry.load_from_file("res://scripts/shared/data/reactions.json")

	print("Data loaded: ", MaterialDB.get_all_materials().size(), " materials, ",
		  ReactionRegistry.get_all_reactions().size(), " reactions")

	# 赛季世界：服务端唯一真源。种子保密、持久化，只有 --new-season 才重置。
	_season = SeasonWorld.new()
	var force_new := OS.get_cmdline_args().has("--new-season")
	if not _season.load_or_create(force_new):
		printerr("Failed to load/create season world")
		return
	print("Season: ", _season.season_id, " (world seed is server-only)")

	print("Generating world from season state...")
	_world = WorldGenerator.new(_season.seed_value, WorldGenerator.DEFAULT_PLANET_RADIUS)
	_world.max_elevation = WorldGenerator.DEFAULT_MAX_ELEVATION
	_world.generate()
	PhysicsConstants.configure_planet(_world.planet_radius)

	_item_registry = ItemRegistry.new()
	add_child(_item_registry)
	var world_items := WorldItemSpawner.generate(_world)
	var spawned_items := 0
	for item in world_items:
		var spawn_result := _item_registry.spawn(item)
		if spawn_result["ok"]:
			spawned_items += 1
		else:
			printerr("World item spawn failed: ", spawn_result["error"])
	print("World items: ", spawned_items, " / ", world_items.size(),
		", total mass ", _item_registry.get_total_mass_kg(), " kg")

	# 启动网络
	_server = ENetServer.new()
	add_child(_server)
	var err := _server.start()
	if err != OK:
		printerr("Failed to start server: ", err)
		return

	# 启动权威验证层
	_authority = Authority.new()
	add_child(_authority)
	_authority.setup(_server)

	print("Server ready. Players: ", _server.get_player_count())
	print("Listening on port ", _server.port)
