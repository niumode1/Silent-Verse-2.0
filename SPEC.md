# Spec: Silent Verse (无言史诗) — Phase 1 原型

## Objective

构建《无言史诗》的最小可玩原型，验证**现实物理参数驱动一切**这个核心前提是否成立。目标：2 个真人玩家能够在服务端上完成「捡石头 → 砍树 → 磨尖木棍 → 绑成石斧 → 砍更多树 → 挖矿石 → 建炉子 → 冶炼出铁 → 锻打成刀」这条完整循环，且每一步都由物理/化学公式计算而非硬编码决定。

### 用户（玩家）
- 50 人同时在线的测试群体
- 不提供任何教程——玩家的现实知识是唯一的指南

### 成功标准
1. 两名真人玩家在同一服务端完成完整冶炼循环（石斧→铁刀），所有步骤由服务端物理/化学公式判定
2. 服务端 CPU < 60%、内存 < 4GB（50 假人 + 2 真人，4 核 8G VPS）
3. 物理公式单元测试全部通过（打击伤害/砍伐/挖掘/反应质量守恒/摩擦/斜面/杠杆/浮力/热传导/相变）
4. 材料数据库包含 ≥ 50 种材料，每种材料覆盖全部 40+ 属性字段
5. 反应注册表包含 ≥ 15 个反应，每个反应的输入质量 = 输出质量
6. 离线实体代谢模拟正确（离线 24h→上线后饥饿/口渴值按公式衰减）
7. 客户端-服务端 ENet 通信延迟 < 80ms（中国大陆同城）

---

## Tech Stack

| 层面 | 选型 | 版本 |
|---|---|---|
| 客户端引擎 | Godot | 4.6.3 |
| 服务端 | Godot Headless | 4.6.3 |
| 物理引擎 | Jolt Physics | Godot 4.6.3 内置 |
| 脚本语言 | GDScript | Godot 4.6.3 内置 |
| 网络传输 | ENet | Godot 4.6.3 内置 |
| 持久化 | JSON 文件 | FileAccess 读写 |
| 部署目标 | Linux (Ubuntu 22.04) | — |
| 客户端平台 | Windows 优先 | 10/11 |
| 测试环境 | 本地 LAN | Phase 1 |
| 美术资源 | CSG 几何体（临时） | Phase 1 |

---

## Commands

```bash
# 开发
godot --editor                          # 启动 Godot 编辑器
godot --headless --path . server_main.tscn  # 启动服务端（无头模式）

# 测试
godot --headless --path . --script tests/run_all_tests.gd  # 运行全部单元测试
godot --headless --path . --script tests/test_physics.gd    # 仅物理测试

# 构建
godot --headless --export-release "Windows Desktop" builds/silent_verse.exe
godot --headless --export-release "Linux X11" builds/silent_verse_server

# 部署（服务端）
scp builds/silent_verse_server user@vps:/opt/silentverse/
ssh user@vps "systemctl restart silentverse"

# 压力测试（50 假人）
godot --headless --path . --script tests/stress_test_50_clients.gd
```

---

## Project Structure

