# 邦交（B4）设计 —— 势力 · 好感 · 使馆 · 外交面板

> **一句话**：13 个势力各挂一条 **-10000 ~ +10000** 的好感；**只有中立及以上才开得了商路**，
> 主动开战直接打到敌对（-6000）；修好**使馆**才出现「外交 / 军事」面板，**米拉**站台；
> 好感够 10000 再花 **2000 钱**才能**结盟**，打服的势力变**附庸**。
>
> 本文是**设计**（2026-10 用户口述，还没实现）：任务拆分与工期在 [`todo.md`](todo.md) §1.11，
> 任务清单在 §7，**要生成的美术素材在 §9**。存档版本 **v7**。
> 故事依据：[`story.md`](story.md) §二（五国）、§1.1（王室这一家）、§五（五年大纲）。

---

## 0. 一页结论

| 项 | 口径 |
|---|---|
| 势力 | **13 个**：王庭 1 + 六兄封地 6 + 四国 4 + 精灵 / 女巫 2 |
| 好感 | `-10000..10000`，七档：敌对 / 冷淡 / 中立 / 友善 / 尊重 / **同盟** / **附庸** |
| 涨 | 送钱（**1 钱 = 1 好感**，最少 100）、商路每跑完一趟 **+100 ×(1+科技加成)**（最高 +300）|
| 掉 | **主动进攻 = 直接 -6000（敌对）**；剧情翻转（沙海 / 圣辉 / 圣火城）也是直接到敌对 |
| 闸 | **商路要先有"中立及以上"**：敌对 / 冷淡 的城市「设为目的地」按钮灰掉 + tooltip 说原因 |
| 上限 | 每个势力一条**天花板**（`cap`）：铁峰与铁鸦堡开战时只有冷淡；**打赢就改写**（铁峰自动变尊重 / 铁鸦堡变附庸）|
| 同盟 | 好感 ≥ 10000 且该势力 `allyable` → 花 **2000 钱**结盟 |
| 附庸 | 打服的势力 `vassal: true`：好感回冷淡、**可通商**、可继续送钱刷到尊重 |
| 建筑 | 新建筑 **使馆**（`embassy`）→ 解锁「外交 / 军事」面板 |
| 面板 | `panel_war.gd`：第 1 页**世界地图**（复用王国地图那套换算）、第 2 页「军事」（B5）|
| 立绘 | 面板右下角 **米拉**（`milla`）|
| 存档 | `state.factions` → **v7** |

---

## 1. 好感（关系值）

### 1.1 七档（用户 2026-10 口述，边界照抄）

| 档 | id | 区间 | 说明 |
|---|---|---|---|
| **敌对** | `enemy` | `x ≤ -6000` | 主动宣战就落在这里；不能开商路；**只能送钱往回刷** |
| **冷淡** | `cold` | `-6000 < x ≤ -2000` | 能看见、不翻脸，但**开不了商路** |
| **中立** | `neutral` | `-2000 < x < 2000` | **商路的门槛**（这一档起才能设目的地）|
| **友善** | `friendly` | `2000 ≤ x < 6000` | 王都 / 铁王城 / 曙光城开局就在这 |
| **尊重** | `respect` | `6000 ≤ x < 10000` | 王都 / 铁王城 / 圣火城的天花板 |
| **同盟** | `ally` | `x ≥ 10000` **且已结盟** | 要花 2000 钱、要 `allyable` |
| **附庸** | `vassal` | —（不是数值档）| **打服的势力**，关系强制冷淡 + `vassal: true` |

> ⚠️ 边界归属：`-6000` 是**敌对**（用户："主动攻击…直接-6000" 必须算敌对），
> 所以「敌对 = ≤ -6000」「冷淡 = (-6000, -2000]」。同理 `2000` 算友善、`6000` 算尊重、`10000` 算同盟。

### 1.2 值域与初始

- 值域夹在 **[-10000, 10000]**（结盟就是满分 10000，附庸是状态位不是分数）
- 每个势力在 `content/factions.json` 里有 `initial`（开局好感）与 `cap`（天花板，见 §1.4）
- **王庭 / 六兄**开局都在善待你（兄弟之间还没翻脸）：王都 / 铁王城 / 曙光城 = **+3000（友善）**，
  铁鸦堡 = **-4000（冷淡）**（伯纳德只信刀剑），其余见 §2.1

### 1.3 怎么涨、怎么掉

| 动作 | 变化 | 谁能做 |
|---|---|---|
| **送礼 / 进贡** | `+钱数`（1 钱 = 1 好感），**最少 100**；钱从国库直接扣 | 任何关系（敌对也能送，"送钱求和"）|
| **商路跑完一趟** | `+100 × (1 + goodwill)` → 100 / 150 / 200 / 300 | 关系 ≥ 中立（vassal 也算）|
| **主动进攻** | **直接 = -6000**（不是减 6000，是打到敌对这条线上）| 任何关系（除自己）|
| **剧情翻转** | 直接 = -6000（`flip` 见 §2.1）| 由章节推进触发，玩家不可选 |
| **击败** | 每个势力自己一套 `defeat` 规则（§4.4）：默认 **冷淡（-4000）+ 附庸**；铁峰**直接 6000（尊重）**；沙海冷淡、不开附庸，之后能刷到尊重 | B5 打赢讨伐战 |

- 送礼**没有冷却、没有上限**（只受 `cap` 与国库限制）——它是唯一能逆转敌对的杠杆
- 送礼不改变 `ally` / `vassal` 状态位（结盟要单独点按钮，附庸只能靠打）

### 1.4 天花板（`cap`）—— "最好也只有冷淡"

`cap` 用**档位 id** 表示，加载时换算成数值上限（避免在 JSON 里写 -2001 这种魔数）：

