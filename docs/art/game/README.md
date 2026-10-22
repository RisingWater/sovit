# 游戏美术素材整理（docs/art/game/）

> 本目录是 `godot/assets/` 的**按分类整理副本**（立绘另存全尺寸稿与管线，见下）。
> 游戏运行时加载的**真源永远是 `godot/assets/`** —— 本目录只用于美术对照 / 重绘 / 交付，不进游戏工程。
> 每张素材的编号 / 作用 / 分类 / 加载代码引用见 [docs/art-assets.md](../../art-assets.md)。
>
> **对齐口径**：除立绘外，目录结构映射 `godot/assets/`（文件名 + 字节数一致）。
> 立绘是例外：`03_portraits/cast/` 放**全尺寸抠好稿**（`NN_<id>.png`，1024×1536），
> 引擎里 `godot/assets/portraits/<id>.png` 是它的**裁切缩放版**（640×896，5:7）——
> 换算管线（bbox 自适应裁 5:7 + LANCZOS）见 `03_portraits/script/`。

## 2026-10 清理（两边同步删）

引擎里**没用的素材已整体删除，本目录同步删**（各 212 个文件，两边保持对齐）：

| 删除项 | 张数 | 原因 |
|---|---|---|
| 商品程序化兜底 `goods/`（本目录原 `04_ui_icons/goods_fallback/`） | 48 | 手绘 `icons/` 已全覆盖。**缺图不再回滚旧图** —— `good_icons.gd` 直接显示**亮品红方块**（FF00FF）+ `push_warning`，一眼定位缺哪张 |
| Kenney UI Pack 多余 tile | 158 | 只用到 `tile_0033 / 0034 / 0036` 三张 |
| 旧版圆钮底 `nav_btn_normal\|hover\|pressed.png` | 3 | 被"圆盘烤在图标里"的 `ui/nav/` 取代 |
| 地图罗盘 `ui/map/compass.png` | 1 | 地图标记按 kind 取图，compass 永不作为 kind |
| `tiny/farm.png` | 1 | TileSet 只用 town / extra / deco |
| 10px 字体 `fusion-pixel-10px-zh_hans.ttf` | 1 | UI 用 12px 档 |

**保留**（看着"没接线"但有用武之地）：`building_src/` 源稿 50 张（`check-footprint.ts` 占地校验的贴图来源）、
`ui/faction/` 23 张与 B4 邦交科技 4 张（B4 外交 / 邦交接线时直接用）、`panel/nav` 里的 diplomacy / military / research_panel 预留图标。

## 目录 ↔ 分类对照

