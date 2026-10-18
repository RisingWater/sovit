import type { GameState, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS, CLASS_IDS, isLuxuryGood } from '../content/index.ts'
import { ECONOMY, TUNING } from '../config.ts'
import { clamp, round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 消费（逐居民）
//
// 每个小人按自己阶层的需求、用**自己的存款**购买。
// 需求分两类：
//  - 食物类需求 → 决定「食物满足率」，买不起就挨饿（食物满足率 < 1）；
//  - 非食物需求（衣物 / 陶器…）→ 决定「舒适度」，缺货只降满意度，不饿死。
// 逐居民结算保证货币守恒（居民付出 = 政府收入）。
// ---------------------------------------------------------------------------

export interface ConsumptionResult {
  /** 各阶层平均食物满足率 0-1。 */
  foodScore: Record<string, number>
  /** 各阶层平均舒适度 0-1。 */
  comfortScore: Record<string, number>
  /** 各阶层平均价格分数 0-1。 */
  priceScore: Record<string, number>
  /** 各**商品**需求的平均满足率（2026-10：教育用它加速熟练度成长）。 */
  needScores: Record<string, number>
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
  const comfortScore: Record<string, number> = {}
  const priceScoreMap: Record<string, number> = {}
  const soldByGood: Record<string, number> = {}
  const needSum: Record<string, number> = {}
  const needCnt: Record<string, number> = {}
  let hungry = 0
  let revenue = 0

  // 遍历所有阶层：财富分层会产生新阶层，必须一并结算。
  for (const classId of CLASS_IDS) {
    const def = ctx.classes[classId]
    const members = state.residents.filter((r) => r.classId === classId)
    if (!def || members.length === 0) {
      foodScore[classId] = 1
      comfortScore[classId] = 1
      priceScoreMap[classId] = 1
      continue
    }

    let foodSum = 0
    let comfortSum = 0
    let priceSum = 0

    for (const r of members) {
      let foodNeeded = 0
      let foodConsumed = 0
      let comfortNeeded = 0
      let comfortConsumed = 0
      let priceNum = 0
      let priceDen = 0
      let spentByResident = 0
      let needRatio = 1
      const needScoreLocal: Record<string, number> = {}

      for (const need of def.needs) {
        const isFood = ALL_GOODS[need.good]?.category === 'food'
        let candidates = [need.good, ...(need.fallbacks ?? [])].filter((g) => ctx.goodSet.has(g))
        // 食物需求兜底到基础食物，避免高级食物缺货时被“饿死”。
        if (isFood) {
          for (const b of TUNING.basicFoods) {
            if (ctx.goodSet.has(b) && !candidates.includes(b)) candidates.push(b)
          }
        }
        if (candidates.length === 0) continue

        const demand = need.perCapita
        const target =
          candidates.find((g) => (state.goods[g] ?? 0) > 0.001) ?? candidates[0]!
        const gdef = ALL_GOODS[target]
        const base = gdef?.baseValue ?? 1
        const price = Math.max(0.01, state.prices[target] ?? base)
        const elastic = isLuxuryGood(target) ? ECONOMY.luxuryElasticity : ECONOMY.priceElasticity
        const factor = clamp(Math.pow(base / price, elastic), TUNING.priceFactorMin, TUNING.priceFactorMax)

        const desired = demand * factor
        const affordable = price > 0 ? r.savings / price : desired
        const want = Math.min(desired, affordable)
        const sold = Math.min(want, state.goods[target] ?? 0)

        state.goods[target] = round2((state.goods[target] ?? 0) - sold)
        const cost = sold * price
        r.savings = round2(Math.max(0, r.savings - cost))
        revenue += cost
        spentByResident += cost
        // 逐人消耗
        if (sold > 0) {
          if (!r.account) {
            r.account = { wage: 0, tax: 0, rent: 0, spent: 0, foodScore: 1, comfortScore: 1, priceScore: 1, hungry: false, bought: {} }
          }
          r.account.bought[target] = round2((r.account.bought[target] ?? 0) + sold)
          state.ledgerToday.bought[target] = round2((state.ledgerToday.bought[target] ?? 0) + sold)
          // 台账里的**阶层拆分**（哪一等的居民买走了它）—— 面板 tooltip 直接读
          // （用户 2026-10："中产 x11 消耗多少资源"）。
          const byClass = (state.ledgerToday.boughtBy[target] ??= {})
          byClass[r.classId] = round2((byClass[r.classId] ?? 0) + sold)
        }

        // 逐项需求的满足率（2026-10）：晋升按"最差那一项"算，所以这里逐项记录
        needRatio = Math.min(needRatio, clamp(sold / demand, 0, 1))
        needScoreLocal[need.good] = clamp(sold / demand, 0, 1)
        if (isFood) {
          foodNeeded += demand
          foodConsumed += sold
        } else {
          comfortNeeded += demand
          comfortConsumed += sold
        }
        soldByGood[target] = (soldByGood[target] ?? 0) + sold

        const ps = priceScore(price, base)
        priceNum += ps * demand
        priceDen += demand
      }

      const f = foodNeeded > 0 ? clamp(foodConsumed / foodNeeded, 0, 1) : 1
      const c = comfortNeeded > 0 ? clamp(comfortConsumed / comfortNeeded, 0, 1) : 1
      foodSum += f
      comfortSum += c
      priceSum += priceDen > 0 ? priceNum / priceDen : 1
      const isHungry = f < TUNING.hungryThreshold
      if (isHungry) hungry += 1

      // 逐人记账：当日消耗（bought）、支出、三项满足率、是否挨饿。
      // 目前按阶层 perCapita 平均分配，所以逐人数值 == 阶层数值；分开记录是为了
      // 将来做差异化分配时不必再改数据结构。
      if (!r.account) {
        r.account = { wage: 0, tax: 0, rent: 0, spent: 0, foodScore: 1, comfortScore: 1, priceScore: 1, hungry: false, bought: {} }
      }
      r.needsMet = Math.round(needRatio * 1000) / 1000
      for (const gid of Object.keys(needScoreLocal)) {
        needSum[gid] = (needSum[gid] ?? 0) + needScoreLocal[gid]!
        needCnt[gid] = (needCnt[gid] ?? 0) + 1
      }
      r.account.foodScore = Math.round(f * 1000) / 1000
      r.account.comfortScore = Math.round(c * 1000) / 1000
      r.account.priceScore = Math.round((priceDen > 0 ? priceNum / priceDen : 1) * 1000) / 1000
      r.account.hungry = isHungry
      r.account.spent = round2(r.account.spent + spentByResident)
    }

    foodScore[classId] = foodSum / members.length
    comfortScore[classId] = comfortSum / members.length
    priceScoreMap[classId] = priceSum / members.length
  }

  state.government.money = round2(state.government.money + revenue)
  state.ledgerToday.sales = round2(state.ledgerToday.sales + revenue)

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

  const needScores: Record<string, number> = {}
  for (const gid of Object.keys(needSum)) needScores[gid] = round2(needSum[gid]! / Math.max(1, needCnt[gid]!))
  return {
    foodScore,
    needScores,
    comfortScore,
    priceScore: priceScoreMap,
    hungry,
    revenue: round2(revenue),
    logs,
  }
}
