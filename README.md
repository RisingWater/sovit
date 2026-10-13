# sovit / The Village

一个**村庄模拟器**：种田、加工、开矿、建厂、盖房，让村民有活干、有饭吃、有房住。
调工资和价格、决定接不接收新村民，看着一个小村子慢慢长起来。

> **当前进度：v0.3 引擎 + 可玩的 Godot 实时游戏。**
> 居民按存款自动分为 穷 / 中产 / 富 / 老板；收入与技能挂钩；
> 住房分三级（茅屋 / 木屋 / 砖房）且与阶层对应；中产及以上才会买房；
> 奢侈品低弹性高定价。
> 完整的资源 / 产业链 / 阶层 / 住房 / 配置数值清单见 [`docs/content.md`](docs/content.md)。
>
> Godot 侧：**标题页 + 小地图 + 建造/派人 + 统计面板 + ESC 菜单 + 昼夜光影 + 音乐音效**，
> 16px 俯视像素美术。

---

## 快速开始

```bash
npm install

npm test            # 类型检查 + 内容自检 + golden + 无头验收（最新版 v0.3，100 天）
npm run sim         # 只跑无头验收（默认最新版 v0.3）
npm run golden      # 生成 Godot 对拍用的黄金轨迹 → godot/tests/golden/
npm run sync:content # 把 content/*.json 同步到 godot/content/
npm run api         # 启动 AI HTTP 接口（http://localhost:8787）
```

> 只测试**最新内容包**（当前 `v0.3`）。要跑其它包或时长：`npm run sim -- [天数] [种子] [内容包]`。

**跑游戏**：用 Godot **4.7.2** 打开 `godot/`，或命令行 `godot --path godot`。
门槛：`cd godot && bash verify.sh`（12 项，见下文）。

---

## 目录结构
```
content/                   # 内容数据（JSON 驱动，改这里 = 改游戏）
├─ goods.json              # 商品（资源 / 加工品 / 消费品 / 投资品）
├─ buildings.json          # 建筑（配方内嵌 + art 美术规格）
├─ classes.json            # 阶层与需求 + 阶层参数
├─ housing.json            # 住房
├─ packs.json              # 内容包（每局允许出现什么）+ 开局场景
└─ economy.json            # schemaVersion + time + 全局参数 / 默认值 / 机制常数
src/
├─ engine/                 # 纯函数引擎（不依赖 UI）
│  ├─ types.ts             # 全部类型（含 ResidentAccount / DayLedger）
│  ├─ config.ts            # 由 content/economy.json 驱动的参数
│  ├─ rng.ts               # 确定性随机（mulberry32）
│  ├─ state.ts             # createInitialState
│  ├─ util.ts              # 数值工具（r2 / round4）
│  ├─ content/             # 内容加载器 load.ts + 校验器 validate.ts + bundle.ts
│  ├─ systems/             # 生产 / 消费 / 人口 / 满意度 / 财政 / 投资 / 用工
│  ├─ tick.ts              # advanceHour / advanceDay 主入口（小时制）
│  ├─ actions.ts           # 动作应用
│  └─ observe.ts           # 观测 JSON
├─ ai/heuristic.ts         # 启发式基线 AI
└─ api/server.ts           # AI HTTP 接口
godot/                     # Godot 4.7.2 实时游戏（GDScript）
├─ scripts/core/           # ContentDB / Rng / SaveManager / SimUtil
├─ scripts/sim/            # SimCore（纯仿真，无 Node 依赖）+ 逐人账目/每日台账
├─ scripts/world/          # SimRunner / main / world_view / game_map / daylight
├─ scripts/ui/             # 见下方「UI 层」
├─ assets/                 # 像素美术 / 字体 / 音乐 / 音效（授权见 assets/CREDITS.md）
├─ content/                # 同步自 content/ 的副本
├─ tests/                  # gdUnit4（golden 回放 + 存档往返 + 逐人账目）+ golden/
├─ tools/                  # 11 个门槛脚本 + 截图工具
├─ verify.sh               # headless 门槛
└─ AGENTS.md
docs/spec.md               # 跨语言仿真契约（TS ↔ GDScript）
scripts/                   # check-content / golden / simulate / gen-art
```

