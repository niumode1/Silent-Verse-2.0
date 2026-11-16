# ============================================================
# ContactForceProbe — 记录刚体受到的接触力
# ============================================================
# 骨骼受力不能只看重力：抓着/抬着的物体通过接触把重量压在手上。
# 物理服务器只有在 _integrate_forces 里才给出接触冲量，所以给每段
# 肢体刚体挂上这个探针，把上一物理步的冲量换算成等效力（N），
# 供骨骼断面应力判定使用。
#
# 同时记录「最强的那一次接触」的对方物体、接触点和法线：手指的
# 等长收缩要把按压力施加在真实接触点上，而不是瞎加在质心。
# ============================================================
class_name ContactForceProbe
extends RigidBody3D

## 上一物理步所有接触冲量之和换算出的等效力（世界坐标，N）
var contact_force: Vector3 = Vector3.ZERO
## 上一物理步最强接触的对方刚体（没有则为 null）
var contact_body: Object = null
## 该接触的世界坐标接触点与法线（法线指向本刚体外部）
var contact_point: Vector3 = Vector3.ZERO
var contact_normal: Vector3 = Vector3.ZERO
## 该接触在上一物理步的冲量大小（N·s）
var contact_impulse: float = 0.0


func _ready() -> void:
	# 接触冲量只在开启接触监控后上报；数量不用大，手部同一时刻
	# 通常只接触 1-2 个物体
	contact_monitor = true
	max_contacts_reported = 8


func _integrate_forces(state: PhysicsDirectBodyState3D) -> void:
	var impulse := Vector3.ZERO
	var strongest := 0.0
	for i in range(state.get_contact_count()):
		var step_impulse: Vector3 = state.get_contact_impulse(i)
		impulse += step_impulse
		var magnitude := step_impulse.length()
		if magnitude > strongest:
			strongest = magnitude
			contact_body = state.get_contact_collider_object(i)
			contact_point = state.get_contact_local_position(i)
			contact_normal = state.get_contact_local_normal(i)
			contact_impulse = magnitude
	contact_force = impulse / maxf(state.step, 0.0001)
	if strongest <= 0.0:
		contact_body = null
		contact_impulse = 0.0
