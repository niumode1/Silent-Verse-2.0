# C++ 粒子内核（GDExtension）

这是粒子物理内核的原生骨架，目标是把 GDScript 里验证过的 DEM/后续 MPM
搬到 C++，而不是用 Godot 场景树模拟粒子。

## 目录

```
gdextension/
├── CMakeLists.txt        # godot-cpp + 本扩展
├── build.bat             # Windows / MSVC 一键构建
└── src/
    ├── register_types.cpp
    ├── soil_dem_kernel.h
    └── soil_dem_kernel.cpp
silent_verse_particles.gdextension
bin/                      # 构建产物（gitignore）
third_party/godot-cpp/    # godot-cpp（gitignore，需自行 clone）
```

## 依赖

- Visual Studio（C++ 工作负载 + 自带的 CMake/Ninja）或等价工具链；
- `third_party/godot-cpp`，master 分支（含 `extension_api-4-7.json`）：

```bash
git clone --depth 1 https://github.com/godotengine/godot-cpp.git third_party/godot-cpp
```

## 构建（Windows）

```powershell
gdextension\build.bat
```

产物：`bin/libsilent_verse_particles.windows.editor.x86_64.dll`。
`.gdextension` 使用 editor 目标；首次加入后需要在 Godot 里重新导入一次
（`--headless --editor --quit`）才会注册类。

## 运行

```powershell
I:\godot\Godot_v4.7.2-stable_win64.exe --headless --path . scenes/test_dem_cpp.tscn
```

## 当前 API

`SoilDEMKernel`（RefCounted）：

```gdscript
var k = ClassDB.instantiate("SoilDEMKernel")
k.configure(count, radius, density, cohesion, friction, stiffness, damping, seed)
k.setup_material(radius, density, cohesion, friction, stiffness, damping)
k.clear_particles()
k.spawn_from_mass(mass, center, spread, seed)   # 返回实际粒子数
k.set_bounds(min, max)
k.set_tool(x, speed)
k.set_spherical_gravity(R, g0)                  # 球心重力
k.set_planar_gravity(g)
k.set_threads(n)                                # 接触计算并行线程数
k.step(dt)
k.get_positions()
k.get_velocities()
k.remove_particles(indices)                     # 静止粒子合并
k.get_total_mass()
k.get_particle_mass()
k.get_tool_force()
k.get_particle_count()
k.get_step_count()
```

活跃粒子预算见
[scripts/shared/world/soil_particle_budget.gd](../scripts/shared/world/soil_particle_budget.gd)：
`radius_for_budget()` 按预算反推粒径，`consolidate_slow()` 移除静止粒子。

物理模型与 [soil_dem.gd](../scripts/shared/world/soil_dem.gd) 一致：
软弹簧-阻尼接触、Coulomb 摩擦、黏聚、推板、球心/盒边界；质量守恒。

## 基准（本机 MSVC Release，1000/5000 粒子，60 步）

| 粒子数 | 每秒粒子更新 | 每秒步数 |
|---|---|---|
| 1000 | 1,669,867 | 1670 |
| 5000 | 406,745 | 81 |
| 5000（4 线程） | ~1,170,000 | 233 |

对比 GDScript 原型（1000 粒子）：约 1.9 万粒子更新/秒。C++ 约 88 倍。
5000 粒子在 60 Hz 下需要 30 万更新/秒，当前单线程已能覆盖；更大的
活跃区需要多线程或 GPU。

## 下一步

- 把 `MatterField` 的组成/状态通过参数传进内核（目前先验参数）；
- 线程池化（现在每步创建线程），扩展活跃区；
- 湿泥/水用 MPM/SPH 内核，与 DEM 颗粒耦合；
- 不规则颗粒/碎块：从破裂面生成凸体，不再用球。
