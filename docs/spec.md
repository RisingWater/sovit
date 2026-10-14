# Sovit 仿真规格（跨语言契约）

> 这份文档是 **TS 引擎与 Godot(GDScript) 移植之间的唯一契约**。
> 任何一处公式/顺序/常量不一致都会导致 golden 轨迹漂移。改引擎必须同步改这里。
> 所有可调数值都在 `content/*.json`，公式里的常量名对应 `content/economy.json`。

---

## 0. 时间模型

- 1 tick = 1 游戏小时；`hoursPerDay`（默认 24）。
- `tickSec`：1 游戏小时 = 多少真实秒（@1x，默认 5 → 2 分钟/天）。
- 每小时的阶段（`tick.ts` → `stepHour`）：
  - `h == dawnHour(6)`：**黎明** `runDawn`
  - `workStart(6) <= h < workEnd(18)`：**生产** `runProductionStep(f)` → **施工** `applyConstructionHours(f)`，
    `f = 1/(workEnd-workStart)`
  - `h == settleHour(18)`：**夜晚** `runNight`
  - 推进：`hour = (hour+1) % hoursPerDay`
- `state.day` 在**黎明** +1。

## 1. 命令队列（次日生效）

- 所有命令（玩家/AI）追加到 `state.pending`。
- **黎明**统一执行 `applyActions(state, pending)` 后清空。因此：
  - 06:00 前下的命令当天 06:00 生效；
  - 06:00 后下的命令等次日 06:00。
- 命令语义见 `actions.ts`；`end_turn` 为空操作。

## 2. 生产（日计划 + 小时执行）

### 2.1 黎明排产 `planProduction`（两阶段公平分配）

对每个 `active` 且到岗人数 `w>0` 的建筑：

```
staffing = w / def.workers
skillEff = skillEffectBase + skillEffectSlope * (shop.skill / 100)     // 0.6 + 0.4*skill/100
desired  = recipe.baseRate * staffing * skillEff * shop.level
inputPer = recipe.inputs（每批次），另加 firewood: recipe.fuel
```

汇总总需求 `demand[g] += inputPer[g] * desired`；再对每种投入算统一系数：

```
factor[g] = min(1, goods[g] / demand[g])
planned   = desired * min_{g∈该建筑用到的投入} factor[g]      // 与建筑顺序无关
shop.planned = planned
shop.profit  = Σ_output(q*planned*baseValue) − Σ_input(q*planned*baseValue) − w*shop.wage
```

### 2.2 白天执行 `runProductionStep(fraction)`

`fraction = 1/(workEnd−workStart)`（默认 1/12）。对每个 `active && planned>0` 的建筑：

```
batches = shop.planned * fraction
goods[g] -= inputPer[g] * batches      // 含 firewood
goods[g] += output[g]  * batches * shop.toolBoost * (1 + techBonuses[def.sector])
```

**不取整**（浮点，避免 12 次累积误差）。

### 2.3 损耗 `applySpoilage`（夜晚，每天一次）

`goods[g] *= (1 − perishRate)`（非耐储商品）。

### 2.4 仓储上限 `applyStorageCap`（夜晚，**紧接 §2.3 之后**）

设计见 `docs/town.md` §三。**两层口径**，都在这一步、每天一次：

**① 每种物资的软上限**（玩家在**选中仓库后的检视面板**里逐项设置，见 §2.4 末的命令）
```
cap_g = government.storageCaps[g]        # 缺项 = 不限
若 goods[g] > cap_g  →  goods[g] = cap_g，丢弃 (原值 − cap_g)，写一条 log
```
用途：某一种货囤满自己的额度后就不再挤占全局空间，别的物资才收得下。

**② 全局总量上限**
```
容量 = Σ 仓储建筑的容量          # 见下
总量 = Σ goods[g]  (本 pack 全部商品)
若 容量 > 0 且 总量 > 容量  →  按**丢弃顺序**丢到等于容量为止，每种写一条 log
```
- 一座建筑的容量 = `storage.storage + storage.storagePerLevel × (等级 − 1)`
- **`workers > 0` 的仓储建筑，`assignedWorkers < 1` 时不计容量**（仓库要有人看着）；
  `workers == 0` 的（城镇中心）直接计入
- 容量 = 0 时**不丢弃**（没有仓储建筑 = 不受上限约束）

**丢弃顺序（确定性）**：`baseValue` 升序；并列按 `goodId` 字典序。即"先扔烂菜，最后才扔丝绸"。

