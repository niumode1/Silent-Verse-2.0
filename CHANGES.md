# 2026-11-17 本机更新记录

这份文件记录从 `944bb51` 之后在本机做的改动、当时的判断、怎么跑、以及
还没做完的地方。**换机器/隔几天回来先看这里**，细节再点进对应文件。

---

## 1. 提交

| 提交 | 内容 |
|---|---|
| `e4f148b` | 物品物理：全物理化、constant_force 球心重力、防穿模、材料试验场 |
| `bb42fa8` | 物理手：拇指 CMC 两自由度原型 |
| `a203a7b` | 世界地质：物质场、行星内部、3D 矿脉、DEM 原型 |
| `47bb7bd` | C++ 粒子内核：GDExtension + DEM 基准 |

`main` 与 `origin/main` 已同步。

---

## 2. 物品物理

文件：[scripts/client/item_physics_body.gd](scripts/client/item_physics_body.gd)

- **禁止睡眠**：`can_sleep = false`，删除手动 `sleeping = true` 和
  `_still_time`；世界物品与试验场样品都一直参与模拟。
- **球心重力**：不再每个刚体走 `_integrate_forces`，改用
  `constant_force`，每 250 ms 刷新方向。999 个常醒物品的物理帧率从
  约 120 帧/25 s 提升到约 1200 帧/25 s。
- **防穿模**：用便宜的地表采样粗判，可疑时打物理射线实测；中心低于
  真实地表 3 cm 就抬回、清径向速度。射线只在玩家 80 m 内做；物理模拟
  本身不因远近停止。
- **滚动阻力**：按材料的 `rolling_resistance` 施加 `Crr·N` 阻力与阻力矩，
  避免圆柱在微小坡度上一直滚。
- **回位判定**：删掉"比出生点低 25 m 就算掉穿"的错误规则；只在真的
  埋入地表（射线实测 >2 m）或低于星球半径 20 m 时回位。

## 3. 材料试验场

文件：[scripts/shared/items/material_test_yard.gd](scripts/shared/items/material_test_yard.gd)

- 出生点前方 7 m 生成一块平坦石台（`TestYardPad`），台上放 **72 个样品**：
  63 种固体材料 + 5 根不同直径木棍 + 4 块重物；
- 液体材料暂不生成（需要容器）；
- 样品头顶有材料/硬度/密度/相态标签，35 m 内可见；
- 开关：`WorldRenderer.test_yard_enabled`，发布前关掉；
- 台面必须高于覆盖范围最高地形，生成时自动采样。

## 4. 世界地质

### 4.1 MatterField

[scripts/shared/world/matter_field.gd](scripts/shared/world/matter_field.gd)

位置 + 深度 → 组成 + 状态：

```gdscript
{ "composition": [{material_id, fraction}, ...],
  "state": {moisture, compaction, temperature_c, pressure_pa,
            density, shear_strength_pa, angle_of_repose_deg} }
```

- 0–3 m 用 `Terrain.get_subsurface_composition`（表土/黏土/砂/砾石）；
- 更深用 `PlanetInterior.get_composition`（地壳基岩/地幔/核心）；
- 矿脉按富集度混入组成；
- 纯查询，不存格子、不存道具；
- `get_dem_parameters(position, depth)`：把状态折算成 DEM 的密度/黏聚/
  摩擦/刚度/滚动阻力，供 C++ 粒子内核使用；
- 可选 `MatterDelta` 增量：`set_delta()` 后，堆积物按质量权重混入采样
  组成（少量堆积轻微改变，大量堆积主导），并通过休止角圆锥抬高
  `get_surface_radius_at()`；
- `MatterDelta` 也记录「挖走」：`remove_volume` 按半球坑反推半径，
  `get_removal_depth_at` 给出表面下陷，`get_surface_offset` 合并
  堆积/挖走；
- `to_dict` / `from_dict` / `save_to_file` / `load_from_file`：JSON
  持久化，堆积/挖走的组成、状态、质量、几何都能还原；
- 同一个 `MatterDelta` 可以传给多个 `GroundChunk`，只有附近的块会
  看到变化。

### 4.2 PlanetInterior

[scripts/shared/world/planet_interior.gd](scripts/shared/world/planet_interior.gd)

- 层序与成分：地壳（按地质省）→ 地幔（橄榄岩+玄武岩）→
  外核（熔融铁镍）→ 内核（固态铁镍）；
- 厚度不能照搬地球：R≈4 km 时地球比例的地壳只有 22 m，装不下 1 km 地形
  和矿脉，所以地壳放大到 45% R；层序/成分保持现实；
- 温度/压力随深度连续变化（内核约 5200 °C、约 59 MPa）；
- `materials.json` 新增 `peridotite`、`molten_iron`、`iron_nickel`，共 **73 种**。

### 4.3 OreVein

[scripts/shared/world/ore_vein.gd](scripts/shared/world/ore_vein.gd)

- 替代表面哈希：每种矿一个 3D FBM 噪声场（世界种子决定），形成矿脉团块；
- 深度带：煤 5–400 m、铜 20–800 m、赤铁矿 100–1200 m、
  磁铁矿 150–1500 m、锡 80–1000 m、金 300–1700 m、燧石 0–60 m；
