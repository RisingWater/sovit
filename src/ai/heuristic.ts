import type { Action, GameState } from '../engine/types.ts'
import { ALL_GOODS, ECONOMY, buildContext, housingCapacity, isLuxuryGood } from '../engine/index.ts'
import type { ContentContext } from '../engine/index.ts'
import { clamp, sum } from '../engine/util.ts'

// ---------------------------------------------------------------------------
// 启发式基线 AI
//
// 两套策略，按内容包自动分派：
//  - 增长策略（含住房的 pack，如 v0.2）：保持建材链运转，建住房提人口上限，
//    补岗位与粮食，直到土地上限。
//  - 稳态策略（v0.1，无住房）：满员用工、按需扩产，人口由岗位封顶。
// ---------------------------------------------------------------------------

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

  for (const shop of state.shops) {
    const def = ctx.buildings[shop.defId]
    if (!def) continue
    actions.push({ type: 'set_workers', shopId: shop.id, value: def.workers })
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
  for (const c of state.construction) counts[c.buildingId] = (counts[c.buildingId] ?? 0) + 1

  const expand = (defId: string): Action | undefined => {
    const s = shopOf(defId)
    return s && s.level < 6 ? { type: 'expand', shopId: s.id } : undefined
  }

  const housingCap = housingCapacity(state, ctx)
  const housingRoom = housingCap - pop
  const jobRoom = jobCapacity(state, ctx) - pop

  // 产能（满员近似）：某商品每日最大产出。
  const productionCapacity = (gid: string): number => {
    let cap = 0
    for (const shop of state.shops) {
      if (!shop.active) continue
      const def = ctx.buildings[shop.defId]
      if (!def) continue
      const recipe = ctx.recipes[def.recipe]
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

  const pushExpand = (defId: string): void => {
    if (picks.length >= MAX_PICKS) return
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
    if ((counts[id] ?? 0) >= n || !ctx.buildingSet.has(id)) return
    const key = 'b:' + id
    if (picked.has(key)) return
    const def = ctx.buildings[id]
    if (!def) return
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

  // 1. 材料瓶颈：木材偏低时补伐木场
  if ((state.goods['wood'] ?? 0) < pop * 2) pushExpand('lumberjack')

  // 2. 必需食品：蔬菜 / 粗面包，按最缺的扩产
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

  // 3. 建材 / 建造力链最小规模
  const minChain: Array<[string, number]> = [
    ['lumberjack', 3],
    ['quarry', 1],
    ['clay_pit', 1],
    ['firewood_works', 1],
    ['brick_kiln', 1],
    ['construction_works', 2],
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
    const requiredLevel = ECONOMY.classHousingLevel
    const cands: Array<{ gid: string; deficit: number; popForType: number }> = []
    for (const gid of ctx.pack.housing) {
      const def = ctx.housing[gid]
      if (!def) continue
      let popForType = 0
      for (const r of state.residents) {
        if ((requiredLevel[r.classId] ?? 1) === def.quality) popForType++
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
    const jobOrder = ['lumberjack', 'quarry', 'clay_pit', 'firewood_works', 'brick_kiln', 'construction_works', 'wheat_farm', 'vegetable_farm'].filter((id) =>
      ctx.buildingSet.has(id),
    )
    jobOrder.sort((a, b) => (counts[a] ?? 0) - (counts[b] ?? 0))
    for (const id of jobOrder) {
      if (picks.length >= MAX_PICKS) break
      pushBuild(id, (counts[id] ?? 0) + 1)
    }
  }

  for (const a of picks) actions.push(a)
  actions.push({ type: 'end_turn' })
  return actions
}

// ---------------------------------------------------------------------------
// 稳态策略（v0.1）
// ---------------------------------------------------------------------------

function decideSteady(state: GameState, ctx: ContentContext): Action[] {
  const pop = state.residents.length
  const avgSat = avgSatOf(state)
  const hungry = lookbackHungry(state)
  const money = state.government.money
  const actions = commonActions(state, ctx, avgSat, hungry)

  const shopOf = (defId: string) => state.shops.find((s) => s.defId === defId)
  const low = (gid: string, perCap: number) => (state.goods[gid] ?? 0) < pop * perCap
  const canExpand = (s: { level: number } | undefined) => !!s && s.level < 5

  const bakery = shopOf('coarse_bakery')
  const mill = shopOf('coarse_mill')
  const farm = shopOf('wheat_farm')
  const veg = shopOf('vegetable_farm')

  if (hungry > 0 && money > 200) {
    if (veg && low('vegetable', 0.5) && canExpand(veg)) actions.push({ type: 'expand', shopId: veg.id })
    else if (bakery && low('coarse_bread', 1.0) && canExpand(bakery)) actions.push({ type: 'expand', shopId: bakery.id })
    else if (mill && low('coarse_flour', 1.0) && canExpand(mill)) actions.push({ type: 'expand', shopId: mill.id })
    else if (farm && low('wheat', 1.0) && canExpand(farm)) actions.push({ type: 'expand', shopId: farm.id })
  } else if (money > 300) {
    if (veg && (state.goods['vegetable'] ?? 0) < pop * 0.3 && canExpand(veg)) {
      actions.push({ type: 'expand', shopId: veg.id })
    } else if (mill && (state.goods['coarse_flour'] ?? 0) < 2 && canExpand(mill)) {
      actions.push({ type: 'expand', shopId: mill.id })
    } else if (farm && (state.goods['wheat'] ?? 0) < 2 && canExpand(farm)) {
      actions.push({ type: 'expand', shopId: farm.id })
    } else if (money > 550) {
      const order = ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm'].filter((id) =>
        ctx.buildingSet.has(id),
      )
      if (order.length > 0) {
        const counts: Record<string, number> = {}
        for (const s of state.shops) counts[s.defId] = (counts[s.defId] ?? 0) + 1
        let pick = order[0]!
        for (const id of order) {
          if ((counts[id] ?? 0) < (counts[pick] ?? 0)) pick = id
        }
        actions.push({ type: 'build', buildingId: pick })
      }
    }
  }

  actions.push({ type: 'end_turn' })
  return actions
}

// ---------------------------------------------------------------------------

export function decide(state: GameState): Action[] {
  const ctx = buildContext(state.pack)
  return ctx.pack.housing.length > 0 ? decideGrowth(state, ctx) : decideSteady(state, ctx)
}
