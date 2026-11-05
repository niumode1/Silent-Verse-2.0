# ============================================================
# ItemEntity — 世界中的物理物品实体
# ============================================================
# 职责：表示一件真实存在于世界里的物品。物品不是背包里的数据条目，
# 而是有材质、几何、质量、温度和位置（世界/手/绑扎/空腔）的物理实体。
#
# 质量与体积永远由「材料密度 × 几何」推导，不手填。
# 构造物（玩家拼装/编织出的东西）用 parts + connections 表示，
# 其质量是各部件质量之和。
# ============================================================
class_name ItemEntity
extends RefCounted

# ============================================================
# 标识与几何
# ============================================================

## 服务端分配的唯一 ID，存档后保持不变
var item_id: int = 0

## 材质 ID（单一均质物品使用；构造物由各部件自带材质）
var material_id: String = ""

## 几何形状：block / plank / rod / blade / wedge / sphere / fiber / granular
var shape: String = "block"

## 尺寸，单位米。不同形状读取不同键：
## box 类：length / width / height；sphere：radius；fiber：length / diameter
## 任意形状可用 volume_m3 直接指定不规则体积
var dimensions: Dictionary = {"length": 0.1, "width": 0.1, "height": 0.1}

## 构造物部件。空数组 = 单一均质物品
## 每个部件：{material_id, shape, dimensions, position?}
var parts: Array = []

## 部件之间的连接/编织关系（交给 ConstructionValidator / ContainmentEvaluator）
var connections: Array = []

## 自定义几何（切割/雕刻后的网格）。非空时渲染与碰撞都以这个网格为准；
## 切割产生的每一块都应是独立 ItemEntity，各自带自己的网格与碰撞体。
var custom_mesh: Mesh = null

## 世界变换（位置与朝向）
var transform: Transform3D = Transform3D.IDENTITY

# ============================================================
# 状态
# ============================================================

var temperature_c: float = 20.0
var wetness: float = 0.0          # 0-1，吸附水/雨/血
var oil_film: float = 0.0         # 0-1，油脂/动物脂肪
var third_body: String = ""       # "mud" / "sand" / "ash" / "blood" / ""
var wear: float = 0.0             # 0-1，表面磨损/抛光程度
var integrity: float = 1.0        # 0-1，结构完整度

## 磨尖后的尖端半径 m；-1 = 未加工
var tip_radius_m: float = -1.0

## 表面粗糙度 µm；-1 = 使用材料默认值
var surface_roughness_um: float = -1.0

## 局部坐标下的纹路方向（木纹/纤维/层理）；零向量 = 各向同性或未指定
var grain_dir_local: Vector3 = Vector3.ZERO

## 握持点在局部坐标下的位置；用于计算力矩
var grip_point_local: Vector3 = Vector3.ZERO

## 位置：{"kind": "world"|"hand"|"attached"|"inside", ...}
var location: Dictionary = {"kind": "world"}

# ============================================================
# 材料与质量
# ============================================================

func get_material() -> MaterialProperty:
	return ItemGeometry.part_material({"material_id": material_id})

## 总体积 m³。构造物 = 各部件体积之和
func get_volume_m3() -> float:
	if not parts.is_empty():
		return ItemGeometry.assembly_volume(parts)
	return ItemGeometry.shape_volume(shape, dimensions)

## 总质量 kg。单一物品 = 密度 × 体积；构造物 = 各部件质量之和
func get_mass_kg() -> float:
	if not parts.is_empty():
		return ItemGeometry.assembly_mass(parts)

	var mat := get_material()
	if mat == null:
		return 0.0
	return mat.density * get_volume_m3()

## 局部坐标下的质心。单一均质物品的几何原点即质心
func get_center_of_mass_local() -> Vector3:
	if parts.is_empty():
		return Vector3.ZERO

	var total_mass: float = 0.0
	var weighted := Vector3.ZERO
	for part in parts:
		var m: float = ItemGeometry.part_mass(part)
		total_mass += m
		weighted += _part_position(part) * m

	if total_mass <= 0.0:
		return Vector3.ZERO
	return weighted / total_mass

## 握点到质心的距离 m，用于腕部力矩判定
func get_grip_lever_m() -> float:
	return (get_center_of_mass_local() - grip_point_local).length()

# ============================================================
# 表面状态（摩擦模型输入）
# ============================================================

func get_surface_state() -> Dictionary:
	var mat := get_material()
	var default_roughness: float = mat.surface_roughness_um if mat != null else 10.0
	return {
		"material_id": material_id,
		"roughness_um": surface_roughness_um if surface_roughness_um >= 0.0 else default_roughness,
		"grain_dir": grain_dir_local,
		"wetness": wetness,
		"oil_film": oil_film,
		"third_body": third_body,
		"temperature_c": temperature_c,
		"wear": wear,
	}

# ============================================================
# 位置
# ============================================================

func is_in_world() -> bool:
	return location.get("kind", "") == "world"

func set_in_world(new_transform: Transform3D = Transform3D.IDENTITY) -> void:
	transform = new_transform
	location = {"kind": "world"}

func set_in_hand(holder_id: int, hand: String) -> void:
	location = {"kind": "hand", "holder_id": holder_id, "hand": hand}

