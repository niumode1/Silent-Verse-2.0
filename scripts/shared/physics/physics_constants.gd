# ============================================================
# PhysicsConstants — 全局物理常数单例
# ============================================================
# 职责：定义《无言史诗》宇宙的所有物理常数。
# 服务端启动时初始化（根据赛季配置设定 R, M, g₀），
# 客户端加载只读副本用于预测渲染。
# 所有其他物理计算模块从此单例读取常数。
# ============================================================
extends Node

# ============================================================
# 万有引力与行星参数
# ============================================================

## 万有引力常数 N·m²/kg²（现实值，永远不变）
const G: float = 6.67430e-11

## 行星半径 m（由赛季配置设定，默认 ~25km 周长）
var planet_radius: float = 3978.87  # R = C/2π = 25000/2π

## 行星质量 kg（从 g₀ 和 R 反推）
var planet_mass: float = 0.0       # M = g₀·R²/G，初始化时计算

## 海平面表面重力加速度 m/s²
const g0: float = 9.81

## 行星周长 m
var planet_circumference: float = 25000.0

## 自转周期 s（= 1 游戏天 = 86400 现实秒）
const rotation_period: float = 86400.0

## 自转角速度 rad/s
const omega_planet: float = 2.0 * PI / 86400.0  # ≈ 7.272×10⁻⁵

## 自转轴倾角 度（产生季节）
const axial_tilt: float = 23.44

# ============================================================
# 大气参数（海平面标准值）
# ============================================================

## 海平面标准气压 Pa
const p0: float = 101325.0

## 海平面标准温度 K (15°C)
const t0: float = 288.15

## 海平面空气密度 kg/m³
const rho_air_0: float = 1.225

## 大气标高 m（气压衰减的特征高度）
const scale_height: float = 8500.0

## 干空气摩尔质量 kg/mol
const m_air: float = 0.0289644

## 通用气体常数 J/(mol·K)
const r_gas: float = 8.314462618

# ============================================================
# 空气阻力系数表（无量纲）
# ============================================================

## 阻力系数参考值
const cd_sphere: float = 0.47
const cd_cylinder_side: float = 0.82
const cd_cylinder_end: float = 1.15
const cd_streamline: float = 0.04
const cd_human_standing: float = 1.2
const cd_human_crouched: float = 0.8
const cd_flat_plate: float = 1.98
const cd_cube: float = 1.05

# ============================================================
# 水的参数
# ============================================================

## 纯水密度 kg/m³ (4°C)
const rho_water: float = 1000.0

## 海水密度 kg/m³
const rho_seawater: float = 1025.0

## 冰密度 kg/m³
const rho_ice: float = 917.0

## 纯水凝固点 °C（海平面）
const t_freeze: float = 0.0

## 纯水沸点 °C（海平面）
const t_boil_water: float = 100.0

## 每升高 300m 沸点降低 1°C
const boil_point_lapse_rate: float = 1.0 / 300.0

## 水的动力粘度 Pa·s (20°C)
const eta_water: float = 1.002e-3

## 水的表面张力 N/m (20°C)
const gamma_water: float = 0.0728

## 水的比热容 J/(kg·K)
const cp_water: float = 4184.0

## 水的汽化潜热 kJ/kg
const lv_water: float = 2260.0

## 水的熔化潜热 kJ/kg
const lf_water: float = 334.0

# ============================================================
# 声学常数
# ============================================================

## 0°C 时空气中的声速 m/s
const c_sound_0c: float = 331.3

## 声速温度系数 m/(s·°C)
const c_sound_temp_coeff: float = 0.606

## 光速 m/s
const c_light: float = 299792458.0

# ============================================================
# 温度相关
# ============================================================

## 绝对零度 °C
const absolute_zero: float = -273.15

## 标准温度 20°C 对应的开尔文
const t_standard_k: float = 293.15

# ============================================================
# 通用物理常数
# ============================================================

## 圆周率（重导出方便使用）
const PI: float = 3.141592653589793

## 2π
const TWO_PI: float = 6.283185307179586

# ============================================================
# 游戏时间常数
# ============================================================

## 1 游戏天的现实秒数
const seconds_per_game_day: float = 86400.0

## 1 游戏月 = 4 游戏天
const game_days_per_month: int = 4

## 1 游戏年 = 16 游戏天
const game_days_per_year: int = 16

## 1 赛季 = 8 游戏年
const game_years_per_season: int = 8

## 1 赛季的现实天数
const real_days_per_season: float = 128.0

# ============================================================
# 初始化
# ============================================================

func _ready() -> void:
    _recalculate_planet_mass()

## 重新计算行星质量（当 R 改变时调用）
func _recalculate_planet_mass() -> void:
    planet_mass = g0 * planet_radius * planet_radius / G
    planet_circumference = TWO_PI * planet_radius

