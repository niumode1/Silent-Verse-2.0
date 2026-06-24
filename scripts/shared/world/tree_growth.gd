# ============================================================
# TreeGrowth — 树木生长模型
# ============================================================
# 懒计算：只在玩家靠近时根据经过的游戏天数计算生长量。
# 生长受阳光、水分、土壤养分、温度和季节的共同影响。
# ============================================================
class_name TreeGrowth
extends RefCounted

## 树种
var species: String = "oak"

## 当前生物量 kg
var biomass: float = 10.0

## 树干直径 m
var trunk_diameter: float = 0.05

## 树高 m
var height: float = 0.5

## 种植时的游戏天数
var planted_day: float = 0.0

## 上次计算时的游戏天数
var last_growth_day: float = 0.0

## 是否存活
var is_alive: bool = true

## 树种参数
const SPECIES_DATA := {
	"oak":   {"max_biomass": 30000.0, "max_height": 25.0, "max_diameter": 1.2,  "growth_rate": 1.0,  "shade_tolerance": 0.7, "water_need": 0.5,  "n_need": 0.04, "cold_tolerance": -20.0, "leaf_nutrient": 0.03},
	"pine":  {"max_biomass": 20000.0, "max_height": 20.0, "max_diameter": 0.8,  "growth_rate": 1.3,  "shade_tolerance": 0.3, "water_need": 0.3,  "n_need": 0.02, "cold_tolerance": -40.0, "leaf_nutrient": 0.02},
	"birch": {"max_biomass": 15000.0, "max_height": 18.0, "max_diameter": 0.6,  "growth_rate": 1.5,  "shade_tolerance": 0.4, "water_need": 0.6,  "n_need": 0.05, "cold_tolerance": -30.0, "leaf_nutrient": 0.04},
	"bamboo":{"max_biomass": 5000.0,  "max_height": 12.0, "max_diameter": 0.15, "growth_rate": 4.0,  "shade_tolerance": 0.5, "water_need": 0.7,  "n_need": 0.06, "cold_tolerance": -5.0,  "leaf_nutrient": 0.02},
}

## 计算生长（懒计算）
## @param current_day: 当前游戏天
## @param soil: 土壤数据 {n, p, k, moisture}
## @param sunlight: 日照比率 0-1
## @param temperature: 当前温度 °C
## @return 生长量 kg
func grow(current_day: float, soil: Dictionary, sunlight: float, temperature: float) -> float:
	if not is_alive:
		return 0.0

	var data: Dictionary = SPECIES_DATA.get(species, SPECIES_DATA["oak"])

	# 温度检查
	if temperature < data["cold_tolerance"]:
		return 0.0

	# 时间差
	var elapsed: float = current_day - last_growth_day
	if elapsed <= 0.0:
		return 0.0

	last_growth_day = current_day

	# 限制因子（取最小）
	var sunlight_factor: float = clampf(sunlight * data["shade_tolerance"] + (1.0 - data["shade_tolerance"]), 0.2, 1.0)
	var water_factor: float = clampf(soil.get("moisture", 0.3) / data["water_need"], 0.1, 1.5)
	var nutrient_factor: float = clampf(soil.get("n", 0.3) / data["n_need"], 0.1, 1.5)
	var limiting: float = minf(sunlight_factor, minf(water_factor, nutrient_factor))

	# 生长曲线：初期快，接近上限时减慢
	var growth_ratio: float = biomass / data["max_biomass"]
	var age_factor: float = 1.0 - growth_ratio * growth_ratio  # 平方减速

	# 生长量
	var growth: float = data["growth_rate"] * limiting * age_factor * elapsed

	# 应用到生物量
	biomass = minf(biomass + growth, data["max_biomass"])

	# 更新尺寸
	var size_ratio: float = biomass / data["max_biomass"]
	height = data["max_height"] * sqrt(size_ratio)
	trunk_diameter = data["max_diameter"] * pow(size_ratio, 0.4)

	# 从土壤消耗养分
	var n_consumed: float = data["n_need"] * growth / 1000.0
	var _p_consumed: float = n_consumed * 0.3
	var _k_consumed: float = n_consumed * 0.5

	return growth

## 创建新树苗
static func create_sapling(p_species: String, p_day: float) -> TreeGrowth:
	var tree := TreeGrowth.new()
	tree.species = p_species
	tree.planted_day = p_day
	tree.last_growth_day = p_day
	tree.biomass = 1.0
	tree.height = 0.1
	tree.trunk_diameter = 0.01
	tree.is_alive = true
	return tree

## 获取成熟度 0-1
func get_maturity() -> float:
	var data: Dictionary = SPECIES_DATA.get(species, SPECIES_DATA["oak"])
	return clampf(biomass / data["max_biomass"], 0.0, 1.0)

## 获取砍伐后可获得的木材质量 kg
func get_harvestable_mass() -> float:
	return biomass * 0.7  # 70% 可收获

## 获取树叶养分量（返回土壤）
func get_leaf_litter_nutrients() -> Dictionary:
	var data: Dictionary = SPECIES_DATA.get(species, SPECIES_DATA["oak"])
	return {
		"n": data["leaf_nutrient"] * biomass / 1000.0,
		"p": data["leaf_nutrient"] * 0.3 * biomass / 1000.0,
		"k": data["leaf_nutrient"] * 0.5 * biomass / 1000.0
	}

## 杀死树木
func kill() -> void:
	is_alive = false
