# 第三方素材授权（godot/assets/）

本项目的美术素材来自以下开源资源。多数为 CC0（公有领域），可商用、无需署名
（署名是自愿的，这里列出以示尊重）。字体为 OFL-1.1，可自由嵌入与再分发。
**例外**：商品图标为 **MIT**（需保留版权声明）；`props/` 的房屋为**专有商用授权**
（禁止散装再分发，所以本仓库应保持私有 —— 见下文）。

| 目录 / 文件 | 来源 | 作者 | 授权 |
|---|---|---|---|
| `tiny/town.png` | [Tiny Town](https://kenney.nl/assets/tiny-town) | Kenney | **CC0 1.0** |
| `tiny/farm.png` | [Tiny Farm](https://kenney.nl/assets/tiny-farm) | Kenney | **CC0 1.0** |
| `ui/*.png` | [UI Pack - Pixel Adventure](https://kenney.nl/assets/ui-pack-pixel-adventure) | Kenney | **CC0 1.0** |
| `cursors/*.png` | [Cursor Pixel Pack](https://kenney.nl/assets/cursor-pixel-pack) | Kenney | **CC0 1.0** |
| `fonts/fusion-pixel-10px-zh_hans.ttf` | [缝合像素字体 Fusion Pixel Font](https://github.com/TakWolf/fusion-pixel-font) | TakWolf | **OFL-1.1** |
| `fonts/fusion-pixel-12px-zh_hans.ttf` | 同上（当前 UI 用的就是这一档） | TakWolf | **OFL-1.1** |
| `buildings/*.png` | 本项目由 `content/*.json` 的 `art` 字段生成 | — | 同项目授权 |
| `thumbs/*.png` | 同上（含自绘的道路/地板笔刷卡） | — | 同项目授权 |
| `icons/*.png` | 用户提供的像素图标包，由 `scripts/import-icons.py` 导入 | **doubao** | **MIT**（见 `icons/LICENSE.txt`） |
| `ui/panel/*.png` | 面板 / 顶栏 / 圆钮图标（财政·科技·人口·就业·金币·建造力·研究力·移民·资源工业），由 `scripts/import-panel-icons.py` 与 `scripts/import-stat-icons.py` 导入 | **workbuddy** | **MIT**（见 `ui/panel/LICENSE.txt`） |
| `ui/tech/*.png` | 科技树卡片图标（29 个，文件名 = 科技 id），由 `scripts/import-tech-icons.py` 导入 | **workbuddy** | **MIT**（见 `ui/tech/LICENSE.txt`） |
| `goods/*.png` | 本项目自绘（36 个商品图标的**程序化兜底**，16×16） | — | 同项目授权 |
| `tiny/extra.png` | 本项目自绘（道路 / 水面 / 桥 / 矿脉 / 砖石地板） | — | 同项目授权 |
| `tiny/deco.png` | 本项目自绘（树 4 种） | — | 同项目授权 |
| `actors/*.png` | 本项目自绘（居民 4 阶层 × 4 向 × 4 帧） | — | 同项目授权 |
| `ui/speed_*.png` | 本项目自绘（暂停 / 1x / 2x / 4x） | — | 同项目授权 |
| `ui/nav_btn_*.png` | 本项目自绘（左侧导航圆钮：木盘 + 粗外框 + 内圈高光 + 四向金属卡扣，16×16，由 `gen-art.ts` 生成） | — | 同项目授权 |
| `music/shimmer_sill_*.ogg` | [RPG Town Pack](https://talontrueblood.itch.io/) | **Talon Trueblood** | **免费使用 + 需署名** |
| `sfx/*.ogg` | [UI SFX Set](https://kenney.nl/assets/ui-audio) | Kenney | **CC0 1.0** |
| `props/src/house_*.png`<br>`props/thumb/*.png` | SUPER RETRO WORLD | Gif | **专有商用授权** |

## icons/ —— MIT，需保留版权声明

36 个 32×32 手绘商品图标。UI 一律通过 `scripts/ui/good_icons.gd` 取用
（`icons/` 优先、`goods/` 程序化兜底）。

- **作者**：doubao
- **授权**：MIT，许可证原文见 [`icons/LICENSE.txt`](icons/LICENSE.txt)
- 素材包本身**不入库**（与 Tiny / UI / Props 包的处理方式一致），只提交导出的 PNG；
  重新导入用 `python scripts/import-icons.py`（读本地素材包）。

> MIT 要求保留版权声明，所以 `LICENSE.txt` 必须随图标一起留在仓库里。

## ui/panel/ 与 ui/tech/ —— MIT（workbuddy）

`ui/panel/`：面板 / 顶栏数值 / 左侧圆钮用的小图标（人口·就业·金钱·满意度·建造力·
研究力·移民·资源工业·财政·科技）。

`ui/tech/`：科技树卡片图标，29 个，**文件名 = 科技 id**。
UI 通过 `UIKit.tech_icon(id)` 取用。

- **作者**：workbuddy
- **授权**：MIT，许可证原文见各自的 `LICENSE.txt`
- 素材包本身**不入库**，只提交导出的 PNG：
  `python scripts/import-panel-icons.py` / `import-stat-icons.py` / `import-tech-icons.py`
- 三者的共同处理放在 `scripts/icon_util.py` 的 `dematt()` —— 同一批素材外圈都有
  一圈浅色 matte，在深色 HUD 上看着像白边，导入时统一去掉

## music/ —— 需署名

`godot/assets/music/shimmer_sill_dawn.ogg` 与 `shimmer_sill_dusk.ogg` 来自
**RPG Town Pack**（Talon 目录，第 1 首 + Bonus）。原始授权文本见
[`music/Read Me (RPG Town Pack).txt`](music/Read%20Me%20(RPG%20Town%20Pack).txt)：

> Free to use in any Godot project with attribution.
> Credit "Music: Talon Trueblood" in your game credits or itch.io page.
> Commercial use permitted with credit.

**必须在游戏的制作人员名单 / itch 页面署名**：

```
Music: Talon Trueblood
```

达成方式：`scripts/ui/music.gd` 会把曲名显示在顶栏"音乐"按钮的 tooltip 里；
发布时另需在标题画面或致谢页放上 `Music: Talon Trueblood`。
授权没有禁止再分发，所以这两首随仓库入库没有问题。

两首曲子轮流播放（播完一首切下一首，**单曲不循环** —— 否则
`AudioStreamPlayer.finished` 不触发，就会退化成单曲无限循环）。
`tools/music_test.gd` 在门槛里锁住这一点。

## props/ —— 专有素材

`godot/assets/props/` 里的 12 张房屋来自 **SUPER RETRO WORLD**（Copyright (C) Gif），
完整授权见 [`godot/Custom_Commercial_License.txt`](../Custom_Commercial_License.txt)。

**授权允许**：用在游戏里、修改改编、**随成品分发**（`Distribute finished projects containing the Assets`）。
**授权禁止**：作为散装文件再分发、上传到公开仓库、以可提取的独立形式公开。

### ⚠️ 本仓库应当保持私有

`assets/props/src/*.png` 与素材包原图**逐字节相同**，属于授权所说的
"standalone files" / "extractable standalone form"。因此：

- **本仓库需保持私有**。私有仓库不构成"publicly available"，落在授权允许范围内。
- 若要公开本仓库，请先按下文把 prop 依赖去掉（约 1 分钟）。
- 发布**打包好的游戏**没有这个问题 —— 授权明说允许 "finished projects containing the Assets"。

### 素材包本身不入库

`godot/Props/`、`godot/Characters/`、`godot/Tilesets/`（原始下载包，共 586 个文件）
不纳入版本管理，与 Tiny / UI 包的处理方式一致：**原始包不入库，游戏实际用到的落到
`godot/assets/`**。

本地要重新生成时：把素材包解到 `godot/Props/`（保持 `Props/Houses/Sprites/house_NN.png`
的相对路径），执行 `npm run gen:art`。缺包时 gen-art 会跳过这 12 座并告警，
游戏会退回自绘的 `buildings/_prop_fallback.png`，其余建筑不受影响。

### 要完全去掉这个依赖

把 `content/buildings.json` 里 12 处

```json
"art": { "arch": "prop", "sprite": "house_02" }
```

改回程序化生成，例如

```json
"art": { "arch": "workshop", "roof": "blue", "wall": "wood", "w": 5 }
```

然后 `npm run gen:art`。代码侧无需改动 —— 只是回到"由图集拼装"的方式。

## 生成物说明

以下**不是**手工资产，请勿手改 —— 改 `content/*.json` 或 `scripts/gen-art.ts` 后重跑 `npm run gen:art`：

- `buildings/*.png` —— 由 `content/buildings.json` / `housing.json` 的 `art` 字段生成
- `tiny/extra.png` —— 由 `scripts/gen-art.ts` 生成
- `actors/*.png` —— 由 `scripts/gen-art.ts` 生成

`tiny/town.png`、`tiny/farm.png`、`ui/*.png` 是上游原图，**不要修改**，升级素材时整个替换。

## 一段历史提醒（Tiny 系列无此问题）

早期评估过 Hyptosis 的 *Mage City Arcanos*（同为 CC0），但 OGA 历史上有过"部分构件疑似
派生自 RPG Maker RTP"的争议（管理员移除过帐篷与钟面，另有路灯的质疑未结）。
Tiny 系列是 Kenney 原创，**没有这类争议**，故最终采用。
