# 物理携带模型 — 最小设计稿

> 状态：草案（Phase 1）
> 进度：步骤 0/0a（ItemEntity + 材料表面/结构字段）、步骤 1（ItemRegistry 唯一位置索引）、步骤 2（世界物品实体）已实现并测试通过（2026-11-05）
> 目标：用「手持 / 绑扎 / 构造物空腔」替换 `inventory` 与 `equipped` 槽位，物品始终是世界中的物理实体。
> 非目标：布料软体模拟、逐顶点空腔形变、物品交接动画、液体在空腔内的流动模拟。

---

## 1. 第一原则

1. **物品是实体**：有唯一 ID、材质、几何和状态，存在位置只有四种——世界里、手里、绑在身上、某个构造物围出的空腔里。
2. **没有瞬移**：拾取 = 手抓住，携带 = 握持或绑扎，收纳 = 放进构造物围出的空腔。每次转移都是服务端校验过的物理移动。
3. **属性从材料 + 几何推导**：质量 = 密度 × 体积；握持上限 = 摩擦 × 握力；绳结强度 = Capstan + 抗拉；空腔容纳 = 实际内壁几何 + 壁材料性质。
4. **守恒**：任意时刻每个 `item_id` 恰好存在于一个位置。转移前后总质量不变。

---

## 2. 数据模型

### 2.1 ItemEntity

```gdscript
class_name ItemEntity
extends RefCounted

var item_id: int              # 服务端分配，全局唯一，存档后不变
var material_id: String
var shape: String             # rod / blade / block / plank / wedge / sphere / fiber / granular
var dimensions: Dictionary    # {length, width, height} 或 {radius}，单位 m
var parts: Array              # 空 = 单一均质物品；非空 = 玩家组合/编织出的构造物
var connections: Array        # 部件之间的连接/编织关系（见 ConstructionValidator）
var transform: Transform3D
var temperature_c: float
var wetness: float            # 0-1
var integrity: float          # 0-1，破损程度
var tip_radius_m: float       # 磨尖后的尖端半径；未加工为 -1
var location: Dictionary      # 见 2.3

func get_volume_m3() -> float
func get_mass_kg() -> float   # 单一物品：density × volume；构造物：Σ 部件质量。派生，不手填
```

**质量不存盘为事实**：序列化时可以带 `mass_kg` 作为缓存，加载时按材料 + 几何重算并校验，防止存档被改或数据漂移。

### 2.2 玩家携带状态（替换 inventory/equipped）

```gdscript
{
    "hands": {
        "left":  0,          # item_id，0 = 空手
        "right": 0
    },
    "grip_hands": {          # 双手持同一件重物时
        1042: 2
    },
    "attachments": [         # 绑扎点，不是装备槽
        {
            "item_id": 1043,
            "anchor": "waist",       # waist / back / shoulder
            "rope_item_id": 1050,
            "wraps": 3,
            "knot_capacity_n": 420.0
        }
    ],
    "carried_load_kg": 0.0   # 每 tick 派生，用于体力消耗与速度
}
```

没有物品数组。手上最多两件；双手持一件时占用两个手位。

### 2.3 位置

```gdscript
# 四种之一，互斥
{"kind": "world",     "transform": Transform3D}
{"kind": "hand",      "holder_id": int, "hand": "left"|"right"}
{"kind": "attached",  "holder_id": int, "attachment_index": int}
{"kind": "inside",    "assembly_id": int, "cavity_id": int}   # 位于某个构造物围出的空腔中
```

服务端每次位置变更都断言：该 `item_id` 在所有空腔/手/绑扎/世界索引中只出现一次。

---

## 3. 手部抓握

### 3.1 握力

```gdscript
# PlayerBody 新增
func get_grip_force() -> float:
    return maxf(get_max_force(), 50.0)   # 单手，N

func get_wrist_torque_limit() -> float:
    return get_max_force() * 0.07        # N·m，腕部力臂约 7cm
```