- 寄主岩性匹配时概率更高（铜在沉积岩、锡在花岗岩、铁在变质/火山）；
- 新接口：
  `get_ore_deposits_at_depth(position, depth_m, terrain)`、
  `get_ore_at(position, depth_m, terrain)`；
- `WorldGenerator.query_world` 现在返回 `depth_m`、`interior`、`ores_underground`。

### 4.4 GroundChunk（过渡原型）

[scripts/shared/world/ground_chunk.gd](scripts/shared/world/ground_chunk.gd)

- 用 marching tetrahedra 从物质场提取**连续等值面**，不再是方块网格；
- 内部采样点只是求值脚手架；表面是不规则三角面；
- 支持移除一格 → 返回同质量物质载荷 → 重建表面；
- `apply_contact(tool, contact_pos, force, slide, penetration_step, ...)`：
  只接受力和工具几何，调用 `ContactResolver.resolve`；地面屈服后按
  `displaced_volume` 移除格子，返回脱落物质的组成/状态/质量；
- `rebuild()`：按当前 `MatterField`（含 `MatterDelta`）重新生成格子和
  表面；堆积增高地形、挖走降低地形，都会增加/减少固体格和碰撞；
- `apply_contact` 在有 `MatterDelta` 时把移除体积写成 delta；没有 delta
  时才退回本块临时的 `_carved`；
- **注意**：这是过渡原型，最终地面要改成粒子法，尚未接进
  `WorldRenderer`。

### 4.5 FractureGenerator（凸多面体破裂）

[scripts/shared/items/fracture_generator.gd](scripts/shared/items/fracture_generator.gd)

- 一个凸体积按平面反复切开，得到若干凸碎片；
- 每个碎片 = 一组半空间平面，顶点用
  `Geometry3D.compute_convex_mesh_points` 求交，面按平面分组三角化；
- 体积由三角面片积分，质量 = 体积 × 密度；
- `make_item_fragments` 直接产出独立 `ItemEntity`：每块自带网格、
  体积、质心、碰撞体；
- 切面方向：`preferred_normal` + `spread_deg`。岩石破坏时用接触法线作
  优选方向，`friction_anisotropy` 越大（板岩 1.8）切面越贴近法线；
  花岗岩等各向同性岩石破裂面更散；
- `GroundChunk.fracture_cell` / `apply_contact`：岩石格受力破坏时直接
  产出独立 `ItemEntity` 碎片（不再是颗粒）；
- 测试 [test_fracture](tests/test_fracture.gd) **11/11**：8 块体积/质量
  总和等于原体积、同种子同结果、每块网格/碰撞体齐全；
  `test_soil_contact` **18/18** 覆盖岩格碎裂。

### 4.6 可视化（过渡）

[scripts/client/ground_chunk_node.gd](scripts/client/ground_chunk_node.gd)、
[scenes/ground_demo.tscn](scenes/ground_demo.tscn)

- `GroundChunkNode` 把格块的网格 + 顶点色材质 + 碰撞体挂进场景；
- `ground_demo` 不替换正式 `WorldRenderer`，只生成一块 8×8 m 近场格块
  给眼睛看（本机 headless 实测 2625 固体格、4419 网格顶点）。

**正式客户端已接入近场物质地面**（`WorldRenderer`）：

- 出生点周围 3×3 个 8 m `GroundChunk`（`near_field_chunks`）；
- 静态地表材质换成 shader，在半径 12 m 的洞口内 `discard`；
- 静态碰撞体保留（近场格块提供接触面）；远场仍是原静态地形；
- `near_field_enabled` 可整体关闭，`near_field_hole_radius` 可调；
- **LOD 地面（M3）**：玩家周围生成单块 **180 m / 4 m 格** 的物质 patch
  （`GroundChunk` 支持自定义 cell/size）；静态地形碰撞按三角面中心移除
  65 m 洞口，视觉 shader 同步 discard；patch 半宽 90 m 覆盖洞口。
  不再使用 per-body collision exception。
- 粒子/物品/玩家现在直接与 patch 或带洞的静态碰撞体接触；
- 格子支持**部分移除**：`GroundChunk.remove_cell(key, volume_limit)`
  只带走 `displaced_volume`，格子在完全移除前保留剩余体积；一次敲击
  不再整格消失。4 m 粗格对精细挖掘仍偏粗，但不再产生 64 m³ 的瞬间坑。
- **G 键调试施力**：对前方近场格块调用 `GroundChunk.apply_contact`；
  土 → 最多 1200 个 C++ DEM 粒子（MultiMesh 渲染），
  岩石 → `ItemEntity` 破裂碎片并挂进 `WorldItems`；
- 粒子系统在 `_process` 里按固定小步长推进并更新 MultiMesh；
- 粒子视觉用 `FractureGenerator` 切出的凸碎片当模板（MultiMesh 实例
  随机旋转），不再是纯球；物理碰撞仍是球；
