# Sovit v0.1 实施计划（引擎 + AI 接口）

> 目标：先交付**数据驱动引擎（纯函数）+ AI HTTP 接口**，不做 UI。
> 引擎面向完整 v1.0 内容，默认跑 v0.1 内容包；UI（等距地图、React）留到后续里程碑。

---

## 0. 交付边界

| 本次做 | 本次不做（预留到 UI 里程碑） |
|---|---|
| 纯函数引擎（生产 / 消费 / 人口 / 阶层 / 财政） | React / 等距地图 / 图表 / 建筑卡片 |
| 全 v1.0 内容表 + v0.1 默认 pack | 买房 / 竞争 / 老板经营（仅留接口签名） |
| HTTP 服务 + 启发式基线 AI + 100 天验收 | 真实 LLM 玩家、存档 UI、Canvas |

**技术栈（本次）**：纯 TypeScript + Node 24，npm 管理，`tsx` 运行。
**后续 UI**：React + TypeScript + Vite + Zustand + Tailwind + Recharts，地图用 CSS 伪等距。

---

## 1. 目录结构

```
sovit/
├─ package.json / tsconfig.json
├─ docs/plan_v0.1.md
├─ src/engine/
│  ├─ types.ts
│  ├─ content/
│  │  ├─ goods.ts        # 全 v1.0 商品表（tier 0-3）
│  │  ├─ recipes.ts      # 全 v1.0 配方表
│  │  ├─ buildings.ts    # 全建筑表（含工人数）
│  │  ├─ classes.ts      # 穷人 / 中产 / 富人 / 老板 需求表
│  │  ├─ housing.ts      # 茅屋 / 木屋 / 砖房
│  │  ├─ content.v01.ts  # v0.1 子集
│  │  └─ index.ts        # ContentPack 选择器
│  ├─ systems/
│  │  ├─ production.ts   # 配方生产、缺料封顶、燃料消耗、熟练度
│  │  ├─ labor.ts        # 岗位分配、熟练度积累
│  │  ├─ market.ts       # 价格、需求价格弹性
│  │  ├─ consumption.ts  # 各阶层按需求 / 购买力消费
│  │  ├─ population.ts   # 饥饿、迁徙、阶层流动
│  │  ├─ satisfaction.ts # 满意度平滑
│  │  ├─ finance.ts      # 工资 / 销售回流 / 税 / 补贴 / 政府余额
│  │  └─ investment.ts   # 建造力、扩产、建店、住房
│  ├─ tick.ts            # advanceDay(state, actions) 纯函数
│  ├─ actions.ts         # 动作 schema（含预留签名）
│  ├─ observe.ts         # 观测 JSON
│  ├─ rng.ts             # 确定性种子随机
│  ├─ state.ts           # createInitialState(pack)
│  └─ index.ts
├─ src/ai/heuristic.ts   # 启发式基线 AI
├─ src/api/server.ts     # GET /state · POST /act · POST /reset
└─ scripts/simulate.ts   # 100 天无头测试 + 断言
```

**核心不变量**：`advanceDay(state, actions) => { state, log }` 为纯函数、带种子随机 → UI / AI / 测试共用同一套引擎。

---

## 2. 内容表（全 v1.0 编码，v0.1 只启用子集）

### 2.1 商品 `GoodDef`
`id, nameZh, tier, category, storable, baseValue, perishRate?`

- `tier`：0 自然资源 / 1 加工品 / 2 消费品 / 3 投资品
- `category`：food / clothing / household / fuel / material / housing / investment / raw

**tier 0 自然**：小麦、蔬菜、亚麻、棉花、木材、石块、粘土、肉类、鱼类、兽皮、甘蔗、染料
**tier 1 加工**：粗面粉、精面粉、糖、粗织物、细织物、木柴、砖、陶器
**tier 2 消费**：粗面包、白面包、糕点、粗布衣、常服、华服、皮衣、熏鱼、肉干
**tier 3 投资**：建造力、茅屋、木屋、砖房

### 2.2 配方 `RecipeDef`
`building, inputs{}, output{}, baseRate, requiresFuel?`

按 v1.0 产业链一比一录入，含多输入配方：
- `粘土 + 木柴 → 砖`
- `精面粉 + 糖 → 糕点`
- `细织物 + 染料 → 华服`
- `鱼类 + 木柴 → 熏鱼`、`肉类 + 木柴 → 肉干`