| `cap` | 数值上限 | 效果 |
|---|---|---|
| `"cold"` | -2001 | **停在冷淡**（送多少钱都上不去）|
| `"friendly"` | 5999 | 最高友善 |
| `"respect"` | 9999 | 最高尊重（能到 9999，但点不了结盟）|
| `"ally"` | 10000 | 可同盟 |

- 送钱 / 商路加好感的**结果都要夹到 `min(cap, 10000)`**
- `cap` 可以**被打服改写**：`defeat.cap` 定义打赢之后的新天花板（见 §4.4）
- **铁峰公国**：开局 → 战争之前 `cap = "cold"`（送多少钱都只有冷淡），所以**那段时间铁峰城开不了商路**；
  **打赢铁峰之战后自动变成 6000（尊重）、`cap` 放到 `"respect"`**（用户 2026-10："后面会打起来，
  打赢了自动变成尊重"）→ 铁峰城从此能通商。不是永远死城，是**要打出来**。

---

## 2. 13 个势力

### 2.1 总表（`content/factions.json` 的落地数据）

| id | 名字 | 领主 | 城市 | 初始 | `cap` | `allyable` | `vassalable` | 剧情翻转 |
|---|---|---|---|---|---|---|---|---|
| `court` | 瓦尔登王庭（王都）| 国王 奥德里克三世 | `capital` | +3000 友善 | `respect` | ✗ | ✗ | — |
| `iron_crown` | 铁王城 | 阿尔伯特（长子）| `iron_crown` | +3000 友善 | `respect` | ✗ | ✗ | — |
| `iron_rook` | 铁鸦堡 | 伯纳德（次子）| `iron_rook` | -4000 冷淡 | `cold` | ✗ | **✓**（打服后）| 章 8–9 南下 → 被击败 → 附庸 |
| `holy_flame` | 圣火城 | 塞德里克（三子）| `holy_flame` | 0 中立 | `respect` | ✗ | ✓〔拟〕| 章 13 → **敌对** |
| `golden_ear` | 金穗城 | 狄奥多（四子）| `golden_ear` | 0 中立 | `ally` | ✓ | ✓ | 章 12 归顺〔见 story §五〕|
| `dawn` | 曙光城 | 伊莲娜（长女）| `dawn` | +3000 友善 | `ally` | ✓ | ✓ | 章 7 姐姐的信 |
| `blackstone` | 黑石堡 | 弗雷德里克（六子）| `blackstone` | 0 中立 | `ally` | ✓ | ✓ | 章 12 后逃跑〔story §五〕|
| `jade` | 翡翠王国 | 女王 艾瑟琳 | `jade` | 0 中立 | `ally` | ✓ | ✓ | 章 11 翡翠之盟 |
| `khan` | 沙海汗国 | 大汗 巴图尔 | `khan` | 0 中立 | `cold` | ✗ | ✗ | 章 6 → **敌对**；打服后 **冷淡→尊重** |
| `peak` | 铁峰公国 | 大公 赫尔曼 | `peak` | -4000 冷淡 | `cold` → 打服后 `respect` | ✗ | ✗（不是附庸）| **无翻转**；B5 打赢「铁峰之战」→ **自动 6000 尊重** |
| `holy_see` | 圣辉教国 | 教皇 格里高利 | `holy_see` | 0 中立 | `respect` | ✗ | ✓〔拟〕| 章 13 → **敌对**（圣战）|
| `silverleaf` | 银叶部落 | 艾隆 | — | 0 中立 | `ally` | ✓ | ✓ | 章 16 联军 |
| `ashen_circle` | 灰烬集会 | 莫甘娜 | — | 0 中立 | `ally` | ✓ | ✓ | 章 15 集会被围 |

**用户原话逐条对上**（2026-10）：

| 用户说的 | 上表 |
|---|---|
| "西边的铁峰公国，初始就是冷淡，最高也就冷淡" | `peak`：初始 -4000、`cap: cold` —— **但 B5 打赢铁峰之战后自动变 6000（尊重）**，见下一行 |
| "后面会打起来，打赢了自动变成尊重"（2026-10 追加）| `peak` 的 `defeat` 规则：`{ rep: 6000, cap: "respect", vassal: false }` —— 打完**不是**冷淡、也不是附庸，是**直接和好成尊重**，铁峰城从此能通商（§4.4）|
| "沙海汗国初始中立，后期如果剧情有进攻剧情会变成敌对，被我们击败后边为冷淡，可以刷到尊重" | `khan`：0 → flip 章 6 敌对 → 击败后关系回冷淡、`defeat: {rep: -4000, cap: "respect", vassal: false}`（**不是附庸**，是普通势力打服再刷）|
| "圣辉教国初始中立，后期剧情触发直接敌对" | `holy_see`：0 → flip 章 13 = -6000 |
| "翡翠王国初始中立，可以同盟/或者附庸" | `jade`：0、`ally`、`vassalable` |
| "王都初始友善，可以刷到尊重" | `court`：+3000、`cap: respect` |
| "铁王城初始友善，可以刷到尊重" | `iron_crown`：+3000、`cap: respect` |
| "曙光城初始友善，可以同盟或者附庸" | `dawn`：+3000、`ally`、`vassalable` |
| "铁鸦堡初始冷淡，最高冷淡，后期击败后可以附庸" | `iron_rook`：-4000、`cap: cold`、`vassalable`，`defeat: {rep: -4000, cap: "respect", vassal: true}` → **附庸** |
| "圣火城初始中立，可以刷到尊重，但是后期圣辉教国剧情触发直接敌对" | `holy_flame`：0、`cap: respect`、flip 章 13 |
| "剩下没有说的，初始都是中立，可以刷到同盟，也可以发动战争打到附庸" | `golden_ear` / `blackstone` / `silverleaf` / `ashen_circle`：0、`ally`、`vassalable` |