- DEM 粒子有**局部地面平面**（`set_ground_plane`），不会穿过地表；
- 静止粒子每 2 s 通过 `consolidate_slow` 合并回 `MatterDelta`，
  并重建附近的近场格块；
- 近场内的玩家/物品通过 **collision exception** 忽略静态地形碰撞，
  只和可见格块接触；离开近场后恢复。不再靠"抬高格块"近似。
- 异常每 300 ms 更新一次，覆盖玩家和 `_items_root` 下的物品。
- 客户端施力已接到 `primary_action`（鼠标左键）：力量来自
  `PlayerBody.get_max_force() × 2`，工具材质用 `bone`（手骨）；
  G 键调试入口已移除。土生成 C++ DEM 粒子，岩石生成独立 ItemEntity
  碎片；移除同时写入 `MatterDelta`。
- **抓握辅助**：右键按住，拇指先 CMC 对掌(+Y)翻指腹，再屈曲(Z)调前后，
  最后 MCP/IP(X)包裹；`test_thumb_axes` 10/10 验证轴不互换。
- **自动接触触发（M2b）**：手掌的 `ContactForceProbe` 报告与
  `TerrainBody`/`GroundCollision` 的接触力 >50 N 时，每 300 ms 对真实
  接触点施力；不再需要按键。headless 无法模拟手部落下，需窗口实测。

### 4.7 SoilDEM（GDScript 小样）

[scripts/shared/world/soil_dem.gd](scripts/shared/world/soil_dem.gd)

- 1000 个 2 cm 粒子，软弹簧-阻尼接触 + Coulomb 摩擦 + 黏聚 + 推板；
- 验证干砂/湿黏土/压实土响应不同、质量守恒、确定性；
- GDScript 性能约 **1.9 万粒子更新/秒**（1000 粒子 ≈19 步/秒），
  只够原型。

## 5. C++ 粒子内核（GDExtension）

目录：[gdextension/](gdextension/)

- C++20 + Visual Studio + CMake/Ninja；godot-cpp master（API 4.7）；
- [silent_verse_particles.gdextension](silent_verse_particles.gdextension)
  使用 editor 目标；
- `SoilDEMKernel`：与 GDScript DEM 同一套模型（软接触/摩擦/黏聚/推板）；
- `setup_material` / `clear_particles` / `spawn_from_mass`：按脱落物质的
  质量和 `MatterField.get_dem_parameters()` 的参数生成粒子；
- `get_particle_mass`：单个粒子质量，用于核对质量守恒；
- `set_spherical_gravity(R, g0)`：球心重力 `g(r)=g0·(R/(R+alt))²`，
  方向指向球心；`set_planar_gravity(g)` 回到固定 -Y；
- `set_threads(n)`：接触计算按粒子下标分 n 段并行，默认 1；
- `get_velocities` / `remove_particles`：供静止粒子合并使用。

### 5.1 活跃粒子预算

[scripts/shared/world/soil_particle_budget.gd](scripts/shared/world/soil_particle_budget.gd)

- `radius_for_budget(mass, density, max_particles)`：按预算反推粒径。
  例：191.7 kg 表土、密度 1534、预算 5000 → 粒径约 3.6 cm；
- `consolidate_slow(kernel, speed_threshold, delta, position, composition,
  state)`：找出速度低于阈值的粒子，从内核移除并返回质量；传入
  `MatterDelta` 时把质量/组成/状态写回稀疏增量。
- 构建：`gdextension\build.bat`；产物 `bin/`（gitignore）；
- 首次加入后需重跑一次 Godot 编辑器导入（`--headless --editor --quit`）；
- 测试：[tests/test_dem_cpp.gd](tests/test_dem_cpp.gd) **23/23 通过**。

### 基准（本机 MSVC Release，60 步）

| 粒子数 | 每秒粒子更新 | 每秒步数 |
|---|---|---|
| 1000 | 1,669,867 | 1670 |
| 5000 | 406,745 | 81 |
| 5000（4 线程，持久池） | ~1.24M | 248 |
| GDScript 1000 | ~18,900 | 19 |

- C++ 约 **88 倍**于 GDScript；
- 5000 粒子按 60 Hz 需要 30 万更新/秒，当前单线程已覆盖；
  更大活跃区需要多线程/GPU。

## 6. 测试命令

```powershell
$GODOT = "I:\godot\Godot_v4.7.2-stable_win64.exe"
& $GODOT --headless --path . scenes/test_geology.tscn       # 27/27
& $GODOT --headless --path . scenes/test_ground_chunk.tscn  # 19/19
& $GODOT --headless --path . scenes/test_dem.tscn           # 11/11
& $GODOT --headless --path . scenes/test_soil_contact.tscn  # 19/19
& $GODOT --headless --path . scenes/test_soil_particles.tscn # 10/10（需先构建）
& $GODOT --headless --path . scenes/test_particle_budget.tscn # 16/16（需先构建）
& $GODOT --headless --path . scenes/test_delta_terrain.tscn  # 12/12
& $GODOT --headless --path . scenes/test_delta_persistence.tscn # 14/14
& $GODOT --headless --path . scenes/test_fracture.tscn       # 14/14
& $GODOT --headless --path . scenes/test_client_strike.tscn  # 6/6（需先构建）
& $GODOT --headless --path . scenes/test_dem_cpp.tscn       # 23/23（需先构建）
& $GODOT --path . scenes/ground_demo.tscn                   # 可视化（非测试）
```