现有 `get_max_force()` 默认 300 N，对应单手可握约 18–24 kg（取决于摩擦）。

### 3.2 能不能抓住

```gdscript
func can_grip(player: PlayerBody, item: ItemEntity, hands: int,
              hand_surface: SurfaceState, sliding_dir: Vector3) -> Dictionary:
    # μ 由接触双方的表面状态和环境实时计算，不是常数（见 3.3）
    var contact := FrictionModel.evaluate(
        hand_surface, item.get_surface(),
        player.get_grip_force() * hands, sliding_dir, player.get_environment())
    var mu: float = contact["static_mu"]
    var grip := player.get_grip_force() * hands      # 双手叠加
    var max_mass := mu * grip / PhysicsConstants.g0
    if item.get_mass_kg() > max_mass:
        return reject("slip: %.2f kg > %.2f kg" % [item.get_mass_kg(), max_mass])

    # 力矩：重心离握点越远越难拿
    var lever := item.get_center_of_mass_offset().length()
    var torque := item.get_mass_kg() * PhysicsConstants.g0 * lever
    if torque > player.get_wrist_torque_limit() * hands:
        return reject("torque: %.1f N·m > %.1f N·m" % [torque, ...])
    return ok()
```

- 单手拿不动的物品：可以尝试双手（`hands = 2`），或拖拽（后续）。
- 剧烈运动增加等效重量：`effective_mass = m * (1 + |a| / g0)`，冲刺/跳跃时校验；Phase 1 可先只算静态。
- 抓取距离：手部锚点到物品抓取点的距离 ≤ 臂长 0.65 m + 物品半径，且服务端做一次视线检查。
- 握力上限不是固定值：μ 由表面状态实时计算，湿、油、泥、血、温度、纹路方向都会改变它，可能降低也可能升高。

### 3.3 摩擦不是常数

摩擦系数不写死，也不是「材料 A + 材料 B」查一张表。它由接触双方的表面状态和环境共同决定：

```
μ = f(材料对, 微观结构, 表面粗糙度, 纹路方向, 硬度比,
      水膜 / 油膜 / 泥 / 血 / 灰, 温度, 法向压力, 相对滑动速度, 磨损)
```

#### 表面状态

每件物品、每只手都有 `SurfaceState`：

```gdscript
{
    "material_id": String,
    "roughness_um": float,     # 由材料 + 加工方式决定：抛光/劈砍/锯切/编织/磨损
    "grain_dir": Vector3,      # 局部坐标下的纹路方向：木纹、纤维、层理、肌肉
    "wetness": float,          # 0-1：吸附水、汗、雨、血
    "oil_film": float,         # 0-1：油脂、动物脂肪
    "third_body": String,      # "mud" / "sand" / "ash" / "blood" / ""
    "temperature_c": float,
    "wear": float              # 抛光/磨损程度
}
```

手也走同一套状态：汗、油、泥、血、茧（粗糙度）、温度、伤口。茧越厚越粗糙；出汗/沾油改变摩擦；这些都从 `PlayerBody` 的体力、代谢、动作历史推导，不写死。

#### 摩擦的组成

- **粘着**：表面能 / 软表面硬度，决定干净干燥接触的基准 μ
- **犁沟**：硬表面的粗糙峰压入软表面，与硬度比、粗糙度斜率相关
- **滞后**：柔性/粘弹性材料（皮、纤维、肉）随粗糙度变形耗能
- **第三体层**：水、油、泥、血、灰，可能润滑，也可能增加磨粒磨损
- **纹路各向异性**：顺纹与横纹的 μ 不同（木材、纤维、层状岩石、肌肉）
- **温度**：接近软化点/熔点、结冰、皮肤出汗都会改变
- **速度与压力**：静摩擦峰值、动摩擦稳态；润滑接触存在 Stribeck 曲线

#### 数据字段

现有 `static_friction` / `kinetic_friction` 改为**标准干燥抛光表面的基准值**，用于校准，不再直接当最终 μ。建议补充：

