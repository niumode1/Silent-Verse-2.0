# ============================================================
# ContactResolver — 工具 / 地面接触的力与状态变化
# ============================================================
# 工具（木棍、石斧、骨凿）压在土/岩上时，这套公式回答：
#   · 接触压力多少（Hertz），谁先屈服（土还是工具）
#   · 土被压下去多深、推开多少体积、堆到哪里（体积守恒 + 休止角）
#   · 工具磨损多少（Archard）：体积、深度、质量损失
#   · 工具一共受哪些力、在哪个截面、会不会屈曲/折断
#   · 摩擦功变成多少热，两边各分多少
# 所有输入只来自 MaterialProperty，不存在按物品名查表。
# 单位约定：材料库的强度是 MPa、杨氏模量对固体是 GPa、对土是 MPa
# （黏土 0.5 MPa / 表土 0.05 MPa 按 MPa 读才是真实量级）。
# ============================================================
class_name ContactResolver
extends RefCounted

const GRAVITY := 9.81

## 工具被握在手里 + 顶在地面 ≡ 一端固定、一端铰支：K = 0.7
const BUCKLING_K := 0.7

## Archard 磨损系数的数量级标定：abrasion_resistance=0 → 1e-3，
## abrasion_resistance=1 → 0（无量纲，对应常见磨粒磨损的 1e-6~1e-2）
const WEAR_RATE_SCALE := 1.0e-3


## 把「多种材料按体积分数混合」的物体折算成一个等效 MaterialProperty。
## parts = [{"material": MaterialProperty, "fraction": float}, ...]
##
## 现实里地面从不只有一种物质：土是矿物颗粒 + 有机质 + 水 + 空气，
## 岩石是多种矿物的集合体。等效规则：
##   · 密度 / 泊松比 / 摩擦 / 粗糙度 / 休止角：体积分数加权（Voigt）
##   · 杨氏模量：Voigt 上界与 Reuss 下界取平均（随机混合的常用估计）
##   · 强度 / 硬度：Reuss 串联平均 1/S = Σφ/S ——弱相控制破坏，
##     这正是复合材料的真实行为（一小撮黏土能让整块砂砾变软）
##   · 导热：几何平均（Maxwell-Garnett 随机混合的近似）
static func composite(parts: Array) -> MaterialProperty:
	var total := 0.0
	for part in parts:
		total += maxf(float(part.get("fraction", 0.0)), 0.0)
	if total <= 0.0:
		return null
	var mat := MaterialProperty.new()
	mat.material_id = "composite"
	mat.display_name = "混合物"
	mat.category = "soil"
	mat.microstructure = "granular"
	var density := 0.0
	var poisson := 0.0
	var friction := 0.0
	var kinetic := 0.0
	var rough := 0.0
	var repose := 0.0
	var abrasion := 0.0
	var mohs := 0.0
	var voigt_e := 0.0
	var reuss_e := 0.0
	var geomean_e := 0.0
	var reuss_comp := 0.0
	var reuss_shear := 0.0
	var reuss_tensile := 0.0
	var reuss_hardness := 0.0
	var log_k := 0.0
	var heat_capacity := 0.0
	var dominant := 0.0
	for part in parts:
		var m: MaterialProperty = part["material"]
		var f: float = maxf(float(part.get("fraction", 0.0)), 0.0) / total
		if f <= 0.0:
			continue
		density += f * m.density
		poisson += f * m.poisson_ratio
		friction += f * m.static_friction
		kinetic += f * m.kinetic_friction
		rough += f * m.surface_roughness_um
		repose += f * m.angle_of_repose
		abrasion += f * m.abrasion_resistance
		mohs += f * m.hardness_mohs
		var e_pa: float = modulus_pa(m)
		voigt_e += f * e_pa
		reuss_e += f / maxf(e_pa, 1.0e-9)
		geomean_e += f * log(maxf(e_pa, 1.0e-9))
		reuss_comp += f / maxf(strength_pa(m.compressive_strength), 1.0e-3)
		reuss_shear += f / maxf(strength_pa(m.shear_strength), 1.0e-3)
		reuss_tensile += f / maxf(strength_pa(m.tensile_strength), 1.0e-3)
		reuss_hardness += f / maxf(hardness_pa(m), 1.0)
		log_k += f * log(maxf(m.thermal_conductivity, 1.0e-6))
		heat_capacity += f * m.specific_heat
		if f > dominant:
			dominant = f
			mat.category = m.category
	mat.density = density
	mat.poisson_ratio = poisson
	mat.static_friction = friction
	mat.kinetic_friction = kinetic
	mat.surface_roughness_um = rough
	mat.angle_of_repose = repose
	mat.abrasion_resistance = abrasion
	mat.hardness_mohs = mohs
	# 把 Pa 折回材料库的单位（固体 GPa / 土 MPa）。
	# 模量跨多个数量级时，Voigt/Reuss 中值会被硬相带偏（30% 花岗岩
	# 混进表土会算出 10 GPa）。随机混合用几何平均更接近实测。
	var e_pa: float = exp(geomean_e)
	mat.youngs_modulus = e_pa / (1.0e6 if mat.category == "soil" else 1.0e9)
	mat.compressive_strength = 1.0 / maxf(reuss_comp, 1.0e-30) / 1.0e6
	mat.shear_strength = 1.0 / maxf(reuss_shear, 1.0e-30) / 1.0e6
	mat.tensile_strength = 1.0 / maxf(reuss_tensile, 1.0e-30) / 1.0e6
	mat.hardness_vickers = 1.0 / maxf(reuss_hardness, 1.0e-30) / 9.807e6
	mat.thermal_conductivity = exp(log_k)
	mat.specific_heat = heat_capacity
	return mat


