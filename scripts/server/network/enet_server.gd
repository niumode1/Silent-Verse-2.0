# ============================================================
# ENetServer — ENet 服务端（信号驱动版）
# ============================================================
class_name ENetServer
extends Node

@export var port: int = 7777
@export var max_clients: int = 50
@export var sync_range: float = 200.0

var is_running: bool = false
var _enet: ENetMultiplayerPeer = null
var _players: Dictionary = {}

signal player_connected(peer_id: int)
signal player_disconnected(peer_id: int)
signal action_received(peer_id: int, action_type: int, data: Dictionary)
signal chat_received(peer_id: int, text: String, position: Vector3)

func start() -> int:
	_enet = ENetMultiplayerPeer.new()
	var err: int = _enet.create_server(port, max_clients)
	if err != OK:
		printerr("ENetServer: Failed to start on port ", port, " error=", err)
		return err

	multiplayer.multiplayer_peer = _enet
	is_running = true
	print("ENetServer: Listening on port ", port, " max_clients=", max_clients)

	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.peer_packet.connect(_on_peer_packet)

	return OK

func stop() -> void:
	if _enet:
		_enet.close()
		_enet = null
	is_running = false
	_players.clear()
	print("ENetServer: Stopped")

func _on_peer_packet(peer_id: int, packet: PackedByteArray) -> void:
	_handle_packet(peer_id, packet)

func _on_peer_connected(peer_id: int) -> void:
	print("ENetServer: Peer connected: ", peer_id)
	_players[peer_id] = {"position": Vector3.ZERO, "rotation": Vector3.ZERO}
	player_connected.emit(peer_id)
	var spawn: String = NetworkPacket.encode(NetworkPacket.Type.PLAYER_SPAWN, {
		"peer_id": peer_id, "position": {"x": 0, "y": 0, "z": 0}
	})
	broadcast_except(spawn, peer_id)

func _on_peer_disconnected(peer_id: int) -> void:
	print("ENetServer: Peer disconnected: ", peer_id)
	player_disconnected.emit(peer_id)
	_players.erase(peer_id)

func send_to(peer_id: int, packet: String) -> void:
	if not is_running or peer_id <= 0:
		return
	if not _players.has(peer_id):
		return
	var p: ENetPacketPeer = _enet.get_peer(peer_id)
	if p == null or p.get_state() != ENetPacketPeer.STATE_CONNECTED:
		_players.erase(peer_id)
		return
	p.put_packet(packet.to_utf8_buffer())

func broadcast(packet: String) -> void:
	for peer_id in _players.keys():
		send_to(peer_id, packet)

func broadcast_except(packet: String, exclude_peer: int) -> void:
	for peer_id in _players.keys():
		if peer_id != exclude_peer:
			send_to(peer_id, packet)

func broadcast_nearby(packet: String, origin: Vector3, range_m: float = sync_range) -> void:
	for peer_id in _players.keys():
		var player: Dictionary = _players[peer_id]
		if origin.distance_to(player["position"]) <= range_m:
			send_to(peer_id, packet)

func broadcast_nearby_except(packet: String, origin: Vector3, exclude_peer: int, range_m: float = sync_range) -> void:
	for peer_id in _players.keys():
		if peer_id == exclude_peer:
			continue
		var player: Dictionary = _players[peer_id]
		if origin.distance_to(player["position"]) <= range_m:
			send_to(peer_id, packet)

func _handle_packet(peer_id: int, packet: PackedByteArray) -> void:
	var json_str: String = packet.get_string_from_utf8()
	var decoded: Dictionary = NetworkPacket.decode(json_str)
	if decoded.has("error"):
		printerr("ENetServer: decode error from ", peer_id, ": ", decoded["error"])
		return

	var pkt_type: int = decoded["type"]
	var payload: Dictionary = decoded["payload"]

	if pkt_type == NetworkPacket.Type.PLAYER_INPUT:
		_handle_player_input(peer_id, payload)
	elif pkt_type == NetworkPacket.Type.ACTION_REQUEST:
		print("  >>> ACTION_REQUEST from peer ", peer_id, " action=", payload.get("action", -1))
		action_received.emit(peer_id, payload["action"], payload["data"])
	elif pkt_type == NetworkPacket.Type.CHAT_MESSAGE:
		chat_received.emit(peer_id, payload["text"], _get_pos(peer_id))

func _handle_player_input(peer_id: int, payload: Dictionary) -> void:
	var move: Dictionary = payload.get("move", {})
	var look: Dictionary = payload.get("look", {})
	if _players.has(peer_id):
		_players[peer_id]["position"] = Vector3(move.get("x", 0), move.get("y", 0), move.get("z", 0))
		_players[peer_id]["rotation"] = Vector3(look.get("x", 0), look.get("y", 0), look.get("z", 0))

func get_player_count() -> int:
	return _players.size()

func _get_pos(peer_id: int) -> Vector3:
	if _players.has(peer_id):
		return _players[peer_id]["position"]
	return Vector3.ZERO

func update_player_position(peer_id: int, pos: Vector3) -> void:
	if _players.has(peer_id):
		_players[peer_id]["position"] = pos
