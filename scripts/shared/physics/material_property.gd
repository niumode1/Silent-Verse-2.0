# ============================================================
# MaterialProperty — 材料物理/化学属性类
# ============================================================
# 职责：定义一种材料的全部现实物理化学参数。
# 游戏中所有物品行为（伤害、耐久、反应、浮沉…）都由此类
# 的属性值通过公式推导得出。不存在任何硬编码的"物品属性"。
#
# 数据来源：materials.json → MaterialDB 加载 → 创建实例
# 运行时只读。新增材料只需修改 JSON，不改代码。
# ============================================================
class_name MaterialProperty
extends Resource

# ============================================================
# 基础标识
# ============================================================

## 材料唯一 ID（如 "oak_wood", "pure_iron"）
@export var material_id: String = ""

## 显示名称（中文）
@export var display_name: String = ""

## 材料形态标签：solid / liquid / granular / gas / powder / fiber / paste
@export var phase: String = "solid"

## 材料大类：wood / stone / metal / organic / soil / liquid / processed / ore
@export var category: String = ""

# ============================================================
# 力学属性 (Mechanical)
# ============================================================

## 密度 kg/m³（决定重量：m = ρ·V）
@export var density: float = 1000.0

## 莫氏硬度 1-10（谁划伤谁的判定基准）
@export var hardness_mohs: float = 1.0

## 维氏硬度 HV（更精确的硬度值，用于穿透/磨损计算）
@export var hardness_vickers: float = 10.0

## 屈服强度 MPa — 超过此应力产生永久变形
@export var yield_strength: float = 10.0

## 抗拉强度 MPa — 拉断所需应力
@export var tensile_strength: float = 10.0

## 抗压强度 MPa — 压碎所需应力
@export var compressive_strength: float = 10.0

## 剪切强度 MPa — 切断所需应力
@export var shear_strength: float = 5.0

## 杨氏弹性模量 GPa — 刚度
@export var youngs_modulus: float = 1.0

## 剪切模量 GPa
@export var shear_modulus: float = 0.4

## 体积模量 GPa
@export var bulk_modulus: float = 1.0

## 泊松比 (0~0.5) — 横向应变/纵向应变比
@export var poisson_ratio: float = 0.3

## 断裂韧性 MPa·√m — 抗裂纹扩展
@export var fracture_toughness: float = 1.0

## 疲劳极限 MPa — 反复加载的安全应力上限
@export var fatigue_limit: float = 1.0

## 静摩擦系数 μs（对自身材料，干燥条件）
@export var static_friction: float = 0.6

## 动摩擦系数 μk（对自身材料，干燥条件）
@export var kinetic_friction: float = 0.4

## 滚动阻力系数 Crr
@export var rolling_resistance: float = 0.05

## 碰撞恢复系数 e (0~1)
@export var restitution: float = 0.3

## 振动阻尼系数 ζ (0~1)
@export var damping_coefficient: float = 0.1

## 耐磨性 (0~1, 1=极其耐磨)
@export var abrasion_resistance: float = 0.5

# ============================================================
# 热学属性 (Thermal)
# ============================================================

## 熔点 °C（inf 表示不熔化/直接分解）
@export var melting_point: float = 1500.0

## 沸点 °C（inf 表示不沸腾/直接分解）
@export var boiling_point: float = 3000.0

## 比热容 J/(kg·K)
@export var specific_heat: float = 1000.0

## 导热系数 W/(m·K)
@export var thermal_conductivity: float = 1.0

## 热膨胀系数 10⁻⁶/K
@export var thermal_expansion: float = 10.0

## 熔化潜热 kJ/kg — 1kg 熔化吸收的热量
@export var heat_of_fusion: float = 200.0

## 汽化潜热 kJ/kg — 1kg 蒸发吸收的热量
@export var heat_of_vaporization: float = 2000.0

## 闪点（自燃温度）°C
@export var flash_point: float = 300.0

## 热辐射率 ε (0~1, 黑体=1)
@export var emissivity: float = 0.8

## 锻造温度 °C（约 0.6×熔点，金属可锻打的温度区间下限）
@export var forging_temperature: float = 800.0

## 最大硬度（加工硬化后可达到的硬度上限，莫氏）
@export var max_hardness_mohs: float = 7.0

## 最小韧性（加工硬化后的韧性下限 MPa√m）
@export var min_toughness: float = 0.5

# ============================================================
# 化学属性 (Chemical)
# ============================================================

## 可燃性 0~1
@export var combustibility: float = 0.0

## 燃烧热值 MJ/kg（可燃物完全燃烧释放的能量）
@export var heat_value: float = 0.0

## 反应活性标签数组，如 ["reducible", "oxidizable", "acid_soluble", "base_soluble"]
@export var reactivity_tags: Array[String] = []

## 水中溶解度 g/100mL (20°C)
@export var solubility_water: float = 0.0

## 毒性 0~1
@export var toxicity: float = 0.0