func set_attached(holder_id: int, attachment_index: int) -> void:
	location = {"kind": "attached", "holder_id": holder_id, "attachment_index": attachment_index}

func set_inside(assembly_id: int, cavity_id: int) -> void:
	location = {"kind": "inside", "assembly_id": assembly_id, "cavity_id": cavity_id}

# ============================================================
# 校验
# ============================================================

func validate() -> Dictionary:
	var errors: Array[String] = []

	if item_id <= 0:
		errors.append("item_id must be positive")
	if parts.is_empty() and not MaterialDB.has_material(material_id):
		errors.append("unknown material_id: " + material_id)
	if get_volume_m3() <= 0.0:
		errors.append("volume must be positive")
	if get_mass_kg() <= 0.0:
		errors.append("mass must be positive")
	if integrity < 0.0 or integrity > 1.0:
		errors.append("integrity must be in [0, 1]")
	if wetness < 0.0 or wetness > 1.0:
		errors.append("wetness must be in [0, 1]")
	if oil_film < 0.0 or oil_film > 1.0:
		errors.append("oil_film must be in [0, 1]")

	return {"valid": errors.is_empty(), "errors": errors}

# ============================================================
# 序列化（存档 / 网络）
# ============================================================

func to_dict() -> Dictionary:
	return {
		"item_id": item_id,
		"material_id": material_id,
		"shape": shape,
		"dimensions": dimensions.duplicate(true),
		"parts": parts.duplicate(true),
		"connections": connections.duplicate(true),
		"transform": _transform_to_dict(transform),
		"temperature_c": temperature_c,
		"wetness": wetness,
		"oil_film": oil_film,
		"third_body": third_body,
		"wear": wear,
		"integrity": integrity,
		"tip_radius_m": tip_radius_m,
		"surface_roughness_um": surface_roughness_um,
		"grain_dir_local": _vec_to_array(grain_dir_local),
		"grip_point_local": _vec_to_array(grip_point_local),
		"location": location.duplicate(true),
	}

static func from_dict(data: Dictionary) -> ItemEntity:
	var item := ItemEntity.new()
	item.item_id = int(data.get("item_id", 0))
	item.material_id = String(data.get("material_id", ""))
	item.shape = String(data.get("shape", "block"))
	var raw_dims = data.get("dimensions", {})
	if raw_dims is Dictionary:
		item.dimensions = raw_dims.duplicate(true)
	item.parts = _array_copy(data.get("parts", []))
	item.connections = _array_copy(data.get("connections", []))
	item.transform = _transform_from_dict(data.get("transform", {}))
	item.temperature_c = float(data.get("temperature_c", 20.0))
	item.wetness = float(data.get("wetness", 0.0))
	item.oil_film = float(data.get("oil_film", 0.0))
	item.third_body = String(data.get("third_body", ""))
	item.wear = float(data.get("wear", 0.0))
	item.integrity = float(data.get("integrity", 1.0))
	item.tip_radius_m = float(data.get("tip_radius_m", -1.0))
	item.surface_roughness_um = float(data.get("surface_roughness_um", -1.0))
	item.grain_dir_local = _array_to_vec(data.get("grain_dir_local", []))
	item.grip_point_local = _array_to_vec(data.get("grip_point_local", []))
	var raw_loc = data.get("location", {"kind": "world"})
	if raw_loc is Dictionary:
		item.location = raw_loc.duplicate(true)
	return item

# ============================================================
# 内部几何计算
# ============================================================

func _part_position(part: Dictionary) -> Vector3:
	var pos = part.get("position", Vector3.ZERO)
	if pos is Vector3:
		return pos
	if pos is Array and pos.size() >= 3:
		return Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	if pos is Dictionary:
		return Vector3(float(pos.get("x", 0.0)), float(pos.get("y", 0.0)), float(pos.get("z", 0.0)))
	return Vector3.ZERO

# ============================================================
# 序列化辅助
# ============================================================

static func _vec_to_array(v: Vector3) -> Array:
	return [v.x, v.y, v.z]

static func _array_to_vec(a) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return Vector3.ZERO

static func _transform_to_dict(t: Transform3D) -> Dictionary:
	var b := t.basis
	return {
		"position": _vec_to_array(t.origin),
		"basis": [b.x.x, b.x.y, b.x.z,
				  b.y.x, b.y.y, b.y.z,
				  b.z.x, b.z.y, b.z.z],
	}

static func _transform_from_dict(data) -> Transform3D:
	if not (data is Dictionary) or data.is_empty():
		return Transform3D.IDENTITY
	var pos := _array_to_vec(data.get("position", []))
	var raw_basis = data.get("basis", [])
	if raw_basis is Array and raw_basis.size() >= 9:
		var bx := Vector3(float(raw_basis[0]), float(raw_basis[1]), float(raw_basis[2]))
		var by := Vector3(float(raw_basis[3]), float(raw_basis[4]), float(raw_basis[5]))
		var bz := Vector3(float(raw_basis[6]), float(raw_basis[7]), float(raw_basis[8]))
		return Transform3D(Basis(bx, by, bz), pos)
	return Transform3D(Basis.IDENTITY, pos)

static func _array_copy(value) -> Array:
	if value is Array:
		return value.duplicate(true)
	return []
