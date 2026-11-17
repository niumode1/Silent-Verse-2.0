# 交接说明

最后更新：2026-11-16（提交 `fc7dd99` 之后）

> **2026-11-17 本机更新**：物品物理全物理化、材料试验场、物质场/
> 行星内部/3D 矿脉、GDScript DEM 小样、C++ GDExtension 粒子内核。
> 具体改动、决策、基准和未完成项见 [CHANGES.md](CHANGES.md)。

给换一台机器继续做的人（或下一个会话）看。读完这一页再去翻
[SPEC.md](SPEC.md) 和 [CLAUDE.md](CLAUDE.md)。

---

## 1. 环境

| 项 | 值 |
|---|---|
| 引擎 | Godot **4.7.2**（升级到 4.7 后，4.6 的 `.mono` 构建不再使用） |
| 本机二进制 | `I:\godot\Godot_v4.7.2-stable_win64.exe` |
| 主场景 | `scenes/client_3d.tscn` |
| 物理引擎 | Jolt Physics（`project.godot` 里 `3d/physics_engine="JoltPhysics3D"`） |

`project.godot` 里 `config/features` 现在是 `"4.7"`，用 4.7 打开不会再改写。但要注意
**4.6 → 4.7 的升级改写是有损的**：它会把 `penetration_slop` 上方那段注释整块删掉，
升级或换引擎后先 `git diff project.godot` 核对。

`.godot/` 已 gitignore。**新机器 / 换引擎版本后，第一次跑测试前必须先重建类缓存**：

```
<godot> --headless --editor --quit --path .
```

否则 `global_script_class_cache.cfg` 是旧的，所有依赖 `class_name` 的测试会报
`Identifier "X" not declared` / `Parse Error` 的假失败（2026-11-16 实测踩过）。

---

## 2. 跑测试

**关键坑：`physics/3d/run_on_separate_thread=true` 让加载了 3D 物理的场景在退出时挂住不返回。**
纯计算场景（如 `test_contact_resolver`）能正常退出，`test_physics`、`test_physical_hand`、
`test_world`、`test_world_items` 会挂住。所以每条命令都必须带超时杀进程，结果只看 stdout。

```powershell
$GODOT = "I:\godot\Godot_v4.7.2-stable_win64.exe"
$PROJ  = "H:\Silent Verse 2.0"        # 路径含空格，传给引擎时必须带引号
function run($name) {
    $p = Start-Process $GODOT -PassThru -NoNewWindow `
        -ArgumentList "--headless --path `"$PROJ`" scenes/$name.tscn"
    if (-not $p.WaitForExit(240000)) { $p.Kill() }
}

run test_physics          # 64/64
run test_reactions        # 31/31
run test_items            # 39/39
run test_item_registry    # 80/80
run test_world_items      # 22/22
run test_world            # 玩法系统集成（打印式，无 PASS 计数）
run test_scene            # autoload/材料库自检（打印式）
```

物理手相关（2026-11-16 在 Windows + 4.7.2 上实测每个 2–17 秒）：

```powershell
run test_physical_hand    # 4/4  手部刚体与关节
run test_self_collision   # PASS 手脚与自身正常碰撞，无例外
run test_shoulder_rig     # PASS 肩关节行程 140.9°
run test_arm_lift         # PASS 抬臂
run test_arm_load         # PASS 负重
run test_arm_walk         # PASS 行走时手臂摆动
run test_motor_semantics  # PASS 铰链电机力矩语义（τ·dt、等长失速）
run test_arm_fracture     # PASS 骨骼断裂 + 皮肉重建耗时
run test_finger_limit     # PASS 指关节限位
run test_thumb_opposition # 打印式：拇指 0/30/60/90° 的指尖轨迹
run test_item_fallback    # PASS 物品掉穿地形回位
run test_finger_grip      # PASS 指腹软组织层能握住 Ø3.2 cm 木棍（§5.1）
```

`test_arm_fracture` 支持 `FRACTURE_MODE=finger` 环境变量：
`$env:FRACTURE_MODE="finger"; run test_arm_fracture` 只断右手食指中节。

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

