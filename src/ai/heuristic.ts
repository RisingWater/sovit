import type { Action, GameState } from '../engine/types.ts'
import { ALL_GOODS, ECONOMY, buildContext, housingCapacity } from '../engine/index.ts'
import type { ContentContext } from '../engine/index.ts'
import { sum } from '../engine/util.ts'

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

  const mul = hungry > 0 ? 0.95 : 1
  for (const gid of ctx.pack.goods) {
    const def = ALL_GOODS[gid]
    if (!def) continue
    actions.push({ type: 'set_price', goodId: gid, value: Math.round(def.baseValue * mul * 100) / 100 })
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

  // 食品扩产：按产能对比，扩最弱且真正不足的一环（保持链条均衡）。
  const foodExpansion = (): Action | undefined => {
    if (productionCapacity('coarse_bread') < pop * 1.15) {
      const links = ['wheat_farm', 'coarse_mill', 'coarse_bakery'].filter((id) =>
        ctx.buildingSet.has(id),
      )
      let weakest = links[0]
      if (weakest) {
        for (const id of links) if (levelSum(id) < levelSum(weakest)) weakest = id
        return expand(weakest)
      }
    }
    if (productionCapacity('vegetable') < pop * 0.6) return expand('vegetable_farm')
    return undefined
  }

  let chosen: Action | undefined

  // 1. 缺粮 → 优先补食品产能
  if (hungry > 0) chosen = foodExpansion()

  // 2. 保证建材链最小规模
  if (!chosen) {
    const chain: Array<[string, number]> = [
      ['lumberjack', 2],
      ['quarry', 1],
      ['clay_pit', 1],
      ['firewood_works', 1],
      ['brick_kiln', 1],
    ]
    for (const [id, n] of chain) {
      if ((counts[id] ?? 0) < n && ctx.buildingSet.has(id)) {
        chosen = { type: 'build', buildingId: id }
        break
      }
    }
  }

  // 3. 食品储备见底 → 扩产
  if (!chosen) chosen = foodExpansion()

  // 4. 住房触顶 → 建住房（人口最终瓶颈）
  if (!chosen && housingRoom < 1 && ctx.pack.housing.length > 0) {
    chosen = { type: 'build_housing', goodId: ctx.pack.housing[0]! }
  }

  // 5. 岗位触顶 → 建产线建筑（各建筑数量均衡）
  if (!chosen && jobRoom < 1 && ctx.buildingSet.has('wheat_farm')) {
    const order = ['wheat_farm', 'coarse_mill', 'coarse_bakery', 'vegetable_farm'].filter((id) =>
      ctx.buildingSet.has(id),
    )
    if (order.length > 0) {
      let pick = order[0]!
      for (const id of order) if ((counts[id] ?? 0) < (counts[pick] ?? 0)) pick = id
      chosen = { type: 'build', buildingId: pick }
    }
  }

  if (chosen) actions.push(chosen)
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
