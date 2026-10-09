import type { GameState, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { ECONOMY } from '../config.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 住房系统
//
// - 国有住房：居住者按人头交租（政府收入，租金玩家可调）。
// - 私有住房：高层需求。居民在满足低级需求（满意度达标）且存款足够时，
//   按玩家设定的价格购买国有住房，转为私有；私有住房提升满意度。
// ---------------------------------------------------------------------------

/** 总住房容量（国有 + 私有）。 */
export function housingCapacity(state: GameState, ctx: ContentContext): number {
  let cap = 0
  for (const [gid, count] of Object.entries(state.housing)) {
    const def = ctx.housing[gid]
    if (def) cap += def.capacity * Math.floor(count)
  }
  return cap
}

/** 私有住房容量。 */
export function privateCapacity(state: GameState, ctx: ContentContext): number {
  let cap = 0
  for (const [gid, count] of Object.entries(state.privateHousing)) {
    const def = ctx.housing[gid]
    if (def) cap += def.capacity * Math.floor(count)
  }
  return cap
}

export interface Occupancy {
  /** 住在私有住房的人数（优先填满）。 */
  privateCount: number
  /** 住在国有住房的人数。 */
  stateCount: number
  privateShare: number
}

/** 假设私有住房更优，居民优先入住私有，其余住国有。 */
export function splitOccupancy(state: GameState, ctx: ContentContext): Occupancy {
  const pop = state.residents.length
  const privateCount = Math.min(pop, privateCapacity(state, ctx))
  const stateCount = Math.max(0, pop - privateCount)
  return {
    privateCount,
    stateCount,
    privateShare: pop > 0 ? privateCount / pop : 0,
  }
}

/** 征收国有住房租金：只向非房主按人头收取，回流政府。 */
export function collectRent(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const rent = state.government.rent
  if (rent <= 0 || state.residents.length === 0) return []
  // 没有任何住房的内容包（如 v0.1）不征收房租。
  if (housingCapacity(state, ctx) <= 0) return []

  const nonOwners = state.residents.filter((r) => !r.homeowner)
  if (nonOwners.length === 0) return []

  const total = round2(nonOwners.length * rent)
  for (const r of nonOwners) {
    r.savings = round2(Math.max(0, r.savings - rent))
  }
  state.government.money = round2(state.government.money + total)
  return [{ day, kind: 'finance', text: `征收房租 ¥${total}（国有住房 ${nonOwners.length} 人）` }]
}

/**
 * 私有住房市场：需求驱动。
 * 居民需同时满足「满意度 ≥ 门槛」与「存款 ≥ 售价」，且尚未拥有住房。
 */
export function runPrivateHousingMarket(
  state: GameState,
  ctx: ContentContext,
  day: number,
): LogEntry[] {
  const logs: LogEntry[] = []
  let soldTotal = 0

  for (const gid of ctx.pack.housing) {
    const price = state.prices[gid] ?? ALL_GOODS[gid]?.baseValue ?? 0
    if (price <= 0) continue

    let stateOwned = Math.floor((state.housing[gid] ?? 0) - (state.privateHousing[gid] ?? 0))
    let sold = 0

    while (stateOwned > 0 && soldTotal < ECONOMY.privateHousingPerDay) {
      let buyer: (typeof state.residents)[number] | undefined
      for (const r of state.residents) {
        if (r.homeowner) continue
        if (r.savings < price) continue
        if (r.satisfaction < ECONOMY.privateHousingNeedThreshold) continue
        if (!buyer || r.savings > buyer.savings) buyer = r
      }
      if (!buyer) break

      buyer.savings = round2(buyer.savings - price)
      buyer.homeowner = true
      state.government.money = round2(state.government.money + price)
      state.privateHousing[gid] = (state.privateHousing[gid] ?? 0) + 1
      stateOwned--
      sold++
      soldTotal++
    }

    if (sold > 0) {
      logs.push({ day, kind: 'invest', text: `${sold} 户购买私有住房（¥${price}/户）` })
    }
  }

  return logs
}
