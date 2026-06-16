# ============================================================
# PhysicsCalc — 物理公式静态计算器
# ============================================================
# 职责：所有物理计算的静态函数库。
# 服务端权威调用。客户端可用同一份代码做预测渲染。
# 所有公式基于现实物理，无任何游戏性平衡调整。
#
# 依赖：PhysicsConstants (全局单例), MaterialDB (全局单例)
# ============================================================
class_name PhysicsCalc
extends RefCounted

# ============================================================
# 运动学 (Kinematics)
# ============================================================

## 自由落体速度（无空气阻力）
static func free_fall_velocity(drop_height: float, g: float = PhysicsConstants.g0) -> float:
	return sqrt(2.0 * g * drop_height)

## 自由落体时间
static func free_fall_time(drop_height: float, g: float = PhysicsConstants.g0) -> float:
	return sqrt(2.0 * drop_height / g)

## 终端速度
static func terminal_velocity(mass: float, cd: float, cross_area: float,
							  air_density: float = PhysicsConstants.rho_air_0,
							  g: float = PhysicsConstants.g0) -> float:
	var denominator: float = air_density * cd * cross_area
	if denominator < 0.000001:
		return INF
	return sqrt(2.0 * mass * g / denominator)

## 带空气阻力的实际落地速度
static func impact_velocity_with_drag(mass: float, drop_height: float, cd: float,
									   cross_area: float, g: float = PhysicsConstants.g0) -> float:
	var v_term: float = terminal_velocity(mass, cd, cross_area,
										  PhysicsConstants.rho_air_0, g)
	var v_freefall: float = free_fall_velocity(drop_height, g)
	# 简化：取两者中较小值。全精度需解微分方程，游戏精度此近似足够
	return minf(v_freefall, v_term)

## 斜抛最大射程（真空中）
static func projectile_range(launch_speed: float, launch_angle_rad: float,
							  g: float = PhysicsConstants.g0) -> float:
	return launch_speed * launch_speed * sin(2.0 * launch_angle_rad) / g

# ============================================================
# 动能 / 势能 / 动量 / 冲量
# ============================================================

static func kinetic_energy(mass: float, velocity: float) -> float:
	return 0.5 * mass * velocity * velocity

static func potential_energy(mass: float, height: float, g: float = PhysicsConstants.g0) -> float:
	return mass * g * height

static func momentum(mass: float, velocity: float) -> float:
	return mass * velocity

static func impulse(force: float, delta_time: float) -> float:
	return force * delta_time

static func force_from_impulse(momentum_change: float, delta_time: float) -> float:
	if delta_time < 0.000001:
		return INF
	return momentum_change / delta_time

# ============================================================
# 摩擦 (Friction)
# ============================================================

## 最大静摩擦力
static func max_static_friction(normal_force: float, mu_s: float) -> float:
	return mu_s * normal_force

## 动摩擦力
static func kinetic_friction_force(normal_force: float, mu_k: float) -> float:
	return mu_k * normal_force

## 滚动阻力
static func rolling_resistance_force(normal_force: float, crr: float) -> float:
	return crr * normal_force

## 斜面静止条件判定
## @return true 如果物体不会自行滑下
static func slope_stable(slope_angle_rad: float, mu_s: float) -> bool:
	return tan(slope_angle_rad) <= mu_s

## 斜面所需推力（上推）
static func slope_push_force(mass: float, slope_angle_rad: float, mu_k: float,
							  g: float = PhysicsConstants.g0) -> float:
	return mass * g * (sin(slope_angle_rad) + mu_k * cos(slope_angle_rad))

## 斜面所需保持力（防止下滑）
static func slope_hold_force(mass: float, slope_angle_rad: float, mu_s: float,
							  g: float = PhysicsConstants.g0) -> float:
	var hold: float = mass * g * (sin(slope_angle_rad) - mu_s * cos(slope_angle_rad))
	return maxf(hold, 0.0)  # 负值 = 不需施力也能静止