### 2.2 城市 → 势力（11 座商路城全有归属）

`content/routes.json` 的每座城加一个 `faction` 字段（唯一真源就是这个字段，别在代码里写映射表）：

| 城 | 势力 | 初识关系 | 能开商路？ |
|---|---|---|---|
| `capital` 王都 | `court` | 友善 | ✅ |
| `iron_crown` 铁王城 | `iron_crown` | 友善 | ✅ |
| `dawn` 曙光城 | `dawn` | 友善 | ✅ |
| `golden_ear` 金穗城 | `golden_ear` | 中立 | ✅ |
| `blackstone` 黑石堡 | `blackstone` | 中立 | ✅ |
| `holy_flame` 圣火城 | `holy_flame` | 中立 | ✅（章 13 后 ✗）|
| `jade` 翡翠城 | `jade` | 中立 | ✅ |
| `holy_see` 圣都 | `holy_see` | 中立 | ✅（章 13 后 ✗）|
| `khan` 汗庭 | `khan` | 中立 | ✅（章 6 后 ✗，打服后 ✅）|
| `iron_rook` 铁鸦堡 | `iron_rook` | **冷淡** | ❌（打服 → 附庸 → ✅）|
| `peak` 铁峰城 | `peak` | **冷淡** | ❌ 战争之前；**打赢铁峰之战（自动 6000 尊重）后 ✅** |

> 银叶部落 / 灰烬集会**没有城**（它们在林子里）—— 只出现在外交面板的列表里，
> 靠送礼 + 剧情涨好感，B5 之后可以结盟参战。

---

## 3. 商路与好感（和 B3 的咬合）

### 3.1 开商路的门槛：中立及以上

- 「设为目的地」按钮在**关系 < 中立**（敌对 / 冷淡）时 **`disabled = true`**，
  `tooltip_text` 写清原因（`%s 与我们的关系是「冷淡」，先送钱缓和`）——用户要求"按钮 disable，且 tip 提示"
- 判定写在引擎里（`route_ready` 旁边），不是面板自己判断：
  `faction_can_trade(city) -> {ok: bool, why: String}`
- **附庸**视为 ≥ 中立（`vassal: true` 直接放行）
- 已经在跑的商路，如果关系后来掉到冷淡/敌对（剧情翻转）→ **不强制停**：商队照跑，
  只是不能再**新设**目的地；面板在该城卡片上标一行「关系变差，下一趟可能被拒」（〔拟〕）
  —— 更狠的做法是"敌对国境封锁，商队折返"，但那会让玩家白丢一车队货，不做

### 3.2 每跑完一趟 +100

- 结算点：商队**到达**那天（`updateRoutes` 里已经算出 `routeExport` 的地方），
  按城市的 `faction` 加好感：`gain = tradeGain(100) × (1 + goodwill)`，再夹 `cap`
- 面板上写出来（商路页那张卡片）：`这趟回来，铁王城对你好感 +150`
- 只算**跑完**（到达并卖出/买进），空跑（缺货没出发）不加

### 3.3 贸易科技里的三级好感加成（用户："+50% +100% +200%"）

| 科技 | 名字 | 效果 `trade.goodwill` | 前置 | 花费（都在前置链内能产出）|
|---|---|---|---|---|
| `trade_goodwill_1` | 通使礼数 | **+0.5** | `trade_caravan_1` | wood 20 / pottery 20 |
| `trade_goodwill_2` | 邦交友道 | **+1.0**（累计 +150%）| `trade_goodwill_1` | pottery 25 / coarse_cloth 20 |
| `trade_goodwill_3` | 万国来朝 | **+2.0**（累计 +200% → 一趟 **+300**）| `trade_goodwill_2` | pottery 30 / coarse_cloth 30 |

- 聚合方式：**加法**（和 `haggleBuy` / `haggleSell` 一样），`tech_bonuses().trade.goodwill`
- 贸易页从 16 项变 **20 项**（+ 3 好感 + 1 邦交，见 §5）

---

## 4. 钱与政治

### 4.1 送礼 / 进贡

| 项 | 规则 |
|---|---|
| 按钮文案 | **王都**（`court`）且**父王还活着** → 「进贡」；其它 / 父王死后 → 「赠送礼物」 |
| "父王还活着" | `completed_chapter() < 6`（章 6「没有遗诏」= 父王暴毙那一章）——判定写在引擎里 `king_alive()` |
| 金额 | 一组固定档位按钮：`100 / 500 / 1000 / 5000`（最少 100，用户："最少 100"）|
| 换算 | `+钱数` 好感（1:1），夹 `cap`；国库不够就灰掉并提示还差多少 |
| 公告 | 进贡/送礼各一条 log（`kind: "diplomacy"`）|

### 4.2 结盟（`faction_ally`）

- 条件：`relation ≥ 10000` **且** `allyable` **且** 国库 ≥ **2000**
- 花 2000 钱，置 `ally: true`；面板上该势力变成「同盟」档并锁住送礼按钮（〔拟〕盟友也能继续送，不锁）
- 盟友出事后（剧情翻转）→ `ally` 自动清掉、关系 = -6000（圣辉/圣火例外，它们本来就不能结盟）

### 4.3 宣战（`faction_attack`）

- 任何势力都能点（除自己）；**点之前弹一次确认**（花多少钱、掉到敌对、有没有兵）
- 效果：关系 **直接 = -6000**（`attackHit`，JSON 可调），清掉 `ally`
- 出兵本身是 **B5 的出击流程**；B4 先跑通"关系立刻敌对 + 记一条 log + 面板变红"，
  战报/胜负/附庸判定等 B5 接上（B4 里 `faction_attack` 不结算战斗，只宣战）

### 4.4 击败（B5 落地）

每个势力一条 `defeat` 规则，**别在代码里分支**：

