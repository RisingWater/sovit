import type { GameState, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { ECONOMY } from '../config.ts'
import { clamp, round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 消费（逐居民）
//
// 每个小人按自己阶层的需求、用**自己的存款**购买；买不起就少买（记为饥饿）。
// 逐居民结算保证：没有跨居民补贴，货币严格守恒（居民付出 = 政府收入）。
// ---------------------------------------------------------------------------

export interface ConsumptionResult {
  /** 各阶层平均食物满足率 0-1。 */
  foodScore: Record<string, number>
  /** 各阶层平均价格分数 0-1。 */
  priceScore: Record<string, number>
  /** 饥饿人数。 */
  hungry: number
  /** 政府销售回款。 */
  revenue: number
  logs: LogEntry[]
}

function priceScore(price: number, base: number): number {
  const ratio = base > 0 ? price / base : 1
  return clamp(ECONOMY.priceIntercept - ECONOMY.priceSlope * ratio, 0, 1)
}

export function runConsumption(
  state: GameState,
  ctx: ContentContext,
  day: number,
): ConsumptionResult {
  const foodScore: Record<string, number> = {}
  const priceScoreMap: Record<string, number> = {}
  const soldByGood: Record<string, number> = {}
  let hungry = 0
  let revenue = 0

  for (const classId of ctx.pack.classes) {
    const def = ctx.classes[classId]
    const members = state.residents.filter((r) => r.classId === classId)
    if (!def || members.length === 0) {
      foodScore[classId] = 1
      priceScoreMap[classId] = 1
      continue
    }

    let foodSum = 0
    let priceSum = 0

    for (const r of members) {
      let needed = 0
      let consumed = 0
      let priceNum = 0
      let priceDen = 0

      for (const need of def.needs) {
        const candidates = [need.good, ...(need.fallbacks ?? [])].filter((g) =>
          ctx.goodSet.has(g),
        )
        if (candidates.length === 0) continue

        const demand = need.perCapita
        const target =
          candidates.find((g) => (state.goods[g] ?? 0) > 0.001) ?? candidates[0]!
        const gdef = ALL_GOODS[target]
        const base = gdef?.baseValue ?? 1
        const price = Math.max(0.01, state.prices[target] ?? base)
        const factor = clamp(Math.pow(base / price, ECONOMY.priceElasticity), 0.2, 1.5)

        const desired = demand * factor
        const affordable = price > 0 ? r.savings / price : desired
        const want = Math.min(desired, affordable)
        const sold = Math.min(want, state.goods[target] ?? 0)

        state.goods[target] = round2((state.goods[target] ?? 0) - sold)
        const cost = sold * price
        r.savings = round2(Math.max(0, r.savings - cost))
        revenue += cost

        needed += demand
        consumed += sold
        soldByGood[target] = (soldByGood[target] ?? 0) + sold

        const ps = priceScore(price, base)
        priceNum += ps * demand
        priceDen += demand
      }

      const f = needed > 0 ? clamp(consumed / needed, 0, 1) : 1
      foodSum += f
      priceSum += priceDen > 0 ? priceNum / priceDen : 1
      if (f < 0.9) hungry += 1
    }

    foodScore[classId] = foodSum / members.length
    priceScoreMap[classId] = priceSum / members.length
  }

  state.government.money = round2(state.government.money + revenue)

  const logs: LogEntry[] = []
  const soldParts = Object.entries(soldByGood)
    .filter(([, q]) => q > 0.01)
    .map(([g, q]) => `${ALL_GOODS[g]?.nameZh ?? g} ${round2(q)}`)
  if (soldParts.length > 0) {
    logs.push({
      day,
      kind: 'finance',
      text: `居民消费 ${soldParts.join('、')}，回款 ¥${round2(revenue)}`,
    })
  }

  return { foodScore, priceScore: priceScoreMap, hungry, revenue: round2(revenue), logs }
}
