# ============================================================
# NetworkPacket — 网络数据包常量与工具
# ============================================================
# 职责：定义客户端与服务端之间的通信协议。
# Phase 1 用 JSON 序列化，后续可换二进制以节省带宽。
# ============================================================
class_name NetworkPacket
extends RefCounted

# ============================================================
# 包类型枚举
# ============================================================

enum Type {
	# 连接
	CONNECT_REQUEST,       # 客户端 → 服务端：请求连接
	CONNECT_ACCEPT,        # 服务端 → 客户端：连接接受
	CONNECT_REJECT,        # 服务端 → 客户端：连接拒绝

	# 玩家状态
	PLAYER_SPAWN,          # 服务端 → 客户端：新玩家（含自己）出现
	PLAYER_DESPAWN,        # 服务端 → 客户端：玩家离开
	PLAYER_STATE,          # 服务端 → 客户端：附近玩家状态同步
	PLAYER_INPUT,          # 客户端 → 服务端：玩家输入/动作

	# 动作请求（客户端请求 → 服务端验证 → 广播结果）
	ACTION_REQUEST,        # 客户端 → 服务端：请求执行动作
	ACTION_RESULT,         # 服务端 → 客户端：动作结果（对请求者）
	ACTION_BROADCAST,      # 服务端 → 附近客户端：动作事件广播

	# 世界状态
	WORLD_CHUNK_REQUEST,   # 客户端 → 服务端：请求区域数据
	WORLD_CHUNK_DATA,      # 服务端 → 客户端：区域数据

	# 通信
	CHAT_MESSAGE,          # 双向：范围文字消息
	VOICE_SIGNAL,          # 双向：WebRTC 信令

	# 系统
	PING,                  # 双向：心跳
	PONG,                  # 双向：心跳回复
	DISCONNECT,            # 双向：断开通知
}

# ============================================================
# 动作类型（ACTION_REQUEST 的子类型）
# ============================================================

enum ActionType {
	MOVE,
	LOOK,
	SWING,               # 挥击（砍/打）
	INTERACT,            # 交互（捡/放/用）
	BUILD,               # 建造
	CHAT,
	EQUIP,
	UNEQUIP,
	DROP,
	PICKUP,
	EAT,
	DRINK,
}

# ============================================================
# 序列化
# ============================================================

## 将包编码为 JSON 字符串
static func encode(packet_type: int, payload: Dictionary) -> String:
	var data := {
		"t": packet_type,
		"ts": Time.get_unix_time_from_system(),
		"p": payload
	}
	return JSON.stringify(data)

## 解码 JSON 字符串为包
static func decode(json_str: String) -> Dictionary:
	var json := JSON.new()
	var err := json.parse(json_str)
	if err != OK:
		return {"error": "parse_failed", "message": json.get_error_message()}
	var data: Dictionary = json.get_data()
	if not data.has("t"):
		return {"error": "missing_type"}
	return {
		"type": data["t"],
		"timestamp": data.get("ts", 0.0),
		"payload": data.get("p", {})
	}

# ============================================================
# 常见包的快捷构造
# ============================================================

## 构造动作请求包
static func make_action_request(action_type: int, action_data: Dictionary) -> String:
	return encode(Type.ACTION_REQUEST, {
		"action": action_type,
		"data": action_data
	})

## 构造玩家输入包
static func make_player_input(move_dir: Vector3, look_dir: Vector3, actions: Array) -> String:
	return encode(Type.PLAYER_INPUT, {
		"move": {"x": move_dir.x, "y": move_dir.y, "z": move_dir.z},
		"look": {"x": look_dir.x, "y": look_dir.y, "z": look_dir.z},
		"actions": actions
	})

## 构造聊天消息包
static func make_chat_message(text: String, range_m: float) -> String:
	return encode(Type.CHAT_MESSAGE, {
		"text": text,
		"range": range_m
	})
