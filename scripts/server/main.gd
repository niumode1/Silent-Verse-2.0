# ============================================================
# ServerMain — Headless 服务端启动入口
# ============================================================
# 运行: godot --headless --path . server_main.tscn
# ============================================================
extends Node

var _server: ENetServer = null
var _authority: Authority = null

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