旧测试仍可跑：`test_items` 39/39，其余见 HANDOFF §2。
3D 物理场景退出挂死（`run_on_separate_thread=true`）是已知的，看 stdout。

## 7. 关键决定

- **重力 g 不改为自然推导**：见 [WISHES.md](WISHES.md)。本游戏保留
  `g0=9.81` 与现有密度，接受"人造/致密世界"前提。
- **地面不是格子，也不是固定道具**：世界 = 物质场 + 稀疏增量；
  近场才实体化。
- **粒子法**：砂/砾用 DEM，湿泥/水用 MPM/SPH；只有活跃区有粒子，
  静止后合并回物质场（质量守恒）。
- **形状自然形成**：碎块沿应力/层理/解理/晶粒边界破裂，土壤颗粒来自
  风化粒径分布；不用噪声生成随机形状。
- **C++ 做粒子内核**：godot-cpp/Jolt/CUDA 生态在 C++；Rust 以后可用于
  服务端编排/网络。
- **不要全星球粒子**：4 km 星球全球 cm 级粒子不可能；活跃集 + LOD。

## 8. 当前已知问题（2026-11-17）

- 初次生成粗 patch + 精细 patch 约 **3 s**（粗 2.4 s + 精细 0.6 s）；
  小范围移动已缓存（粗 patch < 72 m、精细 patch < 3 m 不重建）。
- 精细 patch 只有 12 m，移动出去后又会触发重建；可考虑扩大或增量。
- 静态 50 m 网格的洞边缘仍有少量三角面与 patch 重叠。
- DEM 粒子物理仍是球；视觉用凸碎片模板，但碰撞不是不规则形状。
- DEM 地面是局部平面近似，不是真实格块高度场。
- MPM/SPH 未做；C++ 只构建 Windows editor 目标；Linux/导出/GPU 未做。
- 服务端权威粒子同步、网络、正式存档未接（按 Phase 1 策略延后）。

## 9. 下一步顺序

1. 进入 M5：服务端权威、网络同步、正式存档；
2. 继续优化 M3：分帧构建、精细 patch 增量、消除初次 3 s 卡顿；
3. 人体真实骨骼/肌腱/肌肉系统（见 [WISHES.md](WISHES.md) §2）；
4. 粒子物理不规则化（DEM 多球/凸体）；
4. MPM/SPH（湿泥/水）；
5. Linux/导出构建与 GPU 评估。

## 10. 当前进度快照（2026-11-17）

| 任务 | 状态 |
|---|---|
| M1 粒子地面/合并 | ✅ |
| M2 左键身体力量 | ✅ |
| M2b 手掌接触自动施力 | ✅（待窗口实测） |
| M3 LOD patch + 碰撞开洞 + 部分移除 + 缓存优化 + 精细交互 patch | ✅ |
| M4 粒子不规则视觉 | ✅ |
| M5 delta 存/读 | ✅ |
| M5 网络/服务端权威 | 延后 |

测试：`test_dem_cpp` 23/23、`test_client_strike` 6/6、
`test_ground_chunk` 24/24、`test_soil_contact` 19/19、
`test_fracture` 14/14、`test_delta_terrain` 12/12、
`test_delta_persistence` 14/14、`test_soil_particles` 10/10、
`test_particle_budget` 16/16、`test_geology` 27/27。

最近提交：`3f731d3` 客户端施力；`a51568d` M1；`c14f6e2` M2；
`affe47b` M2b；`3815ad4` M4；`3ae3670` M3 LOD patch；
`e790600` M3 部分移除；当前文档提交见 `git log`。

## 11. 2026-11-19 拇指控制范围与皮肉根节

文件：[scripts/client/first_person_controller.gd](scripts/client/first_person_controller.gd)

用户报告：默认控制的拇指关节方向正确，但切到后两个关节（MCP/IP）时，
它们相对前一节的活动范围不对。

排查结果：物理铰链的轴和符号本身是对的（`test_thumb_axes` 双手 10/10），
问题出在三个叠加处：

1. **皮肉根节接错**：拇指的皮肉管和四指共用 `knuckle_l`（掌中段
   `z=-0.05`），离拇指 CMC（`x=±0.054, z=0.008`）约 8 cm。拇指看起来
   从四指根部斜着长出来，CMC 的实际转动中心被这截假根节盖住。现在
   拇指单独从掌缘 CMC 窝（`0.045·inner, -0.008, 0.008`）起扫；
2. **关节上限错误**：`THUMB_JOINT_LIMITS_DEG` 从 `[80, 90, 80]` 改为
   `[80, 55, 80]`。拇指 MCP 的生理屈曲只有约 50-60°，90° 会让第二个
   关节相对上一节卷出比 CMC 还大的角，整根拇指折进掌心；
