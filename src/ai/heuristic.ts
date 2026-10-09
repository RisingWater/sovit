import type { Action, GameState } from '../engine/types.ts'
import { ALL_GOODS, ECONOMY, buildContext } from '../engine/index.ts'
import { sum } from '../engine/util.ts'

// ---------------------------------------------------------------------------
// 启发式基线 AI
//
// 一个「够用」的示例玩家：满员用工、按财政/满意度调工资与价格、
// 粮食紧张时扩产瓶颈环节、失业明显时建店。
// 主要用于 100 天验收，同时也是 AI 接口的参考实现。
// ---------------------------------------------------------------------------

function lookbackHungry(state: GameState): number {
  return state.history[state.history.length - 1]?.hungry ?? 0
}

export function decide(state: GameState): Action[] {
  const ctx = buildContext(state.pack)
  const actions: Action[] = []

  const pop = state.residents.length
  const avgSat = pop > 0 ? sum(state.residents.map((r) => r.satisfaction)) / pop : 0
  const money = state.government.money
  const hungry = lookbackHungry(state)

  // 1. 满员用工
  for (const shop of state.shops) {
    const def = ctx.buildings[shop.defId]
    if (!def) continue
    actions.push({ type: 'set_workers', shopId: shop.id, value: def.workers })
  }

  // 2. 工资策略
  let wage = ECONOMY.refWage
  if (money < 150) wage = ECONOMY.refWage * 0.8
  if (avgSat < 50 || hungry > 0) wage = ECONOMY.refWage * 1.2
  wage = Math.round(wage * 10) / 10
  for (const shop of state.shops) {
    actions.push({ type: 'set_wage', shopId: shop.id, value: wage })
  }

  // 3. 价格策略：全国有经济下提价只会压缩居民购买力，故维持基准价；
  //    仅在出现饥饿时临时补贴降价。
  const mul = hungry > 0 ? 0.95 : 1
  for (const gid of ctx.pack.goods) {
    const def = ALL_GOODS[gid]
    if (!def) continue
    actions.push({ type: 'set_price', goodId: gid, value: Math.round(def.baseValue * mul * 100) / 100 })
  }

  // 4. 扩产 / 建店（v0.1 面包链 + 蔬菜链）
  const shopOf = (defId: string) => state.shops.find((s) => s.defId === defId)
  const low = (gid: string, perCap: number) => (state.goods[gid] ?? 0) < pop * perCap

  const bakery = shopOf('coarse_bakery')
  const mill = shopOf('coarse_mill')
  const farm = shopOf('wheat_farm')
  const veg = shopOf('vegetable_farm')
  const canExpand = (s: { level: number } | undefined) => !!s && s.level < 5

  if (hungry > 0 && money > 200) {
    // 缺粮：优先补最短缺的最终食品
    if (veg && low('vegetable', 0.5) && canExpand(veg)) actions.push({ type: 'expand', shopId: veg.id })
    else if (bakery && low('coarse_bread', 1.0) && canExpand(bakery)) actions.push({ type: 'expand', shopId: bakery.id })
    else if (mill && low('coarse_flour', 1.0) && canExpand(mill)) actions.push({ type: 'expand', shopId: mill.id })
    else if (farm && low('wheat', 1.0) && canExpand(farm)) actions.push({ type: 'expand', shopId: farm.id })
  } else if (money > 300) {
    // 主动维持蔬菜与上游，避免链条停摆
    if (veg && (state.goods['vegetable'] ?? 0) < pop * 0.3 && canExpand(veg)) {
      actions.push({ type: 'expand', shopId: veg.id })
    } else if (mill && (state.goods['coarse_flour'] ?? 0) < 2 && canExpand(mill)) {
      actions.push({ type: 'expand', shopId: mill.id })
    } else if (farm && (state.goods['wheat'] ?? 0) < 2 && canExpand(farm)) {
      actions.push({ type: 'expand', shopId: farm.id })
    } else if (money > 550) {
      // 粮食与上游充足：建店增加岗位，带动人口（各建筑数量均衡）
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