| 常量 | 值 | 来源 |
|---|---|---|
| 城镇中心容量 | 1000 | `content/buildings.json` 的 `town_center.storage.storage` |
| 仓库容量（1 级） | 300 | 同上 `warehouse` |
| 仓库每级增量 | 150 | `warehouse.storage.storagePerLevel` |

**顺序上的两条硬约束**（都在 `tick.ts` 的夜晚序列里，见 §9.4 / §2.3）：
1. 在**施工开工扣材料之后** —— 开工扣料发生在白天第一个工作小时（§9.3），
   夜晚那条施工收尾（§9.4）也排在丢弃之前，所以不会出现"工地材料被超限丢弃、工地卡死"
2. 在 `applySpoilage` **之后** —— 先损耗、后判上限，损耗腾出的空间能救下本来会被丢的货

**报警**：库存总量 ≥ 容量时 `alerts` 里加 `{type:'storage_full'}`（否则货凭空消失，像是 bug）。

**命令 `set_storage_caps { caps }`**：整体替换 `government.storageCaps`；只收本 pack 里存在的商品，值取非负整数，`0` 视为不限（不入表）。

### 2.5 效率科技加成 `techBonuses`（跨全天的倍率）

15 项「效率科技」在 `content/technologies.json` 里带 `effects`，形如 `"effects": { "agri": 0.10 }`。
值是**加成小数**（`0.10` = +10%），不是倍率。可用键只有 5 个：

| 键 | 作用点 |
|---|---|
| `agri` / `goods` / `material` | 该 **sector** 建筑的产出 |
| `research` | 每日科研力（§10.1） |
| `build` | 每日建造力（§9.1） |

```
techBonuses(state) = for tid in research.done:
                       for k in [agri, goods, material, research, build]:
                         out[k] += technologies[tid].effects[k] ?? 0      # 缺省 0
```

- **加法叠加，不是连乘**：轮作 +20% + 灌溉 +35% + 良种 +50% = **+1.05**。
  连乘后期滚雪球，而且玩家在面板上没法一眼算出"现在是多少"。
- **不取整**（`round2` 只用在最终速率上）。
- 按固定键序累加，**不依赖内容里 `effects` 的键序**。

**三处作用点**（乘数一律是 `1 + 加成`）：

| 位置 | 公式 |
|---|---|
| §2.2 产出 | `goods[g] += output[g] * batches * shop.toolBoost * (1 + techBonuses[def.sector])` —— **投入那张表不动**，多出来的产出是"虚空产量"（不额外吃原料） |
| §10.1 科研 | `researchRate = (基础 + Σ 研究所) * (1 + techBonuses.research)` —— **整条**速率，含 `baseRate` |
| §9.1 建造 | `constructionRate = (失业人口 + Σ 建筑工坊) * (1 + techBonuses.build)` —— **整条**速率 |

- 产出那条与 `toolBoost` 是**相乘**（两条独立路线：工具 +25%、产业科技最多 +105%）。
- 建筑没有 `sector`（无配方建筑：城镇中心 / 仓库 / 建筑工坊 / 研究所）→ 倍率 1。
- 建筑的 `sector`（`agri`/`goods`/`material`）是**内容字段**，校验器强制：
  **有 `recipe` 就必须有 `sector`**，反之不许有。
- **前端**：科技面板顶部显示累计加成，卡片 tooltip 里有单项效果。

## 3. 用工 `assignLabor`（黎明）

1. 重置所有居民 `employed=false, jobShopId=undefined, constructionPay=undefined`。
2. **口粮链**：以 `tuning.foodChainSeedClass` 的食物 `needs` 为种子，对 `recipes` 反复回溯上游投入（仅限本 pack 商品），得到集合 `F`。
   - 若种子阶层无食物需求：退化为「本 pack 所有 `category=food` 商品」。
3. 建筑分为两档：`priority`（其配方任一产出 ∈ F；**无配方的建筑不算**）与其余。
4. 分配（`budget = pop`）：
   - priority 按 `state.shops` 顺序依次满足 `want = min(targetWorkers, def.maxWorkers ?? def.workers)`。
   - 其余按 `want` 比例用**最大余数法**分配剩余 `budget`。
5. 落地：按 `state.shops` 顺序、按 `residents` 顺序依次占用；`shop.skill = 到岗者 skill 平均`。
6. 熟练度增长在**夜晚**（`growSkills`）：在岗者 `skill = min(skillMax, skill + skillGainPerDay)`。

