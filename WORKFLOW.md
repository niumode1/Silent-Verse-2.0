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
| M3 | ◐ | LOD patch + 静态碰撞开洞 + 格子部分移除；性能/精度待优化 |
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

- 玩家周围 **180 m / 4 m 格** 的单块物质 patch；
- 静态地形碰撞按三角面中心移除 **65 m 洞口**，视觉 shader 同步 discard；
- patch 半宽 90 m 覆盖洞口；**不再使用 per-body collision exception**；
- 玩家移动 45 m 触发 patch + 碰撞洞重建（约 2.8 s 卡顿）。

### 交互 / 粒子

- `primary_action`（左键）用玩家身体力量对前方地面施力；
- 手掌接触 `TerrainBody`/`GroundCollision` >50 N 时自动对真实接触点施力；
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
```

GDExtension 任务先运行 `gdextension\build.bat`。

## 当前已知问题

- LOD patch 重建约 2.8 s，移动 45 m 触发一次，有明显卡顿；
- 4 m 粗格对精细挖掘仍偏粗；一次敲击只带走很小体积；
- 静态 50 m 网格的洞口边缘仍有少量三角面重叠 patch；
- 粒子物理仍是球，不是真实不规则颗粒；
- MPM/SPH、Linux/导出构建、服务端权威/网络同步未做。

## 下一步（需要决策）

1. **优化 M3**：patch 增量/缓存、更细交互 patch、消除重建卡顿；
2. **进入 M5**：服务端权威、网络同步、正式存档。
