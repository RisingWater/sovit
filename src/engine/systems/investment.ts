import type { GameState, LogEntry, Shop } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import type { BuildingDef } from '../types.ts'
import { DEFAULTS, ECONOMY } from '../config.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 投资：扩产 / 建店 / 施工队列
//
// 建造成本优先使用「当前内容包内可获得的实物原料」（buildCost 中存在的商品）；
// 若该建筑的成本全是包外商品，则回退为金钱成本。
// 这样 v0.1（纯货币）与 v0.2（建材链驱动）能共用同一套逻辑。
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

/** 已占用的土地名额：建筑 + 在建 + 已建住房。 */
export function usedSlots(state: GameState): number {
  let n = state.shops.length + state.construction.length
  for (const count of Object.values(state.housing)) n += Math.floor(count)
  return n
}

/** 扩产：+1 等级。消耗实物原料；无可用原料时改用资金。 */
export function tryExpand(state: GameState, ctx: ContentContext, shopId: string): AffordResult {
  const shop = state.shops.find((s) => s.id === shopId)
  if (!shop) return { ok: false, reason: '建筑不存在' }
  const def = ctx.buildings[shop.defId]
  if (!def) return { ok: false, reason: '建筑定义缺失' }

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
  shop.level += 1
  return { ok: true }
}

/** 建店：消耗实物原料或资金，进入施工队列。 */
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
    id: `c#${state.construction.length + 1}-${buildingId}`,
    buildingId,
    daysLeft: ECONOMY.constructionDays,
    totalDays: ECONOMY.constructionDays,
  })
  return { ok: true }
}

/**
 * 建造住房：消耗实物材料并占用一个土地名额，直接提升人口上限。
 * 住房是人口增长的最终瓶颈，受土地上限约束。
 */
export function tryBuildHousing(
  state: GameState,
  ctx: ContentContext,
  goodId: string,
): AffordResult {
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
  state.housing[goodId] = (state.housing[goodId] ?? 0) + 1
  return { ok: true }
}

export function processConstruction(
  state: GameState,
  ctx: ContentContext,
  day: number,
): LogEntry[] {
  const logs: LogEntry[] = []
  const remaining = []
  for (const c of state.construction) {
    c.daysLeft -= 1
    if (c.daysLeft > 0) {
      remaining.push(c)
      continue
    }
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
    }
    state.shops.push(shop)
    logs.push({ day, kind: 'invest', text: `${def.nameZh} 建成投产` })
  }
  state.construction = remaining
  return logs
}
