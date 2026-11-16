# 交接说明

最后更新：2026-11-16（提交 `fc7dd99` 之后）

给换一台机器继续做的人（或下一个会话）看。读完这一页再去翻
[SPEC.md](SPEC.md) 和 [CLAUDE.md](CLAUDE.md)。

---

## 1. 环境

| 项 | 值 |
|---|---|
| 引擎 | Godot **4.6.3**（本机是 `.mono` 构建，非 mono 也应当能跑） |
| 本机二进制 | `/home/niumo/bin/godot/godot` |
| 主场景 | `scenes/client_3d.tscn` |
| 物理引擎 | Jolt Physics（`project.godot` 里 `3d/physics_engine="JoltPhysics3D"`） |

`project.godot` 里 `config/features` 必须是 `"4.6"`。用 4.7 的编辑器打开会把它自动改成
`"4.7"`，提交前检查一下。`.godot/` 已 gitignore，新机器首次打开编辑器会重新导入，等它跑完。

---

## 2. 跑测试

**关键坑：`physics/3d/run_on_separate_thread=true` 让 Godot 退出时挂住不返回。**
所以每条命令都必须包 `timeout -s KILL`，**退出码 124 是正常的**，结果看 stdout。

```bash
GODOT=/home/niumo/bin/godot/godot          # 换机器改这里
run() { timeout -s KILL 240 "$GODOT" --headless --path . "scenes/$1.tscn"; }

run test_physics          # 64/64
run test_reactions        # 31/31
run test_items            # 39/39
run test_item_registry    # 80/80
run test_world_items      # 22/22
run test_world            # 玩法系统集成（打印式，无 PASS 计数）
run test_scene            # autoload/材料库自检（打印式）
```

物理手相关（每个 1-4 分钟，需要真实物理步进）：

```bash
run test_physical_hand    # 4/4  手部刚体与关节
run test_self_collision   # PASS 手脚与自身正常碰撞，无例外
run test_shoulder_rig     # PASS 肩关节行程 139.4°
run test_arm_lift         # PASS 抬臂
run test_arm_load         # PASS 负重
run test_arm_walk         # PASS 行走时手臂摆动
run test_motor_semantics  # PASS 铰链电机力矩语义（τ·dt、等长失速）
run test_arm_fracture     # PASS 骨骼断裂 + 皮肉重建耗时
run test_finger_limit     # PASS 指关节限位
run test_thumb_opposition # 打印式：拇指 0/30/60/90° 的指尖轨迹
run test_item_fallback    # PASS 物品掉穿地形回位
run test_finger_grip      # 2/3 **FAIL（已知问题，见 §5.1）**
```

`test_arm_fracture` 支持 `FRACTURE_MODE=finger` 环境变量：
`FRACTURE_MODE=finger run test_arm_fracture` 只断右手食指中节。

`tests/test_reactions.gd` 曾经在注释里写 `--script tests/test_reactions.gd`，
**那样跑不起来**（`--script` 模式不加载 autoload，编译期就找不到 MaterialDB）。
现在有 `scenes/test_reactions.tscn`，走场景。

---

## 3. 当前进度

### Phase 1（SPEC P1.1–P1.15）

| 状态 | 项 |
|---|---|
| ✅ 完成并测试通过 | P1.1–P1.13：项目骨架、PhysicsConstants、MaterialProperty、materials.json（**70 种**，要求 ≥50）、MaterialDB、PhysicsCalc（64 条公式测试）、ReactionSystem（**26 个反应 / 6 类**，要求 ≥15，全部质量守恒）、PlayerBody/AnimalBody/OfflineEntity、单元测试、ENet 网络层、权威验证、客户端输入 |
| ⚠️ 声称完成、本次未复核 | P1.14 两人联机跑完整冶炼循环、P1.15 50 人压测。`85694e2` 提交信息说做了，但此后工作区改动很大（物理手整套），没有重跑 |
| — | 服务端权威分端 / 流式下发：按 CLAUDE.md 的 Phase 1 策略**故意延后**，当前客户端本地确定性生成世界 |

### 超出原 SPEC 范围、当前主攻

真物理手 / 骨架子系统，本轮全部提交（`6d5f0cb`）：

- 肩 → 上臂 → 前臂 → 掌 → 指 的刚体链，Jolt 力限铰链电机
- 肌肉力矩 = `PlayerBody.get_joint_max_torque()`（肌力 × 解剖力臂），
  不主动发力时给 50% 姿态支撑
- 四指三节、拇指两节；拇指生长方向垂直于四指，屈曲平面与四指垂直
- 骨骼受力判定：重力矩 + 接触力臂矩 > σ·W 就断，断口皮肉收在近侧骨节远端
- 皮肉 ImmediateMesh 每帧沿骨节链重扫

---

## 4. 代码地图

改物理手之前只需要看这三个文件：

| 文件 | 行数 | 内容 |
|---|---|---|
| [scripts/client/first_person_controller.gd](scripts/client/first_person_controller.gd) | 2069 | 骨架、手指、肌肉力矩、骨折、皮肉网格、HUD |
| [scripts/shared/entities/player_body.gd](scripts/shared/entities/player_body.gd) | 383 | 骨骼材料常数、截面、断裂力矩、关节力臂 |
| [scripts/shared/physics/contact_resolver.gd](scripts/shared/physics/contact_resolver.gd) | 388 | 工具/地面接触：Hertz、磨损、屈曲、等效材料 |

