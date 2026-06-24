# Silent Verse 建模指南

## 原理

你建的不是"一棵树"或"一块岩石"——你建的是**材质的最小视觉单元**。引擎用体素算法把这些单元组合、切割、拉伸、粉碎成任何形状。

```
你建的                    引擎做的                  玩家看到的
─────────────────────────────────────────────────────────────
1m³ 正方体.glb  →  体素并集 + 噪声扰动  →  任意形状的岩体
         +       →  Marching Cubes 平滑  →  自然不规则表面
   4 张 PBR 贴图   →  Voronoi 碎裂算法    →  碎块/粉末
                   →  布尔减法雕刻        →  玩家刻的任意形状
                   →  路径拉伸            →  细丝/管子/钉子
```

**引擎从不需要更多模型。岩石、山脉、矿脉、土块、沙粒、铜丝——全由同 1 个正方体变出来。**

---

## 格式要求

### 模型 .glb
- 标准 1m × 1m × 1m 正方体
- 原点在几何中心 (0.5, 0.5, 0.5)
- 6 面各 2 三角面 = 共 12 三角面
- UV 全部展开到 [0,1]，相邻面的 UV 边缘对齐
- 格式：`.glb`（GLTF Binary）

### PBR 贴图
- 分辨率：2048×2048
- 颜色贴图：PNG/JPG，不含光照阴影
- 法线贴图：PNG，OpenGL 格式（Y+朝上）
- 粗糙度、金属度：PNG 灰度、单通道即可
- **必须无缝平铺**——正方体切成任何形状后纹理都连续

| 贴图 | 命名 | 通道 |
|---|---|---|
| 颜色 Albedo | `xxx_albedo.png` | RGB |
| 法线 Normal | `xxx_normal.png` | RGB |
| 粗糙度 Roughness | `xxx_roughness.png` | 灰度 |
| 金属度 Metallic | `xxx_metallic.png` | 灰度 |

### 目录
```
assets/models/cubes/
├── stone_granite.glb         每组 1 个 .glb + 4 张图
├── stone_granite_albedo.png
├── stone_granite_normal.png
├── stone_granite_roughness.png
├── stone_granite_metallic.png
├── stone_sandstone.glb
├── stone_sandstone_albedo.png
├── ...（每组同理）
```

---

## 全 70 种材料的视觉分组

游戏数据库 70 种材料各有独立物理属性（密度/硬度/熔点等），但视觉上相同类型的材料外观一样。**建 1 套模型→覆盖同组所有材料。**

### 第一批（必须，10 组）

| 组 | 文件名 | 对应材料 | 外观要求 |
|---|---|---|---|
| 花岗岩 | `stone_granite` | granite, basalt | 浅灰白 + 黑色云母斑点 + 白色长石颗粒，粗糙 |
| 砂岩 | `stone_sandstone` | sandstone | 黄褐色 + 水平层理纹理，沙粒感，偏粗糙 |
| 石灰岩 | `stone_limestone` | limestone, slate | 浅灰白到浅黄，细腻均匀，可有微裂缝 |
| 燧石 | `stone_flint` | flint, obsidian | 深灰到黑色，贝壳状断口（同心弧线纹理），偏光滑 |
| 铁矿石 | `ore_iron` | iron_ore_hematite, iron_ore_magnetite | 锈红色到铁灰色，斑驳不均匀 |
| 铜矿石 | `ore_copper` | copper_ore_malachite, tin_ore_cassiterite, gold_ore | 翠绿色，标志性同心环纹 |
| 黏土 | `clay` | clay | 棕褐色，干裂细纹，细腻偏光滑 |
| 土壤 | `soil` | topsoil, sand, gravel | 深棕色，松散颗粒感，粗糙 |
| 木材 | `wood` | oak_wood, pine_wood, birch_wood, bamboo, vine | 浅棕色直线木纹 + 一面深色粗糙树皮 |
| 水 | `water` | water, seawater | 半透明，蓝色调，极光滑 |

### 第二批（金属+加工品，6 组）

| 组 | 文件名 | 对应材料 | 外观要求 |
|---|---|---|---|
| 铁金属 | `metal_iron` | pure_iron, mild_steel, high_carbon_steel, cast_iron | 银灰色金属光泽，金属度=1 |
| 铜金属 | `metal_copper` | pure_copper, bronze | 红铜色金属光泽 |
| 贵金属 | `metal_precious` | pure_gold, pure_silver | 金/银色高反光 |
| 锡金属 | `metal_tin` | pure_tin | 银白偏暗 |
| 冰 | `ice` | ice, snow | 白色半透明 |
| 玻璃 | `glass` | glass | 透明 |

### 第三批（有机物，5 组）

| 组 | 文件名 | 对应材料 | 外观要求 |
|---|---|---|---|
| 皮革 | `leather` | leather_tanned, hide_raw | 棕色皮纹理，粗糙 |
| 肉 | `flesh` | meat_raw, fat_animal, smoked_meat, spoiled_meat, crackling | 红粉色，纤维纹理 |
| 骨 | `bone` | bone, sinew | 象牙白，光滑 |
| 纤维 | `fiber` | wool, feather, hemp_fiber, grass_fiber, grain_sludge | 蓬松纤维 |
| 粮食 | `grain` | wheat_grain, bread, flour | 米黄色粉末/颗粒 |

### 不需要建模（引擎程序化生成外观）

`slag` `rust` `wood_ash` `quicklime` `slaked_lime` `brick` `pottery` `soap` `salt` `charcoal` `coal` `snow` `alcohol_solution` `potash_solution` `vinegar` `glycerol` `tannin_solution` `waste_liquid` `plant_oil`

——这些用粒子系统、流体 shader、或实时程序化颜色表示。

---

## 不需要的

- 不规则的岩石/矿物形状（体素算法切）
- 大/中/小多版本（引擎缩放+变形）
- 高面数正方体（12 三角面够）
- 4K 贴图（2K 够）
- LOD 版本
- .fbx 格式

---

## 规格总结

| 项目 | 规格 |
|---|---|
| 模型格式 | `.glb` |
| 模型形状 | 1m³ 正方体，12 三角面 |
| 贴图格式 | PNG/JPG，2048×2048，无缝平铺 |
| 每组数量 | 1 个 .glb + 4 张贴图 |
| 首批数量 | 10 组 = 10 个 .glb + 40 张贴图 |
| 贴图类型 | PBR（Albedo / Normal / Roughness / Metallic） |
| 文件位置 | `assets/models/cubes/` |

---

> **开始做第一批 10 组。做完花岗岩发我测试——确认贴图管线没问题再做剩下的。**
