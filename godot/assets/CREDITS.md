# 第三方素材授权（godot/assets/）

本项目的美术素材来自以下开源资源。**除字体外全部为 CC0（公有领域），可商用、无需署名**
（署名是自愿的，这里列出以示尊重）。字体为 OFL-1.1，可自由嵌入与再分发。

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
| `goods/*.png` | 本项目自绘（36 个商品图标） | — | 同项目授权 |
| `tiny/extra.png` | 本项目自绘（道路 / 水面 / 桥 / 矿脉 / 砖石地板） | — | 同项目授权 |
| `tiny/deco.png` | 本项目自绘（树 4 种） | — | 同项目授权 |
| `actors/*.png` | 本项目自绘（居民 4 阶层 × 4 向 × 4 帧） | — | 同项目授权 |
| `ui/speed_*.png` | 本项目自绘（暂停 / 1x / 2x / 4x） | — | 同项目授权 |
| `props/**` | SUPER RETRO WORLD | Gif | **专有，禁止再分发 —— 不入库** |

## ⚠️ props/ —— 专有素材，刻意不入库

`godot/Props/`、`godot/Characters/`、`godot/Tilesets/` 是 **SUPER RETRO WORLD**
（Copyright (C) Gif）素材包，授权见 `godot/Custom_Commercial_License.txt`。

该授权允许：用在游戏里、修改、随成品分发。
**但明确禁止**：

- 把素材作为独立文件或素材包再分发 / 分享 / 再授权
- 上传到其它市场、**repository** 或文件分享服务
- 以**可提取的独立形式**公开

git 仓库正属于 "repository"，原始 PNG 正属于 "extractable standalone form"，
所以**这些目录以及由它们派生的一切产物都不入库**：

| 路径 | 内容 | 是否入库 |
|---|---|---|
| `godot/Props/` `godot/Characters/` `godot/Tilesets/` | 原始素材包 | ❌ 已 gitignore |
| `godot/assets/props/src/*.png` | 生成管线复制出的原图 | ❌ 已 gitignore |
| `godot/assets/props/thumb/*.png` | 由原图派生的建造卡片缩略图 | ❌ 已 gitignore |
| `godot/assets/buildings/*.png` | 其余 25 座（自绘/CC0 拼装，**不含** prop） | ✅ |
| `godot/assets/thumbs/*.png` | 其余缩略图 + 笔刷卡（**不含** prop） | ✅ |

**本地要跑起来**：把该素材包解到 `godot/Props/`（保持 `Props/Houses/Sprites/house_NN.png` 的相对路径），
再执行 `npm run gen:art`。缺包时 gen-art 会跳过这 12 座并在控制台告警，其余建筑不受影响。

**授权信息本身**保留在 `godot/Custom_Commercial_License.txt`（保留许可文本是合规做法，不构成再分发）。

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