## pH 值 0~14（7=中性，仅对水溶液/含水材料有意义）
@export var acidity_ph: float = 7.0

## 抗氧化性 0~1（1=完全抗氧化，如金）
@export var oxidation_resistance: float = 0.5

## 腐蚀性 0~1（对接触材料的侵蚀能力）
@export var corrosiveness: float = 0.0

# ============================================================
# 流体属性 (Fluid — 仅对 phase=liquid/granular 有意义)
# ============================================================

## 动力粘度 Pa·s
@export var viscosity: float = 0.0

## 表面张力 N/m
@export var surface_tension: float = 0.0

## 颗粒休止角 度（仅 granular 有效）
@export var angle_of_repose: float = 30.0

## 毛细上升高度 m（水在多孔介质中）
@export var capillary_rise: float = 0.0

# ============================================================
# 声学属性 (Acoustic)
# ============================================================

## 声速（在材料中的传播速度）m/s
@export var sound_speed: float = 340.0

## 吸声系数 (0~1, 1kHz 时)
@export var sound_absorption: float = 0.1

# ============================================================
# 光学属性 (Optical)
# ============================================================

## 不透明度 0~1（0=完全透明, 1=完全不透明）
@export var opacity: float = 1.0

## 反射率 0~1
@export var reflectivity: float = 0.1

## 折射率（透明材料）
@export var refractive_index: float = 1.0

# ============================================================
# 电学属性 (Electrical)
# ============================================================

## 电导率 S/m
@export var electrical_conductivity: float = 0.0

# ============================================================
# 结构属性 (Structural — 建筑相关)
# ============================================================

## 最大无支撑跨度 m（梁的极限跨度，取决于抗弯强度）
@export var max_beam_span: float = 1.0

## 砂浆粘结强度 MPa（与粘土/石灰砂浆的粘附力）
@export var bond_strength_mortar: float = 0.5

## 握钉力 N（钉子/木钉拔出所需力）
@export var nail_holding: float = 500.0

## 吸水率 %（湿度膨胀系数）
@export var water_absorption: float = 5.0

# ============================================================
# 生态属性 (Ecological)
# ============================================================

## 生物降解率 0~1（在自然环境中分解速率）
@export var biodegradability: float = 0.1

## 氮含量 0~1（对土壤肥力的贡献）
@export var nutrient_n: float = 0.0

## 磷含量 0~1
@export var nutrient_p: float = 0.0

## 钾含量 0~1
@export var nutrient_k: float = 0.0

## 人类可食性 0~1（生食）
@export var edibility_human: float = 0.0

## 动物可食性字典 {"wolf": 0.0, "fox": 0.3, "rabbit": 0.9}
@export var edibility_animal: Dictionary = {}

# ============================================================
# 辅助方法
# ============================================================

## 判断该材料能否划伤另一种材料
func can_scratch(other: MaterialProperty) -> bool:
    return hardness_mohs > other.hardness_mohs

## 判断该材料是否可燃
func is_flammable() -> bool:
    return combustibility > 0.0 and flash_point < 9999.0

## 判断该材料在给定温度下是否熔化
func is_molten_at(temp_c: float) -> bool:
    if melting_point >= 9999.0:
        return false
    return temp_c >= melting_point

## 获取材料对指定动物物种的可食性
func get_edibility_for_species(species: String) -> float:
    if edibility_animal.has(species):
        return edibility_animal[species]
    return 0.0

## 判断是否为流体（液体或颗粒体）
func is_fluid() -> bool:
    return phase == "liquid" or phase == "granular"

## 获取材料的锻造温度范围（约 0.6×熔点 到 0.9×熔点）
func get_forging_range() -> Dictionary:
    if melting_point >= 9999.0:
        return {"min": 0.0, "max": 0.0, "forgable": false}
    return {
        "min": forging_temperature,
        "max": melting_point * 0.9,
        "forgable": true
    }

## 验证材料属性完整性
func validate() -> Dictionary:
    var errors: Array[String] = []

    if material_id == "":
        errors.append("material_id is empty")
    if density <= 0:
        errors.append("density must be positive")
    if hardness_mohs < 0 or hardness_mohs > 10:
        errors.append("hardness_mohs must be in [0, 10]")
    if static_friction < 0 or static_friction > 2:
        errors.append("static_friction out of realistic range")
    if kinetic_friction < 0 or kinetic_friction > 2:
        errors.append("kinetic_friction out of realistic range")
    if kinetic_friction >= static_friction and not (static_friction == 0.0 and kinetic_friction == 0.0):
        errors.append("μk should be less than μs")
    if poisson_ratio < 0 or poisson_ratio > 0.5:
        errors.append("poisson_ratio must be in [0, 0.5]")
    if restitution < 0 or restitution > 1:
        errors.append("restitution must be in [0, 1]")

    return {
        "valid": errors.is_empty(),
        "errors": errors
    }
