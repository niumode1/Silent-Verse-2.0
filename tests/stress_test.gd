# ============================================================
# Stress Test — 50 客户端并发压力测试
# ============================================================
# 运行: godot --headless --script tests/stress_test.gd
# 依赖: 服务端已启动在 127.0.0.1:7777
# ============================================================
extends Node

const CLIENT_COUNT := 50
const SERVER_ADDR := "127.0.0.1"
const SERVER_PORT := 7777

var _clients: Array = []          # {peer: ENetMultiplayerPeer, connected: bool}
var _actions_sent := 0
var _actions_received := 0
var _errors := 0
var _start_time: float = 0.0
var _pending_packets: int = 0

func _ready() -> void:
	print("=== Silent Verse 50-Client Stress Test ===")
	print("Target: ", SERVER_ADDR, ":", SERVER_PORT)
	print("Clients: ", CLIENT_COUNT)
	print()

	_start_time = Time.get_unix_time_from_system()

	# Phase 1: 并发连接
	print("[Phase 1] Connecting ", CLIENT_COUNT, " clients...")
	var connect_start: float = Time.get_unix_time_from_system()

	for i in range(CLIENT_COUNT):
		var peer: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
		var err: int = peer.create_client(SERVER_ADDR, SERVER_PORT)
		if err == OK:
			_clients.append({"peer": peer, "connected": false, "id": 0, "sent": 0, "received": 0})
			_pending_packets += 1
		else:
			_errors += 1
			if _errors <= 3:
				printerr("  Client ", i, " failed to create: err=", err)

		# 不 await，批量创建连接
		if i % 10 == 9:
			await get_tree().process_frame

	var connect_elapsed: float = Time.get_unix_time_from_system() - connect_start
	print("  Created ", _clients.size(), " connections in ", connect_elapsed, "s")

	# 等待所有连接建立 — 手动 poll 每个 peer
	print("  Waiting for handshakes...")
	for retry in range(30):
		var ready := 0
		for c in _clients:
			c["peer"].poll()
			if c["peer"].get_connection_status() == MultiplayerPeer.CONNECTION_CONNECTED:
				c["connected"] = true; ready += 1
		if ready >= 1:
			print("  Retry ", retry + 1, ": ", ready, "/", _clients.size())
		if ready == _clients.size():
			print("  All ", ready, " connected!")
			break
		if retry < 29:
			await get_tree().create_timer(0.1).timeout

	print("  Errors: ", _errors)
	print()

	# Phase 2: 发送动作
	print("[Phase 2] Sending test actions...")
	var action_start: float = Time.get_unix_time_from_system()

	for i in range(CLIENT_COUNT):
		var client: Dictionary = _clients[i]
		var peer: ENetMultiplayerPeer = client["peer"]

		# 检查连接状态
		var status: int = peer.get_connection_status()
		client["connected"] = (status == MultiplayerPeer.CONNECTION_CONNECTED)

		if not client["connected"]:
			continue
		peer.poll()

		# 发送挥击动作
		var pkt: String = NetworkPacket.make_action_request(NetworkPacket.ActionType.SWING, {
			"angular_velocity": 10.0 + randf() * 10.0,
			"lever_arm": 0.5 + randf() * 0.5,
			"target_id": "oak_wood",
			"target_type": "tree",
			"hit_position": {"x": randf(), "y": randf(), "z": randf() + 1.0}
		})
		peer.get_peer(1).put_packet(pkt.to_utf8_buffer())
		client["sent"] += 1
		_actions_sent += 1

		# 每 10 个客户端等一帧
		if i % 10 == 9:
			await get_tree().process_frame

	var action_elapsed: float = Time.get_unix_time_from_system() - action_start
	print("  Sent ", _actions_sent, " actions in ", action_elapsed, "s")

	# Phase 3: 接收服务端回应
	print("[Phase 3] Receiving responses...")
	await get_tree().create_timer(0.5).timeout

	for i in range(CLIENT_COUNT):
		var client: Dictionary = _clients[i]
		var peer: ENetMultiplayerPeer = client["peer"]
		if not client["connected"]:
			continue

		# 检查待处理的包
		peer.poll()
		var recv_count := 0
		while peer.get_available_packet_count() > 0:
			var packet: PackedByteArray = peer.get_packet()
			recv_count += 1
		client["received"] = recv_count
		_actions_received += recv_count

	# Phase 4: 持续负载测试 — 每秒发送一批
	print("[Phase 4] Sustained load — 5 seconds...")
	var sustained_sent := 0
	var sustained_recv := 0

	for second in range(1, 6):
		# 每客户端发送一个动作
		for i in range(CLIENT_COUNT):
			var client: Dictionary = _clients[i]
			if not client["connected"]:
				continue
			var peer: ENetMultiplayerPeer = client["peer"]
			var pkt: String = NetworkPacket.make_chat_message("stress_test_" + str(second), 50.0)
			peer.get_peer(1).put_packet(pkt.to_utf8_buffer())
			sustained_sent += 1

		await get_tree().create_timer(0.5).timeout

		# 接收
		for i in range(CLIENT_COUNT):
			var client: Dictionary = _clients[i]
			var peer: ENetMultiplayerPeer = client["peer"]
			if not client["connected"]:
				continue
			while peer.get_available_packet_count() > 0:
				peer.get_packet()
				sustained_recv += 1

		await get_tree().create_timer(0.5).timeout

	print("  Sustained: sent=", sustained_sent, " recv=", sustained_recv)

	# Phase 5: 统计
	var total_elapsed: float = Time.get_unix_time_from_system() - _start_time
	var connected_count := 0
	for c in _clients:
		if c["connected"]:
			connected_count += 1

	print()
	print("========================================")
	print("  Stress Test Results")
	print("========================================")
	print("  Total time:       ", total_elapsed, " s")
	print("  Clients connected: ", connected_count, "/", CLIENT_COUNT)
	print("  Actions sent:     ", _actions_sent)
	print("  Responses recv:   ", _actions_received)
	print("  Sustained sent:   ", sustained_sent)
	print("  Sustained recv:   ", sustained_recv)
	print("  Errors:           ", _errors)
	print("========================================")

	# 清理
	for c in _clients:
		var peer: ENetMultiplayerPeer = c["peer"]
		peer.close()

	if OS.has_feature("headless"):
		get_tree().quit(0 if connected_count >= CLIENT_COUNT * 0.8 else 1)