## 4. 财政

### 4.1 累进税 `progressiveTax(income, brackets)`
逐档：`slice = max(0, min(income, upTo) − prev)`；`tax += slice*rate`。

### 4.2 工资 `payWages`（夜晚，每天一次）
```
# 失业保障金已取消：没有工程可做 = 零收入（见 §9 与 docs/construction.md）
buildPay = resident.constructionPay ?? 0
gross = buildPay > 0            ? buildPay                         # 工地临时工，固定日薪
      : employed && jobShopId   ? min(wage*(skillIncomeBase+min(skillMax,skill)/100), wageCap||∞)
      : 0
tax = progressiveTax(gross, brackets)
savings += gross − tax ;  government.money += (Σtax − Σgross)
```

## 5. 住房

### 5.1 占用 `assignTenure`
- 房主占自己名下房（`ownedQuality`）。
- 剩余名额：先私有后国有、等级从高到低；租客按阶层从高到低排序。
- 写 `resident.privateTenant`、`resident.housingQuality`。

### 5.2 收租 `collectRent`（夜晚）
- 国有租客 `pay=min(rent,savings)` → 政府。
- 私有租客 `pay` 汇入总额；按**人均份额**`progressiveTax` 计税，税款归政府，余额给房东平分。

### 5.3 买房 `runPrivateHousingMarket`（夜晚）
遍历 `pack.housing`：`price = prices[gid] ?? salePrice ?? baseValue`；
当 `stateOwned>0 && soldTotal<privateHousingPerDay`，选**存款最高**的合格买家：
非房主、`classLevel>=2`、`classLevel==def.quality`、`savings>=price+5`、`satisfaction>=privateHousingNeedThreshold`。
成交：`savings-=price`、`homeowner=true, ownedQuality=quality`、`privateHousing[gid]++`、`government.money+=price`。

## 6. 消费 `runConsumption`（夜晚）

逐**阶层**、逐**居民**、逐 `need`：
```
candidates = [good, ...fallbacks] 过滤到本 pack
若 need 为食物：再补 tuning.basicFoods
target = 第一个 goods>0.001 的候选，否则 candidates[0]
elastic = isLuxury(target) ? luxuryElasticity : priceElasticity
factor  = clamp( (baseValue/price)^elastic , priceFactorMin , priceFactorMax )
desired = perCapita * factor
want    = min(desired, savings/price)
sold    = min(want, goods[target])
goods[target]-=sold ; savings-=sold*price ; revenue+=sold*price
食物 need：foodConsumed+=sold, foodNeeded+=desired（非食物同理记 comfort）
```
每居民 `foodScore = foodConsumed/foodNeeded`；`foodScore < hungryThreshold(0.9)` 记 1 饥饿。
政府 + `revenue`。**奢侈品判定**：`goods[gid].luxury === true`。

## 7. 满意度 `updateSatisfaction`（夜晚）
```
wageScore = clamp(wage/refWage, 0, wageScoreCap) / wageScoreCap
employmentScore = employed ? 1 : unemployedEmploymentScore
base = 100 * (wF*food + wW*wage + wP*price + wE*employment + wC*comfort) / (Σweights)
housingAdj = homeowner ? +privateHousingSatBonus
           : privateTenant ? +privateTenantSatBonus − rentPressure*rentSatPenalty
           : −rentPressure*rentSatPenalty
           + (housingQuality < classHousingLevel ? −(差级数)*housingQualityPenalty : 0)
target = clamp(base + housingAdj + classSatBonus, 0, 100)
satisfaction = clamp(satisfaction + (target−satisfaction)*satisfactionSmoothing, 0, 100)
```
`rentPressure = clamp(rent / max(0.1, refWage − progressiveTax(refWage)), 0, 1)`；`classHousingLevel/classSatBonus` 取自居民阶层的定义。

## 8. 人口与移民（夜晚）

- **死亡（饥饿）**：若 `hungry>0`，`deaths = min(ceil(hungry*hungerDeathRate), pop−minPopulation)`；
  按满意度最低者淘汰，**遗产充公**（政府 +Σsavings）。