## Capstan 方程 — 绑扎/绞盘摩擦力
## @param tension_hold: 手持端张力 N
## @param mu_s: 绳索与圆柱间的静摩擦系数
## @param wrap_angle_rad: 总缠绕角度 rad (= 圈数 × 2π)
## @return 可承受的最大负载端张力 N
static func capstan_max_load(tension_hold: float, mu_s: float, wrap_angle_rad: float) -> float:
	return tension_hold * exp(mu_s * wrap_angle_rad)

## Capstan 方程 — 给定负载求最小缠绕圈数
static func capstan_min_wraps(load_force: float, hold_force: float, mu_s: float) -> int:
	if load_force <= hold_force:
		return 1
	var ratio: float = load_force / hold_force
	var min_angle: float = log(ratio) / mu_s
	var min_wraps: int = ceili(min_angle / PhysicsConstants.TWO_PI)
	return maxi(min_wraps, 1)

# ============================================================
# 简单机械 (Simple Machines)
# ============================================================

## 杠杆 — 机械利益
static func lever_ma(effort_arm: float, load_arm: float) -> float:
	return effort_arm / load_arm

## 杠杆 — 输出力
static func lever_output_force(input_force: float, effort_arm: float, load_arm: float) -> float:
	return input_force * lever_ma(effort_arm, load_arm)

## 杠杆 — 撬棍材质约束（抗弯强度判定）
static func lever_max_force_before_yield(lever_material: MaterialProperty,
										  lever_length: float, lever_cross_section_modulus: float) -> float:
	# σ = F·L / W,  F_max = σy·W / L
	if lever_length < 0.001:
		return INF
	return lever_material.yield_strength * 1e6 * lever_cross_section_modulus / lever_length

## 滑轮组 — 所需拉力
static func pulley_pull_force(load_mass: float, rope_count: int, g: float = PhysicsConstants.g0) -> float:
	return load_mass * g / float(rope_count)

## 斜面 — 机械利益
static func inclined_plane_ma(slope_angle_rad: float, mu_k: float) -> float:
	var denominator: float = sin(slope_angle_rad) + mu_k * cos(slope_angle_rad)
	if denominator < 0.000001:
		return INF
	return 1.0 / denominator

## 楔子 — 分离力
## @param input_force: 楔入力 N
## @param wedge_half_angle_rad: 楔角的一半 rad
## @param mu_k: 楔子与材料间的动摩擦系数
static func wedge_split_force(input_force: float, wedge_half_angle_rad: float, mu_k: float) -> float:
	var denominator: float = 2.0 * sin(wedge_half_angle_rad) + mu_k * cos(wedge_half_angle_rad)
	if denominator < 0.000001:
		return INF
	return input_force / denominator

## 轮轴 — 机械利益
static func wheel_axle_ma(crank_radius: float, drum_radius: float) -> float:
	if drum_radius < 0.001:
		return INF
	return crank_radius / drum_radius

# ============================================================
# 材料力学 (Material Mechanics)
# ============================================================

## 应力
static func stress(force: float, area: float) -> float:
	if area < 0.000001:
		return INF
	return force / area

## 应变
static func strain(change_in_length: float, original_length: float) -> float:
	if original_length < 0.000001:
		return 0.0
	return change_in_length / original_length

## 胡克定律：σ = E·ε
static func hooke_stress(youngs_modulus_gpa: float, strain_val: float) -> float:
	return youngs_modulus_gpa * 1e9 * strain_val

## 莫氏硬度判定：A 能否划伤 B
static func can_scratch(hardness_a: float, hardness_b: float) -> bool:
	return hardness_a > hardness_b

## 屈服判定
static func is_yielding(stress_mpa: float, yield_strength_mpa: float) -> bool:
	return stress_mpa > yield_strength_mpa

## 断裂判定
static func is_fracturing(stress_mpa: float, tensile_strength_mpa: float) -> bool:
	return stress_mpa > tensile_strength_mpa

## 压强（用于穿透判定）
static func pressure(force: float, contact_area: float) -> float:
	if contact_area < 0.000000001:
		return INF
	return force / contact_area

## 圆形尖端接触面积（磨尖程度决定）
static func tip_contact_area(tip_radius_m: float) -> float:
	return PI * tip_radius_m * tip_radius_m

