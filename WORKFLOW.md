# 工作流程（当前里程碑）

目标：把「物质地面 + 接触力 + 粒子/碎片」做成一个可走、可挖、可恢复的闭环。
每个任务都按 **实现 → 测试 → 提交 → 更新 CHANGES.md** 走；只有需要产品/硬件
决策时才停下来问。

## 里程碑 M：近场物质地面闭环

| 任务 | 状态 | 内容 |
|---|---|---|
| M1 | ✅ | DEM 粒子局部地面平面；静止粒子合并回 `MatterDelta`；重建附近格块 |
| M2 | ✅ | 左键主要动作，力量 = `PlayerBody.get_max_force() × 2`，工具 `bone` |
| M2b | ✅ 待窗口实测 | 手掌 `ContactForceProbe` 接触地面 >50 N 自动对接触点施力 |
| M3 | ✅ | LOD patch + 静态碰撞开洞 + 格子部分移除 + 缓存优化 + 精细交互 patch |
| M4 | ✅ | 粒子视觉用凸碎片模板 + 随机旋转；物理碰撞仍是球 |
| M5 | ◐ | `MatterDelta` JSON 存/读完成；网络/服务端权威按 Phase 1 策略延后 |

## 当前实现（2026-11-17）

### 世界 / 地质

- `MatterField`：位置 + 深度 → 组成 / 含水率 / 压实度 / 温度 / 压力 /
  抗剪强度 / 休止角；
- `PlanetInterior`：地壳 / 地幔 / 外核 / 内核，材料库 73 种；
- `OreVein`：3D FBM 矿脉、深度带、寄主岩性；
- `GroundChunk`：marching tetrahedra 连续等值面，支持自定义 cell/size、
  部分格子移除、`rebuild()`；
- `MatterDelta`：堆积/挖走的稀疏增量，JSON 存/读，跨块共享。

### 客户端地面（M3）

- 玩家周围 **180 m / 4 m 格** 的单块物质 patch（粗 LOD）；
- 玩家周围 **12 m / 0.5 m 格** 的精细交互 patch（用于精细挖掘）；
- 粗 patch 缓存：移动 < 72 m 时只更新 shader 中心（0 ms），不重建；
- 精细 patch 缓存：移动 < 3 m 不重建（初次约 576 ms）；
- 静态地形碰撞按三角面中心移除 **65 m 洞口**，视觉 shader 同步 discard；
- 碰撞洞缓存：洞口中心移动 < 32.5 m 不重建；
- 施力时优先查询离接触点最近的 patch（精细 patch 自动优先）。

### 交互 / 粒子

- `primary_action`（左键）用玩家身体力量对前方地面施力；
- 手掌接触 `TerrainBody`/`GroundCollision` >50 N 时自动对真实接触点施力；
- 手指控制：右键按住上下拖动调选中关节；`` ` `` 键循环 proxim/mid/dist；
  1-5 / 6-0 选择左右手手指；滚轮调手臂关节；**E 键**四指/拇指整体
  卷成握姿，再按 E 张开；
- 指腹软皮层：每节 25 个采样点（末节 +5），同时贴合物品和地面；
  5 mm 骨芯仍保留物品/地面硬碰撞作为软皮漏检时的兜底，CCD 防止
  细木棍被一步跨过；骨折判定用 80 ms 低通接触力，避免一碰就断；
- 拇指控制范围：CMC 80° / MCP 55° / IP 80°，控制层与肌肉层使用
  同一张上限表（`test_thumb_range` 6/6）；轴由 `test_thumb_axes` 验证，
  对掌/屈曲不会互换；皮肉从掌缘 CMC 窝起扫，不再接四指共用的掌中根点；
- 出生点前方 1.6 m 有一根 `TEST STICK`（Ø4 cm × 1.1 m，约 1.04 kg）：
  先冻结直立，右键按住并碰到/手掌靠近 45 cm 后释放成普通动态木棍，
  用于复现抓取时手部被顶偏；`WorldRenderer.test_stick_enabled` 控制；
- 土 → C++ DEM 粒子（最多 1200 个，MultiMesh 凸碎片模板）；
- 岩石 → `FractureGenerator` 破裂成独立 `ItemEntity`；
- DEM 粒子有局部地面平面；静止粒子每 2 s 合并回 `MatterDelta`；
- 粒子物理是球，视觉是不规则碎片。

## 测试命令

```powershell
$GODOT = "I:\godot\Godot_v4.7.2-stable_win64.exe"
& $GODOT --headless --path . scenes/test_dem_cpp.tscn        # 23/23
& $GODOT --headless --path . scenes/test_client_strike.tscn  # 6/6
& $GODOT --headless --path . scenes/test_ground_chunk.tscn   # 24/24
& $GODOT --headless --path . scenes/test_soil_contact.tscn   # 19/19
& $GODOT --headless --path . scenes/test_fracture.tscn       # 14/14
& $GODOT --headless --path . scenes/test_delta_terrain.tscn  # 12/12
& $GODOT --headless --path . scenes/test_delta_persistence.tscn # 14/14
& $GODOT --headless --path . scenes/test_soil_particles.tscn # 10/10
& $GODOT --headless --path . scenes/test_particle_budget.tscn # 16/16
& $GODOT --headless --path . scenes/test_geology.tscn        # 27/27
& $GODOT --headless --path . scenes/test_thumb_range.tscn    # 6/6（拇指控制范围）
& $GODOT --headless --path . scenes/test_grip_assist.tscn    # 42/42（E 握持）
```

GDExtension 任务先运行 `gdextension\build.bat`。

## 当前已知问题

- LOD patch 重建约 2.8 s，移动 45 m 触发一次，有明显卡顿；
- 自动跨步只对横躺且高度 ≤45 cm 的物品生效，竖立木棍不再触发；
  站上木棍/石头不会再被抬上天（见 CHANGES §15）；
## 当前已知问题（2026-11-17）

- 初次生成粗 patch + 精细 patch 约 **3 s**（粗 2.4 s + 精细 0.6 s）；
  小范围移动已缓存（粗 patch < 72 m 不重建，精细 patch < 3 m 不重建）。
- 精细 patch 只有 12 m，移动出去后又会触发重建；可考虑扩大或增量。
- 静态 50 m 网格的洞边缘仍有少量三角面与 patch 重叠。
- DEM 粒子物理仍是球；视觉用凸碎片模板，但碰撞不是不规则形状。
- DEM 地面是局部平面近似，不是真实格块高度场。
- MPM/SPH 未做；C++ 只构建 Windows editor 目标；Linux/导出/GPU 未做。
- 服务端权威粒子同步、网络、正式存档未接（按 Phase 1 策略延后）。

## 下一步（需要决策）

1. **进入 M5**：服务端权威、网络同步、正式存档；
2. 继续优化 M3：分帧构建、精细 patch 增量、消除初次 3 s 卡顿；
3. 人体真实骨骼/肌腱/肌肉系统（见 WISHES.md §2）；
4. 粒子物理不规则化（DEM 多球/凸体）；
5. MPM/SPH（湿泥/水）；
6. Linux/导出构建与 GPU 评估。