3. **控制层夹紧不一致**：`_adjust_selected_joint` 原来统一夹到
   `[-15, 95]`，而肌肉层实际按关节上限夹紧，HUD 能转到 95°、关节却在
   55°/80° 停住。现在控制层按 `THUMB_JOINT_LIMITS_DEG` /
   `FINGER_JOINT_LIMITS_DEG` 逐关节夹紧。

另按用户要求把**四指后两节各加长 50%**：中节 2.6→3.9 cm、末节
2.0→3.0 cm，四指总长 11.5 cm；指骨、碰撞胶囊、皮肉扫掠都按新长度
自动重建。

新增测试 `test_thumb_range`：控制层三个上限 + 冻结手掌后逐个关节实际
达到相对屈曲上限，6/6。`test_finger_grip` 在该改动后仍 PASS。

## 12. 2026-11-19 手指与地面接触

用户报告：加长手指后，手指出现弹性，有时会被地面黏住。

根因是手指的硬碰撞胶囊半径只有 5 mm（骨半径），而可见皮肉半径是
9.5 mm。指尖碰到地面时，皮肉先扎进去约 4.5 mm 骨头才停，视觉上像
陷进地面；同时胶囊对地形的摩擦是 0.9，玩家的躯干一移动，手臂就被
静摩擦拉住，看起来既弹又粘。处理：

1. 指骨胶囊半径 5 mm → 9 mm（`FINGER_FLESH_RADIUS`），使硬接触面
   与可见皮肉一致；短末节保证胶囊总高不小于 2r；
2. 指骨胶囊不再与物品层（1）碰撞，物品/木棍的抓握全部交给
   `_update_finger_pads` 的 5 mm 骨面 + 4 mm 软组织层，避免硬胶囊
   把木棍当楔子顶出去（`test_finger_grip` 位移 0.021 m，PASS）；
3. 指骨对地形的摩擦 0.9 → 0.55，抓握摩擦仍由指腹层的 μ=1.1 负责，
   地面接触不再一碰就锁死。

`test_thumb_range` 6/6 保持通过。`test_physical_hand` 在 headless 下
退出挂死是已知的 3D 物理线程问题，与本次改动无关。

## 13. 2026-11-19 竖立试抓木棍

文件：[scripts/client/world_renderer.gd](scripts/client/world_renderer.gd)

用户抓木棍时手部会被木棍顶偏，需要一个稳定、竖直、在出生点附近的
测试目标。新增内容开发期道具：

- `test_stick_enabled`（默认开）在出生点前方 1.6 m 生成一根
  Ø4 cm × 1.1 m 的橡木棍（`item_id=900001`，质量由材料密度 × 体积
  推导，约 1.04 kg）；
- 原点放在木棍**底端**，局部 Y = 地表法线，所以木棍竖直；刚体中心
  再抬高半个长度，底部离地 1 cm；
- 木棍先 `freeze = true`（静态），不会自己倒；头顶有 `TEST STICK` 标签；
- 右键按住且指腹碰到它（手掌距离 < 45 cm 也可）时释放成普通动态
  `ItemPhysicsBody`，之后按正常物理抓取/倒下；
- 抓取仍由 `_update_finger_pads` 的指腹层负责；指骨胶囊只碰地面/
  手掌/身体，不碰物品层。

注意：这是测试夹具，不是「物品可以静止站立」的玩法规则；正式发布前
把 `test_stick_enabled` 和 `test_yard_enabled` 一起关掉。

## 14. 2026-11-19 软皮接触层、骨折滤波、E 握持

用户报告：一碰地或木棍手指就断；手太直，皮肤与木棍接触面积太小，
摩擦力不够；希望有一层能贴合物品的软皮。

1. **软皮层加密**：每节指骨从 4 站 × 3 条 = 12 个采样点增加到
   5 站 × 5 条 = 25 个（末节再加 5 个指尖点）。射线掩码从 1 改为
   1|2，软皮现在同时贴合**木棍等物品和地面**；
2. **硬胶囊退回 5 mm 骨芯**：物品不再和硬胶囊碰撞，正常接触完全由
   软皮层承担；骨芯只保留地面兜底，避免软皮被压穿后无限下沉。
   这样单点楔入、硬碰撞把木棍顶飞、碰一下就骨折的路径都被切断；
3. **地面/物品摩擦分开**：可动物体 μ=1.25（抓握），地面/冻结物
   μ=0.55、低切向粘性，软皮可以贴地但不会把指尖锁死；
4. **骨折判定用低通接触力**：`ContactForceProbe.contact_force_filtered`
   加 80 ms 时间常数，骨骼断裂不再拿单帧冲量/dt（可到上万牛）判；
   手扶地触发的地面施力也改用滤波值，并限制在
   `PlayerBody.get_max_force() × 2` 以内，避免一次扶地炸开地面；
5. **E 键握持辅助**：按 E 四指和拇指慢慢卷到握姿（MCP/PIP/DIP
   70/80/55，拇指 70/55/70），再按 E 张开。手指形成钩子后，软皮层
   才有足够面积贴住木棍；出力仍由肌肉力矩模型计算。