# ============================================================
# 碰撞 (Collision)
# ============================================================

## 一维弹性碰撞后速度（m1 的速度）
static func elastic_collision_v1(m1: float, v1: float, m2: float, v2: float) -> float:
	return ((m1 - m2) * v1 + 2.0 * m2 * v2) / (m1 + m2)

## 一维弹性碰撞后速度（m2 的速度）
static func elastic_collision_v2(m1: float, v1: float, m2: float, v2: float) -> float:
	return ((m2 - m1) * v2 + 2.0 * m1 * v1) / (m1 + m2)

## 非完全弹性碰撞（恢复系数 e）
static func inelastic_collision_v1(m1: float, v1: float, m2: float, v2: float, e: float) -> float:
	var v_cm: float = (m1 * v1 + m2 * v2) / (m1 + m2)  # 质心速度
	var v_elastic: float = elastic_collision_v1(m1, v1, m2, v2)
	return v_cm + e * (v_elastic - v_cm)

## 完全非弹性碰撞（粘在一起）
static func perfectly_inelastic_velocity(m1: float, v1: float, m2: float, v2: float) -> float:
	return (m1 * v1 + m2 * v2) / (m1 + m2)

# ============================================================
# 转动 (Rotation)
# ============================================================

## 力矩
static func torque(force: float, lever_arm: float, angle_rad: float = PI / 2.0) -> float:
	return force * lever_arm * sin(angle_rad)

## 质点转动惯量
static func moment_of_inertia_point(mass: float, radius: float) -> float:
	return mass * radius * radius

## 细杆绕一端的转动惯量
static func moment_of_inertia_rod_end(mass: float, length: float) -> float:
	return mass * length * length / 3.0

## 细杆绕中心的转动惯量
static func moment_of_inertia_rod_center(mass: float, length: float) -> float:
	return mass * length * length / 12.0

## 实心圆柱绕中心轴的转动惯量
static func moment_of_inertia_cylinder(mass: float, radius: float) -> float:
	return 0.5 * mass * radius * radius

## 角动量
static func angular_momentum(moment_of_inertia: float, angular_velocity: float) -> float:
	return moment_of_inertia * angular_velocity

## 转动动能
static func rotational_kinetic_energy(moment_of_inertia: float, angular_velocity: float) -> float:
	return 0.5 * moment_of_inertia * angular_velocity * angular_velocity

## 角加速度
static func angular_acceleration(torque_val: float, moment_of_inertia: float) -> float:
	if moment_of_inertia < 0.000001:
		return INF
	return torque_val / moment_of_inertia

# ============================================================
# 流体 (Fluid Mechanics)
# ============================================================

## 浮力
static func buoyancy_force(fluid_density: float, submerged_volume: float,
							g: float = PhysicsConstants.g0) -> float:
	return fluid_density * submerged_volume * g

## 物体能否浮起
static func can_float(object_density: float, fluid_density: float) -> bool:
	return object_density < fluid_density

## 液体压强（深度 h 处）
static func hydrostatic_pressure(fluid_density: float, depth: float,
								  surface_pressure: float = PhysicsConstants.p0,
								  g: float = PhysicsConstants.g0) -> float:
	return surface_pressure + fluid_density * g * depth

## 水坝受力（平均压力 × 面积）
static func dam_force(fluid_density: float, water_height: float, dam_width: float,
					   g: float = PhysicsConstants.g0) -> float:
	var avg_pressure: float = 0.5 * fluid_density * g * water_height
	var area: float = water_height * dam_width
	return avg_pressure * area

# ============================================================
# 热学 (Thermodynamics)
# ============================================================

## 热传导速率（一维傅里叶定律）
static func heat_conduction_rate(thermal_conductivity: float, area: float,
								  temp_hot: float, temp_cold: float,
								  thickness: float) -> float:
	if thickness < 0.0001:
		return INF
	return thermal_conductivity * area * (temp_hot - temp_cold) / thickness

## 温度变化（给定热量输入）
static func temperature_change(heat_energy_j: float, mass_kg: float,
								specific_heat_j_per_kg_k: float) -> float:
	if mass_kg * specific_heat_j_per_kg_k < 0.000001:
		return 0.0
	return heat_energy_j / (mass_kg * specific_heat_j_per_kg_k)

