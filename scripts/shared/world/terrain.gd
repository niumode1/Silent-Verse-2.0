# ============================================================
# Terrain — 规则驱动的球形行星地形
# ============================================================
# 不再用纯噪声决定大陆。生成顺序：
#   1. 球面板块（Voronoi）+ 板块运动方向
#   2. 汇聚边界抬升山脉，张裂边界形成裂谷/洋中脊，热点形成火山
#   3. 扩散侵蚀抹平尖峰
#   4. 按高度汇流，切出河谷
#   5. 按板块/边界/海拔/河流划分地质省
#   6. 采样时叠加小尺度细节噪声
# 同种子完全确定。
# ============================================================
class_name Terrain
extends RefCounted

# 地质省标志位
const PROV_SEDIMENTARY := 1
const PROV_VOLCANIC := 2
const PROV_METAMORPHIC := 4
const PROV_GRANITE := 8
const PROV_COASTAL := 16
const PROV_RIVER := 32

const GRID_W := 384
const GRID_H := 192
const PLATE_COUNT := 12
const CONTINENTAL_COUNT := 7
const HOTSPOT_COUNT := 4
const BOUNDARY_WIDTH := 0.12       # 板块边界影响宽度（以角距差计）
const RIVER_FLOW_THRESHOLD := 28.0

## 行星半径 m
var planet_radius: float = 3978.87

## 海平面以上最大高度 m
var max_elevation: float = 1000.0

## 海平面以下最大深度 m
var max_depth: float = 500.0

## 目标陆地比例（按纬度面积加权标定海平面）
var land_ratio_target: float = 0.4

var _seed_value: int = 0
var _built: bool = false

var _heights := PackedFloat32Array()
var _provinces := PackedByteArray()
var _river_strength := PackedFloat32Array()
var _plate_a := PackedInt32Array()
var _plate_b := PackedInt32Array()
var _edges := PackedFloat32Array()
var _boundary_types := PackedByteArray()   # 0 none, 1 convergent, 2 divergent, 3 transform
var _hotspot_strength := PackedFloat32Array()

var _plates: Array = []
var _hotspots: Array = []
var _medium_noise: FastNoiseLite = null
var _detail_noise: FastNoiseLite = null


func _init(p_radius: float = 3978.87, p_seed: int = 0) -> void:
	planet_radius = p_radius
	_seed_value = p_seed


# ============================================================
# 构建
# ============================================================

func build() -> void:
	_built = false
	_setup_noise()

	var rng := RandomNumberGenerator.new()
	rng.seed = _seed_value
	_generate_plates(rng)
	_build_grid()
	_smooth_grid()
	_normalize_sea_level()
	_compute_rivers()
	_classify_provinces()
	_built = true


func reseed(new_seed: int) -> void:
	_seed_value = new_seed
	build()


func _ensure_built() -> void:
	if not _built:
		build()


func _setup_noise() -> void:
	_medium_noise = FastNoiseLite.new()
	_medium_noise.seed = _seed_value + 101
	_medium_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_medium_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_medium_noise.fractal_octaves = 2
	_medium_noise.frequency = 3.5

	_detail_noise = FastNoiseLite.new()
	_detail_noise.seed = _seed_value + 102
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_detail_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	_detail_noise.fractal_octaves = 2
	_detail_noise.frequency = 9.0