```jsonc
"defeat": { "rep": -4000, "cap": "respect", "vassal": true }   // 默认：打服 → 冷淡 + 附庸
```

| 势力 / 类别 | `defeat` | 结果 |
|---|---|---|
| **默认**（`vassalable: true` 的：金穗 / 曙光 / 黑石堡 / 翡翠 / 银叶 / 灰烬 / 圣火城 / 圣辉）| `{ rep: -4000, cap: "respect", vassal: true }` | 关系回**冷淡**、变**附庸**、天花板放到尊重 |
| **铁峰公国**（用户 2026-10："打赢了自动变成尊重"）| `{ rep: 6000, cap: "respect", vassal: false }` | **直接 = 6000 → 尊重**，不当附庸；铁峰城从此能通商（它的"和谈"就是这一仗）|
| **沙海汗国** | `{ rep: -4000, cap: "respect", vassal: false }` | 冷淡、不当附庸，之后靠送礼 / 商路刷到尊重 |
| **铁鸦堡** | `{ rep: -4000, cap: "respect", vassal: true }` | 冷淡 + 附庸（和默认一样，单独写只是为了让"这一仗"可查）|
| **王庭 / 铁王城** | 无（`vassalable: false`）| 剧情里不打；真要打也是 `-6000` 敌对，没有"击败"这一档 |

| 项 | 规则 |
|---|---|
| 触发 | B5 的讨伐战打赢（`battle_won` 事件）|
| 附庸能干嘛 | ①**能开商路**（视为中立）②每趟商路照旧 +100 ③送钱能刷到尊重 ④不能再宣战 |
| 面板 | 关系那一行后面挂「附庸」牌；送礼按钮改成「赐赠」〔拟〕|
| 铁峰那一仗排在哪 | 〔拟〕B5 的讨伐线里（章 10「扩军」之后），具体章号等你定 —— 打赢才算数 |

---

## 5. 建筑：使馆（`embassy`）

| 项 | 值 |
|---|---|
| id / 名字 | `embassy` / **使馆** |
| 建造栏 | **「市政」页**（和贸易市场 / 城镇中心同一页）|
| 尺寸 | 贴图 **127×78**（已出，见 §9.2），`art.foot = [7, 3]`（`floor(127/16)=7 × (floor(78/16)-1)=3`）|
| 门 | `art.doors = [[3, 2]]`（底边那一行的第 4 格）|
| 造价 / 建造力 | wood 20 / brick 15 / stone 10；`buildWork` 40（比市场重，比研究所轻）|
| 工人 | 2（`workers: 2, maxWorkers: 4`），**不产出任何商品**（纯功能建筑）|
| 科技锁 | 新科技 **`statecraft`「邦交」**（贸易页，前置 `trade` + `construction`）|
| 解锁 | 建成 → 「外交 / 军事」面板出现（左侧圆钮 + 快捷键 `D`）；只研究科技不建房子**不给面板**（和贸易市场同一套口径："先造出来再说"）|

---

## 6. 面板：外交 / 军事（`panel_war.gd`）

### 6.1 页签与入口

| 项 | 口径 |
|---|---|
| 名字 | 「外交 / 军事」（两个词，一页一个）|
| 页签 | **`世界`**（第 1 页，外交·米拉）· **`军事`**（第 2 页，加雷斯，**B5 才做**）|
| 入口 | 左侧圆钮第 **8** 个（`diplomacy` 图标）；需要**使馆建成**；快捷键 `D` |
| 版式 | 全屏米黄底、`anchor 0..1`、`offset_top = BAR_H`（和统计 / 科技 / 贸易同一套）|
| 立绘 | 右下角 **米拉**（`milla`），高度比照 `PanelPortrait` 默认 0.5（这一页右边是卡片，条件允许就用 0.5）|

### 6.2 第 1 页 · 世界地图（和贸易面板地图页同一套换算）

```
┌ 左：王国地图（`panel_map` 的底图 + 据点 + 地名，按比例缩小）        ┐ ┌ 右：势力卡片 ──────┐
│  · 13 个势力各自的**城**上画据点；没有城的（银叶/灰烬）画在林子位置  │ │ 铁峰公国            │
│  · 点城/据点 → 选中（金色描边），右侧换成那个势力的卡                │ │ 统治者 大公 赫尔曼   │
│  · 敌对势力的据点加一层**暗红蒙版**；同盟/附庸加金色小角标            │ │ 冷淡                │
│  · 复用 `map_rect()` / `icon_rect()` / `region_font()`（不另写一遍）│ │ [赠送礼物][+500]…    │
│                                                                     │ │ [结盟]（灰）         │
└─────────────────────────────────────────────────────────────────────┘ │ [派兵进攻]          │
                                                                        └────────────────────┘
```

- **关系只写档位名**（敌对 / 冷淡 / 中立 / 友善 / 尊重 / 同盟 / 附庸），**不显示数值**（用户要求）
- 数值只在 tooltip 里给（"距离下一档还差 1200"）〔拟〕
- 右侧卡片自下而上：势力名 + 统治者 → **关系牌** → 送礼那一排金额按钮（或者「进贡」）→
  「结盟」（好感不够灰掉，tip 写"要先到同盟"）→ 「派兵进攻」（红字，弹确认）
- 空地（没有城）的势力：在列表里也能选（面板底部一条横向列表：13 个徽记 + 关系牌）

### 6.3 关系牌与配色

| 档 | 颜色 | 徽记 |
|---|---|---|
| 敌对 | 暗红 `#8C2B20` | `rel_enemy.png` |
| 冷淡 | 灰蓝 `#4A5A6A` | `rel_cold.png` |
| 中立 | 米黄 `#8A7250` | `rel_neutral.png` |
| 友善 | 橄榄绿 `#4F7A3A` | `rel_friendly.png` |
| 尊重 | 金 `#B08A2E` | `rel_respect.png` |
| 同盟 | 亮金 + 描边 `#D8B44A` | `rel_ally.png` |
| 附庸 | 紫 `#6B4A78` | `rel_vassal.png` |

