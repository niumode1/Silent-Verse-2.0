# ============================================================
# Climate — 气候与季节系统
# ============================================================
# 驱动行星的温度、降水、风和季节变化。
# 季节由自转轴倾角 + 公转位置决定。
# ============================================================
class_name Climate
extends RefCounted

## 自转轴倾角（度）— 决定季节强度
var axial_tilt: float = 23.44

## 公转周期（游戏天）— 1 游戏年 = 16 游戏天
var orbital_period_days: float = 16.0

## 当前赛季已过的游戏天数
var elapsed_days: float = 0.0

## 赤道平均温度 °C
var equatorial_temp: float = 30.0

## 极地平均温度 °C
var polar_temp: float = -10.0

## 温度随海拔递减率 °C/100m
var temp_lapse_rate: float = 0.65

# ============================================================
# 当前状态
# ============================================================

## 获取当前季节阶段 (0.0 = 春分, 0.25 = 夏至, 0.5 = 秋分, 0.75 = 冬至)
func get_season_phase() -> float:
	var day_in_year: float = fmod(elapsed_days, orbital_period_days)
	return day_in_year / orbital_period_days

## 获取当前季节名称
func get_season_name() -> String:
	var phase: float = get_season_phase()
	if phase < 0.125 or phase >= 0.875: return "spring"
	if phase < 0.375: return "summer"
	if phase < 0.625: return "autumn"
	return "winter"

## 获取当前半球（北半球的季节偏移）
func get_northern_season_offset() -> float:
	return sin(get_season_phase() * TAU)

## 获取指定位置的当前温度 °C
## @param latitude: 纬度（度）
## @param elevation: 海拔 m
func get_temperature(latitude: float, elevation: float) -> float:
	# 基础温度（纬度相关）
	var abs_lat: float = abs(latitude)
	var lat_factor: float = 1.0 - abs_lat / 90.0
	var base_temp: float = polar_temp + (equatorial_temp - polar_temp) * lat_factor

	# 季节影响
	var season_offset: float = get_northern_season_offset()
	# 北半球和南半球的季节相反
	var lat_sign: float = 1.0 if latitude >= 0 else -1.0
	var season_effect: float = season_offset * lat_sign * 15.0  # 最大 ±15°C

	# 海拔递减
	var altitude_effect: float = elevation * temp_lapse_rate / 100.0

	return base_temp + season_effect - altitude_effect

## 获取水分可用性（基于纬度+季节）
func get_moisture_availability(latitude: float) -> float:
	var abs_lat: float = abs(latitude)
	# 赤道多雨，中纬度适中，极地干燥
	if abs_lat < 20:
		return 0.8  # 热带多雨
	elif abs_lat < 50:
		return 0.5  # 温带
	else:
		return 0.2  # 寒带

## 判断是否在生长季节
func is_growing_season(latitude: float) -> bool:
	var temp: float = get_temperature(latitude, 0)
	return temp > 5.0  # 温度高于 5°C 才能生长

## 判断是否为长冬（赛季末最后 16 游戏天）
func is_eternal_winter() -> bool:
	var days_in_season: float = orbital_period_days * 8  # 8 年
	var remaining: float = days_in_season - elapsed_days
	return remaining <= orbital_period_days  # 最后一年 = 长冬

## 获取降水量修正（mm/day 等效，0-1）
func get_precipitation(latitude: float, elevation: float) -> float:
	var moisture: float = get_moisture_availability(latitude)
	var season: float = get_season_phase()

	# 地形雨：迎风坡多雨
	var elevation_bonus: float = clampf(elevation / 500.0, 0.0, 0.3)

	# 夏季多雨
	var season_bonus: float = (1.0 + get_northern_season_offset() * (1.0 if latitude >= 0 else -1.0)) * 0.3

	return clampf(moisture + elevation_bonus + season_bonus, 0.0, 1.0)

## 获取风速 0-1
func get_wind_speed(latitude: float) -> float:
	var abs_lat: float = abs(latitude)
	# 中纬度风大
	if abs_lat > 30 and abs_lat < 60:
		return 0.7
	return 0.3

## 更新（每游戏天调用一次）
func advance_day() -> void:
	elapsed_days += 1.0

## 赛季重置
func reset_season() -> void:
	elapsed_days = 0.0