测试：`test_finger_grip` PASS（位移 0.021 m，无骨折日志）、
`test_thumb_range` 6/6、`test_grip_assist` 42/42、
`test_arm_load` PASS（60 kg 仍会断肘）。
软皮采样密度提高后每帧射线数约翻倍，下一步可在低端机上测开销。

## 15. 2026-11-19 踩木棍飞天

用户报告：踩到木棍会飞天。

两个独立原因都在「自动跨步/自救」里：

1. `_try_step_over` 只要移动被物品挡住，就把玩家沿地表法线抬
   `物品高度 + 0.10 m`，且**没有冷却、没检查接触法线**。玩家站在
   木棍上时接触法线朝上，每一物理帧都被当成「被挡住」，于是每帧
   抬高约 14 cm，直接飞走。现在：
   - 法线朝上（`normal·sky > 0.35`）的地板接触不跨；
   - 一次跨步后至少等 250 ms；
   - 木棍高度按世界姿态计算：横躺只算直径，竖立算整根长度，
     超过 45 cm 不跨；
2. 最后的「卡住自救」无条件每 0.8 s 抬 12 cm。现在只有玩家真的
   低于地表（`position.length() < ground_radius - 3 cm`）才纠正，
   并清掉速度；站在木棍上走不动不再触发。

测试：`test_thumb_range` 6/6、`test_grip_assist` 42/42；
踩木棍的实机行为还需要窗口验证。

## 16. 2026-11-19 手指穿过木棍

用户报告：手指碰到木棍但经常穿模过去，接触不够精细。

根因是软皮层是**离散射线**：每节 25 个采样点，细木棍可能正好从
两条射线之间穿过；手指快速移动时，4 mm 的软皮射线层也可能被一步
跨过。之前为了防单点楔入把物品层从指骨硬胶囊掩码里去掉后，软皮
漏检时就没有任何硬碰撞兜底，于是直接穿过去。

处理：

- 5 mm 骨芯重新加入物品层（掩码 `1|2|4|128`），但硬胶囊埋在 4 mm
  软皮下面：正常接触仍先由分布弹簧承担，骨芯只在软皮漏检/被压穿
  时兜底；
- 指骨本来就有 `continuous_cd = true`，细木棍不会因为一帧位移被跨过；
- 软皮层仍负责木棍的贴合、法向压缩和 μ=1.25 的抓握摩擦；地面仍是
  μ=0.55、低粘性。

另外把软皮轴向采样从 5 站增加到 6 站（`±0.49` 两端），弯指时
关节褶皱附近也有软皮接触点，而不是只有骨节中段。

`test_finger_grip` PASS（位移 0.025 m，无骨折日志，指腹接触 true）。
如果仍能看到明显穿入，下一步是把软皮从「单侧短射线」换成重叠形状
查询，而不是继续放大硬胶囊（会重新引入楔入/顶飞）。

## 17. 2026-11-19 E 握持的临时刚性约束

用户反馈：明明已经握住木棍，木棍仍会从手掌/手臂/手指之间穿模溜走。

根因不是单个碰撞体没检测，而是手部是混合近似：每节指骨 5 mm 硬
胶囊 + 离散软皮射线 + 肌肉马达，手臂又每帧被躯干 `_carry_body`
瞬移。手臂瞬移时 CCD 对「静止的木棍」不起作用，木棍就可能被留在
手的另一侧，表现为从掌心穿出去。

临时处理：按 E 握紧且指腹已经接触到一个可动物品（`ItemPhysicsBody`）
时，在手掌和物品之间建立一个 `PinJoint3D`；松 E 立即释放。
- 约束点是手掌与物品当前位置的中点；
- 只对非冻结物品生效，测试竖棍要先按 E 解除冻结；
- 这是摩擦抓握的刚性代理，不是最终方案：它保证「已经抓住的东西
  不会因为手臂瞬移而掉出/穿过手心」，但不能替代连续软皮碰撞。

新增 `test_grip_constraint`：E 握紧 → 建立 PinJoint 并连到试抓木棍，
松 E → 释放，3/3。`test_grip_assist` 42/42、`test_finger_grip` PASS。
长期方向仍是把软皮从短射线换成连续重叠形状/柔性皮肤层，去掉这个
临时关节。

## 18. 2026-11-19 连续软皮壳（手部接触重写第一步）

用户要求按“连续软皮碰撞”的方向重写，而不是继续加密离散射线。

每个指骨节现在多一个 **9 mm 半径的软皮壳刚体**：

- 独立 `RigidBody3D`（layer 16），只和物品层（1）碰撞；
- 用 `Generic6DOFJoint3D` 挂在对应指骨上：三个角度轴锁死，三个
  线性轴各留 ±1 mm，作为皮肉压缩量；
- 物品先撞到连续的胶囊表面，不会从 30 个软皮射线采样点之间穿过去；
- 骨芯退回 5 mm，只负责地面/手掌/身体，**不再直接撞物品**；
- 软皮壳的接触会写入 `_pulp_touch`，所以 E 握持、试抓木棍释放、
  抓握测试都能看到它；