- `microstructure`：crystalline / fibrous / granular / amorphous / porous / lamellar
- `surface_roughness_um`：材料默认值，物品可按加工方式覆盖
- `friction_anisotropy`：横纹/顺纹 μ 比，各向同性为 1.0
- `surface_energy_mj_m2`：粘着项
- `softening_point_c`：有机/高分子/皮/纤维的软化温度

#### 环境

湿度来自气候与局部环境（雨天、水边、洞穴）；温度来自天气、火源、太阳；油/血/泥来自动作（屠宰、挖掘、受伤）。这些都进入 `SurfaceState`，不是全局常数。

#### 缓存

μ 按「量化后的表面状态 + 环境」缓存；`wetness / oil / temperature / wear` 变化超过阈值时重算。50 人规模下按接触对重算的成本可接受。

#### 行为例子

- 干燥的手抓石头：粘着 + 犁沟，μ 较高
- 满手动物油抓石斧：油膜润滑，μ 显著下降 → 握不住
- 湿手抓湿木头：木材吸水膨胀、纤维变软，μ 可能不降反升
- 顺木纹 vs 横木纹：握持与绑扎的牢固度不同
- 冻僵的手抓冰面：μ 与握力同时下降

### 3.4 服务端动作

- `GRAB {item_id, hand}`：手必须空、物品在世界、距离/握力/力矩通过。
- `RELEASE {hand}`：物品落到手的位置，继承玩家速度，成为世界实体。
- `REGRIP {item_id, hands}`：切换单手/双手。
- 不允许「召唤」：武器参数永远来自手里那件 `ItemEntity`，不是客户端传的 `weapon_id`。

---

## 4. 绑扎

### 4.1 锚点

| 锚点 | 承载系数 | 说明 |
|---|---|---|
| `waist` | 1.5 × `get_carry_capacity()` | 腰带/腰绳 |
| `back` | 2.0 × | 背捆 |
| `shoulder` | 1.0 × | 单肩斜挎 |

默认 `get_carry_capacity()` = 体重 × 0.2（70 kg → 14 kg），所以腰部长期负重上限约 21 kg。

### 4.2 绳结强度