### 6.4 第 2 页 · 军事（B5）

只放一条占位说明 + 「等剿匪之后再来」（面板可以先把页签建起来，页内空着）；
真正的军事页（征召 / 出击 / 战报）在 B5 落。

---

## 7. 主线任务（第 3–5 章）

> 用户 2026-10 口述：「第 3 章游商相关，购买一次 / 出售一次；第 4 章修建市场，商路相关，
> 创建一条商路；第 5 章任务，修建使馆，给王都进贡一次（花钱增加好感）」。
> 台词风格照 `docs/quests.md`（发布人念 `brief`、引擎拼 `goal.text`）。

### 7.1 章 3 · 游商（两条，插在 `q05e` 之后、`q06_pop50` 之前）

| id | 标题 | 发布人 | 目标 | 用意 |
|---|---|---|---|---|
| `q05g_caravan_sell` | 头一笔买卖 | **薇拉** | 卖给游商 **1 次**（任意货、任意数量）| 教会"游商收你的余货"这件事 |
| `q05h_caravan_buy` | 他的货 | **薇拉** | 从游商手里买 **1 次** | 教会"他能带来你没有的东西" |

- `brief`〔拟〕：
  - 卖：「殿下，谷口来了个货郎，说我们的小麦和陶器他都收。……他付的是现钱。」
  - 买：「殿下，他车上有些东西我们烧不出来。贵是贵了点，可我们有他没有的。」
- 两条都 `requires` = `q05d_brick`（有个像样的产出再谈买卖），完成后才轮到 `q06_pop50`
- **新 goal 类型** `caravan_trade`：`{ type:"caravan_trade", side:"sell"|"buy", min: 1 }`
  - 判的是**次数**（成功成交一次算一次），累计在 `state.trade.soldTimes` / `boughtTimes`

### 7.2 章 4 · 市场与商路（两条）

| id | 标题 | 发布人 | 目标 | 用意 |
|---|---|---|---|---|
| `q10h_market` | 市场 | **薇拉** | 科技「通商」+ 贸易市场 ×1 | 商人得有地方站；面板从此常驻 |
| `q10i_route` | 走一趟 | **薇拉** | **创建 1 条商路**（研究「通商」+「常设商队」，选一座城设为目的地）| 车队的第一次 |

- `requires`：`q10h_market` ← `q09_pop100`；`q10i_route` ← `q10h_market`
- `brief`〔拟〕：
  - 市场：「殿下，货郎终究是路过的。我们要有自己的市场，让别人的车也往这儿赶。」
  - 商路：「车已经造好了，就差一个人说「往哪走」。殿下，您说往哪走？」
- **新 goal 类型** `route_created`：`{ type:"route_created", min: 1 }`
  - 判**累计创建过**几条（`state.routes.created`，单调递增）—— 取消了商路也不算白做

### 7.3 章 5 · 使馆与进贡（两条）

| id | 标题 | 发布人 | 目标 | 用意 |
|---|---|---|---|---|
| `q16_embassy` | 使馆 | **米拉** | 科技「邦交」+ 使馆 ×1 | 打开外交面板 |
| `q17_tribute` | 一次进贡 | **米拉** | 给**王都**进贡 **1 次**（送钱 ≥100）| 教会"钱能买好感"这条杠杆 |

- `requires`：`q16_embassy` ← `q14_domestic`（章 5 主线最后一条；**别挂支线 `q15`**）；`q17_tribute` ← `q16_embassy`
- 章 5 现在的主线是「分层与市场」（`q11`–`q15`），这两条接在**末尾**，章末对话仍是薇拉那段 —— 
  〔拟〕或者把章末改成米拉的一段（她第一次正式站到你这边）
- **新 goal 类型** `faction_gift`：`{ type:"faction_gift", to:"court", min: 1 }`
  - 判**送礼次数**（一次成交算一次），累计在 `state.factions[to].gifts`

### 7.4 三个新 goal 类型（两份引擎都要加）

| type | 判什么 | 数据来源 | 进度文案（引擎拼）|
|---|---|---|---|
| `caravan_trade` | 和游商成交的**次数** | `state.trade.soldTimes` / `boughtTimes` | `和游商做成 N 笔买卖` |
| `route_created` | **累计创建过**几条商路 | `state.routes.created` | `已经开通 N 条商路` |
| `faction_gift` | 对某势力**送礼/进贡**的次数 | `state.factions[id].gifts` | `已向王都进贡 N 次` |

→ 同时要进 `KNOWN_GOAL_TYPES`（引擎）、`scripts/check-quests.ts`、`godot/tools/ai_test.gd`（覆盖内容里全部 type）

### 7.5 ⚠️ 一个必须改的旧闸：游商什么时候来

现在（B3 落地版）游商是 **`completed_chapter() >= 3`** 才来（"完成第 3 章之后，游商会开始上门"）。
但用户的章 3 任务要在**章 3 期间**买卖 —— 所以两处要动：

| 位置 | 现在 | 改成 |
|---|---|---|
| `caravan_wave_size()` | 完成第 3 章 → 1 队；第 4 章 → 2；第 5 章 → 3 | **完成第 2 章 → 1 队**；第 3 章 → 2；第 4 章 → 3；第 5 章起 3（或 4）〔拟〕|
| 贸易面板入口 | 村里**有贸易市场**才有圆钮 | **有游商在城里 或 有贸易市场**都能开（地图/商路两页仍要市场）|