## 熔化所需热量
static func melting_energy(mass_kg: float, heat_of_fusion_kj_per_kg: float) -> float:
	return mass_kg * heat_of_fusion_kj_per_kg * 1000.0  # kJ → J

## 蒸发所需热量
static func vaporization_energy(mass_kg: float, heat_of_vaporization_kj_per_kg: float) -> float:
	return mass_kg * heat_of_vaporization_kj_per_kg * 1000.0

## 燃烧产热
static func combustion_heat(mass_kg: float, heat_value_mj_per_kg: float,
							 efficiency: float = 0.9) -> float:
	return mass_kg * heat_value_mj_per_kg * 1e6 * efficiency  # MJ → J

## 炉温估算（简化热平衡）
## @param total_heat_input: 燃烧提供的总热量 J
## @param total_heat_loss_rate: 热流失速率 W
## @param materials: Array[{mass, cp}] 炉内各物质
## @param time_s: 经过时间 s
static func estimate_furnace_temperature(total_heat_input: float, total_heat_loss_rate: float,
										  materials: Array, time_s: float) -> float:
	var total_heat_capacity: float = 0.0
	for mat in materials:
		total_heat_capacity += mat["mass"] * mat["cp"]
	if total_heat_capacity < 0.001:
		return INF
	var net_heat: float = total_heat_input - total_heat_loss_rate * time_s
	return net_heat / total_heat_capacity

## 热膨胀
static func thermal_expansion_length(original_length: float, expansion_coeff_10e_6_per_k: float,
									  temp_change: float) -> float:
	return original_length * expansion_coeff_10e_6_per_k * 1e-6 * temp_change

# ============================================================
# 核心工具公式 — 砍伐 (Chopping)
# ============================================================

## 计算挥击动能
## @param tool_mass: 工具质量 kg
## @param swing_speed: 命中点线速度 m/s
static func swing_kinetic_energy(tool_mass: float, swing_speed: float) -> float:
	return 0.5 * tool_mass * swing_speed * swing_speed

## 计算挥击线速度（来自角速度和杠杆臂）
## @param angular_velocity: 挥击角速度 rad/s
## @param lever_arm: 握持点到命中点的距离 m
static func swing_linear_velocity(angular_velocity: float, lever_arm: float) -> float:
	return angular_velocity * lever_arm

## 砍伐单次砍入深度
## @param kinetic_energy: 挥击动能 J
## @param edge_width: 刃宽 m
## @param wood_shear_strength: 木材剪切强度 MPa
## @param wood_youngs_modulus: 木材杨氏模量 GPa
## @param swing_angle_rad: 挥击角度（相对于木材纹理法线）
static func chop_cut_depth(kinetic_energy_j: float, edge_width: float,
							wood_shear_strength_mpa: float, wood_e_gpa: float,
							swing_angle_rad: float) -> float:
	# 接触面积 = 刃宽 × 初始接触深度（简化）
	# 有效剪切强度 = τ · (1 - 湿度%)
	var penetration_factor: float = cos(swing_angle_rad)  # 正劈最深
	var shear_energy: float = wood_shear_strength_mpa * 1e6  # MPa → Pa
	# 砍入深度 ∝ 动能 / (剪切强度 × 刃宽 × 弹性阻力)
	var depth: float = kinetic_energy_j * penetration_factor / \
		(shear_energy * edge_width * (wood_e_gpa * 1e9) ** 0.3)
	return maxf(depth, 0.0)

## 斧头是否卡住（摩擦判定）
## @param kinetic_friction: 斧刃-木材 μk
## @param side_pressure: 木材对斧侧面的挤压力 N
## @param forward_force: 拔出/继续砍的轴向力 N
static func is_axe_stuck(kinetic_friction: float, side_pressure: float, forward_force: float) -> bool:
	# 卡住条件：2·μk·N_side > F_forward
	return 2.0 * kinetic_friction * side_pressure > forward_force

# ============================================================
# 核心工具公式 — 挖掘/采矿 (Mining)
# ============================================================

