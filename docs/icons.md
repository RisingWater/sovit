# UI 图标：风格、生成与后处理

> 2026-10 定。**图标不再一张张找素材，而是"提示词 + 批量出图 + 脚本抠图"一条流水线**。
> 风格基准是 **v7 那批物资图标**（`godot/assets/icons/`，45 张 64×64）。
>
> **2026-10 已跑完一整轮**：科技树 68 张（56 现有 + 12 商路）+ 面板/圆钮/顶栏 21 张，
> 共 **89 张**全部重绘；`verify.sh tech panel esc tradepanel questpanel` 全绿。
>
> **2026-10-21 补齐**：商路原本只有 12 张图、议价三档靠"复用 _1"顶（卡片上后两档是空白的）。
> 用户："用 comfyui 来生成缺失的图标，交易的艺术 / 砍价的技巧这几个图标都重新做" ——
> 清单里补上 `haggle_buy_2/3`、`haggle_sell_2/3`，六张各来一张，别名表删掉。
> 现在**科技树 72 张 = 科技 72 项，一项一张**（`check:routes` 逐张校验 64×64）。
>
> **2026-10-21（B4 邦交）又出了一批 31 张**：科技 4（`statecraft` 邦交 + `trade_goodwill_1..3` 好感加成）、
> 面板 2（`diplomacy` / `military`）+ 圆盘 2（烤出来的）、**势力徽记 13**、**关系牌 7**、**动作按钮 3**
> —— 后三样都在 `godot/assets/ui/faction/`。同一套提示词与后处理，只是多了三个类别
> （`faction` 48 / `relation` 32 / `action` 32，见 §1 与 §5.2）。
> 建筑贴图（使馆）走另一条流水线：`scripts/gen-building.py`，见 §10。
>
> 脚本：[`scripts/gen-icons.py`](../scripts/gen-icons.py) · 清单：[`scripts/icon-manifest.json`](../scripts/icon-manifest.json)

---

## 1. 覆盖范围

| 类别 | 目录 | 数量 | 原生尺寸 | 显示尺寸 |
|---|---|---:|---:|---|
| 科技树 | `godot/assets/ui/tech/` | **72**（= 科技数，一项一张） | **64×64** | 32（卡片） |
| 面板 / 圆钮 / 菜单 | `godot/assets/ui/panel/` | 21（圆钮 7 + 顶栏 7 + 菜单 8，有重叠） | **32×32** | 24（顶栏）· 16（行内按钮） |
| 左侧圆钮（**自带圆盘**） | `godot/assets/ui/nav/` | **7** + B4 的 2（外交 / 军事） | **48×48** | 48（圆钮 1:1） |
| **势力徽记**（`faction`） | `godot/assets/ui/faction/` | **13**（每个势力一枚） | **48×48** | 48（卡片）· 24（列表） |
| **关系牌**（`relation`） | 同上 | **7**（敌 / 冷 / 中 / 友 / 尊 / 盟 / 附庸） | **32×32** | 24 · 16 |
| **动作按钮**（`action`） | 同上 | **3**（送礼 / 结盟 / 进攻） | **32×32** | 16（`icon_left_button`） |

> **为什么面板图标不做 64**：它最大只显示到 32（`hud.gd::NAV_ICON`），64 只会白占空间；
> 科技树卡片显示 32、素材是 64 = 正好 2 倍整数缩放。这条规则写死在 `SIZE_BY_KIND` 里
> （`tech` 64 / `panel` 32 / `faction` 48 / `relation` 32 / `action` 32），要改就传 `--size`。

---

## 2. 风格基准（v7 物资图标）

对着 `godot/assets/icons/porcelain.png`、`wheat.png`、`iron.png` 能看出这四条：

1. **等距 3/4 视角**，单件物品，**主体占满画面**（上下左右各留 5% 左右）
2. **细描边**，颜色是**加深后的主体色**（深棕/深灰），不是纯黑粗框
3. **3–4 阶平涂 + 抖动高光**，有明暗面，但没有渐变、没有外发光
4. **低饱和自然色**，一件物品里通常 5–8 个色相；**透明底**

## 3. 提示词

提示词 = `prefix` + `Subject: <画什么>. ` + `suffix`，其中 `{BG}` 会被换成本组的幕布色。
三段都写在 `scripts/icon-manifest.json` 的 `style` 里，**改风格只改那份 JSON**。