> 理由：章 3 时还没有市场（市场是章 4 的任务）。让游商在谷口摆摊、"市场"是后来才有的固定摊位，
> 故事上也更顺（`docs/quests.md` 章 3 的 `q05*` 全是"把手艺立起来"，货郎正好这时候来）。
> 代价：`merchant` 门槛里那几条"第 3 章 1 队 / 第 4 章 2 队"的断言要跟着改，面板的提示文案也要改。

---

## 8. 数据与实现

### 8.1 `content/factions.json`（新；`godot/content/` 由 `npm run sync:content` 复制）

```jsonc
{
  "schemaVersion": 1,
  "relation": {
    "min": -10000, "max": 10000,
    // 七档：每档给上界（不含），最后一档是 ally（要结盟才成立）
    "bands": [
      { "id": "enemy",    "nameZh": "敌对", "max": -6000 },
      { "id": "cold",     "nameZh": "冷淡", "max": -2000 },
      { "id": "neutral",  "nameZh": "中立", "max": 2000 },
      { "id": "friendly", "nameZh": "友善", "max": 6000 },
      { "id": "respect",  "nameZh": "尊重", "max": 10000 },
      { "id": "ally",     "nameZh": "同盟", "max": 10000 }
    ],
    "vassalNameZh": "附庸",
    "capByBand": { "cold": -2001, "friendly": 5999, "respect": 9999, "ally": 10000 },
    "giftStep": 100,            // 送钱最少 100，档位 100/500/1000/5000
    "giftRate": 1.0,            // 1 钱 = 1 好感
    "attackHit": -6000,         // 主动开战直接把关系打到这里
    "allyCost": 2000,           // 结盟的钱
    "tradeBand": "neutral",     // 这档起才能开商路
    "tradeGain": 100            // 每完成一趟 +100 × (1 + goodwill)
  },
  "factions": [
    {
      "id": "peak", "nameZh": "铁峰公国", "short": "铁峰",
      "lord": "大公 赫尔曼", "cityIds": ["peak"],
      "initial": -4000, "cap": "cold",
      "allyable": false, "vassalable": false,
      "flip": null,
      // 打赢之后：直接和好成尊重（用户 2026-10："打赢了自动变成尊重"）
      "defeat": { "rep": 6000, "cap": "respect", "vassal": false },
      "glyph": "peak"                 // 徽记图标 id（assets/ui/faction/<glyph>.png）
    }
    // 默认那套（打服 → 冷淡 + 附庸）： { "rep": -4000, "cap": "respect", "vassal": true }
    // …共 13 条
  ]
}
```

- `flip`：`{ "chapter": 6, "to": -6000, "reason": "山口来的马匪" }`（`chapter` = 章号，走 `completed_chapter()`）
- `defeat`：**打赢之后**怎么处理（`rep` / `cap` / `vassal` 三件事），每家都可覆盖，默认 `{ -4000, "respect", true }`
- `cityIds`：一座城只能属于一个势力（`check:factions` 守着）
- 加载校验（`validate.ts::parseFactions`）：13 条齐、档位上界单调递增、`cap` / `defeat.cap` 必须是
  `capByBand` 的键、`flip.chapter` ∈ 1..17、`defeat.rep` 在值域内、`cityIds` 不重复且都能在
  `routes.json` 里找到、`initial` 在值域内

### 8.2 状态（`state.factions`，存档 **v7**）

```ts
interface FactionState {
  rep: Record<factionId, number>;                 // 好感，夹 [min, cap]
  ally: Record<factionId, boolean>;
  vassal: Record<factionId, boolean>;
  gifts: Record<factionId, number>;               // 送过几次（任务 goal 用）
  flipped: Record<factionId, boolean>;            // 剧情翻转只做一次
}

state.factions = { rep, ally, vassal, gifts, flipped }
```

> 另外三处**很小的**状态新增（都在 B4 里）：
> `state.trade.soldTimes` / `boughtTimes`（游商成交次数，章 3 任务用）、
> `state.routes.created`（累计创建过几条商路，章 4 任务用）。
> 都是**单调递增的计数器**，只记事、不参与任何公式，不进 golden 摘要（和 `gifts` 同款）。

### 8.3 命令（4 条，都走 `IMMEDIATE_ACTIONS`）

| 命令 | 参数 | 效果 | 失败原因（面板照抄）|
|---|---|---|---|
| `faction_gift` | `factionId`, `amount` | 扣钱、加好感、`gifts++` | 钱不够 / 低于 100 / 已经到天花板 |
| `faction_ally` | `factionId` | 扣 2000、置 `ally` | 好感不到同盟 / 不可结盟 / 钱不够 |
| `faction_attack` | `factionId` | 关系 = -6000、清 `ally` | 已经附庸 / 已经敌对 |
| `route_assign`（已有）| … | 前面加一道**关系闸**（§3.1）| 关系不够（冷淡/敌对）|

### 8.4 黎明顺序里的插入点

```
applyActions → updateRoutes → activateCompleted → activateResearch → labor → tools
→ planProduction → planConstructionDay → planResearchDay → caravans → quests
→ **updateFactions**（新）
```

- `updateFactions` 做两件事：① 剧情翻转（`completed_chapter()` 到了就置敌对、清盟友）② 夹值域
- 放在 **quests 之后**：今天刚打完一章，翻脸当天生效（"章 13 刚过，传教士发出警告"）
- 商路加好感在 `updateRoutes` 里（它有城市的 `faction`），不在这里重复

### 8.5 引擎改动清单（TS + GDScript 双写）