- **迁出**：若 `avgSat < emigrationSatThreshold`，`leave = min(max(1,floor(pop*0.02)), pop−minPopulation)`；带走存款。
- **分层** `updateClasses`：按 pack 允许阶层的 `wealthThreshold` 升序，取 `savings` 满足的最高阶层。
- **放行** `applyAdmission`：`admit = min(arrivals, housingCapacity−pop, populationCap−pop)`；
  新居民默认最低阶层，属性取 `defaults.newResident`。
  **岗位数不参与**：岗位可以后补，把 `Σ targetWorkers` 当闸门会让村子永远长不大
  （建造队与移民会互斥）。规模由玩家设定的人口上限（`government.populationCap`）兜住。
- **想来人数** `computeArrivals`（job 无关，只看满意度与饥荒）：
  1. 昨日 `hungry > max(1, pop × immigrationHungryRate)` → `arrivals = 0`（"食物充足"这一条）
  2. `avgSat < immigrationSatThreshold` → 0
  3. 否则 `round(pop × immigrationRate × (avgSat−th)/(100−th))`

## 9. 施工（建店 / 升级 / 建房）

> **建造力 = 每日施工产能（速率，不是库存）**。完整设计见 `docs/construction.md`。
>
> **节奏**：施工与生产**同一节奏** —— 产能摊在白天的工作小时里逐小时投入（§9.3），
> 工地上白天能看见进度在爬；**一天的总量 = 黎明钉住的当日建造力**（不结转）。
> 黎明的 `planConstructionDay` 只做一件事：把这个预算钉死（§9.3），白天不再现算。
> 夜晚只做收尾（§9.4）：诊断队首为什么没动 + 把当日投入折成建造工资。

### 9.1 每日产能 `constructionRate`
```
rate = (Σ(失业居民) × construction.unemployedRate
     + Σ(建筑工坊在岗工人) × construction.workshopBase × (skillEffectBase + skillEffectSlope × 熟练度/100))
     × (1 + techBonuses.build)          # 效率科技：起重架 / 脚手架 / 预制件（见 §2.5）
```
- 「建筑工坊」= **没有 `recipe` 的建筑**（产出建造产能而非商品）。
- 失业居民 = `!resident.employed`。产能**不结转**，当天没用完即作废。
- 效率加成乘在**整条速率**上（失业人口那一项也一起放大）。

### 9.2 下单 `tryBuild` / `tryExpand` / `tryBuildHousing`
只检查资源是否够，占住队列位，**不扣材料**；压入
`construction{kind, remaining=buildWork, totalRequired, started=false}`。
- 建筑工时 `buildWork` 见 `content/buildings.json`；住房见 `housing.json`。
- 升级工时 = `construction.upgradePerLevel × 当前等级`。
- `usedSlots = shops + 在建(非 upgrade) + housing`。

### 9.3 黎明 `planConstructionDay` + 白天 `applyConstructionHours(fraction)`（**与 §2.2 同一条件**）

**黎明**（`runDawn`，排在 `assignLabor` **之后**、第一个工作小时**之前**）：
```
state.constructionRateToday = constructionRate(state)   # 当天预算：全天不变
state.constructionWorkToday = 0
```
> 为什么要钉死"当天的预算"：这是"一天总量恰好等于当日建造力"的**硬闸** ——
> 白天每个工作小时投入的量都抵着它，不必依赖"同一天里 `constructionRate()` 恰好不变"
> （它取决于失业人口与建筑工坊的在岗人数；`shop.skill` 只在黎明 `assignLabor` 与
> 入夜 `growSkills` 两处变，但任何一处将来改动都不该动摇当天的总量）。
> 科研（§10.3）钉的是同一道闸，两边完全同构。

**白天**在 `state.hour` 满足 `workStart <= h < workEnd` 时**每小时调用一次**（排在
`runProductionStep` **之后** —— 当小时刚产出的木石粘土，当小时就能用于工地开工扣料）。
`fraction = 1/(workEnd−workStart)`（默认 1/12）。

先进先出，串行投入：
```
rate   = constructionRateToday × fraction     # 这一个小时的量：**常数**，不取整
work   = 0
for c in construction:                        # 队首 → 队尾
    if rate <= 0 → break
    if !c.started:
        spec = costOf(c)                      # 实物原料，或（无可用原料时）资金
        定义缺失 → break                       # 诊断留给夜晚（§9.4）
        不足     → break                       # 停在队首等待，**不跳过**
        足够     → payCost(spec); c.started = true
                   记日志「开工（需建造力 N）」   # **只在 started 翻转时写一次**
    used = min(rate, c.remaining)
    c.remaining = round4(c.remaining − used)  # **r4**：12 次 r2 会漂移
    rate -= used ; work += used
state.constructionWorkToday = round4(state.constructionWorkToday + work)
```
- **每小时的量是个常数**（`constructionRateToday / 工作小时数`），**不是**每小时现算一次
  `constructionRate()`：当天中途的人事变动（在岗人数 / 失业人口）不会动摇今天的量。