## 硬度是否足够
static func can_mine(pick_hardness_mohs: float, rock_hardness_mohs: float) -> bool:
	return pick_hardness_mohs > rock_hardness_mohs

## 单次挖掘体积
## @param impact_force: 冲击力 N
## @param tip_area: 镐尖面积 m²
## @param rock_compressive_strength: 岩石抗压强度 MPa
## @param rock_fracture_toughness: 岩石断裂韧性 MPa√m
## @param efficiency: 形状效率 (0~1)
static func mine_volume_per_strike(impact_force: float, tip_area: float,
									rock_compressive_strength_mpa: float,
									rock_fracture_toughness: float,
									efficiency: float = 0.5) -> float:
	var tip_pressure_pa: float = impact_force / maxf(tip_area, 1e-8)
	var threshold_pa: float = rock_compressive_strength_mpa * 1e6  # MPa → Pa
	if tip_pressure_pa <= threshold_pa:
		print(">> mine rejected: pressure=", tip_pressure_pa/1e6, "MPa threshold=", rock_compressive_strength_mpa, "MPa force=", impact_force, "N tip=", tip_area)
		return 0.0
	# 超出阈值的压力比例 × 尖端投影面积 × 特征深度
	var excess_ratio: float = (tip_pressure_pa - threshold_pa) / threshold_pa
	var volume: float = efficiency * excess_ratio * tip_area * 0.01
	return volume

## 疲劳积累挖掘（硬度不够不能直接劈裂时的渐进损伤）
static func mine_fatigue_damage(impact_force: float, tip_area: float,
								 rock_compressive_strength_mpa: float) -> float:
	var tip_pressure: float = impact_force / maxf(tip_area, 1e-8)
	var threshold: float = rock_compressive_strength_mpa * 1e6
	if tip_pressure <= threshold:
		return tip_pressure / threshold * 0.01  # 极小累积
	return tip_pressure / threshold  # 损伤比例

## 挥击能量损失（镐在岩石上打滑）
## @param impact_angle_rad: 击中角度（偏离法线的角度）
## @param mu_k: 镐-岩石动摩擦
static func mine_energy_loss(impact_angle_rad: float, mu_k: float) -> float:
	# 如果角度大于临界角 → 打滑，能量大量损失
	var critical_angle: float = atan(mu_k) if mu_k > 0.0 else PI / 2.0
	if impact_angle_rad > critical_angle:
		return 0.7  # 70% 能量损失
	return mu_k * cos(impact_angle_rad)  # 摩擦导致的损失比例

# ============================================================
# 核心工具公式 — 磨尖 (Sharpening)
# ============================================================

## Archard 磨损模型 — 材料去除率
## @param wear_coeff: 磨损系数 (~1e-5 石对石)
## @param normal_force: 正压力 N
## @param sliding_speed: 相对滑动速度 m/s
## @param target_hardness_vickers: 被磨物维氏硬度 HV
static func sharpen_wear_rate(wear_coeff: float, normal_force: float,
							   sliding_speed: float, target_hardness_vickers: float) -> float:
	if target_hardness_vickers < 0.01:
		return INF
	return wear_coeff * normal_force * sliding_speed / target_hardness_vickers

## 磨尖后尖端曲率变化
## @param current_tip_radius: 当前尖端曲率半径 m
## @param wear_volume_per_second: 材料去除率 m³/s
## @param duration: 时间 s
## @param shape_factor: 形状因子（取决于磨的方式）
## @param min_radius: 材料最小可达曲率半径 m
static func sharpen_new_tip_radius(current_tip_radius: float, wear_volume_per_second: float,
									duration: float, shape_factor: float,
									min_radius: float) -> float:
	var reduction: float = wear_volume_per_second * duration * shape_factor
	return maxf(current_tip_radius - reduction, min_radius)

# ============================================================
# 核心伤害公式 — 打击伤害 (Strike Damage)
# ============================================================