```
Silent Verse 2.0/
├── project.godot                      # Godot 4.6.3 项目配置
├── SPEC.md                            # 本文件
├── CLAUDE.md                          # AI 编码助手参考
│
├── scripts/
│   ├── shared/                        # ===== 客户端 & 服务端共享 =====
│   │   ├── physics/
│   │   │   ├── physics_constants.gd    # PhysicsConstants 单例 (G/g₀/R/M/大气/水/声光)
│   │   │   ├── material_property.gd    # MaterialProperty Resource 类 (40+ 导出字段)
│   │   │   ├── material_database.gd    # MaterialDB 单例 (加载 materials.json)
│   │   │   ├── physics_calculator.gd   # PhysicsCalc 静态公式库
│   │   │   └── reaction_system.gd      # ReactionSystem (注册表 + evaluate)
│   │   ├── data/
│   │   │   ├── materials.json          # 真实材料数据 (50-100 种)
│   │   │   └── reactions.json          # 反应注册表 (15-50 个反应)
│   │   ├── world/
│   │   │   ├── soil.gd                 # 土壤 NPK 网格
│   │   │   ├── tree_growth.gd          # 树木生长 + 懒计算
│   │   │   └── ore_vein.gd             # 矿脉分布
│   │   └── entities/
│   │       ├── player_body.gd          # 人类生物力学 (力量/耐力/先天变异/锻炼)
│   │       ├── animal_body.gd          # 动物生物力学 (咬合力/速度/感知)
│   │       └── offline_entity.gd       # 离线实体懒计算 (代谢衰减/激活)
│   │
│   ├── server/                         # ===== 服务端专用 =====
│   │   ├── main.gd                     # Headless 启动入口
│   │   ├── cell_manager.gd             # 空间分区管理 (Phase 1: 单 Cell)
│   │   ├── authority.gd               # 权威验证层 (所有玩家动作验证)
│   │   └── network/
│   │       ├── enet_server.gd          # ENet 服务端 (UDP)
│   │       └── voice_signaling.gd      # WebRTC 信令服务
│   │
│   └── client/                         # ===== 客户端专用 =====
│       ├── main.gd                     # 客户端启动入口
│       ├── input_handler.gd            # 玩家输入 → 动作请求 → 服务端
│       ├── prediction.gd               # 客户端预测 + 服务端校正
│       └── rendering/
│           ├── first_person_camera.gd   # 第一人称相机
│           └── material_renderer.gd     # 材料外观渲染
│
├── scenes/                             # Godot 场景文件
│   ├── server_main.tscn                # 服务端入口场景
│   ├── client_main.tscn                # 客户端入口场景
│   └── test_scene.tscn                 # 物理测试场景 (100m×100m)
│
├── assets/                             # 美术资源 (Phase 1: 临时/占位)
│   ├── models/                         # 简易 3D 模型
│   ├── textures/                       # 简易贴图
│   └── sounds/                         # 简易音效
│
└── tests/
    ├── run_all_tests.gd                # 测试运行器入口
    ├── test_physics.gd                 # 物理公式测试套件
    ├── test_reactions.gd               # 化学反应测试套件
    ├── test_materials.gd               # 材料数据完整性测试
    └── test_network.gd                 # 网络同步测试
```

---

## Code Style

### GDScript 规范

```gdscript
# ============================================================
# 文件：scripts/shared/physics/physics_calculator.gd
# 职责：所有物理计算的静态函数库。服务端权威调用，客户端仅读取结果。
# ============================================================
class_name PhysicsCalc
extends RefCounted

## 计算挥击伤害。服务端权威。
## @param weapon: 武器属性 (MaterialProperty + 几何)
## @param angular_velocity: 挥击角速度 rad/s
## @param hit_point_distance: 命中点到握持点距离 m
## @param target_material: 被击中目标的材料属性
## @param hit_body_part: 命中部位
## @return DamageResult (穿透/钝伤判定 + 伤害值)
static func calculate_strike_damage(
    weapon: WeaponGeometry,
    angular_velocity: float,
    hit_point_distance: float,
    target_material: MaterialProperty,
    hit_body_part: BodyPart
) -> DamageResult:
    
    # 1. 线速度 = 角速度 × 杠杆臂长
    var linear_velocity: float = angular_velocity * hit_point_distance
    
    # 2. 动能 E_k = ½mv²
    var kinetic_energy: float = 0.5 * weapon.mass * linear_velocity * linear_velocity
    
    # 3. 硬度比——决定能量在武器和目标的分配
    var hardness_ratio: float = weapon.material.hardness_mohs / \
        (weapon.material.hardness_mohs + target_material.hardness_mohs)
    
    # 4. 接触面积取决于尖端曲率半径
    var contact_area: float = PI * weapon.tip_radius * weapon.tip_radius
    
    # 5. 碰撞能量传递
    var e: float = 0.05  # 肉体恢复系数
    var energy_to_target: float = kinetic_energy * hardness_ratio * (1.0 + e) / 2.0
    
    # 6. 压强判定 → 穿透 vs 钝伤
    var pressure: float = energy_to_target / max(contact_area, 0.000001)
    
    if pressure > target_material.yield_strength:
        # 穿透伤害
        var penetration_depth: float = (pressure - target_material.yield_strength) \
            / (target_material.density * linear_velocity * linear_velocity)
        return DamageResult.penetration(energy_to_target, penetration_depth, hit_body_part)
    else:
        # 钝伤——动能以冲击波传入
        return DamageResult.blunt(energy_to_target, hit_body_part)
```

