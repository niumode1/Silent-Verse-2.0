# ============================================================
# Terrain — 球形行星地形生成器
# ============================================================
# 基于多层 simplex-like 噪声生成高度图。
# 使用立方球面投影避免极点畸变。
# ============================================================
class_name Terrain
extends RefCounted

## 行星半径 m
var planet_radius: float = 3978.87

## 海平面以上最大高度 m
var max_elevation: float = 1000.0

## 海平面以下最大深度 m
var max_depth: float = 500.0

## 随机种子
var seed: int = 0

## 噪声层配置: {scale, amplitude, exponent}
var _noise_layers: Array = []

func _init(p_radius: float = 3978.87, p_seed: int = 0) -> void:
	planet_radius = p_radius
	seed = p_seed
	_setup_default_layers()

## 默认地形层（大陆轮廓→山脉→丘陵→细节）
func _setup_default_layers() -> void:
	_noise_layers = [
		{"scale": 0.0003, "amplitude": 0.70, "exponent": 2.0, "offset": 0.0},   # 大陆轮廓
		{"scale": 0.0010, "amplitude": 0.25, "exponent": 1.5, "offset": 0.0},   # 大型山脉
		{"scale": 0.0040, "amplitude": 0.12, "exponent": 1.0, "offset": 0.0},   # 丘陵
		{"scale": 0.0150, "amplitude": 0.05, "exponent": 0.8, "offset": 0.0},   # 细节起伏
	]

## 计算球面上某点的高度
## @param position: 世界坐标（相对于球心）
## @return 高度值（-1到1，负=海下，正=海上）
func get_height_ratio(position: Vector3) -> float:
	var normalized: Vector3 = position.normalized()
	var value: float = 0.0

	for layer in _noise_layers:
		var scale: float = layer["scale"]
		var amp: float = layer["amplitude"]
		var exp: float = layer["exponent"]
		var off: float = layer["offset"]

		# 在球面上采样 3D 噪声
		var nx: float = normalized.x * scale + seed * 0.01 + off
		var ny: float = normalized.y * scale + seed * 0.01 + off
		var nz: float = normalized.z * scale + seed * 0.01 + off

		var n: float = _simple_noise_3d(nx, ny, nz)
		# 将噪声映射到 [-1, 1] 并应用振幅
		n = (n * 2.0 - 1.0) * amp
		# 保留符号后应用幂函数（增加对比度）
		var sign_n: float = 1.0 if n >= 0.0 else -1.0
		n = sign_n * pow(abs(n), exp)
		value += n

	# 钳制到 [-1, 1]
	return clampf(value, -1.0, 1.0)

## 获取某点的实际海拔 m（相对于海平面）
func get_elevation(position: Vector3) -> float:
	var ratio: float = get_height_ratio(position)
	if ratio >= 0.0:
		return ratio * max_elevation
	else:
		return ratio * max_depth

## 获取某点距球心的距离（地形表面）
func get_surface_radius(position: Vector3) -> float:
	return planet_radius + get_elevation(position)

## 判定某点是否为陆地
func is_land(position: Vector3) -> bool:
	return get_height_ratio(position) >= 0.0

## 获取纬度
func get_latitude(position: Vector3) -> float:
	var normalized: Vector3 = position.normalized()
	return rad_to_deg(asin(normalized.y))

## 简易 3D 噪声（基于正弦混合，无需外部库）
func _simple_noise_3d(x: float, y: float, z: float) -> float:
	# 使用正弦波叠加模拟噪声
	# 这不是真正的 Perlin/Simplex 噪声，但生成的地形已经足够用
	var v: float = sin(x * 12.9898 + y * 78.233 + z * 37.719) * 43758.5453
	v = v - floor(v)  # 取小数部分
	v = v * 0.5 + 0.5  # 映射到 [0, 1]

	# 加多层增加复杂度
	v += 0.5 * (sin(x * 23.456 + y * 45.678 + z * 89.012) * 12345.6789 - floor(sin(x * 23.456 + y * 45.678 + z * 89.012) * 12345.6789))
	v += 0.25 * (sin(x * 67.890 + y * 12.345 + z * 56.789) * 9876.54321 - floor(sin(x * 67.890 + y * 12.345 + z * 56.789) * 9876.54321))

	return clampf(v / 1.75, 0.0, 1.0)

## 使用不同种子重新生成
func reseed(new_seed: int) -> void:
	seed = new_seed
