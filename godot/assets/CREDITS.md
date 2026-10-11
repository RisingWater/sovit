# 第三方素材授权（godot/assets/）

本项目的美术素材来自以下开源资源。**除字体外全部为 CC0（公有领域），可商用、无需署名**
（署名是自愿的，这里列出以示尊重）。字体为 OFL-1.1，可自由嵌入与再分发。

| 目录 / 文件 | 来源 | 作者 | 授权 |
|---|---|---|---|
| `tiny/town.png` | [Tiny Town](https://kenney.nl/assets/tiny-town) | Kenney | **CC0 1.0** |
| `tiny/farm.png` | [Tiny Farm](https://kenney.nl/assets/tiny-farm) | Kenney | **CC0 1.0** |
| `ui/*.png` | [UI Pack - Pixel Adventure](https://kenney.nl/assets/ui-pack-pixel-adventure) | Kenney | **CC0 1.0** |
| `fonts/fusion-pixel-10px-zh_hans.ttf` | [缝合像素字体 Fusion Pixel Font](https://github.com/TakWolf/fusion-pixel-font) | TakWolf | **OFL-1.1** |
| `buildings/*.png` | 本项目由 `content/*.json` 的 `art` 字段生成 | — | 同项目授权 |
| `tiny/extra.png` | 本项目自绘（水面 / 道路 / 桥 auto-tile） | — | 同项目授权 |
| `actors/*.png` | 本项目自绘（居民 4 阶层 × 4 向 × 4 帧） | — | 同项目授权 |

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