- 物品的 `collision_mask` 增加 layer 16，软皮壳和物品互相检测；
- 指骨断裂时，断口以远的软皮壳也不再随手掌搬运。

验证：
- `test_finger_grip` PASS，位移 0.024 m，**骨骼接触=[]、指腹接触=true**
  （木棍完全由软皮壳夹住，骨芯没有参与，因此不会碰一下就骨折）；
- `test_thumb_range` 6/6、`test_grip_assist` 42/42、
  `test_grip_constraint` 3/3、`test_arm_load` PASS（60 kg 仍断肘）；
- 扶地自动施力被限制在 710 N（肌力×2），不再出现 12 kN。

局限：软皮壳是**连续刚性胶囊 + 1 mm 关节压缩**，不是体积可变形
皮肤；外观上仍不会有真实的皮肉凹陷/鼓包。下一步若继续追真实软皮，
要把壳换成 PBD/质点弹簧层，而不是再调这个胶囊。

## 19. 2026-11-19 跳跃键改为空格

E 原来同时绑定跳跃（`interact`）和新的握持辅助，按 E 会一边跳一边
卷手指。现在新增独立的 `jump` 输入动作，绑定 **Space**；角色跳跃改读
`Input.is_action_just_pressed("jump")`。`interact` 仍是 E，留给后续
交互系统，握持辅助继续用 E。HUD 已标出 `Space jump`。

## 20. 2026-11-19 移除临时 PinJoint；真实抓取的架构结论

按用户要求删除 E 握持的 `PinJoint`：抓取不再有任何“标记/焊死”
的假连接，只靠 9 mm 软皮壳的接触和摩擦。

验证（稳定版）：
- `test_finger_grip` PASS，位移 0.023 m，指腹接触 true；
- `test_arm_walk` PASS（mean |ω| 0.10 rad/s，max 2.91 rad/s）。

但必须承认：**移动时仍可能穿模**。根因是 `_carry_body` 每帧把
上臂/前臂/手掌/手指瞬移（6 m/s 行走时约 10 cm/帧）。瞬移直接改
transform，CCD 和接触求解都看不到这段位移，木棍当然可能被留在
手的另一侧。这不是调碰撞层能解决的。

这两天试过的两条“让手连续运动”的路径都失败了：
- 整条手臂只靠关节跟随、不瞬移：`test_arm_walk` max |ω| 39.5 rad/s，
  手臂甩飞；
- 只让手掌/手指物理、上臂/前臂仍瞬移：max |ω| 14.3 rad/s，仍 FAIL，
  且抓取测试在部分版本里直接卡死。

结论：真实抓取要求**整条手臂（至少手腕以上）也是连续物理运动**。
必须改角色/手臂架构，而不是继续调手部参数。候选：
1. 物理躯干 + 主动布娃娃（玩家身体本身是刚体/PD 驱动，手臂自然
   跟随，手臂和物品都在同一套连续物理里）；
2. 肩部改成 PD 驱动的 RigidBody 平台（不再瞬移 StaticBody 锚点），
   整条手臂挂在平台上由关节跟随，平台用速度/弹簧追躯干。
两条都先要在 `test_arm_walk` 上把 max |ω| 压到 8 rad/s 以下，再回来
验证抓取。

## 21. 2026-11-19 M8 阶段 1：全物理站立原型（WIP）

新增 `scenes/physical_biped_stand.tscn` / `tests/physical_biped_stand.gd`：

- 躯干、左右大腿、小腿、脚都是 `RigidBody3D`；
- 髋/膝/踝是 HingeJoint3D，马达力矩来自 `PlayerBody` 的
  hip/knee/ankle 力臂（不写死力量）；
- 没有任何 CharacterBody、`_carry_body` 或 PinJoint；
- 平地、脚底接触、重力全部真实。

当前结果：身体能建起来，关节角也能被马达拉回 0°，但约 1 s 内
失稳摔倒（torso y 从 1.17 掉到 0.1）。原因是只有绕 X 的髋/膝/踝，
没有髋外展/踝内外翻，也没有 COM/CoP 平衡控制器；单纯把关节锁在
0° 不能让人站起来。

下一步（阶段 1 继续）：
1. 髋加第二个自由度（外展/内收），踝加内外翻；
2. 脚底接触点 → 支撑多边形/压力中心 CoP；
3. 用 COM 投影 + CoP 的 PD 控制髋/踝目标角；
4. 先让站立 10 s 通过，再做原地迈步。

2026-11-19 追加：髋外展/内收过渡体 + 脚底 ContactForceProbe 已加；
但当前髋 roll 马达符号/限位仍不对，身体仍会侧翻。下一步必须先写
COM/CoP 控制器并把 hip_roll 的符号/权限校准，不能再用“把关节锁 0”
冒充平衡。

这不是“再加两个参数”；主动布娃娃的站立/行走本身就是控制问题。

## 22. 2026-11-19 M8 阶段1：COM/CoP 与侧向自由度（仍 FAIL）