| 位置 | 改什么 |
|---|---|
| `content/load.ts` / `index.ts` / `validate.ts` | 读 `factions.json`、`parseFactions`、`db.factions` |
| `content/routes.json` + 解析 | 每座城加 `faction`（校验：必须存在）|
| `src/engine/systems/factions.ts`（新）| `relationBand()`、`capOf()`、`canTrade()`、`gift()`、`ally()`、`attack()`、`updateFactions()`、`factionSnapshot()` |
| `systems/tech_bonus.ts` | `trade.goodwill`（加法）|
| `systems/routes.ts` | 商路到达时调用 `factions.gainTrade(id, goodwill)`；`assignRoute` 加关系闸 |
| `state.ts` / `tick.ts` | `state.factions` + 3 个计数器、4 条命令、`updateFactions` 插进黎明 |
| `godot/scripts/sim/sim_core.gd` | 全套镜像（`_factions_state()` 兜底同 `routes` 那套）|
| `godot/scripts/core/content_db.gd` | `factions` 读进来 |
| `godot/scripts/core/save_manager.gd` | `SAVE_VERSION = 7` + `_sanitize` 补 `factions` 段（**老档要能读**，照 `repair_routes` 的规矩）|
| `content/technologies.json` | `statecraft` + `trade_goodwill_1..3`；`statecraft.unlocks.buildings = ["embassy"]` |
| `content/buildings.json` | `embassy`（§5）|
| `content/quests.json` | 6 条新任务（§7）+ 3 个新 goal 类型 |

### 8.6 门槛

| 门槛 | 盯什么 |
|---|---|
| `check:factions`（新，TS）| 13 条齐、档位单调、`cap` 合法、`cityIds` 唯一且都在 `routes.json` 里、`flip.chapter` 合法、徽记图标存在且在 48×48 |
| `verify.sh factions`（新，GD）| 送礼 1:1 且最少 100、天花板夹住、商路门槛（冷淡开不了 / 附庸能开）、开战 = -6000、结盟要 2000 且要满分、剧情翻转只翻一次、老档补 `factions` 段不炸 |
| `verify.sh diplomacy`（新，GD）| 面板：只有使馆建成才有圆钮、两页签、世界地图 13 个势力点得到、关系只写档位名、送礼/结盟/进攻按钮的 disable 与 tooltip、米拉立绘、地图换算与贸易面板**逐点一致** |
| 回归 | `merchant`（游商章节闸前移）、`routes`（商路加好感 / 关系闸）、`quest`（3 个新 goal 类型）、`tech`（贸易页 20 项）、`golden`（重生成）|

---

## 9. 美术素材

> 用户 2026-10："除了拆分子任务，你还需要把要生成的美术素材整理出来。"
> **2026-10-21 已经全部出完**（除了 B5 的兵营）：31 张图标走 ComfyUI 流水线
> （[`icons.md`](icons.md)），使馆走建筑那条（`scripts/gen-building.py`），米拉立绘从
> `docs/art/npc/08_milla.png` 抠好导入。这一节留作**规格记录**，重出时照它来。

### 9.1 图标（31 张，✅ 已入库）

| 组 | 张数 | 文件 | 尺寸 | 画的是什么（实际用的提示词）|
|---|---:|---|---|---|
| **外交 / 军事 面板图标** | 2 | `assets/ui/panel/diplomacy.png`<br>`assets/ui/panel/military.png` | 32×32 | 握手 + 卷轴与火漆／交叉的两把铁剑压在木盾上（两张都烤了左侧圆盘）|
| **左侧圆盘** | 2 | `assets/ui/nav/diplomacy.png`<br>`assets/ui/nav/military.png` | 48×48 | 由上面两张**烤盘**（`manifest.navPlate`），不用单独画 |
| **势力纹章** | 13 | **设计稿** `docs/art/crests/<id>.png`（256×256，单色墨稿）→ 定稿后缩 48 到 `assets/ui/faction/<id>.png` | 48×48（稿 256）| **王冠 + 盾 + 月桂 + 绶带 + 一个大主纹**，单色深墨、主纹留白（照用户 2026-10-21 给的矢量纹章参考图）：鹰／钥匙／渡鸦／火焰／麦穗／朝阳／石塔／盘蛇／交叉弯刀／雪山／拉丁十字／叶子／圆环 |
| **关系牌** | 7 | `assets/ui/faction/rel_<id>.png`：`enemy` `cold` `neutral` `friendly` `respect` `ally` `vassal` | 32×32 | 交叉短刀／蓝色冰块／黄铜天平／**橄榄枝**（品红幕）／金色桂冠／双环相扣／铁链环 |
| **动作按钮** | 3 | `assets/ui/faction/gift.png`<br>`assets/ui/faction/treaty.png`<br>`assets/ui/faction/war.png` | 32×32 | 礼盒+红丝带／带火漆的卷轴／铁战锤 |
| **科技图标** | 4 | `assets/ui/tech/statecraft.png`<br>`assets/ui/tech/trade_goodwill_1.png`<br>`assets/ui/tech/trade_goodwill_2.png`<br>`assets/ui/tech/trade_goodwill_3.png` | 64×64 | 火漆卷轴+丝带+墨水瓶／漆盒礼包／双环压在账本上／王冠+异国贡品堆 |

> 动作按钮做成 **32×32**（不是 24）：`icon_left_button` 显示 16px，32→16 正好整除；
> 24→16 会出半像素、发糊。
>
> ⚠️ **徽记是纹章，不是图标**（2026-10-21 用户两次纠偏）：第一版按物品图标出（王冠压铁砧、黑鸦立断剑……）
> 全带明暗，看着像道具；第二版做成纯色小盾，用户又贴了矢量家族纹章参考图 —— 现在按参考图来：
> **王冠 + 盾 + 月桂 + 绶带 + 一个大主纹，单色深墨、主纹白镂空**。
> 走 `icon-manifest.json` 的 **`v6` 提示词** + 后处理 `ink_knockout()`（`post.crest.mono`，
> 白底不要幕布色），题面模板与 13 个主纹见 [`icons.md`](icons.md) §11。
> **设计稿在 `docs/art/crests/`（256px）**，定稿后再缩 48 覆盖 `assets/ui/faction/`。