复用 [capstan_max_load](scripts/shared/physics/physics_calculator.gd#L106)：

```
T_hold = 绳索抗拉强度(Pa) × 截面积(m²) × 结效率(0.4–0.6)
T_load = T_hold × e^(μs × θ)        # θ = 2π × 缠绕圈数
```

- 校验 `item.mass × g ≤ T_load`，否则打结时滑脱。
- 同时校验锚点承载与绳索自身抗拉。
- 冲击（被击中、坠落）可让绳结松动/断裂，Phase 1 可先只做静态载荷。

### 4.3 绑扎不是装备槽

- 绑在背上的刀不会自动出现在手里；取用需要松绑 + 用手抓。
- 绑扎工具仍可用于建造验证（例如把石斧头绑在木柄上），复用 [ConstructionValidator](scripts/shared/world/construction_validator.gd)。

---

## 5. 容纳（空腔）——构造物的涌现能力

「容器」不是物品类型、不是子类、不是配方产物。任何玩家按自己的想法组合或编织出来的构造物，只要几何上围出了空腔、壁面能挡住内容物，它自然就能装东西。服务端不判断「这是不是容器」，只判断「这个空腔能不能容纳这个物体」。

### 5.1 构造物

一个 `ItemEntity` 可以是单一均质物品（`parts` 为空），也可以是玩家拼装/编织出的构造物（`parts` 非空）：

```gdscript
{
    "item_id": 2001,
    "parts": [
        {"material_id": "vine", "shape": "fiber", "dimensions": {...}, "transform": ...},
        {"material_id": "vine", "shape": "fiber", "dimensions": {...}, "transform": ...}
    ],
    "connections": [
        {"type": "weaving", "part_a_idx": 0, "part_b_idx": 1, "pattern": {...}},
        {"type": "binding", "part_a_idx": 0, "part_b_idx": 1, "wraps": 3}
    ]
}
```

工具、篮筐、木桶、皮袋、陶罐都走同一套数据：部件 + 连接 + 几何。没有「容器配方」，也没有「容器物品 ID」。

### 5.2 空腔推导（服务端，构造完成后计算一次并缓存）

**刚性构造物**：把每个部件按其几何基元（盒/柱/球/胶囊）栅格化到 2–5 cm 体素网格，从外部 flood fill；无法从外部到达的空体素就是空腔。

- `cavity_volume_m3` = 空腔体素数 × 体素体积——由**实际内壁**决定，不是声明的容量
- `opening` = 空腔与外部相连的通道，记录开口位置、法线、最小宽度
- `wall_thickness` / `wall_material` = 包围该空腔的体素与部件
- 一个构造物可以围出多个独立空腔，每个空腔单独描述

**编织 / 柔性结构**（藤篮、布兜、皮袋）：不靠体素，靠编织参数推导：

- 纤维直径、间距、编织方式 → `gap_size_m`
- 材料吸水性 → 潮湿时纤维膨胀，缝隙变小、容积略缩
- 柔性壁会随载荷下垂，空腔形状随姿态变化（Phase 1 只做静态近似）

空腔描述在构造完成时缓存；部件破损、拆解、受热变形时重新计算。

### 5.3 能不能装（对每个内容物单独判定）

不是「容量 = N 格」，而是逐项检查：

1. **几何通过**：内容物最小截面能否通过开口最小宽度；放不进就是放不进。
2. **容积**：`Σ(item.volume × 1.4) ≤ cavity_volume`，1.4 是不规则堆积系数。
3. **支撑**：开口朝上时内容物由空腔底部支撑；倾斜超过内容物 `angle_of_repose`（叠加壁面摩擦）时内容物失去支撑而洒出；开口朝下无法保持。
4. **泄漏**：编织/多孔壁按 `gap_size_m` 判定——
   - 颗粒：粒径 > 缝隙 → 留住；否则漏
   - 液体：缝隙超过毛细可维持的阈值，或材料渗透性过高 → 漏；表面张力、粘度参与判定
   - 连续固体壁（陶、金属、致密木）默认不渗漏，除非有裂纹/破损
5. **结构**：总载荷 vs 壁面/接缝/编织节点强度；超过时 `integrity` 下降，破损后内容物洒落。
6. **环境**：温度（软化/熔化/冻裂）、湿度（吸水膨胀、强度下降、腐烂）、内容物温度（热物品烫坏壁）都参与。

同一个构造物，装石头可以、装沙子漏、装水漏——这是几何与材料性质的自然结果，不需要额外规则。

### 5.4 材料微结构与环境

容纳能力最终由材料的微观结构决定。现有 40+ 属性覆盖了一部分，建议补一个 `microstructure` 字段：

| 微结构 | 行为 |
|---|---|
| `crystalline` | 致密、硬、脆；无裂纹时不渗漏 |
| `fibrous` | 各向异性、可编织、吸水、湿态强度下降 |
| `granular` | 无自支撑，湿态靠粘聚；适合做陶坯，不适合直接当壁 |
| `amorphous` | 玻璃/树脂类，致密但脆 |
| `porous` | 陶、浮石；渗水、毛细上升 |
| `lamellar` | 层状（页岩、云母），易沿层裂开 |

湿度影响由 `water_absorption`、`capillary_rise`、`biodegradability` 与运行时 `wetness` 共同推导；不写死「篮子会烂」这种规则。环境湿度来自气候系统，材料吸湿后强度、缝隙、容积都随之变化。

### 5.5 放入 / 取出

- `PLACE {assembly_id, cavity_id, item_id, hand}`：手必须同时够得到物品和空腔开口，并通过 5.3 的全部检查。
- `TAKE {assembly_id, cavity_id, item_id, hand}`：手空、开口可及。
- 内容物仍是独立 `ItemEntity`，位置为 `inside`，参与构造物总质量与重心计算。
- 没有「格子」；排列顺序只影响渲染，不影响物理。

---

## 6. 服务端权威流程

```
客户端意图 → Authority 校验 → 修改 ItemEntity 位置 → 广播状态
```

校验清单：

1. 物品存在，且当前不在别人手里/空腔里。
2. 距离与视线（手部锚点到物品）。
3. 手位可用、握力/力矩足够。
4. 绑扎的绳/锚点强度足够。
5. 空腔：几何通过、容积、支撑/洒落、泄漏、壁与节点强度、环境（温度/湿度）全部通过。
6. **守恒断言**：转移后全服索引中该物品只出现一次。

失败返回 `ACTION_RESULT {ok: false, reason}`，不做「尽力而为」的部分成功。

客户端永远不能传：质量、几何、材质、伤害、容量。只能传 `item_id` 和意图。

---

## 7. 网络协议（最小）

### 客户端 → 服务端

| 包 | 字段 |
|---|---|
| `GRAB` | `item_id, hand` |
| `RELEASE` | `hand` |
| `REGRIP` | `item_id, hands` |
| `ATTACH` | `item_id, anchor, rope_item_id, wraps` |
| `DETACH` | `item_id` |
| `PLACE` | `assembly_id, cavity_id, item_id, hand` |
| `TAKE` | `assembly_id, cavity_id, item_id, hand` |

### 服务端 → 客户端

| 包 | 字段 |
|---|---|
| `ITEM_SPAWN` | `item_id, material_id, shape, dimensions, transform` |
| `ITEM_DESPAWN` | `item_id` |
| `ITEM_STATE` | `item_id, transform, location` |
| `CARRY_STATE` | `hands, attachments, carried_load_kg` |

- `PICKUP` → `GRAB`，`DROP` → `RELEASE`；`EQUIP/UNEQUIP` 删除，不再有装备槽概念。
- 兴趣管理：只同步附近世界物品；手持/绑扎物品始终同步给本人和附近玩家。

---

## 8. 持久化

存档保存：

- 所有 `ItemEntity`（含 ID、材质、几何、部件、连接、状态、位置）
- 玩家的 `hands / attachments`
- 构造物空腔的 `contents`

加载时：

1. 按材料 + 几何重算质量。
2. 重建位置索引。
3. 校验每个 `item_id` 只出现一次；孤儿物品落到最后已知世界坐标。
4. 不保存任何 `inventory` 数组。

---

## 9. 迁移步骤（每步可独立提交、测试保持绿色）

| 步骤 | 内容 | 涉及文件 | 状态 |
|---|---|---|---|
| 0a | 材料补 `microstructure` / `surface_roughness_um` / `friction_anisotropy` / `softening_point_c`；归一化 13 种加工产物的旧字段名与单位 | `material_property.gd`、`material_database.gd`、`materials.json` | ✅ 完成 |
| 0 | 新增 `ItemEntity` 与质量/几何/表面状态/序列化单测 | `scripts/shared/items/item_entity.gd`、`tests/test_items.gd`、`scenes/test_items.tscn` | ✅ 完成 |
| 1 | 服务端物品注册表与位置索引（世界里/手/绑扎/空腔）；原子移动、回滚、守恒与环检测 | `scripts/server/item_registry.gd`、`tests/test_item_registry.gd`、`scenes/test_item_registry.tscn` | ✅ 完成 |
| 2 | 世界生成产出物品实体（石头、倒木、矿脉露头）；服务端注册，客户端渲染（Phase 1 确定性本地生成） | `world_item_spawner.gd`、`world_generator.gd`、`world_renderer.gd`、`server/main.gd`、`tests/test_world_items.gd` | ✅ 完成 |
| 3 | 双手 + `GRAB/RELEASE`，旧 `equip` 保留为回退路径 | `authority.gd`、`network_packet.gd`、`client/input_handler.gd` |
| 4 | `swing` 从实际持有物品推导武器参数，删除默认石斧 | `authority.gd`、`player_body.gd` |
| 5 | 绑扎（绳结 + 锚点），接入建造验证 | `carry_system.gd`、`construction_validator.gd` |
| 6 | 构造物空腔推导（体素 + 编织）+ `PLACE/TAKE`（放入/取出/洒落/超载） | `containment_evaluator.gd` |
| 7 | 删除剩余的 `equipped` 旧装备槽与客户端 inventory 输入，更新文档与测试（`inventory` 占位已移除） | `authority.gd`、`input_handler.gd`、`SPEC.md` |

---

## 10. 测试清单

### 单元

- 质量 = 密度 × 几何体积；改几何后质量随之变化
- 单手/双手握持上限；力矩超限拒绝；超出臂长拒绝
- 摩擦：干手 vs 油手 vs 泥手抓同一石斧，握持上限不同；顺纹/横纹绑扎强度不同；湿木材摩擦变化方向由吸水率决定；温度接近软化点时 μ 下降
- 绳结：Capstan 载荷、绳断、锚点超载
- 空腔：实际内壁容积、开口通过性、倾斜洒落、超载破损
- 泄漏：同一构造物装石头不漏、装沙子/水漏；缝隙与粒径/毛细关系正确
- 湿度：纤维吸湿后缝隙缩小、强度下降，容纳判定随之变化
- 守恒：任意转移前后总质量不变、每个 `item_id` 唯一位置
- 存档读档往返：位置、手、绑扎、空腔内容一致

### 集成

- 地面石头 → 抓取 → 与木棍绑扎 → `ConstructionValidator` 识别为石斧 → 砍树
- 玩家 A 松手，玩家 B 在范围内抓取；无复制、无瞬移
- 断开连接：手里物品按握力判定留在离线实体手上或落地
- 玩家自己编一个藤筐：装石头成功、装细沙漏出；倾斜后内容物逐个洒出，落地后仍可被抓取

---

## 11. Phase 1 裁剪

**本轮实现**

- `ItemEntity` + 世界物品 + 玩家拼装/编织出的构造物
- 双手抓握 / 松手 / 双手持
- 绳索绑扎到身体和工具
- 刚性构造物空腔（体素 flood fill）+ 编织缝隙判定（至少藤编）
- `PLACE/TAKE` 与洒落、超载

**暂缓**

- 细密织物/皮革缝制的精细缝隙模型
- 拖拽、攀爬时携带、双人抬运
- 逐件内容物刚体堆叠
- 空腔形变、液体在空腔内的流动
- 物品交接动画与手部 IK

---

## 12. 决策状态

### 已确认

1. **摩擦模型**：按表面状态实时计算——材料对 + 微观结构 + 纹路各向异性 + 水/油/泥/血膜 + 温度 + 压力/速度；手也用同一套状态（汗、油、茧、温度、伤口），不写死任何 μ。
2. **空腔推导**：3 cm 体素 + 外部 flood fill（刚性构造物）与编织参数化（柔性构造物），构造完成时计算一次并缓存。
3. **材料微结构**：已加入 `microstructure`（crystalline/fibrous/granular/amorphous/porous/lamellar）以及粗糙度、纹路各向异性、软化温度字段，70 种材料全部覆盖。
4. **掉线持有**：按握力判定——离线实体继续持有，握不住的物品落地。
5. **服务端物品物理**：Phase 1 用自定义粗粒度模拟（静止物品休眠），不逐件开 Jolt 刚体；客户端只做表现。

### 待定

- **物品加工**：磨尖/锻造会改变 `tip_radius_m`、几何与 `integrity`，需要定义「修改物品」动作，建议单独一份设计稿。
- **电磁字段**：`resistivity` / `magnetic_permeability` 目前只存在于 JSON 的 8 种材料里，`MaterialProperty` 尚未读取，属于既有数据缺口，后续统一处理。
