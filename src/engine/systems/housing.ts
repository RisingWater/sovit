import type { GameState, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { ECONOMY } from '../config.ts'
import { clamp, round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 住房系统
//
// - 国有住房：住户按人头向政府交租（租金玩家可调）。
// - 私有住房：最高层需求。居民在满意度达标且存款足够时，按玩家设定的价格
//   向政府购买住房，成为房主（房东）；房客向房主交租。
// - 私有住房提升居住者满意度（房主 > 房客 > 国有住户）。
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

/**
 * 分配住房占用（按人）：
 * - 房主（已购房）占用私有住房名额；
 * - 其余私有住房名额分配给非房主作为房客（优先满意度高者）；
 * - 剩余居民为国有住房住户。
 */
export function assignTenure(state: GameState, ctx: ContentContext): void {
  for (const r of state.residents) r.privateTenant = false
  const owners = state.residents.filter((r) => r.homeowner).length
  let tenantSlots = Math.max(0, privateCapacity(state, ctx) - owners)

  const candidates = state.residents
    .filter((r) => !r.homeowner)
    .sort((a, b) => b.satisfaction - a.satisfaction)
  for (const r of candidates) {
    if (tenantSlots <= 0) break
    r.privateTenant = true
    tenantSlots--
  }
}

/**
 * 征收租金：
 * - 国有住房住户 → 全额交给政府；
 * - 私有住房房客 → 交给房主，但**租金收入同样征所得税**（与工资同税率），
 *   税款归政府，余额分给房主。这样堵住「租金退出政府循环」的赤字漏点。
 * 住户交租以存款为限（不足则拖欠，不产生负储蓄）。
 */
export function collectRent(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const rent = state.government.rent
  if (rent <= 0 || state.residents.length === 0) return []
  if (housingCapacity(state, ctx) <= 0) return []

  const owners = state.residents.filter((r) => r.homeowner)
  const privateTenants = state.residents.filter((r) => r.privateTenant && !r.homeowner)
  const stateTenants = state.residents.filter((r) => !r.homeowner && !r.privateTenant)

  let govTotal = 0
  for (const r of stateTenants) {
    const pay = Math.min(rent, r.savings)
    r.savings = round2(r.savings - pay)
    govTotal += pay
  }

  let privateTotal = 0
  for (const r of privateTenants) {
    const pay = Math.min(rent, r.savings)
    r.savings = round2(r.savings - pay)
    privateTotal += pay
  }

  const taxRate = clamp(state.government.taxRate, 0, 0.95)
  const rentTax = round2(privateTotal * taxRate)
  const netToOwners = round2(privateTotal - rentTax)
  if (owners.length > 0 && netToOwners > 0) {
    const share = netToOwners / owners.length
    for (const o of owners) o.savings = round2(o.savings + share)
  }

  state.government.money = round2(state.government.money + govTotal + rentTax)
  const logs: LogEntry[] = []
  if (govTotal > 0.01) {
    logs.push({ day, kind: 'finance', text: `国有住房租金 ¥${round2(govTotal)}（${stateTenants.length} 人）` })
  }
  if (privateTotal > 0.01) {
    logs.push({
      day,
      kind: 'finance',
      text: `私有住房租金 ¥${round2(privateTotal)}：房东得 ¥${netToOwners}，租金所得税 ¥${rentTax}`,
    })
  }
  return logs
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