### 命名约定
- **类名**：PascalCase (`MaterialProperty`, `PhysicsCalc`)
- **函数名**：snake_case (`calculate_strike_damage`, `apply_reaction`)
- **常量**：UPPER_SNAKE_CASE (`BASE_DECAY_RATE`, `MAX_PLAYERS_PER_CELL`)
- **导出变量**：snake_case (`hardness_mohs`, `yield_strength`)
- **私有函数**：`_` 前缀 (`_validate_mass_conservation`)
- **布尔变量**：`is_`, `has_`, `can_` 前缀

### 文件组织
- 每个文件一个 `class_name`，文件名与类名一致 (snake_case)
- 文件以描述注释块开头（职责说明）
- 公开函数必须有 `@param` 和 `@return` 文档注释
- 数学公式在原处注释推导

---

## Testing Strategy

### 框架
- GUT (Godot Unit Testing) — Godot 原生测试框架
- 测试通过 `godot --headless --script tests/run_all_tests.gd` 运行

### 测试层级

| 层级 | 范围 | 位置 | 覆盖率要求 |
|---|---|---|---|
| **单元测试** | 物理公式、反应、材料验证 | `tests/test_physics.gd` 等 | 100%（所有公式函数） |
| **集成测试** | 服务端权威验证、网络同步 | `tests/test_network.gd` | 关键路径 |
| **压力测试** | 50 假人 + 2 真人 | `tests/stress_test_50_clients.gd` | Phase 1 结束时 |

### Phase 1 必须通过的测试

```
test_physics.gd:
  ✓ test_free_fall_velocity          — v = √(2gh)
  ✓ test_terminal_velocity           — v_t = √(2mg/ρACd)
  ✓ test_kinetic_energy              — E_k = ½mv²
  ✓ test_static_friction             — F_s ≤ μs·N
  ✓ test_kinetic_friction            — F_k = μk·N
  ✓ test_rolling_resistance          — F_rr = Crr·N
  ✓ test_slope_slide_condition       — tan θ > μs
  ✓ test_capstan_equation            — T_load = T_hold·e^(μs·θ)
  ✓ test_lever_mechanical_advantage  — MA = L_effort / L_load
  ✓ test_pulley_mechanical_advantage — F = mg/n
  ✓ test_wedge_force                 — F_split = F_in/(2·sinα+μk·cosα)
  ✓ test_inclined_plane_force        — F = mg·(sinθ+μk·cosθ)
  ✓ test_buoyancy                    — F_buoy = ρ_fluid·V·g
  ✓ test_hydrostatic_pressure        — P = P₀+ρ·g·h
  ✓ test_heat_conduction             — dQ/dt = -k·A·ΔT/d
  ✓ test_phase_change_energy         — Q = m·Lf
  ✓ test_thermal_expansion           — ΔL = α·L₀·ΔT
  ✓ test_mohs_hardness_scratch       — H_A > H_B → A scratches B
  ✓ test_stress_strain               — σ = E·ε
  ✓ test_yield_fracture              — σ > σy→yield, σ > σt→fracture
  ✓ test_pressure_penetration        — P > σy_target → penetration
  ✓ test_torque                      — τ = F·r·sinθ
  ✓ test_rotational_inertia          — I = Σmᵢrᵢ²
  ✓ test_collision_elastic           — 弹性碰撞公式
  ✓ test_collision_inelastic         — 非弹性碰撞公式 × e
  ✓ test_projectile_range            — R = v₀²·sin(2θ)/g
  ✓ test_chop_formula                — 砍伐深度计算
  ✓ test_mine_formula                — 挖掘体积计算
  ✓ test_sharpen_formula             — Archard 磨损模型
  ✓ test_fall_damage                 — 坠物→带入打击公式

test_reactions.gd:
  ✓ test_combustion_mass_conservation   — 输入=输出
  ✓ test_smelting_mass_conservation     — 碳热还原质量守恒
  ✓ test_thermal_decomposition          — CaCO₃→CaO+CO₂
  ✓ test_dissolution                    — 草木灰+水→碱水
  ✓ test_reaction_temperature_requirement — 温度不足→不反应
  ✓ test_incomplete_combustion_co       — 缺氧→CO而非CO₂

test_materials.gd:
  ✓ test_all_materials_have_required_fields  — 每种材料覆盖全部字段
  ✓ test_density_positive                    — ρ > 0
  ✓ test_mohs_range                          — 0 < H ≤ 10
  ✓ test_friction_ordering                   — μs > μk (for each pair)
  ✓ test_poisson_range                       — 0 < ν < 0.5

test_network.gd:
  ✓ test_server_starts                    — Headless 进程启动
  ✓ test_client_connects                  — ENet 连接建立
  ✓ test_action_roundtrip                 — 砍树动作→服务端验证→结果返回
  ✓ test_offline_entity_catchup           — 离线 24h 后代谢正确衰减
```