func _generate_plates(rng: RandomNumberGenerator) -> void:
	_plates.clear()
	_hotspots.clear()

	var continental_slots: Array = []
	for i in range(PLATE_COUNT):
		continental_slots.append(i < CONTINENTAL_COUNT)
	# 用自带 RNG 洗牌，保证确定性
	for i in range(continental_slots.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp = continental_slots[i]
		continental_slots[i] = continental_slots[j]
		continental_slots[j] = tmp

	for i in range(PLATE_COUNT):
		var dir := _random_direction(rng)
		var continental: bool = continental_slots[i]
		var base: float = rng.randf_range(60.0, 150.0) if continental else rng.randf_range(-420.0, -180.0)
		var motion := _random_tangent(dir, rng) * rng.randf_range(0.6, 1.0)
		_plates.append({
			"dir": dir,
			"oceanic": not continental,
			"base": base,
			"motion": motion,
		})

	for i in range(HOTSPOT_COUNT):
		_hotspots.append({
			"dir": _random_direction(rng),
			"radius": deg_to_rad(rng.randf_range(2.5, 7.0)),
			"strength": rng.randf_range(250.0, 500.0),
		})


func _build_grid() -> void:
	var n := GRID_W * GRID_H
	_heights.resize(n)
	_provinces.resize(n)
	_river_strength.resize(n)
	_plate_a.resize(n)
	_plate_b.resize(n)
	_edges.resize(n)
	_boundary_types.resize(n)
	_hotspot_strength.resize(n)

	for y in range(GRID_H):
		var lat: float = -90.0 + (float(y) + 0.5) * 180.0 / float(GRID_H)
		for x in range(GRID_W):
			var lon: float = (float(x) + 0.5) * 360.0 / float(GRID_W)
			var dir := _latlon_dir(lat, lon)

			var best := INF
			var second := INF
			var ia := -1
			var ib := -1
			for i in range(_plates.size()):
				var d: float = 1.0 - dir.dot(_plates[i]["dir"])
				if d < best:
					second = best
					ib = ia
					best = d
					ia = i
				elif d < second:
					second = d
					ib = i

			var edge: float = 1.0 - smoothstep(0.0, BOUNDARY_WIDTH, second - best)
			var pa: Dictionary = _plates[ia]
			var pb: Dictionary = _plates[ib]
			var motion_dot: float = (pa["motion"] as Vector3).dot(pb["motion"] as Vector3)
			var boundary_type := 0
			if motion_dot < -0.15:
				boundary_type = 1     # 汇聚
			elif motion_dot > 0.15:
				boundary_type = 2     # 张裂
			else:
				boundary_type = 3     # 转换

			var height: float = float(pa["base"])
			var pa_oceanic: bool = pa["oceanic"]
			var pb_oceanic: bool = pb["oceanic"]

			if boundary_type == 1:
				if pa_oceanic != pb_oceanic:
					if not pa_oceanic:
						height += 450.0 * pow(edge, 1.4)   # 大陆侧海岸山脉
					else:
						height -= 250.0 * pow(edge, 1.2)   # 海洋侧海沟
				elif pa_oceanic:
					height += 350.0 * pow(edge, 1.4)       # 洋-洋岛弧
				else:
					height += 500.0 * pow(edge, 1.6)       # 陆-陆碰撞山脉
			elif boundary_type == 2:
				if pa_oceanic and pb_oceanic:
					height += 150.0 * pow(edge, 1.5)       # 洋中脊
				else:
					height -= 180.0 * pow(edge, 1.2)       # 大陆裂谷
			else:
				height += 30.0 * edge

			var hot := 0.0
			for hs in _hotspots:
				var angle: float = acos(clampf(dir.dot(hs["dir"] as Vector3), -1.0, 1.0))
				var radius: float = hs["radius"]
				if angle < radius:
					var profile: float = 1.0 - angle / radius
					height += float(hs["strength"]) * profile * profile
					hot = maxf(hot, profile)

			height += _medium_noise.get_noise_3d(dir.x, dir.y, dir.z) * 25.0
			height = clampf(height, -max_depth, max_elevation)

			var idx := y * GRID_W + x
			_heights[idx] = height
			_plate_a[idx] = ia
			_plate_b[idx] = ib
			_edges[idx] = edge
			_boundary_types[idx] = boundary_type
			_hotspot_strength[idx] = hot


func _smooth_grid() -> void:
	var n := GRID_W * GRID_H
	for pass_index in range(2):
		var smoothed := _heights.duplicate()
		for y in range(GRID_H):
			for x in range(GRID_W):
				var idx := y * GRID_W + x
				var total: float = _heights[idx] * 0.40
				var weight: float = 0.40
				for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
					var nx: int = ((x + offset.x) % GRID_W + GRID_W) % GRID_W
					var ny: int = clampi(y + offset.y, 0, GRID_H - 1)
					total += _heights[ny * GRID_W + nx] * 0.15
					weight += 0.15
				smoothed[idx] = total / weight
		_heights = smoothed


func _normalize_sea_level() -> void:
	var n := GRID_W * GRID_H
	var samples: Array[Vector2] = []
	var total_weight: float = 0.0
	for y in range(GRID_H):
		var lat: float = -90.0 + (float(y) + 0.5) * 180.0 / float(GRID_H)
		var weight: float = maxf(cos(deg_to_rad(lat)), 0.0001)
		for x in range(GRID_W):
			samples.append(Vector2(_heights[y * GRID_W + x], weight))
			total_weight += weight

	samples.sort_custom(func(a: Vector2, b: Vector2) -> bool: return a.x < b.x)
	var target_weight: float = total_weight * (1.0 - clampf(land_ratio_target, 0.05, 0.95))
	var cumulative: float = 0.0
	var sea_level: float = 0.0
	for sample in samples:
		cumulative += sample.y
		if cumulative >= target_weight:
			sea_level = sample.x
			break

	for idx in range(n):
		_heights[idx] = clampf(_heights[idx] - sea_level, -max_depth, max_elevation)


func _compute_rivers() -> void:
	var n := GRID_W * GRID_H
	var flow := PackedFloat32Array()
	flow.resize(n)
	flow.fill(1.0)

	var down := PackedInt32Array()
	down.resize(n)
	down.fill(-1)

	for y in range(GRID_H):
		for x in range(GRID_W):
			var idx := y * GRID_W + x
			var lowest: float = _heights[idx]
			var low_idx := -1
			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx: int = ((x + dx) % GRID_W + GRID_W) % GRID_W
					var ny: int = clampi(y + dy, 0, GRID_H - 1)
					var ni := ny * GRID_W + nx
					if _heights[ni] < lowest:
						lowest = _heights[ni]
						low_idx = ni
			down[idx] = low_idx

	var order: Array = []
	for i in range(n):
		order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		if _heights[a] == _heights[b]:
			return a > b
		return _heights[a] > _heights[b])

	for idx in order:
		var d: int = down[idx]
		if d >= 0:
			flow[d] += flow[idx]

	_river_strength.resize(n)
	_river_strength.fill(0.0)
	for idx in range(n):
		if flow[idx] > RIVER_FLOW_THRESHOLD and _heights[idx] > 0.0:
			var strength: float = clampf(
				(flow[idx] / RIVER_FLOW_THRESHOLD - 1.0) / 6.0, 0.0, 1.0)
			_river_strength[idx] = strength
			_heights[idx] -= minf(18.0, strength * 18.0)


