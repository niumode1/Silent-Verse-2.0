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
- 当前切面方向由确定性 RNG 给出；后续应换成应力张量/层理/解理方向，
  接口不变；
- 测试 [test_fracture](tests/test_fracture.gd) **11/11**：8 块体积/质量
  总和等于原体积、同种子同结果、每块网格/碰撞体齐全。

### 4.6 SoilDEM（GDScript 小样）

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
- 测试：[tests/test_dem_cpp.gd](tests/test_dem_cpp.gd) **10/10 通过**。

### 基准（本机 MSVC Release，60 步）

| 粒子数 | 每秒粒子更新 | 每秒步数 |
|---|---|---|
| 1000 | 1,669,867 | 1670 |
| 5000 | 406,745 | 81 |
| 5000（4 线程） | ~1.17M | 233 |
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
& $GODOT --headless --path . scenes/test_soil_contact.tscn  # 13/13
& $GODOT --headless --path . scenes/test_soil_particles.tscn # 10/10（需先构建）
& $GODOT --headless --path . scenes/test_particle_budget.tscn # 16/16（需先构建）
& $GODOT --headless --path . scenes/test_delta_terrain.tscn  # 12/12
& $GODOT --headless --path . scenes/test_delta_persistence.tscn # 14/14
& $GODOT --headless --path . scenes/test_fracture.tscn       # 11/11
& $GODOT --headless --path . scenes/test_dem_cpp.tscn       # 20/20（需先构建）
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

## 8. 还没做 / 坑

- `GroundChunk` 尚未接进渲染/碰撞；客户端地面仍是静态三角网 + 试验场。
- 接触力 → 移除物质 → DEM 粒子已通：`GroundChunk.apply_contact` 返回载荷，
  `SoilDEMKernel.spawn_from_mass` 按质量生成粒子（test_soil_particles
  7/7）。但还没有把它接进实际游戏循环/渲染。
- C++ 内核仍是球形粒子；`FractureGenerator` 已能生成不规则凸碎片和
  ItemEntity，但还没接进 `GroundChunk.apply_contact` 的岩石破坏；
  MPM/SPH 都没做。
- C++ 接触计算已支持多线程（5000 粒子 4 线程约 2.6 倍），但每步都
  创建线程，正式版应换成线程池。
- 球心重力已接进 C++ 内核（`set_spherical_gravity`），但坐标是球心原点；
  实际游戏里需要和客户端/服务端的世界坐标一致。
- 活跃粒子预算已有工具（`radius_for_budget`），静止粒子能从内核移除
  并写入 [MatterDelta](scripts/shared/world/matter_delta.gd) 稀疏增量
  （`consolidate_slow` + `deposit`）；`MatterField` 会读取堆积组成和
  高度，`GroundChunk.rebuild()` 能长出新格子和碰撞。
- 「挖走」已经写进 `MatterDelta`（`remove_volume`），`GroundChunk.rebuild`
  后坑还在；换块/重载的读路径还需要把同一个 delta 传给新块。
- `GroundChunk` 仍是单块原型，没有流式加载；`MatterDelta` 已能 JSON
  持久化并被多个块共享，但还没有接入正式存档/网络。
- 一次移除 0.125 m³ 表土：2 cm 颗粒约 2.7 万；预算 5000 时粒径约 3.6 cm。
- C++ 只构建了 Windows editor 目标；Linux/导出模板/多线程/GPU 未做。
- 试验场石台是开发用人工构造；发布前关 `test_yard_enabled`。
- `PlanetInterior` 的地壳厚度是为可玩性放大的，不是地球比例。
- 服务端权威粒子同步、活跃区管理、持久化都还没开始。

## 9. 下一步顺序

1. 把 `FractureGenerator` 接进岩石破坏（岩块碎裂成 ItemEntity）；
2. 线程池 + 更大活跃区；
4. 多线程空间分区，扩大活跃区；
5. 湿泥/水 MPM/SPH；
6. 接入渲染/网络；服务端权威。
