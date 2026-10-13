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
  - `workStart(6) <= h < workEnd(18)`：**生产** `runProductionStep(1/(workEnd-workStart))`
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
goods[g] += output[g]  * batches
```

**不取整**（浮点，避免 12 次累积误差）。

### 2.3 损耗 `applySpoilage`（夜晚，每天一次）

`goods[g] *= (1 − perishRate)`（非耐储商品）。

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

### 9.1 每日产能 `constructionRate`
```
rate = Σ(失业居民) × construction.unemployedRate
     + Σ(建筑工坊在岗工人) × construction.workshopBase × (skillEffectBase + skillEffectSlope × 熟练度/100)
```
- 「建筑工坊」= **没有 `recipe` 的建筑**（产出建造产能而非商品）。
- 失业居民 = `!resident.employed`。产能**不结转**，当天没用完即作废。

### 9.2 下单 `tryBuild` / `tryExpand` / `tryBuildHousing`
只检查资源是否够，占住队列位，**不扣材料**；压入
`construction{kind, remaining=buildWork, totalRequired, started=false}`。
- 建筑工时 `buildWork` 见 `content/buildings.json`；住房见 `housing.json`。
- 升级工时 = `construction.upgradePerLevel × 当前等级`。
- `usedSlots = shops + 在建(非 upgrade) + housing`。

### 9.3 夜晚 `settleConstruction`（**在 `payWages` 之前**）
先进先出，串行投入：
```
for c in construction:                       # 队首 → 队尾
    if !c.started:
        spec = costOf(c)                     # 实物原料，或（无可用原料时）资金
        不足 → 记日志「等待材料」，break      # 停在队首，不跳过
        足够 → payCost(spec); c.started = true
    used = min(rate, c.remaining)
    c.remaining -= used ; rate -= used ; work += used
    rate <= 0 → break
markConstructionWorkers(work)
```
`markConstructionWorkers`：出工人数 `n = min(失业人数, ceil(work))`；
总工资 `bill = work × refWage × construction.wageRate`，在 n 人之间平均分配，
写入 `resident.constructionPay` 并置 `employed = true`（当晚算就业、计熟练度增长）。

### 9.4 黎明 `activateCompleted`
`remaining <= 0` 的按 kind 生效（建店 / 升级 / 建房），其余留队。

## 10. 研究（科技解锁）

> **科研力 = 每日产能（速率，不是库存）**，与建造力同构。完整设计见 `docs/technology.md`。

### 10.1 每日产能 `researchRate`
```
rate = economy.research.baseRate
     + Σ(研究所在岗工人 × capacity.perWorker × (1 + capacity.levelBonus × (等级−1))
                              × (skillEffectBase + skillEffectSlope × 熟练度/100))
```
- 「研究所」= `capacity.kind == 'research'` 的建筑（不产商品）。
- 基础项**不需要任何建筑**（2.0/天）：保证"研究所"本身能被研究出来，不会自锁。
- 产能**不结转**，当天没用完即作废。

### 10.2 下单 `research { techId }`
只检查材料是否够，占住队列位，**不扣材料**；压入
`research.queue{id, remaining = tech.research, totalRequired, started = false}`。
拒绝条件（按顺序）：科技不存在 / 已完成 / 已在队列 / **前置未完成** / 材料不足。

`cancel_research { techId }` 从队列移除，**已扣材料不退**（与施工一致）。

### 10.3 夜晚 `settleResearch`（紧接 `settleConstruction` 之后）
```
for p in research.queue:                 # 队首 → 队尾
    if rate <= 0: break
    if !p.started:
        材料不足 → 记日志「等待材料」，break   # 停在队首，不跳过
        足够   → 扣材料; p.started = true
    used = min(rate, p.remaining)
    p.remaining -= used ; rate -= used
    rate <= 0 → break
```

### 10.4 黎明 `activateResearch`
`queue[0].remaining <= 0` 时出队并 push 进 `research.done`（解锁随之生效），可连出多项。

### 10.5 解锁判定
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
goods[g] += q × batches × shop.toolBoost          # 只放大**产出**
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