`first_person_controller.gd` 里的关键入口（行号会漂，按函数名找）：

| 函数 | 干什么 |
|---|---|
| `_build_arm_rig(h)` | 建一条手臂的刚体链和关节 |
| `_build_fingers_for_hand(h, palm)` | 建 5 根手指的物理骨节 + 铰链 |
| `_build_fingers_on_hand(hand_root, h, skin)` | 建手指的视觉/基座（拇指根几何在这里） |
| `_finger_flex_deg(h, f, j)` | 量某个关节的屈曲角（肌肉反馈用） |
| `_update_finger_muscles(...)` | 每帧给指关节电机下达力矩 |
| `_update_bone_fractures(sky, g)` | 每帧扫描骨段载荷 |
| `_break_bone(c)` | 执行断裂：切铰链、放开骨节 |
| `_rebuild_body_skin()` | 每帧重扫皮肉网格 |

其他：`scripts/client/contact_force_probe.gd`（接触力探针）、
`scripts/client/item_physics_body.gd`（物品地面回位）、
`scripts/shared/world/terrain.gd::get_subsurface_composition()`。

---

## 5. 已知问题（按优先级）

### 5.1 握持不稳定 —— `test_finger_grip` 2/3 失败

木棍有时能握住，有时被指尖弹出掌心。`NO_THUMB=1` 也会失败，所以不是拇指的问题。
根因：**刚性指尖胶囊 + 硬接触**，接触力集中在一点，指尖互相把木棍楔出去。

调 Jolt 的 `penetration_slop` 能改善某一件物品、又让另一件变坏：
0.10 kg 木棍两次运行一次握住一次被甩飞——对参数是混沌的。

**提议的解法**：给指尖加一层可压缩的指腹接触层（真实指腹有 3–5 mm 皮下脂肪，
接触压力被摊到整个指腹面）。这是"物理优先"的自然做法，不是加抓取力常数。
未实现。

### 5.2 骨折后卡顿 —— 未能复现

用户报告"骨折后游戏非常地卡"。headless 实测结果相反：骨折后物理耗时反而下降
（8.1→4.8 ms，帧间隔 16.5→10.1 ms）。已经修掉两条**无界增长**路径：

1. 断口近侧皮肉被扫到远侧骨节起点 → 两段分开后皮肉被拉成几十米的管子，
   每帧细分点数随距离无限增长（这是最可能的真凶）
2. `_skin_chain` 细分步数封顶 16 步（0.72 m）

如果换机器后仍然卡，需要的信息：哪根骨、是持续掉帧还是周期性尖峰、
当时在做什么动作、是否在陡坡上。

### 5.3 拇指根位置与握持口袋不重合

按用户要求把拇指根往手臂方向挪了一个指节（`z = 0.000`），现在它比四指
合拢围出的握持口袋（`z ≈ -0.055 … -0.078`）靠近端 5–7 cm，**拇指对掌够不到握持区**。
若要恢复对掌能力，需要采用用户当时提的方案二：第一指节前倾 45°。
**这是产品决定，改之前先问。**

### 5.4 地下混合材料未接入

`terrain.get_subsurface_composition()` 已经能按深度返回物质组成，
`ContactResolver.composite()` 也能把混合组成折算成等效材料，
但**还没有任何地方调用这条链**——挖土/接触地面的物理仍按单一材料算。
接入点是 `contact_resolver` 的调用方（工具压地）与物品回位的射线查询。

### 5.5 `README.md` 不是本项目的

当前 [README.md](README.md) 是 `addons/copy_all_errors/` 那个 vendored 插件自带的说明。
**改它之前必须跟作者确认。** 本次交接没有动它。

---

## 6. 提交历史

```
3a4b466 测试：补上 test_reactions 场景
f42dfec 测试：补上 test_physics 场景文件
fc7dd99 物理参数：Jolt 速度迭代 24、穿透容差 0.5 mm、推测接触 4 mm
442bc6c 落枝加粗到 3.0-6.5 cm
5108c98 物品掉穿地形：按当前位置回位，不再瞬移回出生点
b3d1c8a 地形：地下物质组成（复合材料的来源）
6d5f0cb 物理手：肩-肘-腕-掌-指铰链链、肌肉力矩、骨骼断裂与皮肉网格
91b828c 玩家身体：骨骼材料力学、关节力矩与骨质疏松
df39e06 接触层：ContactResolver 与 ContactForceProbe
9c6eea2 恢复 project.godot 引擎特性版本到 4.6
ee56fc0 检查点：规则地形、动态物品、物理手原型与角色控制
b6f883d Phase 1 玩法系统完成 + 3D客户端 + 建模指南
a73d638 玩法系统：世界生成 + 冶炼 + 锻造 + 自由建造
85694e2 Phase 1 完成：物理引擎 + 网络层 + 联机验证
```

每个提交的正文都写了**为什么**改，`git show <hash>` 可读。从这个提交之后
约定：一个提交只做一件事，正文写动机和验证结果。

---

## 7. 下一步建议

1. **指腹软组织接触层**（§5.1）——握持是"无背包 + 手持"玩法的基础，
   这件不解决，后续所有物品交互都测不准。
2. **重新验证 P1.14/P1.15**——两人联机 + 50 人压测，把结果写回 SPEC。
3. 把 `get_subsurface_composition` 接到接触路径（§5.4），让挖土的手感来自
   真实地层而不是一种土。
4. 骨折后卡顿若在新机器上复现，按 §5.2 收集四项信息再查。