引擎与表现分离：`advanceHour` 是不修改入参的纯函数，带种子随机，TS / GDScript 共用同一套逻辑并以 golden 轨迹对拍。

### UI 层（`godot/scripts/ui/`）

| 文件 | 作用 |
|---|---|
| `ui_kit.gd` | 静态工具：字体 / 9-slice 样式盒 / 按钮 / 卡片 / 颜色常量 |
| `hud.gd` | 顶栏（两行）：人口就业满意国库 + 资源条 + 快存快读统计菜单 |
| `minimap_widget.gd` | 左上角挂件：日期时间框 + 圆形小地图 + 村名红巾（可改名） |
| `build_bar.gd` | 底部建造栏：住宅/农场/食品加工/矿场/工业/娱乐/其它 + 笔刷尺寸 |
| `inspector.gd` | 右侧详情：选中建筑/居民，移民开关 |
| `panel_stats.gd` | 可拖动的统计面板：资源 / 人口 / 财务三 Tab |
| `chart.gd` | 折线图控件（自绘） |
| `game_stats.gd` | 统计采样（读 ledger 与 resident.account，不重算公式） |
| `esc_menu.gd` | ESC 菜单：新游戏 / 保存 / 读取 / 音效 / 音乐 / 设置资源 / 退出 |
| `new_game_dialog.gd` | 新游戏：村名（≤6 字）+ 难度（初始资源 ×0.5 / ×1 / ×2 / ×10 可选） |
| `title_screen.gd` | 标题页：只读展示村庄 + 缓慢环绕镜头 + 定期换村庄 |
| `music.gd` / `sfx.gd` | 背景音乐（两首轮流）/ 菜单音效（播放器池） |

---

## 引擎 API

```ts
import { createInitialState, advanceDay, observe } from './src/engine/index.ts'

let state = createInitialState({ pack: 'v0.3', seed: 12345 })

state = advanceDay(state, [
  { type: 'set_wage', shopId: 'coarse_bakery#1', value: 3 },
  { type: 'set_price', goodId: 'coarse_bread', value: 1.8 },
  { type: 'build_housing', goodId: 'hut' },   // 建房，提升人口上限
  { type: 'build', buildingId: 'brick_kiln' },// 建店，进入施工队列
  { type: 'end_turn' },                        // 含 end_turn 才会结算一天
]).state

console.log(observe(state))
```

### 动作

| 动作 | 说明 |
|---|---|
| `set_wage { shopId, value }` | 设定该店工资 |
| `set_workers { shopId, value }` | 设定目标用工数 |
| `set_price { goodId, value }` | 设定商品售价 |
| `expand { shopId }` | 扩产（+1 等级） |
| `toggle { shopId, active }` | 开 / 关 |
| `build { buildingId }` | 建店（进入施工队列） |
| `build_housing { goodId }` | 建造公房，提升人口上限 |
| `set_price { goodId, value }` | 设定商品售价；住房的 `goodId`（如 `hut`）即**卖给村民的价格** |
| `set_rent { value }` | 设定公房人均日租金 |
| `set_tax { value }` | 设为**单一扁平税率**（会覆盖整张税表） |
| `set_tax_bracket { index, upTo?, rate? }` | 编辑累进税**某档的阈值/税率**（last 档 `upTo:null`） |
| `set_population_cap { value }` | 设定人口上限：迁入到这个数就停（次日 06:00 生效） |
| `end_turn` | 结算一天 |

预留（返回 `not_implemented`）：`sell_shop`、`retake_shop`、`subsidy`。

### 逐人账目与每日台账

仿真层为每个人记录 `ResidentAccount`（当日工资/税/租金/消费/三项满足率/是否挨饿/逐商品购买量），
并每天产出一份 `DayLedger`（社会总流量 + 逐商品产量/工业消耗/居民购买）。

