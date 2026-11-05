# ============================================================
# ItemGeometry — 物品几何/质量推导的唯一实现
# ============================================================
# ItemEntity、ConstructionValidator 等所有需要「由形状+尺寸+材料
# 推导体积/质量」的地方都调用这里，避免各写一套公式。
# ============================================================
class_name ItemGeometry
extends RefCounted

## 由形状和尺寸推导体积 m³
## box 类：length / width / height；sphere：radius；fiber：length / diameter
## 任意形状可用 dimensions.volume_m3 直接指定
static func shape_volume(p_shape: String, dimensions: Dictionary) -> float:
	if dimensions.has("volume_m3"):
		return maxf(float(dimensions.get("volume_m3", 0.0)), 0.0)

	var length: float = maxf(float(dimensions.get("length", 0.0)), 0.0)
	var width: float = maxf(float(dimensions.get("width", 0.0)), 0.0)
	var height: float = maxf(float(dimensions.get("height", 0.0)), 0.0)

	match p_shape:
		"sphere":
			var radius: float = float(dimensions.get("radius",
				width * 0.5 if width > 0.0 else length * 0.5))
			return (4.0 / 3.0) * PI * radius * radius * radius
		"fiber":
			var diameter: float = float(dimensions.get("diameter",
				width if width > 0.0 else height))
			var r: float = diameter * 0.5
			return PI * r * r * length
		"wedge":
			return 0.5 * length * width * height
		_:
			return length * width * height

## 单个部件的体积 m³
static func part_volume(part: Dictionary) -> float:
	var dims = part.get("dimensions", {})
	if dims is Dictionary and not dims.is_empty():
		return shape_volume(String(part.get("shape", "block")), dims)
	if part.has("volume_m3"):
		return maxf(float(part.get("volume_m3", 0.0)), 0.0)
	return 0.0

## 单个部件的材料。优先使用已加载的 MaterialProperty，其次按 material_id 查询
static func part_material(part: Dictionary) -> MaterialProperty:
	var cached = part.get("material")
	if cached is MaterialProperty:
		return cached
	var material_id := String(part.get("material_id", ""))
	if material_id != "" and MaterialDB.has_material(material_id):
		return MaterialDB.get_material(material_id)
	return null

## 单个部件的质量 kg。有几何时由材料密度推导，否则兼容旧数据使用 mass_kg
static func part_mass(part: Dictionary) -> float:
	var dims = part.get("dimensions", {})
	if dims is Dictionary and not dims.is_empty():
		var mat := part_material(part)
		if mat != null:
			return mat.density * part_volume(part)
	if part.has("mass_kg"):
		return maxf(float(part.get("mass_kg", 0.0)), 0.0)
	return 0.0

static func assembly_volume(parts: Array) -> float:
	var total: float = 0.0
	for part in parts:
		if part is Dictionary:
			total += part_volume(part)
	return total

static func assembly_mass(parts: Array) -> float:
	var total: float = 0.0
	for part in parts:
		if part is Dictionary:
			total += part_mass(part)
	return total

## 以给定方向为局部 Y 轴的正交基（树木、石头、倒木共用）
static func basis_from_up(up: Vector3) -> Basis:
	var y := up.normalized()
	var x := y.cross(Vector3.UP)
	if x.length() < 0.001:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)