### 2.3 建筑 `BuildingDef`
`id, nameZh, tier(1/2/3), workers, recipe`

工人数严格按表：
- 一级：小麦农场 6、蔬菜农场 4、亚麻农场 4、棉花农场 4、甘蔗园 4、染料园 3、伐木场 3、采石场 3、粘土坑 3、狩猎营地 3、渔场 4
- 二级：粗面粉磨坊 2、精面粉磨坊 3、粗面包房 2、白面包房 3、糕点房 4、糖坊 2、粗织坊 3、细织坊 4、粗布衣坊 3、常服坊 3、华服坊 4、皮衣坊 3、木柴坊 2、砖窑 2、陶器坊 3、熏鱼坊 3、肉干坊 3
- 三级：建筑工坊 3、住房坊 4

### 2.4 阶层 `ClassDef`
`id, needs[{good, perCapita}], incomeBase`

| 阶层 | 需求 |
|---|---|
| 穷人 poor | 粗面包、蔬菜 |
| 中产 middle | 白面包、肉 / 鱼 / 熏鱼 / 肉干、粗布衣、陶器 |
| 富人 rich | 糕点、常服、华服、皮衣、砖房 |
| 老板 boss | 高级商品 + 再投资（本次仅预留） |

### 2.5 住房 `HousingDef`
`id, quality, capacity, goods`：茅屋（穷人）/ 木屋（中产）/ 砖房（富人）

### 2.6 v0.1 默认 pack
- 商品：小麦 / 面粉 / 面包 / 蔬菜
- 建筑：小麦农场 → 磨坊 → 面包房 + 蔬菜农场
- 阶层：启用穷人（+ 少量中产）
- 其余全量数据放 `v1.0` pack，只做冒烟测试

---

## 3. 数据模型（关键结构）

```ts
interface GameState {
  seed: number; rngState: number; day: number; pack: 'v0.1' | 'v1.0'
  government: { money: number; taxRate: number }
  goods: Record<GoodID, number>          // 中央仓库库存
  prices: Record<GoodID, number>         // 售价（玩家 / AI 设定）
  shops: Shop[]
  residents: Resident[]
  construction: Construction[]
  history: DaySnapshot[]; log: LogEntry[]; alerts: Alert[]
}

interface Shop {
  id: string; defId: BuildingID; owner: 'state'   // 预留 PlayerID
  targetWorkers: number; wage: number; level: number; active: boolean
  profit: number                                  // 昨日利润（展示用）
}

interface Resident {
  id: string; classId: ClassID
  savings: number; satisfaction: number; skill: number
  jobShopId?: string
}
```

---

## 4. 每日结算顺序 `advanceDay`

1. **用工**：按 `targetWorkers` 自动分配居民到岗位，其余失业；岗位熟练度 = 平均 `skill`
2. **生产**：`产出 = baseRate × (工人/满员) × (0.6 + 0.4·熟练度/100) × level`；缺原料 / 缺燃料 → 按最短板封顶并写日志
3. **发工资**：`政府余额 −= Σ(工人×工资)`；`居民储蓄 += 工资`
4. **消费**：各阶层按 `needs × 人口 × 价格弹性` 产生需求；购买力来自储蓄；`sold = min(需求, 库存)`；`政府余额 += 售价×销量`，`居民储蓄 −= 支出`；买不起 / 缺货 → 记未满足
5. **吃饭 / 饥饿**：按阶层需求满足率算 `fedRatio` 与饥饿人数
6. **满意度**：`target = 40·食物满足 + 30·工资水平 + 30·(1 − 价格压力)`，`sat += (target − sat)·0.2`
7. **人口**：`avgSat>65 且无饥饿 → 迁入（约 pop·2%）`；`avgSat<40 或饥饿 → 迁出 / 死亡`；阶层流动（存款 / 满意度上升 → 升阶）
8. **投资**：建造力消耗、扩产 / 建店排队完工（v0.1 简化为 1 天）
9. **税 / 补贴**：v0.1 `taxRate = 0`，逻辑预留
10. **写 history / log / alerts**；更新 `rngState`

**核心张力**：工资高 → 满意度高但余额掉；价格高 → 余额稳但满意度掉；余额 < 0 → 破产警报 → 满意度惩罚。

---

## 5. AI 接口

