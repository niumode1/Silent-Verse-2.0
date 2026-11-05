# ============================================================
# ItemCollision — 由物品实际几何生成碰撞形状
# ============================================================
# 基本形状（块/球/圆柱）用精确 primitive；
# 切割、雕刻或任意部件组合出的自定义网格，用网格自身的凸包生成碰撞体。
# 每一块被切开的物体都是独立 ItemEntity，各自调用这里生成自己的碰撞体，
# 不存在“共享父碰撞体”或“只用原物体包围盒”。
# ============================================================
class_name ItemCollision
extends RefCounted

## 返回该物品需要的碰撞形状数组（动态刚体使用凸形状）
static func build_shapes(item: ItemEntity, visual_mesh: Mesh = null) -> Array:
	var shapes: Array = []

	var mesh: Mesh = null
	if item.custom_mesh != null:
		mesh = item.custom_mesh
	elif item.shape == "custom" and visual_mesh != null:
		mesh = visual_mesh

	if mesh != null:
		var convex: Shape3D = mesh.create_convex_shape()
		if convex != null:
			shapes.append(convex)
			return shapes
		# 网格无法生成凸包时，退回尺寸包围盒
		var fallback := BoxShape3D.new()
		fallback.size = Vector3(
			float(item.dimensions.get("length", 0.2)),
			float(item.dimensions.get("height", 0.2)),
			float(item.dimensions.get("width", 0.2)))
		shapes.append(fallback)
		return shapes

	var dims := item.dimensions
	match item.shape:
		"fiber":
			var cap := CapsuleShape3D.new()
			cap.height = float(dims.get("length", 1.0))
			cap.radius = float(dims.get("diameter", dims.get("width", 0.2))) * 0.5
			shapes.append(cap)
		"sphere":
			var sphere := SphereShape3D.new()
			sphere.radius = float(dims.get("radius", 0.2))
			shapes.append(sphere)
		_:
			var box := BoxShape3D.new()
			box.size = Vector3(
				float(dims.get("length", 0.2)),
				float(dims.get("height", 0.2)),
				float(dims.get("width", 0.2)))
			shapes.append(box)
	return shapes
