# ============================================================
# GroundChunkNode — 把 GroundChunk 挂进场景
# ============================================================
# 只负责表现：网格、碰撞体、顶点色材质。格子和物质真值仍在
# GroundChunk / MatterField / MatterDelta 里。
# ============================================================
class_name GroundChunkNode
extends Node3D

var chunk: GroundChunk = null

var _mesh_instance: MeshInstance3D = null
var _body: StaticBody3D = null
var _collision: CollisionShape3D = null


func setup(p_chunk: GroundChunk) -> void:
	chunk = p_chunk
	transform = Transform3D(chunk.basis, chunk.anchor)
	_build_nodes()
	refresh()


func refresh() -> void:
	if chunk == null:
		return
	if _mesh_instance == null:
		_build_nodes()
	var mesh := chunk.build_mesh()
	_mesh_instance.mesh = mesh
	# patch 不生成碰撞，只用于视觉和挖掘检测


func _build_nodes() -> void:
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "GroundMesh"
		var mat := StandardMaterial3D.new()
		mat.vertex_color_use_as_albedo = true
		mat.roughness = 1.0
		mat.metallic = 0.0
		_mesh_instance.material_override = mat
		add_child(_mesh_instance)

	# 完全禁用 patch 碰撞体，只保留视觉网格
	# 碰撞由静态地形提供，patch 只用于挖掘检测和视觉
	if _body == null:
		pass  # 不创建碰撞体