2026-11-16 在 Windows + Godot 4.7.2 上把上面 21 个测试场景全量重跑了一遍：
单元类与物理手/手臂类全部通过。当天下午给指骨加了指腹软组织接触层之后
`test_finger_grip` 也转为通过（§5.1）。4.7 没有引入回归。

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
| `_build_pulp_samples(...)` | 建一节指骨的指腹采样点（12-15 个） |
| `_update_finger_pads(h)` | 每帧把指腹软组织力施加到手指和物体上 |
| `_update_bone_fractures(sky, g)` | 每帧扫描骨段载荷 |
| `_break_bone(c)` | 执行断裂：切铰链、放开骨节 |
| `_rebuild_body_skin()` | 每帧重扫皮肉网格 |

其他：`scripts/client/contact_force_probe.gd`（接触力探针）、
`scripts/client/item_physics_body.gd`（物品地面回位）、
`scripts/shared/world/terrain.gd::get_subsurface_composition()`。

---

## 5. 已知问题（按优先级）

### 5.1 握持不稳定 —— 接触模型已修，大树枝仍握不住

旧症状：木棍有时能握住，有时被指尖弹出掌心（同一份代码连跑三次只过一两次）。
根因：**刚性指尖胶囊 + 硬接触**是单点接触，手指继续收拢时把木棍像瓜子一样楔出去。
调 `penetration_slop` / `baumgarte` / 马达力矩都救不回来。

2026-11-16 实现**指腹软组织接触层**：

- 指骨胶囊半径 9 mm → 5 mm（真实指骨量级），外面留 4 mm 可压缩指腹
- 每节指骨 12–15 个采样点（掌侧 ±46°、四站，末节另加指尖半球三点），
  每点朝骨外打一条短射线，压进皮肉多少就按软组织刚度（2.6 kN/m/节）
  顶回多少，切向给库仑摩擦（μ≈1.1）
- 力作用在真实接触点上，因此会自动产生绕关节的力矩；接触压力摊在
  整个指腹面上，合力把物体往掌心里带
- 指腹只推不拉；握力仍然只来自肌力 × 力臂，没有加任何抓取力常数
- 实现：`first_person_controller.gd` 的 `_build_pulp_samples()` /
  `_update_finger_pads()`；接触状态记在 `_pulp_touch` 供测试判定

实测（Windows + 4.7.2，默认 Ø3.2 cm / 0.30 m / 0.10 kg 木棍）：
**11/11 通过**，位移 1.5–5.8 cm、末速 ≤0.25 m/s。

**仍未解决**：Ø3.5 cm × 1.0 m 木棍超过 0.35 kg 就滑脱（0.45 kg 滑 0.43 m，
0.58 kg 直接飞 3–5 m）。世界里刷出来的树枝是 1.0–2.0 m、Ø3.5–9 cm，
多数比这重。瓶颈已经不是接触模型——测试里手掌被冻结、木棍悬在掌前，
全部重量都压在手指上；真实握持时手掌托住大部分重量。下一步按顺序：
先做 §5.3 的拇指对掌（现在拇指根比握持口袋近端偏 5–7 cm，够不到），
再看要不要给手掌也加一层柔性接触。

### 5.2 骨折后卡顿 —— 未能复现

用户报告"骨折后游戏非常地卡"。headless 实测结果相反：骨折后物理耗时反而下降
（8.1→4.8 ms，帧间隔 16.5→10.1 ms）。已经修掉两条**无界增长**路径：

1. 断口近侧皮肉被扫到远侧骨节起点 → 两段分开后皮肉被拉成几十米的管子，
   每帧细分点数随距离无限增长（这是最可能的真凶）
2. `_skin_chain` 细分步数封顶 16 步（0.72 m）

如果换机器后仍然卡，需要的信息：哪根骨、是持续掉帧还是周期性尖峰、
当时在做什么动作、是否在陡坡上。

### 5.3 拇指对掌 —— 45° 前倾和补掌骨都试过，不成立

按用户要求把拇指根往手臂方向挪了一个指节（`z = 0.000`），现在它比四指
合拢围出的握持口袋（`z ≈ -0.055 … -0.078`）靠近端 5–7 cm，**拇指对掌够不到握持区**。

2026-11-16 做过两轮试验（代码已全部回退，工作区没有残留）：

1. **第一指节前倾 45°**（只转方向、不动根位置）：拇指屈曲后指尖落到
   `z ≈ +0.03`（掌后），原因是整条链绕掌侧轴转 45° 后，屈曲平面跟着
   转到「向后卷」的方向。`test_finger_grip` 从 13/13 掉到 2/3，还出现
   一次 7.2 m 的甩飞。
