import type { GameState, LogEntry, Shop } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ECONOMY } from '../config.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 投资：扩产 / 建店 / 施工队列
// ---------------------------------------------------------------------------

export function moneyCostExpand(level: number): number {
  return ECONOMY.expandMoneyBase * level
}

export function moneyCostBuild(tier: 1 | 2 | 3): number {
  return ECONOMY.buildMoneyByTier[tier]
}

export interface AffordResult {
  ok: boolean
  reason?: string
}

/** 扩产：立即消耗资金并 +1 等级。 */
export function tryExpand(state: GameState, ctx: ContentContext, shopId: string): AffordResult {
  const shop = state.shops.find((s) => s.id === shopId)
  if (!shop) return { ok: false, reason: '建筑不存在' }
  const def = ctx.buildings[shop.defId]
  if (!def) return { ok: false, reason: '建筑定义缺失' }
  const cost = moneyCostExpand(shop.level)
  if (state.government.money < cost) {
    return { ok: false, reason: `资金不足（需 ¥${cost}）` }
  }
  state.government.money = round2(state.government.money - cost)
  shop.level += 1
  return { ok: true }
}

/** 建店：扣资金 + 材料，进入施工队列。 */
export function tryBuild(state: GameState, ctx: ContentContext, buildingId: string): AffordResult {
  if (!ctx.buildingSet.has(buildingId)) {
    return { ok: false, reason: '该建筑不在当前内容包内' }
  }
  const def = ctx.buildings[buildingId]
  if (!def) return { ok: false, reason: '建筑定义缺失' }

  const cost = moneyCostBuild(def.tier)
  if (state.government.money < cost) {
    return { ok: false, reason: `资金不足（需 ¥${cost}）` }
  }

  const materials = def.buildCost ?? {}
  for (const [gid, qty] of Object.entries(materials)) {
    if (!qty || !ctx.goodSet.has(gid)) continue
    if ((state.goods[gid] ?? 0) < qty) {
      return { ok: false, reason: `材料不足：${gid} 需 ${qty}` }
    }
  }

  state.government.money = round2(state.government.money - cost)
  for (const [gid, qty] of Object.entries(materials)) {
    if (!qty || !ctx.goodSet.has(gid)) continue
    state.goods[gid] = round2((state.goods[gid] ?? 0) - qty)
  }

  state.construction.push({
    id: `c#${state.construction.length + 1}-${buildingId}`,
    buildingId,
    daysLeft: ECONOMY.constructionDays,
    totalDays: ECONOMY.constructionDays,
  })
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
      level: 1,
      active: true,
      profit: 0,
      skill: 50,
    }
    state.shops.push(shop)
    logs.push({ day, kind: 'invest', text: `${def.nameZh} 建成投产` })
  }
  state.construction = remaining
  return logs
}