## 杨氏模量统一换算成 Pa（见文件头的单位约定）
static func modulus_pa(mat: MaterialProperty) -> float:
	if mat.category == "soil":
		return maxf(mat.youngs_modulus, 1.0e-6) * 1.0e6
	return maxf(mat.youngs_modulus, 1.0e-6) * 1.0e9


## 强度统一换算成 Pa
static func strength_pa(mpa: float) -> float:
	return maxf(mpa, 0.0) * 1.0e6


## 维氏硬度换算成 Pa（HV ≈ 9.807 MPa）
static func hardness_pa(mat: MaterialProperty) -> float:
	return maxf(mat.hardness_vickers, 1.0) * 9.807e6


## 两体接触的等效模量 E* = 1 / ((1-ν₁²)/E₁ + (1-ν₂²)/E₂)
static func effective_modulus(a: MaterialProperty, b: MaterialProperty) -> float:
	var c1: float = (1.0 - a.poisson_ratio * a.poisson_ratio) / modulus_pa(a)
	var c2: float = (1.0 - b.poisson_ratio * b.poisson_ratio) / modulus_pa(b)
	return 1.0 / maxf(c1 + c2, 1.0e-30)


## 球形/圆头端面的 Hertz 接触半径 a = (3Fr/4E*)^(1/3)
static func hertz_contact_radius(force_n: float, tip_radius: float,
		e_star: float) -> float:
	if force_n <= 0.0 or tip_radius <= 0.0:
		return 0.0
	return pow(3.0 * force_n * tip_radius / (4.0 * e_star), 1.0 / 3.0)


## 地基极限承载力 q_u（Pa）。
## 土：Terzaghi 公式 q_u = c·N_c + γ·D·N_q + 0.5·γ·B·N_γ，
##   内摩擦角取休止角（松砂的休止角≈内摩擦角），黏聚力取剪切强度。
## 岩：承载力由单轴抗压强度控制。
static func bearing_capacity(ground: MaterialProperty, width: float,
		depth: float) -> float:
	if ground.category != "soil":
		return strength_pa(ground.compressive_strength)
	var phi: float = deg_to_rad(clampf(ground.angle_of_repose, 0.1, 45.0))
	var tan_phi: float = tan(phi)
	var n_q: float = exp(PI * tan_phi) * pow(tan(PI * 0.25 + phi * 0.5), 2.0)
	var n_c: float = (n_q - 1.0) / maxf(tan_phi, 1.0e-6)
	var n_gamma: float = 2.0 * (n_q + 1.0) * tan_phi
	var c: float = strength_pa(ground.shear_strength)
	var gamma: float = ground.density * GRAVITY
	var b: float = maxf(width, 1.0e-4)
	var terzaghi: float = c * n_c + gamma * maxf(depth, 0.0) * n_q \
		+ 0.5 * gamma * b * n_gamma
	# 土体的整体承载力再高，也高不过土本身的贯入阻力（单轴抗压强度）。
	# 取两者较小：是「土体整体剪切破坏」还是「端头把土压碎」，谁先发生算谁。
	return minf(terzaghi, strength_pa(ground.compressive_strength))


