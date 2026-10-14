# 科技图标（手绘）

科技树卡片上的图标，32×32，**文件名就是科技 id**（与 `content/technologies.json` 一一对应）。

| | |
|---|---|
| **作者** | workbuddy |
| **授权** | **MIT**（允许再分发） |
| 来源 | 用户提供的 `tech_icons/` 素材包，由 `scripts/import-tech-icons.py` 导入 |
| 数量 | 29 个（= 全部科技，一个不缺） |

许可证原文见 [`LICENSE.txt`](LICENSE.txt)。MIT 要求保留版权声明，该文件必须随图标一起留在仓库里。

## 命名

素材文件名是 `NN_<techId>_64x64.png`，去掉 `NN_` 前缀与 `_64x64` 后缀即科技 id。

**唯一的例外**：`05_hunting_camp_64x64.png` 对应我们的科技 id **`hunting`**
（素材按建筑名 `hunting_camp` 走的，科技名是 `hunting`）。映射写在导入脚本的
`OVERRIDE` 里，脚本会校验"每个图标都能对上某个科技 id、且每个科技都有图标"，
对不上直接报错退出。

## 处理

1. **降采样到 32×32**：实测 29 张**全是真正的 64×64**（不是某个原生分辨率的整数倍放大，
   脚本里检测过），所以用**最近邻**降到 32。不用 LANCZOS —— 它会引入灰边，
   与全游戏的硬边像素风格冲突。
2. **去毛边**：复用 `scripts/icon_util.py` 的 `dematt()`。同一批 workbuddy 素材，
   外圈确实有那圈浅色 matte（合计去掉 1671px），在深色卡片上会看着发白。

## 目录分工

| 目录 | 内容 |
|---|---|
| `assets/ui/tech/`（本目录） | **科技**图标（29 个） |
| `assets/ui/panel/` | 面板 / 顶栏 / 圆钮图标（人口·就业·金钱·满意度…） |
| `assets/icons/` | **商品**图标（36 个，作者 doubao） |
| `assets/goods/` | 商品图标的程序化兜底（`gen:art` 生成） |

分开是必须的：`GoodIcons.count_hand_drawn()` 按目录数文件，
科技图标混进 `assets/icons/` 会被数成商品图标。