## 完整的打击伤害计算（服务端权威）
## 这是游戏中最核心的物理公式——所有武器对人/动物的伤害由此推导
##
## @param weapon_material: 武器主体材料
## @param weapon_mass: 武器有效质量 kg
## @param angular_velocity: 挥击角速度 rad/s
## @param lever_arm: 握持点到命中点距离 m
## @param tip_radius: 命中点尖端曲率半径 m（钝器则较大）
## @param target_material: 被击中部位的材料属性
## @param body_part_multiplier: 部位伤害倍率
## @return Dictionary {damage, penetration_depth, damage_type, energy_delivered}
static func calculate_strike_damage(
	weapon_material: MaterialProperty,
	weapon_mass: float,
	angular_velocity: float,
	lever_arm: float,
	tip_radius: float,
	target_material: MaterialProperty,
	body_part_multiplier: float = 1.0
) -> Dictionary:

	# 1. 命中点线速度
	var linear_velocity: float = angular_velocity * lever_arm

	# 2. 动能 E_k = ½mv²
	var kinetic_energy_j: float = 0.5 * weapon_mass * linear_velocity * linear_velocity

	# 3. 硬度比 — 决定能量分配
	var w_h: float = weapon_material.hardness_mohs
	var t_h: float = target_material.hardness_mohs
	var hardness_ratio: float = w_h / maxf(w_h + t_h, 0.01)

	# 4. 接触面积
	var contact_area: float = PI * tip_radius * tip_radius
	contact_area = maxf(contact_area, 1e-8)

	# 5. 碰撞恢复系数（肉体低，硬物高）
	var e: float = 0.5 * (weapon_material.restitution + target_material.restitution)

	# 6. 传递到目标的能量
	var energy_to_target: float = kinetic_energy_j * hardness_ratio * (1.0 + e) / 2.0

	# 7. 压强判定 → 穿透 vs 钝伤
	# F ≈ E / d 估计，然后用压强比较
	var estimated_force: float = energy_to_target / maxf(tip_radius, 1e-6)
	var contact_pressure_mpa: float = estimated_force / contact_area / 1e6

	var result: Dictionary = {
		"kinetic_energy": kinetic_energy_j,
		"energy_delivered": energy_to_target,
		"linear_velocity": linear_velocity,
		"contact_pressure_mpa": contact_pressure_mpa,
		"hardness_ratio": hardness_ratio
	}

	# 判定穿透还是钝伤
	if contact_pressure_mpa > target_material.yield_strength:
		# 穿透！
		var excess_pressure: float = (contact_pressure_mpa - target_material.yield_strength) * 1e6
		var penetration: float = excess_pressure / maxf(target_material.density * linear_velocity * linear_velocity, 0.01)
		result["damage_type"] = "penetration"
		result["penetration_depth_m"] = penetration
		result["base_damage"] = energy_to_target * body_part_multiplier
	else:
		# 钝伤 — 冲击波传入
		result["damage_type"] = "blunt"
		result["penetration_depth_m"] = 0.0
		result["base_damage"] = energy_to_target * body_part_multiplier

	return result

# ============================================================
# 坠落伤害
# ============================================================

## 计算坠落伤害（坠物砸人，或人自己坠落）
static func calculate_fall_damage(mass: float, fall_height: float,
								   impact_area: float,
								   target_material: MaterialProperty,
								   g: float = PhysicsConstants.g0) -> Dictionary:
	var velocity: float = free_fall_velocity(fall_height, g)
	var kinetic_energy_j: float = kinetic_energy(mass, velocity)
	var impact_force: float = kinetic_energy_j / maxf(sqrt(impact_area), 1e-4)
	var pressure_mpa: float = impact_force / maxf(impact_area, 1e-8) / 1e6

	var damage_type: String = "blunt"
	var penetration: float = 0.0

	if pressure_mpa > target_material.yield_strength:
		damage_type = "penetration"
		penetration = (pressure_mpa - target_material.yield_strength) * 1e6 / \
			maxf(target_material.density * velocity * velocity, 0.01)

	return {
		"damage_type": damage_type,
		"base_damage": kinetic_energy_j,
		"impact_velocity": velocity,
		"pressure_mpa": pressure_mpa,
		"penetration_depth_m": penetration
	}