### 9.2 建筑与立绘（各 1 张，✅ 已入库）

| 素材 | 文件 | 规格 | 备注 |
|---|---|---|---|
| **使馆** | `godot/assets/building_src/embassy.png`（**素材**）→ `godot/assets/buildings/embassy.png`（`npm run gen:art` 生成）| **127×78** 透明底，v3 建筑画风（正面平视 + 屋顶略俯视、2× 密度像素、粗深棕描边）| `art.foot = [7, 3]`（`floor(127/16)=7 × (floor(78/16)−1)=3`）、门 `[[3,2]]`；提示词与候选见 `scripts/building-manifest.json` |
| **米拉立绘** | `godot/assets/portraits/milla.png` | **640×896**（5:7）透明底 | 源图 `docs/art/npc/08_milla.png`（1024×1536，已带 alpha）→ 裁 `(110,140,910,1260)` → 缩 640×896，再压掉边缘残绿。和另外七张同尺寸同取景 |

> `assets/ui/thumbs/embassy.png` **不用单独出** —— `gen:art` 顺手做缩略图。
> 王国地图那张底图**不用重画**：外交面板直接复用 `assets/ui/map/kingdom_map_bare.webp`。
> ⚠️ 使馆贴图**已经出了，但还没进 `content/buildings.json`** —— 那一行随 B4-4 落地才写进去
> （现在写了会凭空多出一座能盖、什么都没用的建筑）。

### 9.3 图标流水线怎么加（照着抄）

```jsonc
// scripts/icon-manifest.json 里各加一条；`bg` 按"带不带绿"分：主体里有绿 → magenta，其余 green
{ "id": "diplomacy", "kind": "panel", "bg": "green",
  "subject": "two clasped hands … above a rolled parchment scroll with a red wax seal", "nav": true },
{ "id": "court", "kind": "faction", "bg": "green",
  "subject": "a golden crown resting on a black iron anvil, heraldic emblem" }
```

- `kind` 新增三个：`"faction"`（48×48）、`"relation"`（32×32）、`"action"`（32×32），
  都写进 `godot/assets/ui/faction/`；尺寸表在 `gen-icons.py::SIZE_BY_KIND`
- `nav`（圆盘）只给 `diplomacy` / `military` 两张开；`post.navPlate` 参数照现有 7 张
- 关系牌 / 动作按钮是**小符号**，`post` 用 panel 那套（留白 + 提饱和 + 1px 描边），
  否则 32px 下糊成一团（面板图标踩过这个坑）
- ⚠️ **有绿就得换品红幕**：`jade`（绿宝石）和 `rel_friendly`（橄榄枝）第一版用绿幕，
  主体被整块抠掉了 —— 绿幕的图里不能有绿（§4 那条规则）

### 9.4 建筑怎么做（`gen-building.py`）

```sh
python scripts/gen-building.py --only embassy --candidates 4   # 出 4 个候选
python scripts/gen-building.py --only embassy --pick 3         # 挑一个落盘
```

- 清单 `scripts/building-manifest.json`：提示词 + 生成尺寸（**1536×960**，比图标大一号 → 像素更细）
- 提示词必须带 `straight-on front elevation` + `not an isometric corner view`：
  少了会画成 45° 转角小楼，和 v3 那批明显不是一套
- 落盘只写到 `building_src/`；`buildings/` 与 `thumbs/` 由 `npm run gen:art` 生成（需要 content 里有这座建筑）
- 生成完照旧跑 `python scripts/gen-icons.py --only <id>` → `--sheet` 看审阅图 → 入库

---

## 10. 明确不做

- 好感的**数值**不上面板（用户要求只写档位名），只在 tooltip 里给
- 不做"每回合自然衰减 / 回升"（好感只由送礼、商路、剧情、战争改变）
- 不做势力之间的**互相**关系（只有"我们 ↔ 他们"）
- 不做人质 / 联姻 / 间谍（story.md 提到人质，本版不做）
- 外交面板不做"势力列表的排序与筛选"（13 个一格排下来就够）
- 出征的**战场**不做（只有 B5 那一页战报）

---

## 11. 验收清单（手测，B4 做完时逐条过）

1. 研究「邦交」→ 建造栏「市政」页出现使馆；建成前没有外交圆钮，建成后出现且点得开
2. 面板两页：「世界」「军事」；世界页就是王国地图缩略，13 个势力点得到，关系只写档位名
3. 铁峰城 / 铁鸦堡的「设为目的地」是**灰的**，tip 说清"关系冷淡"；其余 9 城能设
4. 送 100 钱 → 好感 +100、国库 -100；送 99 钱 → 拒绝并说明"最少 100"
5. 一路送到天花板（铁峰，战争之前）→ 停在冷淡，再送提示"已经到顶"；
   **打赢铁峰之战后它自动 = 6000「尊重」、铁峰城的按钮亮起来**（`defeat: {rep:6000, cap:"respect"}`）
6. 商路跑完一趟 → 该国好感 +100（研究「万国来朝」后 +300），面板与 log 都对得上
7. 派兵进攻 → 弹确认 → 关系立刻敌对（-6000）、面板变红、log 一条
8. 敌对国送钱到 0 以上 → 变中立，商路按钮**亮起来**
9. 好感 10000 且 `allyable` → 「结盟」亮起，花 2000 → 变「同盟」；不够时是灰的且 tip 说差多少
10. 章 3：和游商买一次、卖一次 → 两条任务各自变绿
11. 章 4：建市场、开一条商路 → 两条任务变绿
12. 章 5：建使馆、给王都进贡一次（按钮写「进贡」）→ 两条任务变绿；父王死后同按钮变「赠送礼物」
13. 存档 → 读档：好感 / 同盟 / 附庸 / 计数都还在；v6 老档读进来不崩
