import type { GameState } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { TUNING } from '../config.ts'
import { assignedWorkers } from './labor.ts'
import { shopToolBoost } from './tools.ts'
import { buildingSectorBoost, techBonuses } from './tech_bonus.ts'
import { round2, round4 } from '../util.ts'

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

/**
 * 燃料的**取料顺序**（2026-10：地图上有了煤矿）。
 *
 * 以前燃料写死是木柴（`goods['firewood']`），有了煤之后两者都能烧：
 * **先煤、后木柴** —— 煤是矿里挖的，木柴要拿木材换，先烧煤更省。
 * 每座工坊在**黎明排产时**定下今天烧哪种（`shop.fuelGood`），然后全天不变 ——
 * 这样"排产按哪种燃料算批次"和"执行时扣哪种"永远是同一个答案。
 *
 * ⚠️ 与 GDScript `sim_core.gd::FUEL_ORDER` 必须同序（门槛 `coal` 钉着）。
 */
export const FUEL_ORDER: readonly string[] = ['coal', 'firewood']

/**
 * 给这座工坊挑今天烧的燃料：
 * 1. 按 `FUEL_ORDER` 找第一个**够用**的（`stock >= need`）
 * 2. 都不够 → 挑**存量最多**的那个（让排产按它打折，而不是直接摆烂）
 * 3. 这个内容包里一个都没有 → 返回空串（老内容包只有木柴时不会出问题）
 */
function pickFuel(state: GameState, need: number): string {
  let fallback = ''
  for (const gid of FUEL_ORDER) {
    if (!(gid in state.goods)) continue
    if ((state.goods[gid] ?? 0) + 1e-9 >= need) return gid
    if (fallback === '' || (state.goods[gid] ?? 0) > (state.goods[fallback] ?? 0)) fallback = gid
  }
  return fallback
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
    const recipe = def.recipe ? ctx.recipes[def.recipe] : undefined
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
      // 燃料按当天的存量挑（先煤后木柴），挑中的那个记在 shop 上，
      // 执行时（runProductionStep）照它扣 —— 排产与执行不会各说各话。
      const fuel = pickFuel(state, recipe.fuel * desired)
      shop.fuelGood = fuel === '' ? undefined : fuel
      if (fuel !== '') inputPer[fuel] = (inputPer[fuel] ?? 0) + recipe.fuel
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
  // 效率科技加成当日一次性取出（`state.research.done` 当天不会变，黎明才结算科技）。
  const tech = techBonuses(state, ctx)
  for (const shop of state.shops) {
    if (!shop.active || shop.planned <= 0) continue
    const def = ctx.buildings[shop.defId]
    if (!def) continue
    const recipe = def.recipe ? ctx.recipes[def.recipe] : undefined
    if (!recipe) continue

    const batches = shop.planned * fraction
    // 台账里的**来源拆分**（哪个建筑吃掉了它）：面板 tooltip 直接读这张表，
    // 所以必须在**真正扣料的这一处**累加（用户 2026-10："面粉都是面包房消耗"）。
    const addBy = (g: string, qty: number): void => {
      const by = (state.ledgerToday.consumedBy[g] ??= {})
      by[shop.defId] = round4((by[shop.defId] ?? 0) + qty)
    }
    for (const [g, q] of Object.entries(recipe.inputs)) {
      if (q && q > 0) {
        state.goods[g] = (state.goods[g] ?? 0) - q * batches
        state.reserved[g] = Math.max(0, (state.reserved[g] ?? 0) - q * batches)
        // 当日台账：实际工业消耗（小时累计）
        state.ledgerToday.consumed[g] = round4((state.ledgerToday.consumed[g] ?? 0) + q * batches)
        addBy(g, q * batches)
      }
    }
    if (recipe.fuel && recipe.fuel > 0) {
      // 烧黎明时挑好的那种燃料（老存档 / 老内容里没有 `fuelGood` → 回退木柴）
      const fuel = shop.fuelGood ?? 'firewood'
      state.goods[fuel] = (state.goods[fuel] ?? 0) - recipe.fuel * batches
      state.reserved[fuel] = Math.max(0, (state.reserved[fuel] ?? 0) - recipe.fuel * batches)
      state.ledgerToday.consumed[fuel] = round4((state.ledgerToday.consumed[fuel] ?? 0) + recipe.fuel * batches)
      addBy(fuel, recipe.fuel * batches)
    }
    // 只放大**产出**，投入（上面两段）完全不动 —— 这就是"虚空产量"。
    // 倍率 = 工具（+25%）× 该产业的效率科技加成（1 + techBonuses()[def.sector]），两者**相乘**；
    // 建筑没写 sector（无配方建筑不产商品，本来就到不了这里）则为 1。
    const boost = shopToolBoost(shop) * buildingSectorBoost(def, tech)
    for (const [g, q] of Object.entries(recipe.output)) {
      if (q && q > 0) {
        state.goods[g] = (state.goods[g] ?? 0) + q * batches * boost
        state.ledgerToday.produced[g] = round4((state.ledgerToday.produced[g] ?? 0) + q * batches * boost)
      }
    }
  }
}