**正式用 `v2`**：

```
Hand-painted pixel art item icon from a cosy medieval town simulation game,
64x64 sprite enlarged with nearest neighbour, soft dark-brown outline,
rich dithered shading with small specular highlights, slightly desaturated warm palette,
Subject: <画什么>.
No text, no frame, no border, no ground shadow, no glow, no vignette, no gradients,
no second object, no background texture, no watermark; crisp hard pixel edges without
anti-aliasing; isolated on a flat solid {BG} background; the single object is centred and
fills most of the frame.
```

另外两套留着做对比（`--variants 3` 一次出三套只看不落盘）：

| 变体 | 侧重点 | 结论 |
|---|---|---|
| `v1` | 16-bit、平涂、更"复古" | 细节偏碎，人形容易糊 |
| `v2` | 手绘 cozy、抖动高光 | **采用**：人形/器物都立得住 |
| `v3` | 等距俯视、更写实 | ❌ 会在物体下面**画一块底座/地砖**，抠图抠不掉 |

⚠️ `v3` 的失败值得记着：**只要提示词里出现"isometric ground/floor/tile"这类词，模型就会画底座**，
而底座是实色、抠不掉。所以 suffix 里明确写了 `no ground shadow, no second object`。

## 4. 幕布分组规则（重要）

| 图标里**有没有绿** | 用哪种幕布 | 理由 |
|---|---|---|
| 没有绿 | **亮绿**（`#00FF00`） | 绿幕和主体的色相天然分开 |
| 有绿（草药 / 作物 / 幼苗 / 甘蔗 …） | **亮品红**（`#FF00FF`） | 绿色主体放绿幕上会被抠掉 |

规则落实在 manifest 的 `"bg": "green" | "magenta"` 字段；`gen-icons.py` 按它选幕布色。

**抠图用的不是 RGB 距离，是色相偏向**：

```
绿幕分   = G − max(R, B)        → 越大越"幕布"
品红幕分 = min(R, B) − G         → 越大越"幕布"
alpha = clamp((hi − 分数) / (hi − lo))
```

**为什么不用 RGB 距离**（实测踩过）：模型把"纯绿幕"画成了**灰绿**（实测 `(136,200,116)`），
石头的 RGB 距离只有 33 —— 按距离切会把整块石头当背景抠掉。色相分对中性色恒等于 0，
所以不受幕布被画淡的影响。

**也刻意不做泛洪**（从四边灌水）：分组规则已经保证了"绿幕的图里没绿、品红幕的图里没品红"，
色相分离就够用；泛洪在 Python 里对 1024² 太慢，还容易把主体内部的同色块吃掉。

## 5. 生成与后处理

### 5.1 参数

| 项 | 值 | 说明 |
|---|---|---|
| 模型 | `z_image_turbo_bf16` + `qwen_3_4b`(lumina2) + `ae` | 见 `manifest.style.models` |
| 生成尺寸 | **768×768** | 1024 更清楚但慢一倍；64 输出 768 已经够（12 倍下采样） |
| 步数 / cfg / 采样器 | 8 / 1 / `res_multistep` + `simple` | Turbo 模型的设计点 |
| 批量 | **一个 prompt 里 8–10 个分支** | 一个图标一个分支（各自提示词与 seed），共用 UNET/CLIP/VAE |
| seed | `hash(id) % 1e6` | 同一个 id 每次同一张；manifest 里写 `"seed"` 可锁定 |

### 5.2 后处理（`gen-icons.py` 里做）

```
原图 768²  →  色相抠图（alpha）→  边缘去幕布色（despill）
           →  饱和 / 对比度微调（panel 才有）→  裁到内容 bbox
           →  摆成正方形（tech 留 5% 边 / panel 留 20% 边）→ LANCZOS 缩到 64 / 32
           →  alpha 硬化（>=110 记 255，否则 0，保像素硬边）
           →  panel 再加 1px 深色描边（见下）
           →  RGB 量化到 48 色（不抖动）→ 存 PNG（约 1–6 KB）
```

**每类图标的后处理参数不一样**，写在 `manifest.post` 里：