- **开工时刻 = 这一天第一个工作小时**（材料在这一刻扣，不是夜晚）。
- 一天的投入总量 = `constructionRateToday`（每小时 1/工作小时数），**不结转**。
- 日志节奏：小时里**不写**「等待材料」（否则一天刷 12 条）—— 那条诊断在夜晚（§9.4），
  每天最多一条；「开工」只在 `started` 翻转的那一小时写一次。
- `rate` 本身**不取整**（取整会让工作小时之和不再恰好等于日产能）；
  只有落进状态的两处（`remaining` / `constructionWorkToday`）用 r4。

### 9.4 夜晚 `settleConstruction`（**在 `payWages` 之前**）

产能已经在白天投完了，这里只做两件事：

```
# ① 诊断：队首为什么没动（每天最多一条）
若 constructionRate > 0：
    c = 第一条 !started 的工程
    它前面若有「已开工且 remaining > 0」的工程 → 不诊断   # 产能被前面的工程正常吃掉了
    costOf(c) 缺失 → 记日志「定义缺失，施工停摆」
    买不起        → 记日志「等待材料（…）」

# ② 当日投入折成建造工资
markConstructionWorkers(state.constructionWorkToday)
state.constructionWorkToday = 0
```

`markConstructionWorkers(work)`：出工人数 `n = min(失业人数, ceil(work))`；
总工资 `bill = work × refWage × construction.wageRate`，在 n 人之间平均分配，
写入 `resident.constructionPay` 并置 `employed = true`（当晚算就业、计熟练度增长）。
`work` = 当日白天逐小时累计的投入量（`constructionWorkToday`，r4）。

### 9.5 黎明 `activateCompleted`
`remaining <= 0` 的按 kind 生效（建店 / 升级 / 建房），其余留队。

### 9.6 有效工位数 `effectiveSlots`
```
slots = (def.maxWorkers ?? def.workers) + (def.capacity?.slotsPerLevel ?? 0) × (等级 − 1)
```
**这是工位上限的唯一口径**，三处共用：
- `assignLabor`：实际派人时按它截断 `targetWorkers`
- `set_workers` 动作：按它截断 `value`
- 表现层：建筑面板的用工拖动条 `max_value`

> 曾经 `set_workers` 是按 `maxWorkers` 那个**常数**截断的，于是
> "把研究所升到 L3 再拖满 12 人"会被**静默夹回 6 人** ——
> 上限看着是 12、拖到 12、次日却只有 6 个工位在开。同一口径必须只有一份实现。

**升级时的用工目标重算**（`activateCompleted` 的 `upgrade` 分支）：

| 升级前 | 升级后 |
|---|---|
| `targetWorkers == 旧 slots`（满员） | `targetWorkers = 新 slots`（**继续满员**） |
| 不满员 | **保持原来的绝对数字**（不按比例缩放） |

不减这一手的话，研究所从 L1 升到 L2 会"自动少 3 个工位"，玩家看着莫名其妙。

### 9.7 拆除 `demolish`
`{ type: 'demolish', shopId }` → 从 `state.shops` 移除该店。

- **只作用于已建成的**。还在 `state.construction` 队列里的不属于 `state.shops`，
  要取消得走施工队列那条路（不在这条动作的职责内）。
- **退「建造资源」**：按 `def.buildCost` 原样退回库存（只退 `goodSet` 里真实存在的项，
  与 `presentCost` 同一口径）。
- **不退「建造力」**：那是每日产能 / 已经投进去的人工，没有"退"的概念。
- **工人自动变回失业**：`assignLabor` 每晚按 `state.shops` 现算，无需额外处理。
- 建筑不存在 → `ok: false, reason: '建筑不存在'`。
- **占用地格由表现层释放**：`world_view._sync()` 会对"引擎里已消失"的店
  调 `_remove_shop_view()` —— 收走精灵、擦掉 `map.occupied`、清掉所有
  按 shop_id 索引的表。不做这一步就会留下"鬼影"且那块地永远不能再建。
