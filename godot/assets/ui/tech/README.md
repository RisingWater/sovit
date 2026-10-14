# 科技图标

科技树卡片上的图标，32×32，**文件名就是科技 id**（与 `content/technologies.json`
一一对应，`UIKit.tech_icon()` 直接按 id 取图，显示尺寸 `UIKit.TECH_ICON_SIZE = 32`）。

| | |
|---|---|
| **数量** | 44 个（43 项科技齐全 + `research_institute` 一张暂时没对上科技） |
| **作者** | workbuddy（29 张第一批 + **15 张第二批 `tech_icons_v2`**） |
| **授权** | **MIT**（允许再分发） |
| 来源 | 用户提供的素材包，由 `scripts/import-tech-icons.py` 导入（**两个源合并**） |

许可证原文见 [`LICENSE.txt`](LICENSE.txt)。MIT 要求保留版权声明，该文件必须随图标一起留在仓库里。

## 两批图标的来历

| 批次 | 数量 | 生成方式 | 重跑命令 |
|---|---|---|---|
| 第一批 `tech_icons/` | 29 | 手绘素材，最近邻 64→32 + `dematt()` 去毛边 | `python scripts/import-tech-icons.py` |
| 第二批 `tech_icons_v2/` | 15 | 同上（**这 15 张就是效率科技的图标**） | 同上（脚本会把两个源合并导入） |

- 两个源里同一 id 后出现的覆盖先出现的；两批之间**没有重叠 id**。
- 第二批的素材目录在仓库外（`C:\Users\wangxu\WorkBuddy\...\outputs\tech_icons_v2`），
  文件名是 `NN_<英文名>_<中文名>.png` —— 比第一批多一段中文名，英文名另有 4 个对不上
  我们的科技 id，映射表都在导入脚本的 `OVERRIDE` 里：
  `improved_kiln → kiln_upgrade`、`woodworking_machinery → sawmill_machinery`、
  `brick_machine → brick_press`、`lifting_frame → crane`。
- 素材里可能有**已退役科技**的图标（`research_institute` 那条科技已删）：
  导入脚本只警告 + 跳过，不当致命错误；致命的是"某项科技没有图标"。

> **图标来源只有一个：用户的 workbuddy 素材**（两批：`tech_icons/` 29 张 +
> `tech_icons_v2/` 15 张），全部由 `scripts/import-tech-icons.py` 导入。
> 早先那 15 张曾有一版**程序化兜底图**（`scripts/gen-tech-icons.ts`），
> 已被 v2 素材取代并**从仓库删除** —— 不要再引入第二套来源，
> 否则"跑个脚本把好图覆盖掉"这种事迟早会发生。

改了素材或脚本要连 PNG 一起提交，并重跑 `--headless --path godot --import`。

## 命名

素材文件名是 `NN_<techId>_64x64.png`，去掉 `NN_` 前缀与 `_64x64` 后缀即科技 id。

**唯一的例外**：`05_hunting_camp_64x64.png` 对应我们的科技 id **`hunting`**
（素材按建筑名 `hunting_camp` 走的，科技名是 `hunting`）。映射写在导入脚本的
`OVERRIDE` 里，脚本会校验"每个图标都能对上某个科技 id、且每个科技都有图标"，
对不上直接报错退出。（这一步只覆盖素材包那 29 张；新增的 15 张由生成脚本负责。）

## 处理

1. **降采样到 32×32**：实测素材包 29 张**全是真正的 64×64**（不是某个原生分辨率的整数倍放大，
   脚本里检测过），所以用**最近邻**降到 32。不用 LANCZOS —— 它会引入灰边，
   与全游戏的硬边像素风格冲突。
2. **去毛边**：复用 `scripts/icon_util.py` 的 `dematt()`。同一批 workbuddy 素材，
   外圈确实有那圈浅色 matte（合计去掉 1671px），在深色卡片上会看着发白。

## 目录分工

| 目录 | 内容 |
|---|---|
| `assets/ui/tech/`（本目录） | **科技**图标 |
| `assets/ui/panel/` | 面板 / 顶栏 / 圆钮图标（人口·就业·金钱·满意度…） |
| `assets/icons/` | **商品**图标（36 个，作者 doubao） |
| `assets/goods/` | 商品图标的程序化兜底（`gen:art` 生成） |

分开是必须的：`GoodIcons.count_hand_drawn()` 按目录数文件，
科技图标混进 `assets/icons/` 会被数成商品图标。
