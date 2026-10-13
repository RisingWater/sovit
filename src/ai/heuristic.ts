import type { Action, GameState } from '../engine/types.ts'
import {
  ALL_GOODS,
  ECONOMY,
  assignedWorkers,
  buildContext,
  canResearch,
  foodChainShopIds,
  housingCapacity,
  isBuildingUnlocked,
  isLuxuryGood,
} from '../engine/index.ts'
import type { ContentContext } from '../engine/index.ts'
import { clamp, sum } from '../engine/util.ts'

// ---------------------------------------------------------------------------
// 启发式基线 AI
//
// 只有一套增长策略：保持建材链运转，建住房提人口上限，补岗位与粮食，直到土地上限。
//
// 施工是一条**串行**队列，产能 = 失业人口 + 建筑工坊工人（见 docs/construction.md）。
// 因此有两条硬约束：① 不能无限下单（队列会永远排不完）；② 必须靠建筑工坊提供建造力
// （全村满员就业时产能为 0，且不能用"压低开岗数"留人——那会让移民一个都进不来）。
// ---------------------------------------------------------------------------

/** 同时排队施工的工程上限。 */
const MAX_CONSTRUCTION_QUEUE = 4
/** 有在建工程时，留给工地的常住人口比例。 */
const CONSTRUCTION_RESERVE_RATIO = 0.25
/** 常备建造队占人口的比例：低于这个数就不再开新工位（见 pushBuild 内注释）。 */
const CREW_RESERVE_RATIO = 0.2

/**
 * 研究优先级 = docs/technology.md 依赖图的拓扑序。
 * 每天只在队列为空时补一项；买不起 / 前置未满足就顺延到下一项。
 */
const RESEARCH_ORDER: string[] = [  'research_institute',
  'stonework',
  'digging',
  'firewood',
  'construction',
  'toolmaking',
  'hunting',
  'brickmaking',
  'pottery',
  'fiber_crops',
  'fishing',
  'carpentry',
  'fine_milling',
  'white_baking',
  'coarse_weaving',
  'fine_weaving',
  'curing',
  'coarse_tailoring',
  'entertainment',
  'cash_crops',
  'sugar_refining',
  'common_tailoring',
  'leatherwork',
  'pastry_baking',
  'masonry_housing',
  'porcelain',
  'luxury_tailoring',
  'domestic_service',
  'housing_works',
]

/** "引擎"建筑：不产商品、只产每日产能（建造力 / 科研力）。它们优先于一切生产建筑。 */
function isEngineBuilding(def: { capacity?: unknown }): boolean {
  return def.capacity !== undefined
}

function lookbackHungry(state: GameState): number {
  return state.history[state.history.length - 1]?.hungry ?? 0
}

function avgSatOf(state: GameState): number {
  const pop = state.residents.length
  return pop > 0 ? sum(state.residents.map((r) => r.satisfaction)) / pop : 0
}

function jobCapacity(state: GameState, ctx: ContentContext): number {
  let total = 0
  for (const shop of state.shops) {
    if (!shop.active) continue
    const def = ctx.buildings[shop.defId]
    if (def) total += def.workers
  }
  return total
}