- 面板点「拆除」要**弹二次确认窗**（不可撤销，得让玩家看清拆的是哪一座）。

## 10. 研究（科技解锁）

> **科研力 = 每日产能（速率，不是库存）**，与建造力同构。完整设计见 `docs/technology.md`。
>
> **节奏**：科研与生产 / 施工**同一节奏** —— 产能摊在白天的工作小时里逐小时投入（§10.3），
> 研究所头顶的进度条白天能看见在爬；**一天的总量仍是当天的科研力**（不结转）。
> 夜晚只做收尾（§10.4）：诊断队首为什么没动。

### 10.1 每日产能 `researchRate`
```
rate = (economy.research.baseRate
     + Σ(研究所在岗工人 × capacity.perWorker × (1 + capacity.levelBonus × (等级−1))
                              × (skillEffectBase + skillEffectSlope × 熟练度/100)))
     × (1 + techBonuses.research)       # 效率科技：抄书房 / 学院 / 印刷术（见 §2.5）
```
- 「研究所」= `capacity.kind == 'research'` 的建筑（不产商品）。
- 基础项现在是 **0**（研究所是科研力的唯一来源，见 `docs/technology.md` 纪元 0）。
- 效率加成乘在**整条速率**上（基础项也一起放大）。
- 产能**不结转**，当天没用完即作废。

### 10.2 下单 `research { techId }`
只检查材料是否够，占住队列位，**不扣材料**；压入
`research.queue{id, remaining = tech.research, totalRequired, started = false}`。
拒绝条件（按顺序）：科技不存在 / 已完成 / 已在队列 / **前置未完成** / 材料不足。

`cancel_research { techId }` 从队列移除，**已扣材料不退**（与施工一致）。

### 10.3 黎明 `planResearchDay` + 白天 `applyResearchHours(fraction)`

**黎明**（`runDawn`，排在 `assignLabor` **之后**、第一个工作小时**之前**）：
```
state.researchRateToday = researchRate(state)   # 当天预算：全天不变
state.researchWorkToday = 0
```
> 为什么要钉死"当天的预算"：这是"一天总量恰好等于当日科研力"的**硬闸** ——
> 逐小时投入的量与当日已投累计都抵着它，不必依赖"同一天里 `researchRate()` 恰好不变"
> （`shop.skill` 只在黎明 `assignLabor` 与入夜 `growSkills` 两处变，所以实际一天内不变，
> 但多一条隐含依赖就多一个将来会被改坏的地方）。施工那边（§9.3 的
> `planConstructionDay`）钉的是同一道预算，两边完全同构。

**白天**在 `state.hour` 满足 `workStart <= h < workEnd` 时**每小时调用一次**，
排在 `runProductionStep`、`applyConstructionHours` **之后**（先生产、再施工、后科研）。
`fraction = 1/(workEnd−workStart)`（默认 1/12）。
```
rate  = researchRateToday × fraction     # 这一个小时的量：**常数**，不取整
left  = min(rate, researchRateToday − researchWorkToday)   # 同一格多调一次不会多投
for p in research.queue:                 # 队首 → 队尾
    if left <= 0 → break
    if !p.started:
        材料不足 → 记「等待材料」（p.waiting 去重，每天最多一条）; break   # 停在队首，不跳过
        足够   → 扣材料; p.started = true; 记「开始研究」
    used = min(left, p.remaining)
    p.remaining = max(0, round4(p.remaining − used))   # **r4**：12 次 r2 会漂移
    p.waiting = false
    left = round4(left − used)
    researchWorkToday = round4(researchWorkToday + used)
```
- **每小时的量是个常数**（不是"把队首剩下的需求摊到当天剩下的小时里"）：队首只剩 5、
  日产能 12 时，就是每小时 1、走 5 个小时在**当天中途**跑完。
- **队首中途跑完 → 这一格剩下的产能继续投给下一条**（同格、串行）—— 剩余的产能不许丢，
  这是"一天总量 = 当天科研力"成立的关键；队列空了就作废（**不结转第二天**）。
- `fraction` 只用于"这一格投多少"的语义说明与对称；实际额度由 `researchRateToday` 与
  `researchWorkToday` 的差兜底，所以一天的总投入恰好等于 `researchRateToday`。
- **完工不在这里激活**：跑完后仍留在队列里，等夜晚之后的黎明 `activateResearch` 才出队（§10.5）。

