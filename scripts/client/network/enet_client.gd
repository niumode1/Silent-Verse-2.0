# ============================================================
# ENetClient — ENet 客户端（信号驱动版）
# ============================================================
class_name ENetClient
extends Node

@export var server_address: String = "127.0.0.1"
@export var server_port: int = 7777

var is_connected: bool = false
var peer_id: int = 0
var _enet: ENetMultiplayerPeer = null
var nearby_players: Dictionary = {}

signal connected_to_server()
signal disconnected_from_server()
signal player_spawned(peer_id: int, pos: Vector3)
signal player_despawned(peer_id: int)
signal player_state_updated(peer_id: int, state: Dictionary)
signal action_result_received(action_data: Dictionary)
signal action_broadcast_received(action_data: Dictionary)
signal chat_received(peer_id: int, text: String)

func connect_to_server(address: String = "", port: int = 0) -> int:
	if address != "": server_address = address
	if port > 0: server_port = port
	_enet = ENetMultiplayerPeer.new()
	var err: int = _enet.create_client(server_address, server_port)
	if err != OK:
		printerr("ENetClient: Failed to connect err=", err)
		return err
	multiplayer.multiplayer_peer = _enet
	multiplayer.connected_to_server.connect(_on_ok)
	multiplayer.connection_failed.connect(_on_fail)
	multiplayer.server_disconnected.connect(_on_server_gone)
	multiplayer.peer_packet.connect(_on_peer_packet)
	return OK

func disconnect_from_server() -> void:
	if _enet: _enet.close(); _enet = null
	is_connected = false; nearby_players.clear()

func _on_ok() -> void:
	is_connected = true; peer_id = multiplayer.get_unique_id()
	print("ENetClient: Connected, peer_id=", peer_id)
	connected_to_server.emit()

func _on_fail() -> void:
	printerr("ENetClient: Connection failed"); is_connected = false

func _on_server_gone() -> void:
	print("ENetClient: Disconnected"); is_connected = false
	disconnected_from_server.emit()

func _on_peer_packet(pid: int, packet: PackedByteArray) -> void:
	var json_str: String = packet.get_string_from_utf8()
	var decoded: Dictionary = NetworkPacket.decode(json_str)
	if decoded.has("error"): return
	var pkt_type: int = decoded["type"]
	var payload: Dictionary = decoded["payload"]

	if pkt_type == NetworkPacket.Type.PLAYER_SPAWN:
		var pd: Dictionary = payload.get("position", {})
		player_spawned.emit(payload["peer_id"], Vector3(pd.get("x",0), pd.get("y",0), pd.get("z",0)))
	elif pkt_type == NetworkPacket.Type.PLAYER_DESPAWN:
		player_despawned.emit(payload["peer_id"])
	elif pkt_type == NetworkPacket.Type.PLAYER_STATE:
		var pid2: int = payload["peer_id"]; nearby_players[pid2] = payload
		player_state_updated.emit(pid2, payload)
	elif pkt_type == NetworkPacket.Type.ACTION_RESULT:
		action_result_received.emit(payload)
	elif pkt_type == NetworkPacket.Type.ACTION_BROADCAST:
		action_broadcast_received.emit(payload)
	elif pkt_type == NetworkPacket.Type.CHAT_MESSAGE:
		chat_received.emit(payload.get("peer_id", 0), payload.get("text", ""))

func send_packet(packet: String) -> void:
	if _enet and is_connected:
		_enet.get_peer(1).put_packet(packet.to_utf8_buffer())

func send_player_input(move_dir: Vector3, look_dir: Vector3, actions: Array = []) -> void:
	send_packet(NetworkPacket.make_player_input(move_dir, look_dir, actions))

func send_action_request(action_type: int, action_data: Dictionary) -> void:
	send_packet(NetworkPacket.make_action_request(action_type, action_data))

func send_chat(text: String, range_m: float = 50.0) -> void:
	send_packet(NetworkPacket.make_chat_message(text, range_m))

func send_ping() -> void:
	send_packet(NetworkPacket.encode(NetworkPacket.Type.PING, {"ts": Time.get_unix_time_from_system()}))