/** 公共动作：满员用工 + 工资 + 价格。 */
function commonActions(
  state: GameState,
  ctx: ContentContext,
  avgSat: number,
  hungry: number,
): Action[] {
  const actions: Action[] = []
  const money = state.government.money
  const pop = state.residents.length

  // 用工：**留一支常备建造队**，其余按「食品链 → 引擎 → 其余」三档分配。
  //
  // 建造力 = 失业人口，所以必须让一部分人不上岗；否则全村满员就业 → 建造力 0
  // → 连"建筑工坊"（唯一能打破僵局的建筑）都盖不出来。
  // 早先不敢这么做，是因为迁入闸门曾经是 `jobCapacity = Σ targetWorkers`，
  // 压低开岗数会让移民一个都进不来；**现在迁入只看住房 + 粮食 + 满意度**，这个顾虑没有了。
  //
  // ⚠️ 一定要分档：把所有工坊**一起**等比摊薄会连食品链一起削，
  //    实测直接从 20 人饿到 4 人。食品链必须优先拿满它的份额。
  {
    const crewNeed = Math.max(2, Math.round(pop * CREW_RESERVE_RATIO))
    const foodIds = foodChainShopIds(state, ctx)
    let budget = Math.max(0, pop - crewNeed)

    const targets = new Map<string, number>()
    const defOf = (s: { defId: string }) => ctx.buildings[s.defId]

    // ① 食品链：在预算内等比摊派（吃饭优先）
    const foodShops = state.shops.filter((s) => foodIds.has(s.id))
    const foodWant = foodShops.reduce((a, s) => a + (defOf(s)?.workers ?? 0), 0)
    const foodScale = foodWant > budget ? budget / foodWant : 1
    for (const s of foodShops) {
      const w = Math.floor((defOf(s)?.workers ?? 0) * foodScale)
      targets.set(s.id, w)
      budget -= w
    }
    // ② 引擎建筑（研究所 / 建筑工坊）：固定工位，本身就是产能来源
    for (const s of state.shops) {
      if (targets.has(s.id)) continue
      const def = defOf(s)
      if (!def || !def.capacity) continue
      targets.set(s.id, def.workers)
    }
    // ③ 其余：只能用①②剩下的零头
    const rest = state.shops.filter((s) => !targets.has(s.id))
    const restWant = rest.reduce((a, s) => a + (defOf(s)?.workers ?? 0), 0)
    const restScale = restWant > budget ? budget / restWant : 1
    for (const s of rest) {
      targets.set(s.id, Math.floor((defOf(s)?.workers ?? 0) * restScale))
    }

    for (const s of state.shops) {
      actions.push({ type: 'set_workers', shopId: s.id, value: targets.get(s.id) ?? 0 })
    }
  }

  let wage = ECONOMY.refWage
  if (money < 150) wage = ECONOMY.refWage * 0.8
  if (avgSat < 50 || hungry > 0) wage = ECONOMY.refWage * 1.2
  wage = Math.round(wage * 10) / 10
  for (const shop of state.shops) {
    actions.push({ type: 'set_wage', shopId: shop.id, value: wage })
  }

  // 工坊工资上限：常态给默认上限；财政为负时收紧到岗位工资。
  const cap = money < 0 ? ECONOMY.refWage : ECONOMY.defaultWageCap
  for (const shop of state.shops) {
    actions.push({ type: 'set_wage_cap', shopId: shop.id, value: cap })
  }

  for (const gid of ctx.pack.goods) {
    const def = ALL_GOODS[gid]
    if (!def || def.category === 'housing') continue
    const base = def.baseValue
    const cur = state.prices[gid] ?? base
    let level = base > 0 ? cur / base : 1
    if (isLuxuryGood(gid)) {
      // 带迟滞的区间控制：允许赤字扩产。
      // 财政跌破 -1000 → 提价；回到 0 以上 → 回落到正常价；中间保持不变。
      if (money < -1000) level = Math.min(15, level * 1.05)
      else if (money > 0) level = Math.max(ECONOMY.luxuryPriceMarkup, level * 0.98)
      level = clamp(level, ECONOMY.luxuryPriceMarkup, 15)
    } else {
      // 必需品（高弹性）：维持基准价；缺粮时略降，绝不提价（提价只会少收 + 饿死人）。
      level = hungry > 0 ? 0.95 : 1
    }
    actions.push({ type: 'set_price', goodId: gid, value: Math.round(base * level * 100) / 100 })
  }

  // 租金：常态维持默认值（提价只会压缩居民购买力，反噬财政）。
  actions.push({ type: 'set_rent', value: ECONOMY.defaultRent })

  // 累进税：财政为负时提高最高档税率；盈余充足时回落。
  const bs = state.government.taxBrackets
  const topIdx = bs.length - 1
  const top = bs[topIdx]
  if (top) {
    if (money < 0) {
      actions.push({
        type: 'set_tax_bracket',
        index: topIdx,
        rate: Math.min(0.8, Math.round((top.rate + 0.02) * 100) / 100),
      })
    } else if (money > 500 && top.rate > 0.15) {
      actions.push({
        type: 'set_tax_bracket',
        index: topIdx,
        rate: Math.round((top.rate - 0.02) * 100) / 100,
      })
    }
  }

  return actions
}

// ---------------------------------------------------------------------------
// 增长策略
// ---------------------------------------------------------------------------