### 10.4 夜晚 `settleResearch`（紧接 `settleConstruction` 之后）

产能已经在白天投完了，这里只做一件事：**队首为什么没动**（每天最多一条诊断）。
```
若 researchRate(state) > 0：               # 产能为 0 时队首本来就没机会开工，不诊断
    p = queue[0]；没有 / 定义缺失 / 已 started 且 remaining<=0 → 不写
    材料不足 → 记「研究「X」等待材料（缺什么）」
```
> 白天每小时都可能撞上同一个缺口，日志若写在小时里会刷 12 条屏，所以挪到夜晚，
> 与施工的 §9.4 同一套口径。

### 10.5 黎明 `activateResearch`
`queue[0].remaining <= 0` 时出队并 push 进 `research.done`（解锁随之生效），可连出多项。

### 10.6 解锁判定
```
可建(建筑) = 没有任何科技 unlocks 它          # 开局免费
          或 解锁它的科技 ∈ research.done
```
住房同理（`unlocks.housing`）。`unlocks` 里每座建筑**至多出现一次**（内容校验强制）。
**商品不单独设锁**：商品的可用性由"产出它的建筑是否解锁"决定。

开局已研究的科技取 `pack.start.techs`（缺省空）。开局自带某建筑**实例**的 pack
必须把解锁它的科技也列进去，否则会出现"有这座建筑但建造栏里是锁的"。

## 11. 工具（工坊耗材与产出加成）

> 完整设计见 `docs/technology.md` §八。

- `economy.tools.perWorkstation`（0.05）：每个**在岗工位**每日消耗的工具数。
- 商品带 `toolBonus`（category = `tool`）；`economy.tools.order` 由低到高排工具品级。

### 11.1 黎明 `allocateTools`（**必须在 `planProduction` 之前**）
```
for shop in shops:
    shop.toolBoost = 1
    if !shop.active or 该建筑没有 recipe: continue    # 产能建筑不产商品，加成无从施加
    workers = 在岗工人数;  if workers <= 0: continue
    need = perWorkstation × workers
    for gid in reverse(economy.tools.order):          # 从**最高级**工具往下找
        if goods[gid] >= need:
            goods[gid] -= need ; ledgerToday.consumed[gid] += need
            shop.toolBoost = 1 + ALL_GOODS[gid].toolBonus
            break
```
工具不够时按 `state.shops` 顺序先到先得（确定性，便于对拍）。

### 11.2 生产小时 `runProductionStep`
```
goods[g] += q × batches × shop.toolBoost × (1 + techBonuses[def.sector])   # 只放大**产出**
ledgerToday.produced[g] += 同上
# 投入与燃料那几行**完全不动**
```
效果即"投入不变、产出 ×1.25" —— 单位原料成品率提高（"虚空产量"）。

## 12. 初始状态 `createInitialState`

- 商品/价格/住房取自 `ctx.pack.goods` / `pack.housing`，数量取自 `pack.start`。
- 建筑取自 `pack.start.shops`；居民默认值取 `defaults.startResident`，阶层分布取 `defaults.startDistribution`。
- 科技：`research.done = pack.start.techs ?? []`，`research.queue = []`。
- 工具：新建 / 初始店铺 `toolBoost = 1`。
- `hour=0, day=0, pending=[]`。

## 13. 随机数（mulberry32）

```
state = (state + 0x6d2b79f5) & 0xFFFFFFFF
t = state
t = (t ^ (t >> 15)) * (t | 1) & 0xFFFFFFFF          // 32 位乘法
t ^= (t + ((t ^ (t >> 7)) * (t | 61) & 0xFFFFFFFF)) & 0xFFFFFFFF
out = ((t ^ (t >> 14)) & 0xFFFFFFFF) / 2^32
```
> GDScript 无无符号移位/32 位乘法，需手动 `& 0xFFFFFFFF`。

## 14. 内容 schema

见 `content/README.md`。`economy.json.schemaVersion` 必须等于引擎支持的版本（当前 `1`）。

## 15. 黄金轨迹（golden）

- `scripts/golden.ts`：固定 `pack/seed/脚本`，逐日输出 `godot/tests/golden/<pack>-<seed>.json`。
- Godot 侧 `tests/` 用 gdUnit4 回放同一脚本，逐日比对摘要（数值容差 ~1e-3）。
- 脚本只在指定 tick 入队命令；不含 AI，保证纯仿真可跨语言复现。
