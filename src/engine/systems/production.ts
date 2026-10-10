import type { GameState } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { TUNING } from '../config.ts'
import { assignedWorkers } from './labor.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 生产（两阶段 · 公平配给 · 日计划 + 小时执行）
//
// 黎明 planProduction：算出各建筑今日批次（按日初库存两阶段公平配给）。
// 白天 runProductionStep：每小执行 计划 × fraction（消耗原料、产出）。
//
// 说明：白天执行不再 round，保持浮点精度（否则 12 次舍入会累积误差）。
// ---------------------------------------------------------------------------

function goodValue(gid: string, qty: number): number {
  return (ALL_GOODS[gid]?.baseValue ?? 0) * qty
}

/** 损耗：非耐储商品每日按 perishRate 折损（服务 perishRate=1 → 当天不结转）。 */
export function applySpoilage(state: GameState, ctx: ContentContext): void {
  for (const gid of ctx.pack.goods) {
    const def = ALL_GOODS[gid]
    if (!def || !def.perishRate || def.perishRate <= 0) continue
    const cur = state.goods[gid] ?? 0
    if (cur <= 0) continue
    state.goods[gid] = round2(cur * (1 - Math.min(1, def.perishRate)))
  }
}

interface Item {
  shop: GameState['shops'][number]
  desired: number
  inputPer: Record<string, number>
  output: Record<string, number>
}

/** 黎明排产：两阶段公平配给，写入 shop.planned 与 shop.profit。 */
export function planProduction(state: GameState, ctx: ContentContext): void {
  for (const shop of state.shops) shop.planned = 0

  const items: Item[] = []
  const demand: Record<string, number> = {}
  const reserved: Record<string, number> = {}

  for (const shop of state.shops) {
    if (!shop.active) continue
    const def = ctx.buildings[shop.defId]
    if (!def) continue
    const recipe = ctx.recipes[def.recipe]
    if (!recipe) continue
    const workers = assignedWorkers(state, shop.id)
    if (workers <= 0) continue

    const staffing = workers / def.workers // 不封顶：工坊多派人就多产
    const skillEff = TUNING.skillEffectBase + TUNING.skillEffectSlope * (shop.skill / 100)
    const desired = recipe.baseRate * staffing * skillEff * shop.level
    if (desired <= 0) continue

    const inputPer: Record<string, number> = {}
    for (const [g, q] of Object.entries(recipe.inputs)) {
      if (q && q > 0) inputPer[g] = (inputPer[g] ?? 0) + q
    }
    if (recipe.fuel && recipe.fuel > 0) {
      inputPer['firewood'] = (inputPer['firewood'] ?? 0) + recipe.fuel
    }

    items.push({ shop, desired, inputPer, output: recipe.output as Record<string, number> })
    for (const [g, q] of Object.entries(inputPer)) {
      demand[g] = (demand[g] ?? 0) + q * desired
    }
  }

  const factor: Record<string, number> = {}
  for (const g of Object.keys(demand)) {
    const avail = state.goods[g] ?? 0
    factor[g] = demand[g]! > 0 ? Math.min(1, avail / demand[g]!) : 1
  }

  for (const it of items) {
    let f = 1
    for (const g of Object.keys(it.inputPer)) f = Math.min(f, factor[g] ?? 1)
    const planned = it.desired * f
    it.shop.planned = planned
    for (const [g, q] of Object.entries(it.inputPer)) {
      reserved[g] = (reserved[g] ?? 0) + q * planned
    }

    let outVal = 0
    for (const [g, q] of Object.entries(it.output)) if (q) outVal += goodValue(g, q * planned)
    let inVal = 0
    for (const [g, q] of Object.entries(it.inputPer)) inVal += goodValue(g, q * planned)
    const wages = assignedWorkers(state, it.shop.id) * it.shop.wage
    it.shop.profit = round2(outVal - inVal - wages)
  }

  state.reserved = reserved
}

/** 白天按小时执行今日计划的一部分（fraction = 1 / 工作小时数）。 */
export function runProductionStep(state: GameState, ctx: ContentContext, fraction: number): void {
  for (const shop of state.shops) {
    if (!shop.active || shop.planned <= 0) continue
    const def = ctx.buildings[shop.defId]
    if (!def) continue
    const recipe = ctx.recipes[def.recipe]
    if (!recipe) continue

    const batches = shop.planned * fraction
    for (const [g, q] of Object.entries(recipe.inputs)) {
      if (q && q > 0) {
        state.goods[g] = (state.goods[g] ?? 0) - q * batches
        state.reserved[g] = Math.max(0, (state.reserved[g] ?? 0) - q * batches)
      }
    }
    if (recipe.fuel && recipe.fuel > 0) {
      state.goods['firewood'] = (state.goods['firewood'] ?? 0) - recipe.fuel * batches
      state.reserved['firewood'] = Math.max(0, (state.reserved['firewood'] ?? 0) - recipe.fuel * batches)
    }
    for (const [g, q] of Object.entries(recipe.output)) {
      if (q && q > 0) state.goods[g] = (state.goods[g] ?? 0) + q * batches
    }
  }
}
