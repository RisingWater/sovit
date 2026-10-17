# 第三方素材授权（godot/assets/）

本项目的美术素材来自以下开源资源。多数为 CC0（公有领域），可商用、无需署名
（署名是自愿的，这里列出以示尊重）。字体为 OFL-1.1，可自由嵌入与再分发。
**例外**：商品图标为 **MIT**（需保留版权声明）。
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
| `ui/panel/*.png` | 面板 / 顶栏 / 圆钮 / ESC 菜单图标（财政·科技·人口·就业·金币·建造力·研究力·移民·资源工业；另有 2026-10 后加的 11 张：任务面板、金色/灰色问号、新游戏·保存·读取·设置·音乐·音效·调试·退出），前一批由 `scripts/import-panel-icons.py` 与 `import-stat-icons.py` 导入 | **workbuddy** | **MIT**（见 `ui/panel/LICENSE.txt`） |
| `ui/tech/*.png` | 科技树卡片图标（29 个，文件名 = 科技 id），由 `scripts/import-tech-icons.py` 导入 | **workbuddy** | **MIT**（见 `ui/tech/LICENSE.txt`） |
| `portraits/*.png` | 七人顾问团立绘（7 张，640×960，绿幕图抠成透明底），由 `scripts/import-portraits.py` 导入 | **workbuddy** | 随本项目 |
| `goods/*.png` | 本项目自绘（36 个商品图标的**程序化兜底**，16×16） | — | 同项目授权 |
| `tiny/extra.png` | 本项目自绘（道路 / 水面 / 桥 / 矿脉 / 砖石地板） | — | 同项目授权 |
| `tiny/deco.png` | 本项目自绘（树 4 种） | — | 同项目授权 |
| `actors/*.png` | 本项目自绘（居民 4 阶层 × 4 向 × 4 帧） | — | 同项目授权 |
| `ui/speed_*.png` | 本项目自绘（暂停 / 1x / 2x / 4x） | — | 同项目授权 |
| `ui/nav_btn_*.png` | 本项目自绘（左侧导航圆钮：木盘 + 粗外框 + 内圈高光 + 四向金属卡扣，16×16，由 `gen-art.ts` 生成） | — | 同项目授权 |
| `music/shimmer_sill_*.ogg` | [RPG Town Pack](https://talontrueblood.itch.io/) | **Talon Trueblood** | **免费使用 + 需署名** |
| `sfx/*.ogg` | [UI SFX Set](https://kenney.nl/assets/ui-audio) | Kenney | **CC0 1.0** |
| `building_src/*.png` | 用户提供的 v3 建筑整图（34 张，workbuddy 生成） | workbuddy | 随本项目 |

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
研究力·移民·资源工业·财政·科技）。**全部 32×32**，用的时候只按整数分之一缩
（顶栏 / 按钮 16 = 一半；面板标题 32 = 原件；顶栏数值 24）。

其中十一张是**后加**的（2026-10，同为 **workbuddy 自绘**、同一个素材包）：

| 文件 | 素材包里的名字 | 用在哪 |
|---|---|---|
| `quest_panel.png` | `09_task_panel_32x32` | 任务追踪条标题（16）/ 任务面板标题（32）/ 左侧圆钮第 5 个（32） |
| `ai_assist.png` | `08_question_mark_gold_32x32` | 顶栏那个问号按钮（16）/ 面板标题（32）—— **可问** 状态 |
| `ai_assist_off.png` | `08_disabled_question_mark_grey_32x32` | 同一个按钮的 **冷却中** 状态（灰色问号） |
| `new_game.png` | `10_new_game_32x32` | ESC 菜单「新游戏…」 |
| `save.png` | `11_save_32x32` | ESC 菜单「保存…」 |
| `load.png` | `12_load_32x32` | ESC 菜单「读取…」 |
| `settings.png` | `13_settings_32x32` | ESC 菜单「设置资源…」 |
| `music.png` | `14_music_32x32` | ESC 菜单「音乐：开/关」 |
| `sfx.png` | `15_sound_effect_32x32` | ESC 菜单「音效：开/关」 |
| `debug.png` | `16_debug_32x32` | ESC 菜单「建筑占地：开/关」 |
| `exit.png` | `17_exit_32x32` | ESC 菜单「退出游戏」 |

这十一张都是 32×32 透明底、**没有外圈毛边**，所以 `dematt()` 对它们是空操作。
前两张登记在 `scripts/import-stat-icons.py` 的 `WANT` 表里；**后九张（ESC 菜单那批）没登记**
—— 它们是"界面用图"而不是"状态图标"，而且素材包不入库，登记了也没法重导。
⚠️ 本地没有源包时，重跑 `import-stat-icons.py` 对已登记的条目只会就地把已有的图再过一遍
去毛边（`dematt` 幂等），不会把它们换成别的东西。

门槛 `quest_test` / `ai_test` / `esc_test` 各有"这张图还在不在、尺寸对不对"的断言 ——
贴图被删或改名时 Godot **不报错**，只是界面上空一块。

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

## portraits/ —— 七人顾问团立绘

七张半身立绘（`sebastian / alvin / reynard / isabella / vera / luna / serafina`），
**640×960**、透明底、2:3。人物与设定见 [`docs/characters.md`](../../docs/characters.md)。

- **作者**：workbuddy（用户提供的绿幕图）
- **授权**：随本项目
- **重新导入**：`python scripts/import-portraits.py`（读本地绿幕图，抠掉 `#00FF00` 底）
- 绿幕图本身不入库（与图标 / 建筑整图一致），只提交抠好的 PNG
- 五张右下角带生成工具的 `AI生成 / WORKBUDDY` 水印 —— **没抹**（原图自带，见
  `docs/characters.md` §七）
- 后 31 张表情按 `<id>_<mood>.png` 接着放，命名表在 `docs/characters.md` §5.2

## 建筑整图（v3）

34 张成品建筑整图，来源为用户提供的素材包（workbuddy 生成），随本项目授权。

- 入库副本：`godot/assets/building_src/<id>.png`（**已提交**，干净检出即可跑 `gen:art`）
- 重新导入：`python scripts/import-building-sprites.py`（读本地素材包，按**中文名**对 id）
- 生成物：`godot/assets/buildings/<id>.png` + `thumbs/<id>.png`
- **尺寸规则**（`scripts/gen-art.ts` 的 `STOREYS`）：显示高度 = 层数 × 3 格 + 屋顶 2 格，
  每座取满足上限的最大整数下采样倍率。详见该文件的注释。
- 素材包本身不入库（与 Tiny / UI 包一致）：**原始包不入库，实际用到的落到 `godot/assets/`**

> 素材里有 4 座当年本项目尚未实装的建筑（仓库 / 市场 / 别墅 / 城镇中心），已一并导入备用。
> 现在的交接情况：**城镇中心、仓库已实装**（`content/buildings.json` 里写 `art.arch = "sprite"`）；
> **市场 / 别墅还没实装**（`building_src/market.png`、`villa.png` 在库里备用，
> 设计稿见 `docs/town.md`）。实装时把对应条目加进 `content/buildings.json` 并设
> `art.arch = "sprite"` 即可（占地由贴图尺寸推出，或显式写 `art.foot`），**无需改代码**。
>
> ⚠️ 反过来的坑也踩过：素材明明在 `building_src/` 里，却给同一座建筑写了**程序化规格**
> （`warehouse` 曾经是 `{arch:"warehouse", roof:"blue", ..., w:4}`）—— 于是建造栏卡片和
> 地图上一直是程序化占位图，那张整图白白搁置（用户报的"仓库缩略图不对"就是这个）。
> 加建筑前先看一眼 `building_src/` 里有没有它的图。

### 历史：Super Retro World 已完全移除（2026-10）

在此之前有 12 座建筑用 **SUPER RETRO WORLD**（Copyright (C) Gif）的整图，那份授权
**禁止散装再分发、禁止上传公开仓库**，所以当时 `godot/assets/props/` 那 48 个文件
让整个仓库**必须保持私有**。

改用 v3 建筑整图后：

- `godot/assets/props/`（48 个文件）已删除
- `godot/Custom_Commercial_License.txt`（SRW 授权原文）已删除
- `.gitignore` 里 SRW 那段说明已改写
- **本仓库不再需要保持私有** —— 那条约束随素材一起消失了

## 生成物说明

以下**不是**手工资产，请勿手改 —— 改 `content/*.json` 或 `scripts/gen-art.ts` 后重跑 `npm run gen:art`：

- `buildings/*.png` —— 由 `content/buildings.json` / `housing.json` 的 `art` 字段生成
  （`arch: "sprite"` 的是 v3 整图缩放来的，其余由图集程序化拼装）
- `tiny/extra.png` —— 由 `scripts/gen-art.ts` 生成
- `actors/*.png` —— 由 `scripts/gen-art.ts` 生成

`tiny/town.png`、`tiny/farm.png`、`ui/*.png` 是上游原图，**不要修改**，升级素材时整个替换。

## 一段历史提醒（Tiny 系列无此问题）

早期评估过 Hyptosis 的 *Mage City Arcanos*（同为 CC0），但 OGA 历史上有过"部分构件疑似
派生自 RPG Maker RTP"的争议（管理员移除过帐篷与钟面，另有路灯的质疑未结）。
Tiny 系列是 Kenney 原创，**没有这类争议**，故最终采用。
