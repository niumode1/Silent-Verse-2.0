# ============================================================
# 测试脚本 — 验证 autoload 和材料数据库加载
# 运行：godot --headless --script tests/test_autoload.gd
# 或在编辑器中附加到任意 Node 执行
# ============================================================
extends Node

func _ready() -> void:
    print("=== 开始 autoload 验证 ===")

    # 1. 检查 PhysicsConstants
    print("\n[PhysicsConstants]")
    print("  G: ", PhysicsConstants.G)
    print("  g0: ", PhysicsConstants.g0)
    print("  planet_radius: ", PhysicsConstants.planet_radius)
    print("  rotation_period: ", PhysicsConstants.rotation_period)

    # 测试重力函数
    var surface_pos := Vector3(PhysicsConstants.planet_radius, 0, 0)
    var g_vec := PhysicsConstants.get_gravity_vector(surface_pos)
    print("  gravity at surface: ", g_vec, " magnitude=", g_vec.length())

    var high_alt_grav := PhysicsConstants.get_gravity_at_altitude(500.0)
    print("  gravity at 500m: ", high_alt_grav, " m/s²")

    var high_pressure := PhysicsConstants.get_pressure_at_altitude(500.0)
    print("  pressure at 500m: ", high_pressure / 1000.0, " kPa")

    # 2. 测试 MaterialDB 加载
    print("\n[MaterialDB]")
    MaterialDB.load_from_file("res://scripts/shared/data/materials.json")
    print("  is_loaded: ", MaterialDB.is_loaded)

    if MaterialDB.is_loaded:
        var all_mats := MaterialDB.get_all_materials()
        var categories := MaterialDB.get_all_categories()
        print("  total materials: ", all_mats.size())
        print("  categories: ", categories)

        # 测试几个关键查询
        var oak := MaterialDB.get_material("oak_wood")
        if oak:
            print("  oak_wood: density=", oak.density, " hardness=", oak.hardness_mohs)
            print("    static_friction=", oak.static_friction, " kinetic_friction=", oak.kinetic_friction)

        var iron := MaterialDB.get_material("pure_iron")
        if iron:
            print("  pure_iron: density=", iron.density, " hardness=", iron.hardness_mohs)
            print("    melting_point=", iron.melting_point, " yield=", iron.yield_strength)

        var steel := MaterialDB.get_material("high_carbon_steel")
        if steel:
            print("  high_carbon_steel: hardness=", steel.hardness_mohs, " yield=", steel.yield_strength)
            print("    max_hardness=", steel.max_hardness_mohs)

        # 测试摩擦对查询
        var friction := MaterialDB.get_friction_pair(oak, iron, 0.3)
        print("  oak-iron friction (wet 0.3): us=", friction["static_friction"], " uk=", friction["kinetic_friction"])

        # 测试按类别查询
        var metals := MaterialDB.get_by_category("metal")
        print("  metals count: ", metals.size())
        for m in metals:
            print("    - ", m.material_id, " (density=", m.density, ")")

        # 按反应标签查询
        var reducibles := MaterialDB.get_by_reactivity_tag("reducible")
        print("  reducible materials: ", reducibles.size())

    # 3. 测试 ReactionSystem 加载
    print("\n[ReactionSystem]")
    ReactionRegistry.load_from_file("res://scripts/shared/data/reactions.json")
    print("  is_loaded: ", ReactionRegistry.is_loaded)

    if ReactionRegistry.is_loaded:
        var all_rxns := ReactionRegistry.get_all_reactions()
        print("  total reactions: ", all_rxns.size())

        var smelt := ReactionRegistry.get_reaction("smelt_iron_hematite")
        if not smelt.is_empty():
            print("  smelt_iron_hematite: type=", smelt["type"])
            print("    temp_min=", smelt["temperature_min"], " optimal=", smelt["temperature_optimal"])

        # 测试反应匹配
        var test_inputs := [
            {"material_id": "iron_ore_hematite", "mass_kg": 5.5},
            {"material_id": "charcoal", "mass_kg": 2.0},
            {"material_id": "limestone", "mass_kg": 1.0}
        ]
        var matches := ReactionRegistry.find_possible_reactions(test_inputs, 1300, "reducing")
        print("  reactions matching at 1300°C reducing: ", matches.size())
        for match in matches:
            print("    - ", match["reaction"]["id"], " quality=", match["match_quality"])

        # 执行反应测试
        var result := ReactionRegistry.evaluate_reaction(smelt, test_inputs, 1350, "reducing", 3600, true)
        print("  evaluate smelt_iron (1h at 1350°C):")
        print("    progress: ", result["reaction_progress"])
        print("    mass_conservation_ok: ", result["mass_conservation_ok"])
        print("    heat: ", result["heat_released_j"] / 1e6, " MJ")
        print("    products:")
        for p in result["products"]:
            print("      - ", p["material_id"], ": ", p["mass_kg"], " kg")

    # 4. 测试 PhysicsCalc 几个关键公式
    print("\n[PhysicsCalc]")
    print("  free_fall 10m: ", PhysicsCalc.free_fall_velocity(10.0), " m/s")
    print("  terminal_velocity 80kg human: ", PhysicsCalc.terminal_velocity(80.0, 1.2, 0.7), " m/s")
    print("  lever_ma (2m effort, 0.2m load): ", PhysicsCalc.lever_ma(2.0, 0.2))
    print("  capstan_max_load (100N hold, 0.9μs, 3 wraps): ",
        PhysicsCalc.capstan_max_load(100.0, 0.9, 3.0 * PhysicsConstants.TWO_PI), " N")
    print("  slope_push_force 50kg on 20°: ", PhysicsCalc.slope_push_force(50.0, deg_to_rad(20.0), 0.5), " N")
    print("  buoyancy oak log (0.212m³): ", PhysicsCalc.buoyancy_force(1000.0, 0.212), " N")

    # 完整打击伤害计算
    print("  打击伤害测试 (石斧 vs 肉体):")
    var flint := MaterialDB.get_material("flint")
    var meat := MaterialDB.get_material("meat_raw")
    if flint and meat:
        var strike := PhysicsCalc.calculate_strike_damage(
            flint, 2.0, 15.0, 0.8, 0.002, meat, 1.0
        )
        print("    type: ", strike["damage_type"])
        print("    pressure: ", strike["contact_pressure_mpa"], " MPa")
        print("    base_damage: ", strike["base_damage"])

    print("\n=== 验证完成 ===")

    # 如果是 headless 模式，退出
    if OS.has_feature("headless"):
        get_tree().quit()