func _classify_provinces() -> void:
	var n := GRID_W * GRID_H
	_provinces.resize(n)
	_provinces.fill(0)

	for idx in range(n):
		var h: float = _heights[idx]
		var flags := 0
		if absf(h) < 20.0:
			flags |= PROV_COASTAL

		if h > 0.0:
			if _river_strength[idx] > 0.0:
				flags |= PROV_RIVER

			var pa: Dictionary = _plates[_plate_a[idx]]
			var pb: Dictionary = _plates[_plate_b[idx]]
			var pa_oceanic: bool = pa["oceanic"]
			var pb_oceanic: bool = pb["oceanic"]
			var boundary: int = _boundary_types[idx]
			var edge: float = _edges[idx]
			var hot: float = _hotspot_strength[idx]

			if boundary == 1 and edge > 0.30:
				if pa_oceanic and pb_oceanic:
					flags |= PROV_VOLCANIC
				elif not pa_oceanic:
					flags |= PROV_VOLCANIC
			if hot > 0.15:
				flags |= PROV_VOLCANIC

			if boundary == 1 and edge > 0.40 and not pa_oceanic:
				flags |= PROV_METAMORPHIC
			if h > 220.0:
				flags |= PROV_METAMORPHIC

			if boundary == 1 and edge > 0.30 and not pa_oceanic and not pb_oceanic and h > 100.0:
				flags |= PROV_GRANITE

			if not pa_oceanic and h < 170.0 and edge < 0.60 and hot < 0.10:
				flags |= PROV_SEDIMENTARY

		_provinces[idx] = flags


# ============================================================
# 查询
# ============================================================

func get_height_ratio(position: Vector3) -> float:
	var elev := get_elevation(position)
	if elev >= 0.0:
		return elev / maxf(max_elevation, 0.001)
	return elev / maxf(max_depth, 0.001)