| 参数 | tech 64 | panel 32 | **faction 48** | **relation 32** | **action 32** | 为什么 |
|---|---:|---:|---:|---:|---:|---|
| `margin` | 0.05 | **0.20** | 0.08 | 0.12 | 0.14 | 圆钮只有 48px，内容做到 ~25px（=旧素材的观感），四周留白才不挤 |
| `contrast` | 1.00 | **1.12** | 1.06 | 1.12 | 1.10 | 米黄面板上不需要，压在木盘上需要 |
| `color` | 1.00 | **1.20** | 1.10 | 1.15 | 1.15 | 同上：木盘本身是暖棕，图标不提饱和就会糊成一片 |
| `rim` | 0 | **1** | 1 | 1 | 1 | **给剪影外面加 1px 深色描边** —— 不加的话棕色图标和木盘分不开 |

> 徽记 / 关系牌 / 动作按钮都是**小尺寸、贴着文字或按钮**，所以照 panel 那套（留白 + 提饱和 + 1px 描边），
> 只是留白小一点（徽记在 48px 里要尽量满）。

> ⚠️ **圆钮底下是一块木色圆盘，图标必须自带分离手段**（2026-10 用户："左侧圆形图标和背景区分不太开，
> 不好看，而且大小也太大了"）。办法就是上面这三条：留白 + 提饱和 / 对比 + 1px 深色描边。
> `rim` 是在**缩放之后**加的，所以它恒为 1px，不会随图放大。

### 5.3 左侧圆钮：圆盘直接烤进图标（`nav` 版）

**2026-10 用户**："圆框全是马赛克……这个效果很好啊，要不然就不要画的圆框，直接用这个带圆形背景的图标吧。"

| 项 | 以前 | 现在 |
|---|---|---|
| 圆盘从哪来 | `ui/nav_btn_*.png`（**16×16** 拉到 48 = 3 倍 Nearest，圆边全锯齿） | **烤进图标**：`assets/ui/nav/<id>.png`（48×48，抗锯齿） |
| 按钮自己的 StyleBox | `StyleBoxTexture` 三张（常态 / 悬停 / 按下） | **`StyleBoxEmpty`**（一点框都不画） |
| 悬停 / 按下 | 换贴图 | `modulate`：悬停 ×1.12、按下 ×0.84 |
| 图标显示尺寸 | 32（32 原生） | **48 = 1:1**（`hud.gd::NAV_ICON`） |

圆盘参数在 `manifest.navPlate`：

```json
"navPlate": { "size": 48, "ring": [104,74,46], "frame": [196,156,108],
              "fill": [216,188,142], "ring_px": 2, "frame_px": 2, "icon_px": 32 }
```

- 画法：**4 倍超采样**画三个同心圆（外圈深木 → 中圈木色 → 米色盘面），缩到 48 后边缘抗锯齿
- 图标按 **32px 原样居中贴上去**（不缩放 —— 像素画一缩放就糊）
- manifest 里给某个面板图标加 `"nav": true`，脚本就会顺手出一张 `nav/<id>.png`
- `ui/nav_btn_*.png` **保留但不再使用**（`node scripts/gen-art.ts nav` 仍能重画它，备查）

### 5.4 落盘之后

```sh
# 图标是美术资源，要让 Godot 生成 .import
Godot_v4.7.2-stable_win64_console.exe --headless --path godot --import
bash godot/verify.sh tech          # 科技卡片图标都载得进来
bash godot/verify.sh esc panel     # 面板 / 圆钮 / 顶栏都有图标
```

> 新图标必须有 `.png.import`，否则导出包里就是空的 —— 和别的贴图一样，`.import` **要入库**。

---

## 6. 脚本用法

```sh
python scripts/gen-icons.py --list                       # 看清单（id / 类别 / 幕布 / 画什么）
python scripts/gen-icons.py --only stonework --dry-run   # 只打印提示词，不出图
python scripts/gen-icons.py --only stonework,trade --variants 3   # 试 3 套风格，只出预览
python scripts/gen-icons.py --kind tech --batch 10       # 正式生成「科技树」这一类
python scripts/gen-icons.py --kind faction --batch 7      # 势力徽记（48×48）
python scripts/gen-icons.py --kind relation,action        # 关系牌 / 动作按钮（32×32）
python scripts/gen-icons.py --all --batch 10             # 全部（自动分批跑完）
python scripts/gen-icons.py --all --no-gen               # 不重新生成，只重跑抠图/缩放
python scripts/gen-icons.py --all --no-gen --sheet       # 顺便拼一张审阅图
```