# ============================================================
# 咬合伤害
# ============================================================

## 计算动物咬合伤害
## @param bite_force_n: 咬合力 N（从动物属性获取）
## @param teeth_tip_area: 牙齿总尖端面积 m²
## @param teeth_hardness_mohs: 牙齿硬度
## @param target_material: 目标材料
## @param shake_multiplier: 撕扯倍率（狼会摇头撕扯）
static func calculate_bite_damage(bite_force_n: float, teeth_tip_area: float,
								   teeth_hardness_mohs: float, target_material: MaterialProperty,
								   shake_multiplier: float = 1.0) -> Dictionary:
	var pressure_mpa: float = bite_force_n / maxf(teeth_tip_area, 1e-8) / 1e6
	var depth: float = 0.0
	var damage_type: String = "crush"

	if teeth_hardness_mohs > target_material.hardness_mohs and \
	   pressure_mpa > target_material.yield_strength:
		damage_type = "puncture"
		depth = (pressure_mpa - target_material.yield_strength) * 1e6 / \
			maxf(target_material.density * 5.0 * 5.0, 0.01)

	return {
		"damage_type": damage_type,
		"base_damage": bite_force_n * shake_multiplier * 0.01,
		"pressure_mpa": pressure_mpa,
		"penetration_depth_m": depth
	}

# ============================================================
# 锻造相关
# ============================================================

## 计算锻造变形量
static func forge_deformation(hammer_mass: float, hammer_velocity: float,
							   target_yield_strength_mpa: float, contact_area: float) -> float:
	var energy: float = kinetic_energy(hammer_mass, hammer_velocity)
	var yield_pa: float = target_yield_strength_mpa * 1e6
	return energy / maxf(yield_pa * contact_area, 1e-8)

## 加工硬化 — 硬度提升
static func work_hardening_increase(current_hardness: float, max_hardness: float,
									 deformation_strain: float) -> float:
	var increase: float = deformation_strain * 0.5
	return minf(current_hardness + increase, max_hardness)

## 加工硬化 — 韧性下降
static func work_hardening_toughness_decrease(current_toughness: float, min_toughness: float,
											   deformation_strain: float) -> float:
	var decrease: float = deformation_strain * 0.3
	return maxf(current_toughness - decrease, min_toughness)

## 淬火判定 — 加热到奥氏体化温度后快冷 → 马氏体（高硬度低韧性）
static func quench_hardness_change(base_hardness: float, max_hardness: float,
									temp_before_quench: float,
									austenitizing_temp: float = 800.0) -> float:
	if temp_before_quench < austenitizing_temp:
		return base_hardness  # 没烧够温度，淬火无效
	# 淬火后硬度大幅提升
	return base_hardness + (max_hardness - base_hardness) * 0.7

## 回火 — 部分恢复韧性，降低硬度
static func temper_effect(current_hardness: float, min_hardness: float,
						   current_toughness: float, max_toughness: float,
						   temper_temp: float) -> Dictionary:
	# 回火温度越高 → 越软越韧
	var factor: float = clampf(temper_temp / 400.0, 0.0, 1.0)
	var new_hardness: float = current_hardness - (current_hardness - min_hardness) * factor * 0.5
	var new_toughness: float = current_toughness + (max_toughness - current_toughness) * factor * 0.4
	return {"hardness": new_hardness, "toughness": new_toughness}

# ============================================================
# 气体行为（CO 中毒等）
# ============================================================

## 封闭空间气体浓度
static func gas_concentration(gas_mass: float, space_volume: float) -> float:
	if space_volume < 0.001:
		return INF
	return gas_mass / space_volume  # kg/m³

## CO 中毒判定（简化）
static func is_co_toxic(concentration_kg_per_m3: float, exposure_time_s: float) -> float:
	# CO 浓度 > 0.0012 kg/m³ (≈1000 ppm) 开始有毒
	# 毒性累积 ∝ 浓度 × 时间
	var toxic_dose: float = concentration_kg_per_m3 * exposure_time_s
	# > 0.01 开始中毒症状
	return clampf(toxic_dose / 0.01, 0.0, 1.0)  # 0=安全, 1=致命