| 目录 | 分类 | 张数 | 来源 `godot/assets/` |
|---|---|---|---|
| `01_title/` | 游戏标题 | 3 | `ui/logo_title.png`、`icon.png`、`icon.ico` |
| `02_background/` | 背景 | 1 + 3 | `ui/map/kingdom_map_bare.webp`；`ui/tile_0033\|0034\|0036.png`（Kenney UI Pack 9-slice 底纹） |
| `03_portraits/cast/` | 立绘（抠好） | 21 | `NN_<id>.png` 1024×1536 透明底（z-image-turbo 白底生成 → BiRefNet 抠图）；引擎用的是缩到 640×896 的版本 |
| `03_portraits/src/` | 立绘（原图） | 21 | 生成原图（1024×1536 白底） |
| `03_portraits/script/` | 立绘管线 | 3 | `generate.py` · `cutout.py` · `prompt.json`（21 人提示词）；路径已改成相对本目录，可直接重跑 |
| `03_portraits/villagers/` | 立绘 | 4 | `actors/*.png`（穷人 / 中产 / 富人 / 老板四阶层小人） |
| `04_ui_icons/goods_handdrawn/` | UI图标 | 48 | `icons/*.png`（手绘商品 / 服务图标，64×64 为主；缺图显示品红方块，无兜底） |
| `04_ui_icons/panel/` | UI图标 | 24 | `ui/panel/`（面板标题 / 顶栏状态 / ESC 菜单图标） |
| `04_ui_icons/nav/` | UI图标 | 9 | `ui/nav/`（左侧圆钮图标，48×48 圆盘烤在图里） |
| `04_ui_icons/tech/` | UI图标 | 76 | `ui/tech/`（科技卡片图标，文件名 = 科技 id） |
| `04_ui_icons/faction/` | UI图标 | 23 | `ui/faction/`（B4 外交：13 势力徽记 + 7 关系牌 + 3 动作按钮，引擎端暂未接线） |
| `04_ui_icons/map/` | UI图标 | 13 | `ui/map/`（地图标记 + `_hover` 橙色悬停版；羊皮纸底图在 `02_background/`） |
| `04_ui_icons/thumbs/` | UI图标 | 57 | `thumbs/`（建造卡 / 科技面板建筑缩略图，含 `_floor` / `_road`；`housing_works` 是 content 已删项的遗留） |
| `04_ui_icons/coin.png` | UI图标 | 1 | `ui/coin.png`（价格 / 金额前的行内金币） |
| `05_buttons/` | 按钮 | 5 | `ui/speed_pause\|1x\|2x\|4x.png`、`slider_grabber.png` |
| `06_ui_deco/` | UI装饰 | 7 | `ui/ring_tl\|tr\|bl\|br.png`（小地图圆环）、`ui/ribbon_l\|m\|r.png`（村名红巾） |
| `07_buildings/` | 建筑贴图 | 56 | `buildings/*.png`（含 town_center 三段位变体） |
| `07_buildings/src/` | 源稿 | 50 | `building_src/*.png`（生成 `buildings/` 的原稿，`check:footprint` 也用它） |
| `08_world_tiles/` | 场景图块 | 3 | `tiny/`（town 原图集 / extra 自绘地形 / deco 树） |
| `09_cursors/` | 光标 | 5 | `cursors/`（Kenney Cursor Pixel Pack, CC0） |
| `10_fonts_audio/` | 字体 / 音频 | 2 + 3 + 2 | `fonts/`（fusion-pixel 12px、libertine）、`music/`（3 曲）、`sfx/`（2 音效） |

⚠️ 各目录里带的 `LICENSE` / `LICENCE` / `README` / `CREDITS` 是第三方素材的授权与出处文件，**不要删**（根下那份 `CREDITS.md` 是 `godot/assets/CREDITS.md` 的副本）。

## 已知缺口（重绘时优先补）

- **立绘还缺 3 张**：**艾莉丝（elise）**〔⚠️ `content/scenes.json` 已在引用，立绘为空时面板无图〕、艾隆（aelon）、莫甘娜（morgana）；
  每人还只有默认一张，表情差分 `<人>_<表情>.png` 一张没有（重出管线见 `03_portraits/script/`）。
- **商品图标缺一张就显示一块亮品红方块**（不回滚旧图）—— 看到品红块 = `content/goods.json` 里有新商品但没画 `icons/<id>.png`。
- `04_ui_icons/faction/` 23 张与 `tech/` 里的 `statecraft` + `trade_goodwill_1..3` 共 4 张是 B4 批，`content/*.json` 与引擎端还没接线。
- 其余（商品 / 科技 / 建筑缩略图）与 `content/*.json` 全量对齐，无缺口。

## 源目录更新后如何重新同步

`godot/assets/` 有增删改后，按上表映射重新复制（同名覆盖即幂等）；或让 agent 按 [docs/art-assets.md](../../art-assets.md) 重跑一遍整理。
校验口径：**除 `03_portraits/` 外**，两边"文件名 + 字节数"多重集合必须完全相等；
立绘只校验人数一致（cast 21 张 ↔ 引擎 21 张），尺寸差异是管线造成的，属预期。
