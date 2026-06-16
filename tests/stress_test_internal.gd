# ============================================================
# Internal Stress Test — 服务端内置 50 人压测
# ============================================================
# 在服务端进程内直接模拟 50 个玩家的加载、动作、离线。
# 避免了 ENet 同时断开造成的 UDP 层问题。
# ============================================================
extends Node

const PLAYER_COUNT := 50

var _start_time: float = 0.0
var _player_ids: Array = []
var _actions_processed := 0
var _reactions_evaluated := 0

func _ready() -> void:
	print("=== Internal Stress Test (50 simulated players) ===\n")
	_start_time = Time.get_unix_time_from_system()

	# Phase 1: 批量创建玩家实体
	print("[1/5] Creating ", PLAYER_COUNT, " player bodies...")
	var bodies: Array = []
	for i in range(PLAYER_COUNT):
		var body := PlayerBody.new()
		body.roll_innate_traits()
		bodies.append(body)
		_player_ids.append(i)

	print("  Created ", bodies.size(), " players with random traits")
	print("  Memory estimate: ", bodies.size(), " × Resource")

	# Phase 2: 批量动作计算
	print("\n[2/5] Processing 5 actions per player (250 total)...")
	var calcs := 0
	var actions := [
		{"type": "chop", "target": "oak_wood", "weapon": "flint"},
		{"type": "mine", "target": "sandstone", "weapon": "flint"},
		{"type": "mine", "target": "granite", "weapon": "pure_iron"},
		{"type": "attack", "target": "meat_raw", "weapon": "flint"},
		{"type": "attack", "target": "meat_raw", "weapon": "high_carbon_steel"}
	]

	for body in bodies:
		for action_data in actions:
			var weapon_mat := MaterialDB.get_material(action_data["weapon"])
			var target_mat := MaterialDB.get_material(action_data["target"])
			if not weapon_mat or not target_mat:
				continue

			if action_data["type"] == "chop":
				var ek: float = PhysicsCalc.swing_kinetic_energy(2.0, 12.0)
				PhysicsCalc.chop_cut_depth(ek, 0.005, target_mat.shear_strength, target_mat.youngs_modulus, 0.0)
			elif action_data["type"] == "mine":
				var force: float = PhysicsCalc.momentum(2.0, 12.0) / 0.001
				PhysicsCalc.mine_volume_per_strike(force, 1e-4, target_mat.compressive_strength, target_mat.fracture_toughness)
			elif action_data["type"] == "attack":
				PhysicsCalc.calculate_strike_damage(weapon_mat, 2.0, 15.0, 0.8, 0.002, target_mat, 1.0)
			calcs += 1

	_actions_processed = calcs
	print("  Calculations: ", calcs)

	# Phase 3: 化学反应
	print("\n[3/5] Evaluating reactions (10 per player)...")
	var rxn_count := 0
	var all_rxns := ReactionRegistry.get_all_reactions()
	for body in bodies:
		for rxn in all_rxns:
			var test_inputs: Array = [{"material_id": "iron_ore_hematite", "mass_kg": 10.0},
									   {"material_id": "charcoal", "mass_kg": 3.0},
									   {"material_id": "limestone", "mass_kg": 2.0}]
			ReactionRegistry.evaluate_reaction(rxn, test_inputs, 1400.0, "reducing", 3600.0, true)
			rxn_count += 1
			if rxn_count >= PLAYER_COUNT * 10:
				break
		if rxn_count >= PLAYER_COUNT * 10:
			break

	_reactions_evaluated = rxn_count
	print("  Reactions: ", rxn_count)

	# Phase 4: 离线实体追赶计算
	print("\n[4/5] Simulating offline entity catch-up...")
	var offlines := 0
	for i in range(PLAYER_COUNT):
		var entity := OfflineEntity.new()
		entity.entity_type = "human"
		entity.position = Vector3(randf() * 1000, 0, randf() * 1000)
		entity.offline_since = _start_time - 86400.0  # 模拟离线 24h
		entity.hunger = 100.0
		entity.thirst = 100.0
		entity.health = 100.0
		entity.has_shelter = randf() > 0.5
		if entity.has_shelter:
			entity.shelter_decay_reduction = randf() * 0.5
		var result := entity.catch_up(_start_time)
		offlines += 1

	print("  Offline entities processed: ", offlines)

	# Phase 5: 动物创建
	print("\n[5/5] Creating animal bodies...")
	var animals := 0
	var species_list := ["wolf", "fox", "rabbit"]
	for i in range(PLAYER_COUNT):
		var animal := AnimalBody.create(species_list[i % 3])
		if animal:
			var meat := MaterialDB.get_material("meat_raw")
			if meat:
				animal.calculate_bite_damage(meat)
			animals += 1

	print("  Animals: ", animals)

	# 汇总
	var elapsed: float = Time.get_unix_time_from_system() - _start_time
	print("\n═════════════════════════════════════")
	print("  Internal Stress Test Results")
	print("═════════════════════════════════════")
	print("  Players:         ", PLAYER_COUNT)
	print("  Physics calcs:   ", _actions_processed)
	print("  Reactions:       ", _reactions_evaluated)
	print("  Offline entities:", offlines)
	print("  Animals:         ", animals)
	print("  Elapsed:         ", elapsed, " s")
	print("═════════════════════════════════════")

	print("\nServer remains running — ready for connections.")