function decideGrowth(state: GameState, ctx: ContentContext): Action[] {
  const pop = state.residents.length
  const avgSat = avgSatOf(state)
  const hungry = lookbackHungry(state)
  const actions = commonActions(state, ctx, avgSat, hungry)

  const shopOf = (defId: string) => state.shops.find((s) => s.defId === defId)
  const counts: Record<string, number> = {}
  for (const s of state.shops) counts[s.defId] = (counts[s.defId] ?? 0) + 1
  // 在建的也算进去，避免重复建店
  for (const c of state.construction) {
    if (c.kind === 'shop' && c.buildingId) counts[c.buildingId] = (counts[c.buildingId] ?? 0) + 1
  }

  const expand = (defId: string): Action | undefined => {
    const s = shopOf(defId)
    return s && s.level < 6 ? { type: 'expand', shopId: s.id } : undefined
  }

  const housingCap = housingCapacity(state, ctx)
  const housingRoom = housingCap - pop
  const jobRoom = jobCapacity(state, ctx) - pop
  // 富余劳动力：一个闲人都没有时再建店，只会把现有工坊一起摊瘦（施工还要另留人）。
  const spareJobs = pop - jobCapacity(state, ctx)

  // 产能（满员近似）：某商品每日最大产出。
  const productionCapacity = (gid: string): number => {
    let cap = 0
    for (const shop of state.shops) {
      if (!shop.active) continue
      const def = ctx.buildings[shop.defId]
      if (!def) continue
      const recipe = def.recipe ? ctx.recipes[def.recipe] : undefined
      if (!recipe) continue
      const out = recipe.output[gid]
      if (out) cap += recipe.baseRate * shop.level * out
    }
    return cap
  }
  const levelSum = (defId: string): number =>
    state.shops.reduce((a, s) => a + (s.defId === defId && s.active ? s.level : 0), 0)

  // 食品扩产：优先补**最缺的必需食物**（蔬菜 / 粗面包），再考虑高级食品。
  const foodExpansion = (): Action | undefined => {
    const breadRatio = productionCapacity('coarse_bread') / Math.max(1, pop * 1.15)
    const vegRatio = productionCapacity('vegetable') / Math.max(1, pop * 0.6)

    if (vegRatio < 1 && vegRatio <= breadRatio) return expand('vegetable_farm')
    if (breadRatio < 1) {
      const links = ['wheat_farm', 'coarse_mill', 'coarse_bakery'].filter((id) =>
        ctx.buildingSet.has(id),
      )
      let weakest = links[0]
      if (weakest) {
        for (const id of links) if (levelSum(id) < levelSum(weakest)) weakest = id
        const a = expand(weakest)
        if (a) return a
      }
    }
    if (vegRatio < 1) return expand('vegetable_farm')

    // 高级食品（白面包 / 糕点）链：中产富人需要，产能不足时补上游
    if (productionCapacity('white_bread') + productionCapacity('pastry') < pop * 0.5) {
      const links = ['wheat_farm', 'fine_mill', 'white_bakery', 'pastry_shop'].filter((id) =>
        ctx.buildingSet.has(id),
      )
      let weakest = links[0]
      if (weakest) {
        for (const id of links) if (levelSum(id) < levelSum(weakest)) weakest = id
        const a = expand(weakest)
        if (a) return a
      }
    }
    return undefined
  }

  const classCount: Record<string, number> = {}
  for (const r of state.residents) classCount[r.classId] = (classCount[r.classId] ?? 0) + 1

  // 本回合可执行多个建设 / 扩产动作；每个都先查负担，避免卡在"建不起的建筑"上空转。
  const picks: Action[] = []
  const MAX_PICKS = 6
  const picked = new Set<string>()
  const budget: Record<string, number> = {}
  const afford = (g: string, q: number) => (budget[g] ?? state.goods[g] ?? 0) >= q
  const spend = (g: string, q: number) => {
    budget[g] = (budget[g] ?? state.goods[g] ?? 0) - q
  }
  const matsOf = (cost?: Partial<Record<string, number>>): Array<[string, number]> =>
    Object.entries(cost ?? {}).filter(([g, q]) => q && ctx.goodSet.has(g)) as Array<[string, number]>
  const canAfford = (mats: Array<[string, number]>) => mats.every(([g, q]) => afford(g, q))
  const payMats = (mats: Array<[string, number]>) => mats.forEach(([g, q]) => spend(g, q))

  // 施工是**串行**队列，下单也不再扣材料（开工时才扣），所以必须自己限流：
  // 排太多的话队尾永远轮不到，且材料会被反复"看上去够"而超订。
  //
  // ⚠️ 必须把**今天已经放进 picks 的单**也算进去：只数 `state.construction`
  // 会在一天里连推好几个（每个都看到 length < 4），把队列顶到 6–9，
  // 之后每天都判定"队满" → 研究所/建筑工坊这类关键建筑永远排不进去。
  const queuedTotal = (): number =>
    state.construction.length +
    picks.filter((p) => p.type === 'build' || p.type === 'build_housing' || p.type === 'expand').length

  // 开局"引擎优先"：研究所还没研究出来时把队列压到 1 项，这样它一解锁就能
  // 立刻排到队首（否则被 30+ 建造力的杂项埋在队尾，白白多磨十几天）。
  // 不能连生产建筑一起禁掉——失业人口的**唯一收入**就是上工地（见 docs/technology.md §五），
  // 队列一空全村零收入，直接饿死。
  const bootstrapping =
    !state.research.done.includes('research_institute') &&
    (state.goods['coarse_bread'] ?? 0) > pop * 8
  const queueLimit = bootstrapping ? 1 : MAX_CONSTRUCTION_QUEUE
  const queueFull = (): boolean => queuedTotal() >= queueLimit

  const pushExpand = (defId: string): void => {
    if (picks.length >= MAX_PICKS) return
    if (queueFull()) return
    const shop = shopOf(defId)
    if (!shop || shop.level >= 8) return
    const key = 'e:' + shop.id
    if (picked.has(key)) return
    const def = ctx.buildings[defId]
    if (!def) return
    const mats = matsOf(def.buildCost).map(([g, q]) => [g, q * shop.level] as [string, number])
    if (mats.length > 0) {
      if (!canAfford(mats)) return
      payMats(mats)
    } else if (state.government.money < ECONOMY.expandMoneyBase * shop.level) {
      return
    }
    picks.push({ type: 'expand', shopId: shop.id })
    picked.add(key)
  }
  const pushBuild = (id: string, n: number): void => {
    if (picks.length >= MAX_PICKS) return
    if (queueFull()) return
    if ((counts[id] ?? 0) >= n || !ctx.buildingSet.has(id)) return
    // 科技没研究出来就别下单（不然白白占一个 pick，引擎会拒绝）
    if (!isBuildingUnlocked(state, ctx, id)) return
    const def = ctx.buildings[id]
    if (!def) return

    // 留一支建造队：建造力 = **失业人口**，所以必须让一部分人不上岗，
    // 否则全村满员就业 → 建造力 0 → 连"建筑工坊"都盖不出来（唯一能打破僵局的建筑）。
    // 迁入已经不看岗位数了（population.ts），所以压低开岗数不再会挡住移民。
    const crewNeed = Math.max(2, Math.round(pop * CREW_RESERVE_RATIO))
    if (spareJobs <= crewNeed && !isEngineBuilding(def)) return

    // 没有富余劳动力时，**引擎建筑照建**：它们把工人变成产能（一人顶两个闲人）。
    // 生产建筑也不再拦 —— 迁入闸门是 `jobCapacity = Σ targetWorkers`（population.ts），
    // 岗位数不高于人口就一个移民都进不来，村子会被永久锁死在当前规模。
    // 食品链优先由 `assignLabor` 的优先级保证，不靠这里限建。
    if (spareJobs <= 0 && isEngineBuilding(def)) { /* 引擎建筑永远可建 */ }
    const key = 'b:' + id
    if (picked.has(key)) return
    const mats = matsOf(def.buildCost)
    if (mats.length > 0) {
      if (!canAfford(mats)) return
      payMats(mats)
    } else if (state.government.money < (ECONOMY.buildMoneyByTier[def.tier] ?? 0)) {
      return
    }
    picks.push({ type: 'build', buildingId: id })
    picked.add(key)
  }
  const pushHouse = (gid: string): void => {
    if (picks.length >= MAX_PICKS) return
    if (queueFull()) return
    const key = 'h:' + gid
    if (picked.has(key)) return
    const def = ctx.housing[gid]
    if (!def) return
    const mats = matsOf(def.buildCost)
    if (!canAfford(mats)) return
    payMats(mats)
    picks.push({ type: 'build_housing', goodId: gid })
    picked.add(key)
  }

  // 0. 建造力引擎：建筑工坊必须是**第一座**建筑。
  //    施工能力一旦归零（全村满员就业且没有工坊）就再也建不动任何东西——死锁：
  //    没有工坊 → 没有建造力 → 建不出工坊。开局那批失业人口是唯一的起手资本，
  //    必须优先拿去建工坊，而不是被食品链一次吃光。
  //    它不产商品，只把工人变成 2 倍建造力，是村子唯一的产能增量来源。
  if (ctx.buildingSet.has('construction_works')) pushBuild('construction_works', 2)

  // 0. 科技：研究队列空着就按优先级表补一项。
  //
  // 顺序 = docs/technology.md 依赖图的拓扑序。**研究所必须第一项**：
  // 在它之前全村只有 2.0 科研力/天（12 科研力要熬 6 天），而它一投产就跳到 ~16/天。
  // 之后 营造（建筑工坊）是最关键的一步：不研究它，村子满员就业后建造力归零、彻底停工。
  if (state.research.queue.length === 0) {
    for (const tid of RESEARCH_ORDER) {
      if (!ctx.technologies[tid]) continue
      const check = canResearch(state, ctx, tid)
      if (check.ok) {
        picks.push({ type: 'research', techId: tid })
        break
      }
    }
  }

  // 0b. 产能与耗材产线：研究所 / 建筑工坊 / 工具坊 —— 这三座是"引擎"，优先于一切生产建筑。
  // ⚠️ 每样**只要 1 座**：`counts` 把在 builder 也算进去，写 2 会导致第一座还没盖好
  //    就再排一座，把施工队列占满，食品链（尤其蔬菜农场）永远排不进去
  //    —— 而蔬菜产能是迁入闸门 `foodCapOk` 的一半，卡住它 = 人口永久冻结。
  if (ctx.buildingSet.has('research_institute')) pushBuild('research_institute', 1)
  if (ctx.buildingSet.has('construction_works')) pushBuild('construction_works', 1)
  if (ctx.buildingSet.has('tool_works')) {
    // 一座满员工具坊供养约 40 个在岗工位（每工位日耗 0.05）；不够就再建
    const workstations = state.shops.reduce(
      (a, s) => a + (ctx.buildings[s.defId]?.recipe ? assignedWorkers(state, s.id) : 0),
      0,
    )
    pushBuild('tool_works', Math.max(1, Math.ceil(workstations / 40)))
  }

  // 1. 木材（通用建材）：木材偏低时补伐木场
  if ((state.goods['wood'] ?? 0) < pop * 2) pushExpand('lumberjack')

  // 2. 必需食品：先补齐缺失的粮食链建筑，再按最缺的扩产
  for (const id of ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm']) {
    if (ctx.buildingSet.has(id)) pushBuild(id, 1)
  }
  const breadRatio = productionCapacity('coarse_bread') / Math.max(1, pop * 1.15)
  const vegRatio = productionCapacity('vegetable') / Math.max(1, pop * 0.6)
  if (vegRatio < 1 && vegRatio <= breadRatio) pushExpand('vegetable_farm')
  if (breadRatio < 1) {
    const links = ['wheat_farm', 'coarse_mill', 'coarse_bakery'].filter((id) =>
      ctx.buildingSet.has(id),
    )
    let weakest = links[0]
    for (const id of links) if (weakest && levelSum(id) < levelSum(weakest)) weakest = id
    if (weakest) pushExpand(weakest)
  }
  if (vegRatio < 1) pushExpand('vegetable_farm')

  // 3. 建材链最小规模（建筑工坊已在上面的"引擎"段处理）
  const minChain: Array<[string, number]> = [
    ['lumberjack', 3],
    ['quarry', 1],
    ['clay_pit', 1],
    ['firewood_works', 1],
    ['brick_kiln', 1],
  ]
  for (const [id, n] of minChain) pushBuild(id, n)

  // 4. 高级食品 / 奢侈品 / 服务链：保证产量，才能从富人身上抽税
  if (productionCapacity('white_bread') + productionCapacity('pastry') < pop * 0.5) {
    const links = ['wheat_farm', 'fine_mill', 'white_bakery', 'pastry_shop'].filter((id) =>
      ctx.buildingSet.has(id),
    )
    let weakest = links[0]
    for (const id of links) if (weakest && levelSum(id) < levelSum(weakest)) weakest = id
    if (weakest) pushExpand(weakest)
  }
  {
    const has = (c: string) => (classCount[c] ?? 0) > 0
    if (has('middle')) {
      for (const id of ['fine_mill', 'white_bakery', 'flax_farm', 'coarse_weaver', 'coarse_clothes_shop', 'hunting_camp', 'pottery_works']) {
        pushBuild(id, 1)
      }
    }
    if (has('rich') || has('boss')) {
      const servants = Math.max(
        1,
        Math.ceil(((classCount['rich'] ?? 0) * 0.3 + (classCount['boss'] ?? 0) * 0.5) / 4),
      )
      for (const id of ['sugarcane_farm', 'sugar_works', 'pastry_shop', 'cotton_farm', 'fine_weaver', 'common_clothes_shop', 'dye_farm', 'luxury_clothes_shop', 'leather_shop', 'porcelain_works']) {
        pushBuild(id, 1)
      }
      pushBuild('domestic_service', servants)
    }
    if (has('middle') || has('rich') || has('boss')) {
      const entDemand =
        (classCount['middle'] ?? 0) * 0.1 +
        (classCount['rich'] ?? 0) * 0.3 +
        (classCount['boss'] ?? 0) * 0.6
      if (entDemand > 0) pushBuild('theater', Math.max(1, Math.ceil(entDemand / 5)))
    }
  }

  // 5. 住房：仅当"住房比岗位更缺"时才建房（人口上限 = min(住房, 岗位)）
  if (ctx.pack.housing.length > 0 && housingRoom <= jobRoom) {
    const classLevel = (c: string): number => ctx.classes[c]?.housingLevel ?? 1
    const cands: Array<{ gid: string; deficit: number; popForType: number }> = []
    for (const gid of ctx.pack.housing) {
      const def = ctx.housing[gid]
      if (!def) continue
      let popForType = 0
      for (const r of state.residents) {
        if (classLevel(r.classId) === def.quality) popForType++
      }
      const deficit = Math.ceil(popForType / def.capacity) - Math.floor(state.housing[gid] ?? 0)
      cands.push({ gid, deficit, popForType })
    }
    cands.sort((a, b) => b.deficit - a.deficit || b.popForType - a.popForType)
    for (const c of cands) {
      if (c.deficit > 0) pushHouse(c.gid)
      else if (housingRoom < 4 && c.popForType > 0) pushHouse(c.gid)
    }
  }

  // 6. 岗位：仅当"岗位比住房更缺"时建产线（优先建材/资源，顺带产砖与建造力）
  if (jobRoom <= housingRoom) {
    const jobOrder = ['lumberjack', 'quarry', 'clay_pit', 'firewood_works', 'brick_kiln', 'construction_works'].filter((id) =>
      ctx.buildingSet.has(id),
    )
    jobOrder.sort((a, b) => (counts[a] ?? 0) - (counts[b] ?? 0))
    for (const id of jobOrder) {
      if (picks.length >= MAX_PICKS) break
      pushBuild(id, (counts[id] ?? 0) + 1)
    }
    // 粮食链：补最弱环节，保持 小麦 : 磨坊 : 面包房 均衡（避免只堆磨坊/面包房）
    const breadLinks = ['wheat_farm', 'coarse_mill', 'coarse_bakery'].filter((id) =>
      ctx.buildingSet.has(id),
    )
    if (breadLinks.length > 0) {
      let weakest = breadLinks[0]
      for (const id of breadLinks) if (weakest && levelSum(id) < levelSum(weakest)) weakest = id
      if (weakest) pushBuild(weakest, (counts[weakest] ?? 0) + 1)
    }
    if (ctx.buildingSet.has('vegetable_farm')) {
      pushBuild('vegetable_farm', (counts['vegetable_farm'] ?? 0) + 1)
    }
  }

  // 人口上限：AI 把上限钉在「粮食产能养得起的人数」，但**至少留出 +2 的余量**。
  // 这是迁入的**唯一**规模闸门（已不看岗位数），用来防止一口气涌进来一堆人、
  // 粮食跟不上饿死 —— 正是玩家用这个旋钮要做的事。
  // ⚠️ 不能把上限钉死在当前人口上：那样"没粮食 → 不招人 → 没人手建粮食链"会自锁，
  //    所以永远留一点增量；真的粮食不够时由引擎的饥饿闸门兜底（昨日饥饿 >5% → 无人愿来）。
  {
    const breadCap = productionCapacity('coarse_bread') / 1.15 // 穷人 1.0 粗面包/人·天 + 余量
    const vegCap = productionCapacity('vegetable') / 0.55 // 穷人 0.5 蔬菜/人·天 + 余量
    const foodCap = Math.floor(Math.min(breadCap, vegCap))
    const cap = Math.max(pop + 2, foodCap)
    if (cap !== state.government.populationCap) {
      actions.push({ type: 'set_population_cap', value: cap })
    }
  }

  for (const a of picks) actions.push(a)
  actions.push({ type: 'end_turn' })
  return actions
}

// ---------------------------------------------------------------------------

export function decide(state: GameState): Action[] {
  return decideGrowth(state, buildContext(state.pack))
}