## 给定法向力，工具能压入土里的平衡深度（m）。超过这个深度，
## 地基承载力已经能托住工具，不再下沉。
static func equilibrium_depth(ground: MaterialProperty, force_n: float,
		tip_area: float) -> float:
	if ground.category != "soil" or force_n <= 0.0 or tip_area <= 0.0:
		return 0.0
	var phi: float = deg_to_rad(clampf(ground.angle_of_repose, 0.1, 45.0))
	var tan_phi: float = tan(phi)
	var n_q: float = exp(PI * tan_phi) * pow(tan(PI * 0.25 + phi * 0.5), 2.0)
	var n_c: float = (n_q - 1.0) / maxf(tan_phi, 1.0e-6)
	var n_gamma: float = 2.0 * (n_q + 1.0) * tan_phi
	var gamma: float = ground.density * GRAVITY
	var pressure: float = force_n / tip_area
	var c: float = strength_pa(ground.shear_strength)
	var width: float = sqrt(4.0 * tip_area / PI)
	var surface_term: float = c * n_c + 0.5 * gamma * width * n_gamma
	var depth_term: float = gamma * n_q
	if depth_term <= 0.0:
		return 0.0
	return maxf((pressure - surface_term) / depth_term, 0.0)


## 圆头球冠压入深度 d 时排开的体积（m³）
static func spherical_cap_volume(radius: float, depth: float) -> float:
	var d: float = clampf(depth, 0.0, 2.0 * radius)
	return PI * d * d * (3.0 * radius - d) / 3.0


## 土被推开后按休止角堆成圆锥：V = πR³tanφ/3 → R
static func pile_radius(volume: float, ground: MaterialProperty) -> float:
	if volume <= 0.0:
		return 0.0
	var phi: float = deg_to_rad(clampf(ground.angle_of_repose, 5.0, 60.0))
	return pow(3.0 * volume / (PI * tan(phi)), 1.0 / 3.0)


## Archard 磨损体积 V = K·F_n·s / H
static func archard_wear(material: MaterialProperty, normal_force: float,
		slide_distance: float) -> float:
	if normal_force <= 0.0 or slide_distance <= 0.0:
		return 0.0
	var k: float = clampf(
		(1.0 - clampf(material.abrasion_resistance, 0.0, 1.0)) * WEAR_RATE_SCALE,
		1.0e-6, 1.0e-2)
	return k * normal_force * slide_distance / hardness_pa(material)


## 圆截面杆的截面二次矩 I = πr⁴/4，截面积 A = πr²
static func shaft_section(radius: float) -> Dictionary:
	var r: float = maxf(radius, 1.0e-4)
	return {
		"area": PI * r * r,
		"second_moment": PI * pow(r, 4.0) * 0.25,
		"extreme_fiber": r,
	}