> 目前是**平均分配**，所以逐人数值 == 阶层数值 —— 但结构先分开，
> 将来做差异化分配（按收入 / 偏好 / 距离）时不必再动数据结构。

UI 的统计面板**直接读这两份记录**，不自己重算公式，因此不存在口径漂移。

---

## AI HTTP 接口

```
GET  /health                     健康检查
GET  /state                      当前观测（Observation）
POST /reset  { seed?, pack? }    重开局
POST /act    { actions: [...] }  应用动作；含 end_turn 则结算一天
```

示例：

```bash
curl http://localhost:8787/state

curl -X POST http://localhost:8787/act \
  -H "content-type: application/json" \
  -d '{"actions":[{"type":"build_housing","goodId":"hut"},{"type":"end_turn"}]}'
```

响应包含 `observation` / `applied`（每个动作是否成功）/ `log`（当日日志）。

---

## 内容包

| Pack | 内容 | 人口/阶层 |
|---|---|---|
| `v0.3`（默认） | 中产/富人消费链（白面包 / 糕点 / 成衣 / 服务 / 娱乐）+ 三级住房 | 四阶层财富分层，开局 12 人 / 无建筑 |
| `v1.0` | 全量商品 / 配方 / 建筑（多一座住房坊） | 四阶层，开局 16 人 + 自带粮食链与建筑工坊 |

全量内容以 JSON 存放在仓库根 `content/`，`ContentPack` 只决定「本局允许出现什么」。
内容与**全部可调参数**都是数据驱动：加商品 / 建筑 / 产业链 / 阶层，或调工资 / 税表 / 弹性 / 阈值 / 开局场景 = 改 `content/*.json`，无需改代码（见 [`content/README.md`](content/README.md)）。
`v0.1` / `v0.2` 两个早期内容包**已删除**；**日常只测试 `v0.3`**。
完整的资源 / 产业链 / 阶层 / 住房 / 配置数值清单见 [`docs/content.md`](docs/content.md)。

---

## 验收（`npm run sim`）

断言：

1. 人口不崩（≥ 开局 70%）
2. 满意度终值 ≥ 45
3. 政府余额不失控（含住房的 pack：**接受赤字，仅报告**）
4. 同种子结果完全可复现
5. 含住房的 pack：人口增长 ≥ 开局 1.3 倍

参考结果（v0.3，seed 12345，空开局）：100 天人口 **12 → 243**，峰值饥饿 1。

---

## 经济机制

- **每日循环**：期初库存 → 按需**公平生产**（不依赖建筑顺序）→ 发工资 → 收租 → 购买消费品 → 买房 → 结算满意度。完整顺序见 [`docs/content.md`](docs/content.md) 第十节。
- **封闭货币循环**：村里的钱只在「村财政 ↔ 村民」之间流动，外面的钱不进也不出。恒等式：**财政净收入 ≡ −村民净储蓄**。
- **所得税（累进，可运行时调整）**：税表 `government.taxBrackets` 由玩家编辑（`set_tax_bracket`）；对**工资**与**房东租金收入**同规则计征。默认 `[≤2:8%, 2–3.5:22%, >3.5:42%]`。
- **建造走实物材料**：建厂 / 盖房消耗木材 / 石块 / 粘土 / 砖，不依赖财政积累。
- **房租**：公房租金属村财政；私房租金由房客付给房主，其中按所得税扣税归财政。
- **买房**：只有 **中产及以上** 才会买；且只能买与本阶层对应的等级（中产→木屋，富/老板→砖房）。
- **财富分层**：村民按存款自动分为 穷 / 中产 / 富 / 老板（阈值见 `content/classes.json`）；收入与技能挂钩（`工资 × (0.5 + 技能/100)`），熟练者变富 → 升阶，形成流动。
- **住房三级 + 阶层对应**：茅屋(4人)/木屋(3人)/砖房(2人，富/老板独居)；住低于本阶层要求的房会扣满意度。
- **奢侈品**：衣物 / 日用 / 糕点属低弹性商品（`luxuryElasticity`），定价高也能卖动。
- **财政可能长期赤字**：私房租金流向房主，而房主只存不花，这部分钱退出流通，因此财政长期倾向赤字。目前按设计接受它，把"钱不够"当作张力来源。
- **人口增长**：住房有 + 粮食充足 + 满意度够 → 人就一直迁入，到**人口上限**为止（玩家可调）。迁入**不看岗位数**（岗位能后补，卡它会让村子永远长不大）；土地无上限。
- **劳动力分配**：食品产业链优先（从成品回溯上游），剩余劳动力按需求比例分给建材链。
- **收入**：在职工坊工资，或**上工地**的临时工日薪（`refWage × 0.8`）。
  失业保障金**已取消** —— 没有工程可做的人当天收入为 0。

