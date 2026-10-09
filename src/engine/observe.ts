import type { GameState, Observation, ObserveShop, Shop, ShopStatus } from './types.ts'
import { ALL_BUILDINGS } from './content/index.ts'
import { buildContext } from './content/index.ts'
import { sum } from './util.ts'

// ---------------------------------------------------------------------------
// 观测：把 GameState 压成给 AI 的精简 JSON
// ---------------------------------------------------------------------------

function shopStatus(shop: Shop): ShopStatus {
  if (!shop.active) return 'red'
  if (shop.profit < 0) return 'red'
  if (shop.profit < 5) return 'yellow'
  return 'green'
}

export function observe(state: GameState): Observation {
  const ctx = buildContext(state.pack)

  const byClass: Record<string, number> = {}
  for (const r of state.residents) {
    byClass[r.classId] = (byClass[r.classId] ?? 0) + 1
  }

  const total = state.residents.length
  const employed = state.residents.filter((r) => r.employed).length
  const avgSat = total > 0 ? sum(state.residents.map((r) => r.satisfaction)) / total : 0
  const lastSnapshot = state.history[state.history.length - 1]
  const hungry = lastSnapshot?.hungry ?? 0

  const shops: ObserveShop[] = state.shops.map((s) => {
    const def = ALL_BUILDINGS[s.defId]
    return {
      id: s.id,
      type: s.defId,
      nameZh: def?.nameZh ?? s.defId,
      workers: state.residents.filter((r) => r.jobShopId === s.id).length,
      maxWorkers: def?.workers ?? 0,
      wage: s.wage,
      level: s.level,
      active: s.active,
      profit: s.profit,
      skill: Math.round(s.skill),
      status: shopStatus(s),
    }
  })

  const prices: Record<string, number> = {}
  const inventory: Record<string, number> = {}
  for (const gid of ctx.pack.goods) {
    prices[gid] = state.prices[gid] ?? 0
    inventory[gid] = state.goods[gid] ?? 0
  }

  return {
    day: state.day,
    pack: state.pack,
    government: { money: state.government.money, taxRate: state.government.taxRate },
    population: {
      total,
      byClass,
      hungry,
      avgSatisfaction: Math.round(avgSat * 10) / 10,
      employed,
      unemployed: total - employed,
    },
    shops,
    market: { prices, inventory },
    alerts: state.alerts,
    history: state.history.slice(-30),
  }
}
