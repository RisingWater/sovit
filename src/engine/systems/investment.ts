import type { GameState, LogEntry, Shop } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import type { BuildingDef } from '../types.ts'
import { DEFAULTS, ECONOMY } from '../config.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 投资：扩产 / 建店 / 建房 / 施工队列
//
// 施工在「夜晚」递减、在「次日黎明」完工启用（下次日 06:00 可用）。
// 建造成本优先使用「当前内容包内可获得的实物原料」；否则回退为金钱成本。
// ---------------------------------------------------------------------------

export function moneyCostExpand(level: number): number {
  return ECONOMY.expandMoneyBase * level
}

export function moneyCostBuild(tier: 1 | 2 | 3): number {
  return ECONOMY.buildMoneyByTier[tier]
}

/** 建筑成本中「当前内容包内可用」的实物原料。 */
function presentCost(def: BuildingDef, ctx: ContentContext): Array<[string, number]> {
  const out: Array<[string, number]> = []
  for (const [gid, qty] of Object.entries(def.buildCost ?? {})) {
    if (qty && ctx.goodSet.has(gid)) out.push([gid, qty])
  }
  return out
}

export interface AffordResult {
  ok: boolean
  reason?: string
}

/** 已占用的土地名额：建筑 + 在建(建店/建房) + 已建住房（升级不额外占地）。 */
export function usedSlots(state: GameState): number {
  let n = state.shops.length
  for (const c of state.construction) if (c.kind !== 'upgrade') n += 1
  for (const count of Object.values(state.housing)) n += Math.floor(count)
  return n
}

function nextConstructionId(state: GameState, tag: string): string {
  return `c#${state.construction.length + 1}-${tag}`
}

/** 扩产：+1 级；材料/资金立即扣除，次日黎明生效。 */
export function tryExpand(state: GameState, ctx: ContentContext, shopId: string): AffordResult {
  const shop = state.shops.find((s) => s.id === shopId)
  if (!shop) return { ok: false, reason: '建筑不存在' }
  const def = ctx.buildings[shop.defId]
  if (!def) return { ok: false, reason: '建筑定义缺失' }
  if (state.construction.some((c) => c.kind === 'upgrade' && c.shopId === shopId)) {
    return { ok: false, reason: '该建筑正在升级' }
  }

  const mats = presentCost(def, ctx)
  if (mats.length > 0) {
    const scale = shop.level
    for (const [gid, qty] of mats) {
      if ((state.goods[gid] ?? 0) < qty * scale) {
        return { ok: false, reason: `材料不足：${gid} 需 ${round2(qty * scale)}` }
      }
    }
    for (const [gid, qty] of mats) {
      state.goods[gid] = round2((state.goods[gid] ?? 0) - qty * scale)
    }
  } else {
    const cost = moneyCostExpand(shop.level)
    if (state.government.money < cost) {
      return { ok: false, reason: `资金不足（需 ¥${cost}）` }
    }
    state.government.money = round2(state.government.money - cost)
  }

  state.construction.push({
    id: nextConstructionId(state, `up-${shopId}`),
    kind: 'upgrade',
    shopId,
    buildingId: shop.defId,
    daysLeft: ECONOMY.constructionDays,
    totalDays: ECONOMY.constructionDays,
  })
  return { ok: true }
}