---

## 时间与结算（小时制）

- **1 tick = 1 游戏小时**，`tickSec=5`（@1x → 2 分钟/天）；暂停 / 1x / 2x / 4x。
- **06:00 排产**（日界）：应用「次日生效」命令 → 启用昨日完工 → 用工 → 两阶段公平配给排产。
- **06:00–18:00**：每小执行今日计划 × 1/12（生产结算按小时）。
- **18:00 结算**：工资（日结）→ 收租 → 消费 → 买房 → 满意度 → 人口 → 移民 → 损耗 → 技能 → 施工进度。
- **18:00–06:00**：夜间，无生产。
- **所有命令次日 06:00 生效**（建筑、升级、建房、派人、停产、价格、税费一律延后）。
- 完整契约见 [`docs/spec.md`](docs/spec.md)。

---

## Godot 实时游戏

`godot/` 是一个 Godot **4.7.2** 工程（GDScript）。`scripts/sim/SimCore` 是 `docs/spec.md` 的忠实移植，
纯 `RefCounted`、无 Node 依赖，能在 headless 下运行。

### 玩法

- **标题页**：背景是只读展示的村庄（固定种子 + 缓慢环绕镜头 + 每 14 秒换一个村），
  左下三个选项（开始游戏 / 读取进度 / 退出游戏）。
- **新游戏**：设置村庄名（≤6 字）与难度（初始资源倍率），随机种子开局。
- **建造**：底部建造栏按类别分 Tab，选建筑后在地图上落位，次日 06:00 生效。
- **笔刷**：道路 / 地板 / **清除**（把路面地板抹回草地），笔刷尺寸可调。
- **查看**：点击建筑或居民看详情；统计面板有资源 / 人口 / 财务三 Tab 与折线图。
- **小地图**：左上角，跟随镜头位置与缩放；红巾显示村名，点击可改名。
- **存档**：顶栏「快存 / 快读」走默认存档位（也支持 F5 / F9）；ESC 菜单里是文件对话框，可选路径。
- **昼夜光影**：世界随时间调色（夜里偏蓝压暗、白天原色、日出黄昏偏金黄），UI 不受影响。

### 对拍与门槛

- **对拍**：`godot/tests/test_golden.gd` 回放 `scripts/golden.ts` 生成的轨迹，逐日比对 → 两套实现零漂移。
- **门槛**：`cd godot && bash verify.sh`，12 项全绿才算过：

| 项 | 检查什么 |
|---|---|
| `import` / `parse` | 资源导入、每个改动的 `.gd` 过 `--check-only` |
| `gdUnit4` | golden 回放 + 存档往返 + 逐人账目 |
| `smoke` / `move` | 基本可运行；移动建筑不崩、不泄漏标签 |
| `music` | 两首曲子存在、**单曲不循环**（否则切歌失效） |
| `sfx` | 音效池非空、按钮**真的**接上了回调 |
| `daylight` | 色调曲线连续、白天纯白、夜间压暗、24 点接回 0 点 |
| `bartab` | 建造栏每座建筑只出现在一个 Tab；单页不显示翻页；笔刷尺寸只在「其它」 |
| `panel` | 面板可拖动、不被内容撑宽、**无新数据时不重建**（否则按钮点不动） |
| `imm` | 移民按钮点完**显示立刻变化**（断言渲染文本，不是只看入队） |
| `minimap` | 圆环贴图已加载、尺寸是 64 的整数倍、跟随镜头与缩放、顶栏无日期时间 |
| `esc` | ESC 开关菜单、顶栏只留快存快读、保存/读取真的开 FileDialog |
| `newgame` | 村名上限一致、倍率精确成比例、新游戏后仓库精灵还在 |

