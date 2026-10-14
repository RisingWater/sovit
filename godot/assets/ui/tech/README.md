# 科技图标

科技树卡片上的图标，32×32，**文件名就是科技 id**（与 `content/technologies.json`
一一对应，`UIKit.tech_icon()` 直接按 id 取图，显示尺寸 `UIKit.TECH_ICON_SIZE = 32`）。

| | |
|---|---|
| **数量** | 44 个（43 项科技齐全 + `research_institute` 一张暂时没对上科技） |
| **作者** | workbuddy（前 29 张）；后 15 张由本仓库脚本生成 |
| **授权** | **MIT**（前 29 张，允许再分发） |
| 来源 | ① 用户提供的 `tech_icons/` 素材包，由 `scripts/import-tech-icons.py` 导入 ② `scripts/gen-tech-icons.ts` 程序化生成 |

许可证原文见 [`LICENSE.txt`](LICENSE.txt)。MIT 要求保留版权声明，该文件必须随图标一起留在仓库里。

## 两批图标的来历

| 批次 | 数量 | 生成方式 | 重跑命令 |
|---|---|---|---|
| 素材包导入 | 29 | 手绘素材，最近邻 64→32 + `dematt()` 去毛边 | `python scripts/import-tech-icons.py` |
| 新增科技 | 15 | **纯程序化绘制**，见下 | `node --experimental-strip-types scripts/gen-tech-icons.ts` |

后 15 张（`crop_rotation` / `irrigation` / `improved_seeds` / `workshop_division` /
`standardization` / `assembly_line` / `kiln_upgrade` / `sawmill_machinery` /
`brick_press` / `scriptorium` / `academy` / `printing_press` / `crane` /
`scaffolding` / `prefab_parts`）由 `scripts/gen-tech-icons.ts` 生成：

- 复用 `scripts/lib/pixel.ts` 的 `Canvas`（与 `gen-art.ts` 同一套无依赖 PNG 编解码）
- **硬边**：只用矩形 / 多边形 / 圆弧 / 单点按整数像素直写，没有抗锯齿、渐变、
  模糊阴影，也不写任何半透明像素（脚本里有 alpha 只允许 0/255 的自检）
- 调色板全部取自上面那 29 张手绘图标（统计代表色后去重），每张最后统一补一圈
  1px 深色描边，所以两批图标混在一起是一套
- 脚本会校验图案没顶到画布边缘（否则描边会被裁掉）

改了脚本要连 PNG 一起提交，并重跑 `--headless --path godot --import`。

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