### 测试运行
```bash
# 全部测试
godot --headless --path . --script tests/run_all_tests.gd

# 单项
godot --headless --path . --script tests/test_physics.gd

# CI 模式（JSON 输出）
godot --headless --path . --script tests/run_all_tests.gd --ci
```

---

## Boundaries

### Always
- 服务端权威：所有物理计算、反应判定、伤害计算在服务端执行
- 先定义材料属性（JSON），再写玩法逻辑（GDScript）
- 新增反应→添加到 `reactions.json`，不改 `reaction_system.gd`
- 材料数据从 JSON 启动时加载，运行时只读
- 反应输入质量 = 输出质量（验证函数 `_validate_mass_conservation`）
- 每个物理公式函数有对应单元测试
- 客户端仅做输入采集、预测渲染、服务端校正

### Ask First
- 修改材料属性字段结构（影响所有现有材料数据）
- 修改物理常数（G/g₀/R/大气/水参数）
- 新增反应类型（超出燃烧/碳热还原/热分解/溶解/发酵腐败五种）
- 添加第三方依赖
- 改变网络协议或序列化格式

### Never
- 硬编码任何配方或物品属性数值
- 「木剑伤害=5」之类的手动平衡值
- 物质凭空产生或消失（无来源的材料产出）
- 信任客户端输入（所有操作必须服务端验证后执行）
- 在客户端直接修改服务端权威状态

---

## Phase 1 实施任务（概要）

| # | 任务 | 依赖 | 预计文件数 |
|---|---|---|---|
| P1.1 | Godot 项目骨架 + 目录结构 + project.godot | — | 3 |
| P1.2 | PhysicsConstants 单例（G/g₀/R/M/大气/水/声光） | P1.1 | 1 |
| P1.3 | MaterialProperty 类（40+ 导出字段） | P1.1 | 1 |
| P1.4 | materials.json 材料数据库（50 种） | P1.3 | 1 |
| P1.5 | MaterialDB 加载与查询单例 | P1.3, P1.4 | 1 |
| P1.6 | PhysicsCalc 静态公式库（全部公式） | P1.2, P1.5 | 1 |
| P1.7 | ReactionSystem + reactions.json（15 反应） | P1.5 | 2 |
| P1.8 | PlayerBody + AnimalBody + OfflineEntity | P1.5 | 3 |
| P1.9 | 物理公式单元测试（全部 30+ 测试） | P1.6 | 1 |
| P1.10 | 反应系统单元测试 | P1.7 | 1 |
| P1.11 | ENet 服务端 + 客户端网络层 | P1.1 | 3 |
| P1.12 | 权威验证层（动作→服务端计算→广播） | P1.6, P1.11 | 1 |
| P1.13 | 客户端输入处理 + 预测渲染 | P1.11 | 2 |
| P1.14 | 2 人联机验证完整冶炼循环 | P1.12, P1.13 | — |
| P1.15 | 50 人压力测试 | P1.14 | 1 |

---

## Resolved Decisions

1. **持久化方式** → JSON 文件（FileAccess 读写），Phase 1 不引入数据库依赖
2. **美术资源** → Godot 内置 CSG 几何体（CSGBox3D/CSGCylinder3D/CSGSphere3D）搭临时模型，功能优先
3. **测试环境** → 本地 LAN 测试（开发机运行服务端 + 2 客户端），有 VPS 后再迁移
4. **Godot 版本** → 锁定 4.6.3 稳定版
5. **浮点一致性** → 服务端力学公式用纯 GDScript 数学计算，不依赖 Jolt 物理步进结果，跨平台浮点一致
