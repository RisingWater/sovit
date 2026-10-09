import type { ClassID, GameState, LogEntry } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { ECONOMY } from '../config.ts'
import { clamp, round2 } from '../util.ts'
import { progressiveTax } from './finance.ts'

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
 * 分配住房占用（按人、按阶层）：
 * - 房主占用自己名下的住房（等级 = ownedQuality）；
 * - 其余名额先私有后国有、从高等级往下分配，优先满足高阶层；
 * - `housingQuality` 记录每名居民实际居住等级，用于满意度（阶层需住对应等级）。
 */
export function assignTenure(state: GameState, ctx: ContentContext): void {
  for (const r of state.residents) {
    r.privateTenant = false
    r.housingQuality = r.homeowner ? r.ownedQuality ?? 1 : 0
  }

  const ownerByQuality: Record<number, number> = { 1: 0, 2: 0, 3: 0 }
  for (const r of state.residents) {
    if (r.homeowner) {
      const q = r.ownedQuality ?? 1
      ownerByQuality[q] = (ownerByQuality[q] ?? 0) + 1
    }
  }

  const privateSlots: Record<number, number> = { 1: 0, 2: 0, 3: 0 }
  const stateSlots: Record<number, number> = { 1: 0, 2: 0, 3: 0 }
  for (const [gid, count] of Object.entries(state.housing)) {
    const def = ctx.housing[gid]
    if (!def) continue
    const n = Math.floor(count)
    const priv = Math.min(n, Math.floor(state.privateHousing[gid] ?? 0))
    privateSlots[def.quality] = (privateSlots[def.quality] ?? 0) + priv * def.capacity
    stateSlots[def.quality] = (stateSlots[def.quality] ?? 0) + (n - priv) * def.capacity
  }
  for (let q = 1; q <= 3; q++) {
    privateSlots[q] = Math.max(0, (privateSlots[q] ?? 0) - (ownerByQuality[q] ?? 0))
  }

  const order: ClassID[] = ['poor', 'middle', 'rich', 'boss']
  const tenants = state.residents
    .filter((r) => !r.homeowner)
    .sort((a, b) => order.indexOf(b.classId) - order.indexOf(a.classId))

  for (const r of tenants) {
    let assigned = false
    for (let q = 3; q >= 1 && !assigned; q--) {
      if ((privateSlots[q] ?? 0) > 0) {
        privateSlots[q] = privateSlots[q]! - 1
        r.privateTenant = true
        r.housingQuality = q
        assigned = true
      }
    }
    for (let q = 3; q >= 1 && !assigned; q--) {
      if ((stateSlots[q] ?? 0) > 0) {
        stateSlots[q] = stateSlots[q]! - 1
        r.housingQuality = q
        assigned = true
      }
    }
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

  const baseRate = clamp(state.government.taxRate, 0, 0.95)
  const grossShare = owners.length > 0 ? privateTotal / owners.length : 0
  const taxPerOwner = owners.length > 0 ? progressiveTax(grossShare, baseRate) : 0
  const rentTax = round2(taxPerOwner * owners.length)
  const netShare = round2(grossShare - taxPerOwner)
  if (owners.length > 0 && netShare > 0) {
    for (const o of owners) o.savings = round2(o.savings + netShare)
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
      text: `私有住房租金 ¥${round2(privateTotal)}：房东得 ¥${round2(netShare * owners.length)}，租金累进税 ¥${rentTax}`,
    })
  }
  return logs
}

/**
 * 私有住房市场：需求驱动，分层。
 * 只有 **中产及以上** 才能购买；且只能购买与本阶层要求等级对应的住房
 * （中产→木屋，富/老板→砖房）。穷人只住国有住房。
 */
export function runPrivateHousingMarket(
  state: GameState,
  ctx: ContentContext,
  day: number,
): LogEntry[] {
  const logs: LogEntry[] = []
  let soldTotal = 0

  for (const gid of ctx.pack.housing) {
    const def = ctx.housing[gid]
    if (!def) continue
    const price = state.prices[gid] ?? def.salePrice ?? ALL_GOODS[gid]?.baseValue ?? 0
    if (price <= 0) continue

    let stateOwned = Math.floor((state.housing[gid] ?? 0) - (state.privateHousing[gid] ?? 0))
    let sold = 0

    while (stateOwned > 0 && soldTotal < ECONOMY.privateHousingPerDay) {
      let buyer: (typeof state.residents)[number] | undefined
      for (const r of state.residents) {
        if (r.homeowner) continue
        if (r.classId === 'poor') continue // 只有中产及以上才会私有化
        if (ECONOMY.classHousingLevel[r.classId] !== def.quality) continue // 对应等级住房
        if (r.savings < price) continue
        if (r.satisfaction < ECONOMY.privateHousingNeedThreshold) continue
        if (!buyer || r.savings > buyer.savings) buyer = r
      }
      if (!buyer) break

      buyer.savings = round2(buyer.savings - price)
      buyer.homeowner = true
      buyer.ownedQuality = def.quality
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