/** 建店：消耗实物原料或资金，进入施工队列（次日黎明启用）。 */
export function tryBuild(state: GameState, ctx: ContentContext, buildingId: string): AffordResult {
  if (!ctx.buildingSet.has(buildingId)) {
    return { ok: false, reason: '该建筑不在当前内容包内' }
  }
  const def = ctx.buildings[buildingId]
  if (!def) return { ok: false, reason: '建筑定义缺失' }

  if (usedSlots(state) >= ECONOMY.maxBuildingSlots) {
    return { ok: false, reason: '土地已满' }
  }

  const mats = presentCost(def, ctx)
  if (mats.length > 0) {
    for (const [gid, qty] of mats) {
      if ((state.goods[gid] ?? 0) < qty) {
        return { ok: false, reason: `材料不足：${gid} 需 ${qty}` }
      }
    }
    for (const [gid, qty] of mats) {
      state.goods[gid] = round2((state.goods[gid] ?? 0) - qty)
    }
  } else {
    const cost = moneyCostBuild(def.tier)
    if (state.government.money < cost) {
      return { ok: false, reason: `资金不足（需 ¥${cost}）` }
    }
    state.government.money = round2(state.government.money - cost)
  }

  state.construction.push({
    id: nextConstructionId(state, buildingId),
    kind: 'shop',
    buildingId,
    daysLeft: ECONOMY.constructionDays,
    totalDays: ECONOMY.constructionDays,
  })
  return { ok: true }
}

/** 建房：消耗实物材料并进入施工队列（次日黎明建成，提升人口上限）。 */
export function tryBuildHousing(state: GameState, ctx: ContentContext, goodId: string): AffordResult {
  if (!ctx.pack.housing.includes(goodId)) {
    return { ok: false, reason: '该住房不在当前内容包内' }
  }
  const def = ctx.housing[goodId]
  if (!def) return { ok: false, reason: '住房定义缺失' }

  if (usedSlots(state) >= ECONOMY.maxBuildingSlots) {
    return { ok: false, reason: '土地已满' }
  }

  const mats = Object.entries(def.buildCost ?? {}).filter(
    ([gid, qty]) => qty && ctx.goodSet.has(gid),
  ) as Array<[string, number]>
  for (const [gid, qty] of mats) {
    if ((state.goods[gid] ?? 0) < qty) {
      return { ok: false, reason: `材料不足：${gid} 需 ${qty}` }
    }
  }
  for (const [gid, qty] of mats) {
    state.goods[gid] = round2((state.goods[gid] ?? 0) - qty)
  }

  state.construction.push({
    id: nextConstructionId(state, `house-${goodId}`),
    kind: 'housing',
    housingId: goodId,
    daysLeft: ECONOMY.constructionDays,
    totalDays: ECONOMY.constructionDays,
  })
  return { ok: true }
}

/** 夜晚：施工进度 −1 天。 */
export function advanceConstruction(state: GameState): void {
  for (const c of state.construction) c.daysLeft -= 1
}

/** 黎明：完工的施工启用（建店 / 升级 / 建房）。 */
export function activateCompleted(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []
  const remaining = []
  for (const c of state.construction) {
    if (c.daysLeft > 0) {
      remaining.push(c)
      continue
    }
    if (c.kind === 'shop' && c.buildingId) {
      const def = ctx.buildings[c.buildingId]
      if (!def) continue
      const count = state.shops.filter((s) => s.defId === c.buildingId).length
      const shop: Shop = {
        id: `${c.buildingId}#${count + 1}`,
        defId: c.buildingId,
        owner: 'state',
        targetWorkers: def.workers,
        wage: ECONOMY.refWage,
        wageCap: ECONOMY.defaultWageCap,
        level: DEFAULTS.newShop.level,
        active: true,
        profit: 0,
        skill: DEFAULTS.newShop.skill,
        planned: 0,
      }
      state.shops.push(shop)
      logs.push({ day, kind: 'invest', text: `${def.nameZh} 建成投产` })
    } else if (c.kind === 'upgrade' && c.shopId) {
      const shop = state.shops.find((s) => s.id === c.shopId)
      if (shop) {
        shop.level += 1
        const def = ctx.buildings[shop.defId]
        logs.push({ day, kind: 'invest', text: `${def?.nameZh ?? shop.defId} 升级至 Lv${shop.level}` })
      }
    } else if (c.kind === 'housing' && c.housingId) {
      const def = ctx.housing[c.housingId]
      state.housing[c.housingId] = (state.housing[c.housingId] ?? 0) + 1
      logs.push({ day, kind: 'invest', text: `${def?.nameZh ?? c.housingId} 建成` })
    }
  }
  state.construction = remaining
  return logs
}