## 主入口。参数（都用世界坐标，单位 SI）：
##   tool / ground: MaterialProperty
##   force: Vector3          玩家作用在工具握持端的力（N）
##   ground_normal: Vector3  地面外法线（单位向量）
##   tool_axis: Vector3      从接触点指向握持端的工具轴向（单位向量）
##   length: float           接触点到握持端的自由长度（m）
##   tip_radius: float       端头曲率半径（m，平头取截面半径）
##   shaft_radius: float     杆身半径（m）
##   slide_distance: float   本步相对滑移距离（m）
##   depth: float            当前已压入深度（m）
##   penetration_step: float 本步工具试图压入地面的距离（m，来自物理步）
##   round_tip: bool         端头是半球（true）还是平头（false）
## 返回见文件头列出的全部量。
static func resolve(p: Dictionary) -> Dictionary:
	var tool: MaterialProperty = p["tool"]
	var ground: MaterialProperty = p["ground"]
	var force: Vector3 = p["force"]
	var n: Vector3 = (p["ground_normal"] as Vector3).normalized()
	var axis: Vector3 = (p["tool_axis"] as Vector3).normalized()
	var length: float = maxf(float(p.get("length", 1.0)), 1.0e-3)
	var tip_radius: float = maxf(float(p.get("tip_radius", 0.01)), 1.0e-4)
	var shaft_radius: float = maxf(float(p.get("shaft_radius", 0.01)), 1.0e-4)
	var slide: float = maxf(float(p.get("slide_distance", 0.0)), 0.0)
	var depth: float = maxf(float(p.get("depth", 0.0)), 0.0)

	# ---- 力分解：法向（压入地面）与切向（摩擦/侧推）----
	var into: Vector3 = -n
	var normal_force: float = maxf(force.dot(into), 0.0)
	var tangent_vec: Vector3 = force - into * force.dot(into)
	var tangent_force: float = tangent_vec.length()
	var flow_dir: Vector3 = tangent_vec.normalized() if tangent_force > 1.0e-6 \
		else Vector3.ZERO

	# ---- 接触几何与压力 ----
	# 平头（削过的木棍端面）是面接触：A = πr²，压力均匀；
	# 圆头（磨圆的端头、石球）是 Hertz 接触：a = (3Fr/4E*)^(1/3)，
	# 球头峰值压力 p0 = 3F/2A，是平均压力的 1.5 倍。
	var round_tip: bool = bool(p.get("round_tip", false))
	var e_star: float = effective_modulus(tool, ground)
	var contact_radius: float = tip_radius
	var contact_area: float = PI * tip_radius * tip_radius
	var peak_pressure: float = normal_force / maxf(contact_area, 1.0e-12)
	var mean_pressure: float = peak_pressure
	if round_tip:
		contact_radius = hertz_contact_radius(normal_force, tip_radius, e_star)
		contact_area = maxf(PI * contact_radius * contact_radius,
			PI * tip_radius * tip_radius * 1.0e-6)
		mean_pressure = normal_force / maxf(contact_area, 1.0e-12)
		peak_pressure = 1.5 * mean_pressure

	# ---- 地面是否屈服 ----
	var q_ground: float = bearing_capacity(ground, 2.0 * contact_radius, depth)
	var ground_yield: bool = peak_pressure > q_ground

	# ---- 工具端头是否被压溃（接触应力超过硬度/抗压强度）----
	var tool_contact_strength: float = minf(
		strength_pa(tool.compressive_strength), hardness_pa(tool))
	var tool_yield: bool = peak_pressure > tool_contact_strength

	# ---- 土被压入多深、排开多少体积、堆到哪 ----
	# 工具的位移由物理求解器给出（这一物理步它想往地面里走多远），
	# 这里只决定这段位移是被土吸进去（塑性流动）还是被顶回来。
	var step: float = maxf(float(p.get("penetration_step", 0.0)), 0.0)
	var d_eq: float = depth
	var absorbed: float = 0.0
	var displaced_volume: float = 0.0
	if ground_yield and step > 0.0:
		absorbed = step
		d_eq = depth + step
		var tip_area: float = PI * tip_radius * tip_radius
		displaced_volume = tip_area * step
		# 圆头端面：排开体积按球冠体积差算（更接近真实端头形状）
		if round_tip:
			displaced_volume = maxf(
				spherical_cap_volume(tip_radius, d_eq)
				- spherical_cap_volume(tip_radius, depth), 0.0)
	# 土对工具的反力：屈服后最多只能提供 q_u·A，压不动就把工具顶回去
	var reaction_force: float = minf(normal_force, q_ground * contact_area)
	var displaced_mass: float = displaced_volume * ground.density
	var pile_r: float = pile_radius(displaced_volume, ground)
	var pile_h: float = pile_r * tan(deg_to_rad(clampf(ground.angle_of_repose, 5.0, 60.0)))

	# ---- 磨损：两边各按自己的 Archard 系数 ----
	var tool_wear_volume: float = archard_wear(tool, normal_force, slide)
	var ground_wear_volume: float = archard_wear(ground, normal_force, slide)
	var tool_wear_depth: float = tool_wear_volume / maxf(contact_area, 1.0e-12)
	var tool_wear_mass: float = tool_wear_volume * tool.density

	# ---- 摩擦热：Q = μ·F_n·s，按热流分配 ----
	var mu: float = sqrt(maxf(tool.kinetic_friction, 0.0) \
		* maxf(ground.kinetic_friction, 0.0))
	var heat_j: float = mu * normal_force * slide
	var tool_effusivity: float = sqrt(maxf(tool.thermal_conductivity, 1.0e-6) \
		* tool.density * maxf(tool.specific_heat, 1.0))
	var ground_effusivity: float = sqrt(maxf(ground.thermal_conductivity, 1.0e-6) \
		* ground.density * maxf(ground.specific_heat, 1.0))
	var tool_heat_fraction: float = tool_effusivity \
		/ maxf(tool_effusivity + ground_effusivity, 1.0e-12)

	# ---- 工具的力链：轴向压力 + 端部侧向力 ----
	# axis 从接触点指向握持端：往地面里压 → 杆受压（正），往上拔 → 0
	var axial_force: float = maxf(-force.dot(axis), 0.0)
	var lateral_force: float = tangent_force
	var section: Dictionary = shaft_section(shaft_radius)
	var area: float = float(section["area"])
	var second_moment: float = float(section["second_moment"])
	var fiber: float = float(section["extreme_fiber"])
	var e_tool: float = modulus_pa(tool)
	# 欧拉屈曲：P_cr = π²EI/(KL)²
	var p_cr: float = PI * PI * e_tool * second_moment \
		/ pow(BUCKLING_K * length, 2.0)
	var buckles: bool = axial_force > p_cr
	# 握持端弯矩最大：M = F_side · L，σ = M·c/I + F_axial/A
	var moment: float = lateral_force * length
	var bending_stress: float = moment * fiber / maxf(second_moment, 1.0e-30)
	var axial_stress: float = axial_force / maxf(area, 1.0e-12)
	var total_stress: float = bending_stress + axial_stress
	var strength: float = strength_pa(minf(tool.tensile_strength,
		tool.compressive_strength))
	var breaks: bool = total_stress > strength or buckles

	return {
		# 力
		"normal_force": normal_force,
		"tangential_force": tangent_force,
		"axial_force": axial_force,
		"lateral_force": lateral_force,
		# 接触
		"contact_radius": contact_radius,
		"contact_area": contact_area,
		"pressure_pa": peak_pressure,
		"mean_pressure_pa": mean_pressure,
		"bearing_capacity_pa": q_ground,
		"ground_yield": ground_yield,
		"tool_yield": tool_yield,
		# 地面状态变化
		"penetration_depth": d_eq,
		"absorbed_step": absorbed,
		"reaction_force": reaction_force,
		"displaced_volume": displaced_volume,
		"displaced_mass": displaced_mass,
		"pile_radius": pile_r,
		"pile_height": pile_h,
		"flow_direction": flow_dir,
		# 磨损
		"tool_wear_volume": tool_wear_volume,
		"tool_wear_depth": tool_wear_depth,
		"tool_wear_mass": tool_wear_mass,
		"ground_wear_volume": ground_wear_volume,
		# 热
		"friction_heat": heat_j,
		"tool_heat_fraction": tool_heat_fraction,
		# 工具断裂
		"buckling_load": p_cr,
		"buckles": buckles,
		"bending_moment": moment,
		"bending_stress": bending_stress,
		"axial_stress": axial_stress,
		"total_stress": total_stress,
		"strength": strength,
		"breaks": breaks,
		"break_location": length,
	}