2. **补上掌骨**（拇指改成三节：掌骨 4.5 + 近节 3.0 + 末节 2.4 = 9.9 cm，
   接近真人从 CMC 到指尖），并把生长方向前倾 35°：指尖 x/y 能进到口袋
   附近（x≈-0.02、y≈-0.03），但 z 停在 0 附近，离口袋仍差 3–5 cm；
   握持 0/3，拇指和食指/中指撞上后卡住，出现负屈曲读数。

根因：口袋离 CMC 有 5.5–7.8 cm，拇指要在根不动的前提下同时**前伸 +
内收**——真实 CMC 是两自由度（屈曲 + 内收/外展），现有一个铰链做不到。
单自由度下要么前倾（卷向掌后），要么不倾（只在掌中段横跨），凑不出
口袋的位置。

可选路径（都要产品决定，别直接动手）：

- **A. CMC 加第二个自由度 + 三节带掌骨**：最接近真人，但要处理拇指与
  食指、中指的碰撞，工作量最大。
- **B. 拇指根往前移到 `z ≈ -0.03`**（这次对话之前的位置），保留现有
  单自由度。改动最小，但和用户之前「放在腕侧」的要求相反。
- **C. 放弃对掌**：接受四指夹持，给手掌加柔性接触层让掌面分担重量。
- **D. 先放着**，去复验 P1.14/P1.15。

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

1. **§5.1 的剩余部分**——指腹层已经让 Ø3.2 cm 木棍稳定握住；要让世界里的
   真实树枝（1–2 m、Ø3.5–9 cm、0.4 kg 以上）也拿得起来，卡在拇指对掌上。
   前倾 45° 和补掌骨都试过、都不成立，原因和三条可选路径见 §5.3。
2. **重新验证 P1.14/P1.15**——两人联机 + 50 人压测，把结果写回 SPEC。
3. 把 `get_subsurface_composition` 接到接触路径（§5.4），让挖土的手感来自
   真实地层而不是一种土。
4. 骨折后卡顿若在新机器上复现，按 §5.2 收集四项信息再查。

---

## 8. 2026-11-17 本机更新

完整记录见 [CHANGES.md](CHANGES.md)，摘要：

- **物品物理**：禁止睡眠；球心重力改用 `constant_force`；防穿模射线；
  按材料 `rolling_resistance` 加滚动阻力。999 个常醒物品从约 120 帧/25 s
  提升到约 1200 帧/25 s。
- **材料试验场**：出生点前方 72 个材料样品 + 平坦石台；开关
  `WorldRenderer.test_yard_enabled`。
- **世界地质**：`MatterField`（组成+状态）、`PlanetInterior`（地壳/地幔/
  外核/内核，materials.json 共 73 种）、`OreVein`（3D FBM 矿脉+深度带）、
  `GroundChunk`（marching tetrahedra 等值面，过渡原型）。
- **粒子法**：`SoilDEM` GDScript 小样；C++ GDExtension `SoilDEMKernel`
  （1000 粒子约 1.67M 更新/秒，5000 粒子约 407K，4 线程 248 步/秒）。
- **物质地面闭环（M1–M4）**：LOD patch（180 m / 4 m 格）+ 静态碰撞
  65 m 洞口；左键按身体力量施力；手掌接触 >50 N 自动施力；土→DEM 粒子
  （MultiMesh 凸碎片视觉），岩石→ItemEntity 破裂碎片；粒子有局部地面
  平面，静止后合并回 `MatterDelta`；delta 可 JSON 存/读。
- 新增测试：`test_ground_chunk` 24/24、`test_soil_contact` 19/19、
  `test_dem_cpp` 23/23、`test_client_strike` 6/6、`test_fracture` 14/14、
  `test_delta_terrain` 12/12、`test_delta_persistence` 14/14、
  `test_soil_particles` 10/10、`test_particle_budget` 16/16、
  `test_geology` 27/27。
- **还没做 / 已知问题**：LOD patch 重建约 2.8 s（移动 45 m 一次）；
  4 m 粗格精细挖掘手感待优化；粒子物理仍是球；MPM/SPH、Linux/导出、
  服务端权威/网络同步未做。详见 [WORKFLOW.md](WORKFLOW.md) 与
  [CHANGES.md](CHANGES.md)。