在站立原型上继续加：

- 髋外展/内收过渡体（hip_roll），给马达足够的等效惯量；
- 脚底改用 `ContactForceProbe`，读取真实接触点/法向力；
- 每帧计算全身 COM、COM 速度、脚底 CoP、capture point；
- 尝试踝策略（CoP 误差 → 踝目标）+ 髋策略 + 侧向 hip_roll 目标。

实测：脚底 CoP 和 COM 能算出来，关节也能被马达保持；但简单 PD
仍会失稳摔倒。数据表明踝目标很快饱和到 ±28.6°，CoP 跟不上
capture point，随后躯干倾倒。换成“踝+髋+侧向”组合也只是把摔倒
时间从约 1 s 推迟到约 2–3 s，没有本质解决。

结论：主动布娃娃站立需要真正的 whole-body 平衡控制器（状态估计 +
COM/CoP/capture point + 踝/髋/跨步策略 + 增益整定），不是几个
PD 参数能凑出来的。下一步应单独做控制器，不要继续在手部/碰撞层
上打补丁；当前原型保持 WIP，不接入主游戏。

## 23. 2026-11-19 站立控制器继续调参：仍未通过

在 COM/CoP + hip_roll 基础上尝试了静态 COM 误差、capture point、
踝/髋/侧向组合。当前最好结果：躯干能在约 1.06 m 高度保持 2–3 s，
之后踝目标饱和、躯干倾倒。换符号/增益只是改变摔倒方向和时间，
没有稳定收敛。

这不是“再调一个参数”的问题：踝关节可用力矩约 15–20 N·m，
而 28 kg 躯干/腿的倒立摆在外界扰动下需要的恢复力矩更大；
要么提高踝/髋的解剖力臂/肌力模型，要么用 whole-body/LQR 控制器
同时分配踝、髋、跨步。下一步应单独立项做控制器，不再在原型里
盲调 PD。

## 24. 2026-11-19 下肢肌力按解剖量级单独建模（仍 FAIL）

原来站立原型的髋/膝/踝力矩沿用 `get_joint_max_torque`：
`516 N × 0.04 m ≈ 20 N·m`，对 28 kg 躯干 + 腿的倒立摆明显不够。
新增 `PlayerBody.get_leg_joint_max_torque()`：

- 髋 180 N·m、髋外展 90、膝 140、踝 100（成人峰值量级）；
- 再乘先天力量 `current_strength/400` 和体格缩放；
- 这是肌肉能力上限，不是玩法硬编码；手部仍走原来的手指倍率。

换上下肢力矩后，站立时间略有延长，但控制器仍会饱和/倾倒，
`physical_biped_stand` 仍 FAIL。说明力矩不是唯一瓶颈：当前
“COM 误差 → 踝/髋目标角”的 PD 分配本身不收敛，需要 whole-body
控制器（统一分配踝/髋/跨步），而不是三个独立 PD。

当前最终状态：站立原型 WIP，未接入主游戏；没有假平衡/瞬移。

## 25. 2026-11-19 直接踝力矩试验（仍 FAIL）

试过绕过踝马达、直接给小腿/脚一对反向踝力矩，用躯干 pitch 的 PD
产生恢复力矩；髋/膝仍用马达保持。两种符号都试了：

- 一个符号在 1 s 内把躯干推倒；
- 另一个符号下踝力矩饱和到 ±100 N·m，髋角仍被压到约 29°，
  躯干在 1–2 s 内倒下。

说明单靠踝关节直接力矩无法稳定这个 28 kg 躯干 + 双腿的倒立摆；
必须同时分配髋/膝/踝的 whole-body 力矩，并处理脚底接触约束。
该试验已回退，不留在代码里；当前仍停在提交 `974c391` 的 WIP。

下一步应做真正的 whole-body 控制器（状态空间/LQR 或
centroidal momentum control），而不是继续单关节试符号。

## 26. 稳定版本标记（2026-11-20）

本次把当前可运行的主线标记为稳定版本。包含：

- 球形世界、地表 LOD、物质场、DEM 粒子、破裂、`MatterDelta` 存/读；
- 物理手：每节指骨 5 mm 骨芯 + 9 mm 连续软皮壳（layer 16，
  Generic6DOF 软挂），指腹 30 点采样；抓取只靠接触/摩擦，
  没有 PinJoint/抓取标记；
- E 握持辅助（只改肌肉目标角）、Space 跳跃、TEST STICK 试抓木棍；
- 下肢肌力按解剖量级单独建模（髋 180 / 膝 140 / 踝 100 N·m，
  按先天力量/体格缩放）。

已知未完成/不计入稳定判据：

- M8 全物理主动布娃娃：`physical_biped_stand` 仍 FAIL（COM/CoP
  控制器未收敛），未接入主控制器；
- 近场挖地碰撞/`test_client_strike` 仍是 2/3；
- 服务端权威、网络同步、正式存档仍按 Phase 1 策略延后。

已通过的核心回归：`test_finger_grip`、`test_thumb_range`、
`test_grip_assist`、`test_arm_walk`、`test_arm_load`。