func get_elevation(position: Vector3) -> float:
	_ensure_built()
	var dir := position.normalized()
	var base := _sample_bilinear(_heights, dir)
	var detail: float = _detail_noise.get_noise_3d(dir.x, dir.y, dir.z) * 12.0
	return clampf(base + detail, -max_depth, max_elevation)


func get_surface_radius(position: Vector3) -> float:
	return planet_radius + get_elevation(position)


func is_land(position: Vector3) -> bool:
	return get_elevation(position) >= 0.0


func get_latitude(position: Vector3) -> float:
	return rad_to_deg(asin(clampf(position.normalized().y, -1.0, 1.0)))


func get_river_strength(position: Vector3) -> float:
	_ensure_built()
	return _sample_bilinear(_river_strength, position.normalized())


func get_province(position: Vector3) -> Dictionary:
	_ensure_built()
	var idx := _nearest_index(position.normalized())
	return {
		"flags": int(_provinces[idx]),
		"plate_id": _plate_a[idx],
		"boundary": _boundary_types[idx],
		"river": _river_strength[idx],
		"height": _heights[idx],
	}


func get_plate_count() -> int:
	_ensure_built()
	return _plates.size()


func get_hotspot_count() -> int:
	_ensure_built()
	return _hotspots.size()


# ============================================================
# 采样工具
# ============================================================

func _latlon_dir(lat_deg: float, lon_deg: float) -> Vector3:
	var phi := deg_to_rad(90.0 - lat_deg)
	var theta := deg_to_rad(lon_deg)
	var s := sin(phi)
	return Vector3(s * cos(theta), cos(phi), s * sin(theta))


func _grid_coords(dir: Vector3) -> Vector2:
	var lat: float = rad_to_deg(asin(clampf(dir.y, -1.0, 1.0)))
	var lon: float = rad_to_deg(atan2(dir.z, dir.x))
	if lon < 0.0:
		lon += 360.0
	var gx: float = lon / 360.0 * float(GRID_W) - 0.5
	var gy: float = (lat + 90.0) / 180.0 * float(GRID_H) - 0.5
	return Vector2(gx, gy)


func _nearest_index(dir: Vector3) -> int:
	var coords := _grid_coords(dir)
	var x: int = int(round(coords.x))
	x = ((x % GRID_W) + GRID_W) % GRID_W
	var y: int = clampi(int(round(coords.y)), 0, GRID_H - 1)
	return y * GRID_W + x


func _sample_bilinear(values, dir: Vector3) -> float:
	var coords := _grid_coords(dir)
	var gx := coords.x
	var gy := coords.y
	var x0 := int(floor(gx))
	var y0 := int(floor(gy))
	var fx := gx - float(x0)
	var fy := gy - float(y0)

	var x0w: int = ((x0 % GRID_W) + GRID_W) % GRID_W
	var x1w: int = ((x0 + 1) % GRID_W + GRID_W) % GRID_W
	var y0c: int = clampi(y0, 0, GRID_H - 1)
	var y1c: int = clampi(y0 + 1, 0, GRID_H - 1)

	var v00: float = values[y0c * GRID_W + x0w]
	var v01: float = values[y0c * GRID_W + x1w]
	var v10: float = values[y1c * GRID_W + x0w]
	var v11: float = values[y1c * GRID_W + x1w]
	var top: float = lerpf(v00, v01, fx)
	var bottom: float = lerpf(v10, v11, fx)
	return lerpf(top, bottom, fy)


func _random_direction(rng: RandomNumberGenerator) -> Vector3:
	var theta := rng.randf() * TAU
	var phi := acos(2.0 * rng.randf() - 1.0)
	return Vector3(sin(phi) * cos(theta), cos(phi), sin(phi) * sin(theta))


func _random_tangent(dir: Vector3, rng: RandomNumberGenerator) -> Vector3:
	var reference := Vector3.UP
	if absf(dir.dot(reference)) > 0.99:
		reference = Vector3.RIGHT
	var tangent := dir.cross(reference).normalized()
	return tangent.rotated(dir, rng.randf() * TAU).normalized()