## 设置赛季行星参数（每赛季由开发者配置）
func configure_planet(radius: float, _surface_gravity: float = g0) -> void:
    planet_radius = radius
    # 注意：g0 是 const，如果赛季需要不同的 g₀，用此参数覆盖逻辑
    # Phase 1 保持 g0=9.81 不变
    _recalculate_planet_mass()

# ============================================================
# 与位置相关的物理量计算
# ============================================================

## 计算给定位置的重力加速度矢量
## @param position: 相对于球心的 3D 位置（世界坐标，球心在原点）
## @return 重力加速度矢量 m/s²，方向指向球心
func get_gravity_vector(position: Vector3) -> Vector3:
    var r: float = position.length()
    if r < 0.001:  # 在球心——不应该发生
        return Vector3.DOWN * g0
    var r_hat: Vector3 = position.normalized()
    var g_magnitude: float = G * planet_mass / (r * r)
    return -r_hat * g_magnitude

## 计算给定海拔的重力加速度大小
## @param altitude: 海拔高度 m（距海平面）
## @return 重力加速度大小 m/s²
func get_gravity_at_altitude(altitude: float) -> float:
    return g0 * pow(planet_radius / (planet_radius + altitude), 2.0)

## 计算给定海拔的气压
## @param altitude: 海拔高度 m
## @return 气压 Pa
func get_pressure_at_altitude(altitude: float) -> float:
    return p0 * exp(-altitude / scale_height)

## 计算给定海拔的空气密度
## @param altitude: 海拔高度 m
## @return 空气密度 kg/m³
func get_air_density_at_altitude(altitude: float) -> float:
    return rho_air_0 * exp(-altitude / scale_height)

## 计算给定海拔的沸点
## @param altitude: 海拔高度 m
## @return 水的沸点 °C
func get_water_boiling_point(altitude: float) -> float:
    return t_boil_water - altitude * boil_point_lapse_rate

## 计算给定温度的声速
## @param temp_celsius: 温度 °C
## @return 声速 m/s
func get_sound_speed(temp_celsius: float) -> float:
    return c_sound_0c + c_sound_temp_coeff * temp_celsius

## 计算给定位置的空气阻力
## @param velocity: 物体速度 m/s
## @param cd: 阻力系数（无量纲）
## @param cross_area: 横截面积 m²
## @param altitude: 海拔 m
## @return 空气阻力矢量 N（与速度方向相反）
func get_air_drag(velocity: Vector3, cd: float, cross_area: float, altitude: float) -> Vector3:
    var speed: float = velocity.length()
    if speed < 0.001:
        return Vector3.ZERO
    var rho: float = get_air_density_at_altitude(altitude)
    var drag_magnitude: float = 0.5 * rho * cd * cross_area * speed * speed
    return -velocity.normalized() * drag_magnitude

## 计算终端速度
## @param mass: 物体质量 kg
## @param cd: 阻力系数
## @param cross_area: 横截面积 m²
## @param altitude: 海拔 m
## @return 终端速度 m/s
func get_terminal_velocity(mass: float, cd: float, cross_area: float, altitude: float) -> float:
    var rho: float = get_air_density_at_altitude(altitude)
    var g_local: float = get_gravity_at_altitude(altitude)
    return sqrt(2.0 * mass * g_local / (rho * cd * cross_area))

# ============================================================
# 摩擦系数参考矩阵 [材料A][材料B] → (μs, μk)
# 运行时由 MaterialDB 填充完整数据
# 这里提供默认参考值
# ============================================================

## 获取默认静摩擦系数（无具体材料对数据时的回退）
func get_default_static_friction(hardness_a: float, hardness_b: float, surface_wetness: float = 0.0) -> float:
    # 粗糙估算：硬度越高，摩擦越低（近似）
    var base_friction: float = clampf(0.3 + 0.5 * (1.0 - (hardness_a + hardness_b) / 20.0), 0.05, 0.9)
    # 表面湿度修正
    var wetness_factor: float = 1.0 - surface_wetness * 0.7
    return base_friction * wetness_factor

## 获取默认动摩擦系数
func get_default_kinetic_friction(hardness_a: float, hardness_b: float, surface_wetness: float = 0.0) -> float:
    # μk 通常约为 μs 的 70-80%
    return get_default_static_friction(hardness_a, hardness_b, surface_wetness) * 0.75

# ============================================================
# 恢复系数参考值
# ============================================================

## 碰撞恢复系数 e（0=完全塑性，1=完全弹性）
const e_steel_steel: float = 0.9
const e_wood_wood: float = 0.6
const e_stone_stone: float = 0.3
const e_flesh_flesh: float = 0.05
const e_wood_stone: float = 0.4
const e_metal_wood: float = 0.5
const e_metal_flesh: float = 0.08