- 预览图与审阅图都在 `%TEMP%\sovit_icons\`（`sheet.png` 是 1:1，`sheet_zoom.png` 是放大版）
- `--only` 里写错 id 会直接报错列出缺哪些，不会静默漏
- 生成完会检查**四角幕布分**；低于 25 说明模型没听"纯色背景"这句话，会打一行 `!!` 提示换 seed

## 7. 验收清单

1. 64×64 的科技图标在科技面板里**不糊、不溢出**（`verify.sh tech`）
2. 面板图标 32×32，圆钮里居中、顶栏 24px 下还认得出（`verify.sh panel`）
3. 没有绿边、没有白边、没有底座的残影（连底色是米黄的面板一起看）
4. 同一批图标放在一起**色调统一**（都偏低饱和暖色，没有一张特别艳）
5. 文件大小 2–6 KB；`.import` 都在

## 8. 已知坑

| 现象 | 原因 / 处理 |
|---|---|
| 整块主体被抠掉 | 用了 RGB 距离切图 → 改色相分（§4） |
| 物体下面有一块地砖/底座 | 提示词带了 isometric ground → 用 `v2`，别用 `v3` |
| 主体边缘一圈绿毛 | 忘了 despill，或 despill 把整张图都去了色（只该动 `alpha < 248` 的边） |
| 图标发灰发白 | 同上：despill 范围写错，把不透明像素也改了 |
| 幕布不是纯绿/纯品红 | 模型没听指令；幕布分量化检查会报 `!!`，换 seed 重跑 |
| 图标在 64px 下糊成一团 | 提示词里主体太碎（"三个工具的细节"）→ 一个图标一个**主**物件 |
| 圆钮里看不清 / 和木底糊在一起 | 缺 `panel` 那三件套：留白 20%、+20% 饱和、1px 深色描边（§5.2） |
| 金币图标认不出来 | 一枚大金币在 24px 下像个"皇冠圆片" → 用**三叠不同高度的金币**（`money` 已改） |

---

## 9. 文件名

图标文件名 = **id**，和内容里的 id 一一对应：

- 科技：`content/technologies.json` 的 `id`（`ui_kit.tech_icon()` 就按它找图）
- 面板：`hud.gd::NAV_ITEMS` / `STAT_ICONS` 里第三列那个 id（`stat_icon()` 按它找图）
- 势力 / 关系 / 动作：`assets/ui/faction/<id>.png`，id 就是 `content/factions.json` 的势力 id
  （`court` / `peak` …）、`rel_<档位>`、`gift` / `treaty` / `war`

**不要**用中文文件名（跨平台工具链最容易出编码问题，历史上踩过）。

---

## 10. 建筑贴图（另一条流水线）

建筑不是方形图标，尺寸按"格子"算（16px 一格、**最上一行不占地**），所以单独一个脚本：

```sh
python scripts/gen-building.py --list                     # 看清单
python scripts/gen-building.py --only embassy --candidates 4   # 出 4 个候选 + 审阅图
python scripts/gen-building.py --only embassy --pick 3          # 第 3 个落盘（可反复挑）
python scripts/gen-building.py --only embassy --pick 3 --no-gen # 只重跑抠图/缩放
```

- 清单：[`scripts/building-manifest.json`](../scripts/building-manifest.json)（画什么 + 生成尺寸 + 目标宽/最高）
- 风格基准是 `godot/assets/building_src/` 的 **v3 建筑包**：2× 密度像素、**粗深棕描边**、
  **正面平视 + 屋顶略俯视**（不是等距转角）、站在基线上、透明底、色调偏低饱和暖色
- 提示词里必须写 `straight-on front elevation` 与 `not an isometric corner view` ——
  少了这几句模型会画成 45° 转角的小楼，和 v3 那批明显不是一套（2026-10 实测）
- 生成尺寸用 **1536×960**（比图标大）：像素网格更细，缩到 128 宽之后才和 v3 的颗粒度接近
- 抠图 / despill / 硬边 / 48 色全部复用 `gen-icons.py`（`load_icons_module()` 直接当模块加载）
- 产物写到 `godot/assets/building_src/<id>.png`（**素材副本，入库**）；
  之后 `npm run gen:art` 会做成 `buildings/<id>.png` + `thumbs/<id>.png`，
  前提是 `content/buildings.json` 里有这座建筑（`art.arch: "sprite"`）
- 占地：`floor(宽/16) × (floor(高/16) − 1)`，写完用 `npm run check:footprint` 核一遍