- **数据源**是仓库根 `content/`；改完跑 `npm run sync:content` 同步到 `godot/content/`。

---

## 美术与音频素材

全部清单与授权见 [`godot/assets/CREDITS.md`](godot/assets/CREDITS.md)。

| 素材 | 来源 | 授权 |
|---|---|---|
| 地形 / 建筑 / 人物 | Kenney Tiny Town / Tiny Farm | CC0 |
| 界面框 / 圆环 / 红巾 | Kenney UI Pack - Pixel Adventure | CC0 |
| 光标 | Kenney Cursor Pixel Pack | CC0 |
| 字体 | Fusion Pixel Font | OFL-1.1 |
| 菜单音效 | Kenney UI SFX Set | CC0 |
| 背景音乐 | RPG Town Pack（Talon Trueblood） | 免费 + **需署名** |
| 12 张房屋贴图 + 标题 logo | SUPER RETRO WORLD / AI 生成 | ⚠️ **见下** |

> ⚠️ **仓库必须保持私有。** `godot/assets/props/` 的 12 张房屋来自 SUPER RETRO WORLD，
> 其授权**禁止**以可提取的独立形式再分发、**禁止上传到任何仓库**。
> 标题 logo 为 AI 生成（带 WORKBUDDY 水印），授权归属需自行确认。
> 音乐需在制作人员名单署名 `Music: Talon Trueblood`。
> 详见 [`CREDITS.md`](godot/assets/CREDITS.md)。

---

## 后续

- **标题页**：村庄规模比镜头可视范围大不少（铺到半径 75 格、可视约 33 格），可收紧半径让人更密
- **性能**：`_render_base_terrain()` 每格都跑，512×512 全量重画偏慢，可只重画可视区
- **重构**：`load_from` 与 `start_new_game` 的公共步骤抽成一个函数
  （历史上"新游戏少一步、读档有"已经踩过两次）；占地时清除装饰应收敛进 `map.occupy()`
- **科技树**：**已实装**（TS + Godot 双边）—— 商品与建筑逐项研究解锁，消耗**原材料 + 科研力**；
  科研力由新建筑**研究所**提供（可升级：每级 +3 工位、+30% 科研力），另有 2.0/天的基础科研力兜底。
  只有最初级食物链（+ 木材 + 茅屋）免费。共 29 项科技 / 5 个纪元 / 1,552 科研力。
  完整设计见 [docs/technology.md](docs/technology.md)
- **工具产业链**（同属上面那份设计）：工具坊用木材 + 石块造**石制工具**，
  工坊每工位日耗 0.05 工具，换来**产出 ×1.25、投入不变**（"虚空产量"，灵感来自
  《戴森球计划》增产剂）。一座满员工具坊供养约 40 个在岗工位
- **建造力系统**：**已实现**（两步都落地）—— 施工从「固定 2 天 + 建造力当库存」改成
  「失业人口 + 建筑工坊提供**每日产能** + 先进先出队列」，材料改为**开工时**扣，失业保障金取消。
  完整设计见 [docs/construction.md](docs/construction.md)，公式契约见 [docs/spec.md](docs/spec.md) §9
- **村庄规模上限**：目前土地无上限，村子可以一直铺开，缺一个"扩张成本 / 距离衰减"的约束
- **中后期缺少花钱的地方**：存款只会越攒越多，需要更多高阶层消费出口
- **库存上限 / 损耗**，抑制过量囤积
- **更多村庄内容**：季节、灾害、随机事件、村民个体差异（现在同阶层的人数值完全一样）
