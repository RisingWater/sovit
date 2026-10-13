# 面板图标（手绘）

面板标题、页签、顶栏数值与左侧圆钮用的图标，32×32。

| 文件 | 用途 |
|---|---|
| `finance.png` | 统计面板「财务」页签 + 左侧圆钮「财政」 |
| `research.png` | 科技面板标题 + 左侧圆钮「科技」（顶栏数值「科研力」也用） |
| `research_panel.png` | `05_research_64x64` 原样另存（备用，未接） |
| `population.png` | 顶栏「人口」+ 圆钮「人口」 |
| `employed.png` | 顶栏「就业」 |
| `money.png` | 顶栏「国库」 |
| `build.png` | 顶栏「建造力」 |
| `migration.png` | 移民相关（备用，未接） |
| `resource.png` | 左侧圆钮「资源」 |

素材里的中文名（`人口.png` / `金币.png` …）**只是导入脚本的输入**，
落盘一律用英文 id —— 中文文件名在跨平台工具链里最容易出编码问题。

## 来源与授权

- **作者**：workbuddy
- **授权**：**MIT**（允许再分发）
- 由 `scripts/import-panel-icons.py`（财政/科技）与 `scripts/import-stat-icons.py`
  （人口/就业/金币/建造力/研究力/移民/资源工业）从本地素材包与用户提供的原图导出；
  原图**不入库**，只提交导出的 PNG，与 `assets/icons/` 的处理方式一致。

> MIT 要求保留版权声明，所以 `LICENSE.txt` 必须随图标一起留在仓库里。
> 许可证原文见 [`LICENSE.txt`](LICENSE.txt)。

## 与其它图标目录的区别

| 目录 | 内容 | 尺寸 |
|---|---|---|
| `assets/icons/` | **商品**图标（36 种，作者 doubao） | 32×32 |
| `assets/ui/panel/`（本目录） | **面板装饰**图标 | 32×32 |
| `assets/goods/` | 商品图标的程序化兜底，`gen:art` 生成 | 16×16 |
| `assets/ui/*.png` | Kenney UI Pack 的 9-slice 框体 | 按索引 |

> 分开放是有原因的：`GoodIcons.count_hand_drawn()` 按目录数文件，
> 面板图标混进 `assets/icons/` 会被数成商品图标。

## 缩放说明

原图是**真正的 64×64**（不是某个原生分辨率的整数倍放大），
所以 64→32 用**最近邻**降采样：LANCZOS 会引入灰边，
与全游戏的硬边像素风格冲突（字体也是原生尺寸、只做整数倍缩放）。