### `GET /state`（观测，精简）
```json
{ "day":12, "government":{"money":320},
  "population":{"total":52,"byClass":{"poor":44,"middle":8},"hungry":3,"avgSatisfaction":68},
  "shops":[{"id":"wheat1","type":"wheat_farm","workers":6,"wage":3,"profit":5,"status":"green"}],
  "market":{"prices":{"bread":2,"vegetable":1},"inventory":{"wheat":24,"flour":0,"bread":16,"vegetable":8}},
  "alerts":[{"type":"hunger","count":3}],
  "history":[{"day":11,"population":50,"satisfaction":70,"money":310}] }
```

### `POST /act`（数组，`end_turn` 触发一天）
```json
[{"type":"set_wage","shopId":"wheat1","value":4},
 {"type":"set_price","goodId":"bread","value":2},
 {"type":"expand","shopId":"bakery1"},
 {"type":"toggle","shopId":"mill1","active":false},
 {"type":"end_turn"}]
```
预留签名（v0.1 返回 `not_implemented`）：`build`、`sell_shop`、`retake_shop`、`set_tax`、`subsidy`。

### `POST /reset`
`{seed?, pack?}` → 新状态（保证可复现）。

**实现**：`src/api/server.ts` 用 Node 原生 `http`，无框架依赖，`npm run api` 启动。

### 启发式基线 AI（`src/ai/heuristic.ts`）
- 保证岗位充足、工资贴近参考值
- 缺粮 → 降价或扩产面包房
- 库存积压 → 降产
- 余额告急 → 提价 / 微降工资
- 资金健康 → 扩产瓶颈环节

---

## 6. 100 天验收（`scripts/simulate.ts`）

用基线 AI 跑 100 天，断言：
1. 人口不崩（`[start×0.7, start×1.5]` 带内）
2. 满意度终值 ≥ 45，且不连续长期为 0
3. 政府余额不跌破阈值（如 −1000）
4. 同种子结果完全可复现（快照哈希一致）

输出人口 / 满意度 / 余额三条曲线 + 每日收支明细。

---

## 7. 实现顺序与里程碑

| 里程碑 | 内容 | 校验 |
|---|---|---|
| M1 | 脚手架 + `types.ts` + 全 v1.0 内容表 | 内容表类型检查通过 |
| M2 | 引擎系统 + v0.1 pack + `createInitialState` | 单日结算跑通 |
| M3 | `scripts/simulate.ts` 跑 100 天 + 调参 | 验收 1 / 2 / 3 通过 |
| M4 | `observe/actions` + HTTP 服务 + 启发式 AI | AI 经 HTTP 玩 100 天通过 |

---

## 8. 本次明确不做

- React / UI / 地图 / 图表 / 建筑卡片
- 买房 / 竞争 / 老板经营（仅预留接口签名）
- 真实 LLM 接入
- Canvas
- 存档 UI

---

## 9. v1.0 完整产业链（参考，供内容表录入）

- **链1 面包**：小麦 →（粗面粉磨坊）粗面粉 →（粗面包房）粗面包；小麦 →（精面粉磨坊）精面粉 →（白面包房）白面包；精面粉 + 糖 →（糕点房）糕点；甘蔗 →（糖坊）糖
- **链2 蔬菜**：蔬菜农场 → 蔬菜 → 居民
- **链3 肉鱼**：狩猎营地 → 肉类 / 兽皮；渔场 → 鱼类；（熏鱼坊 / 肉干坊）可储存
- **链4 纺织**：亚麻 → 粗织物 / 细织物；棉花 → 细织物；细织物 + 染料 → 华服
- **链5 建材**：伐木场 → 木材；采石场 → 石块；粘土坑 → 粘土；（砖窑）粘土 + 木柴 → 砖；（建筑工坊）→ 建造力；（住房坊）→ 茅屋 / 木屋 / 砖房
- **链6 燃料**：木材 →（木柴坊）木柴 → 面包房 / 砖窑 / 熏鱼坊 / 肉干坊 / 陶器坊
- **链7 建筑**：建筑工坊（木材 + 石块 + 砖 → 建造力）、住房坊（木材 / 砖 / 石块 → 住房）

**经济循环**：自然资源 → 加工品 → 消费品 → 居民；投资品 → 扩产 → 产能；住房 → 卖给居民 → 回收存款；剩余价值 → 老板消费；政府税收 → 补贴 / 建设 → 回到起点。
