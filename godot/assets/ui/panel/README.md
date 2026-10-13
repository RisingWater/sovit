# 面板图标（手绘）

面板标题与页签用的小图标，32×32。

| 文件 | 用途 |
|---|---|
| `finance.png` | 统计面板的「财务」页签 |
| `research.png` | 科技面板标题、顶栏「科技」按钮 |

## 来源与授权

- **作者**：workbuddy
- **授权**：**MIT**（允许再分发）
- 由 `scripts/import-panel-icons.py` 从用户提供的 64×64 原图导出；
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
