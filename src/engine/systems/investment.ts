import type { Construction, GameState, LogEntry, Shop } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import type { BuildingDef } from '../types.ts'
import { DEFAULTS, ECONOMY, TUNING } from '../config.ts'
import { round2 } from '../util.ts'
import { markConstructionWorkers } from './labor.ts'
import { assignedWorkers } from './labor.ts'

// ---------------------------------------------------------------------------
// 投资：扩产 / 建店 / 建房 / 施工队列
//
// **建造力 = 每日施工产能（速率，不是库存）**，设计见 docs/construction.md：
//   每日产能 = 失业人口 × unemployedRate
//            + Σ(建筑工坊工人 × capacity.perWorker × (1 + levelBonus × (等级−1)) × 熟练度曲线)
//   一个工程需要「n 建造力」= n 个人·天，工期 = 需求量 ÷ 每日产能。
//   建造与升级共用一条**先进先出**队列，串行投入；当天没用完的产能作废（不结转）。
//
// 材料在**下单时只检查够不够**，**开工时才真正扣除**（排队 20 天不会把材料压死）；
// 开工时材料不足就停在队首等待，不跳过队列。
//
// 完工的工程在「次日黎明」启用（下次日 06:00 可用）。
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

/** 一个工程的开工成本：实物原料，或（无可用实物原料时）金钱。 */
interface CostSpec {
  mats: Array<[string, number]>
  money: number
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

/**
 * 某工程的开工成本。定义缺失时返回 null（内容已校验，正常不会发生）。
 * 扩产按「当前等级」放大实物原料 / 金钱。
 */
function costOf(c: Construction, state: GameState, ctx: ContentContext): CostSpec | null {
  if (c.kind === 'shop') {
    const def = c.buildingId ? ctx.buildings[c.buildingId] : undefined
    if (!def) return null
    const mats = presentCost(def, ctx)
    return mats.length > 0 ? { mats, money: 0 } : { mats: [], money: moneyCostBuild(def.tier) }
  }
  if (c.kind === 'upgrade') {
    const shop = state.shops.find((s) => s.id === c.shopId)
    const def = shop ? ctx.buildings[shop.defId] : undefined
    if (!shop || !def) return null
    const mats = presentCost(def, ctx)
    if (mats.length === 0) return { mats: [], money: moneyCostExpand(shop.level) }
    return { mats: mats.map(([g, q]) => [g, q * shop.level] as [string, number]), money: 0 }
  }
  if (c.kind === 'housing') {
    const def = c.housingId ? ctx.housing[c.housingId] : undefined
    if (!def) return null
    const mats = Object.entries(def.buildCost ?? {}).filter(
      ([gid, qty]) => qty && ctx.goodSet.has(gid),
    ) as Array<[string, number]>
    return { mats, money: 0 }
  }
  return null
}

function shortageReason(state: GameState, spec: CostSpec): string {
  for (const [gid, qty] of spec.mats) {
    if ((state.goods[gid] ?? 0) < qty) return `材料不足：${gid} 需 ${round2(qty)}`
  }
  if (state.government.money < spec.money) return `资金不足（需 ¥${spec.money}）`
  return '资源不足'
}

function canAfford(state: GameState, spec: CostSpec): boolean {
  for (const [gid, qty] of spec.mats) if ((state.goods[gid] ?? 0) < qty) return false
  return state.government.money >= spec.money
}

function payCost(state: GameState, spec: CostSpec): void {
  for (const [gid, qty] of spec.mats) {
    state.goods[gid] = round2((state.goods[gid] ?? 0) - qty)
  }
  if (spec.money > 0) state.government.money = round2(state.government.money - spec.money)
}

/** 工程的中文标签（日志用）。 */
function labelOf(c: Construction, ctx: ContentContext): string {
  if (c.kind === 'shop' && c.buildingId) return ctx.buildings[c.buildingId]?.nameZh ?? c.buildingId
  if (c.kind === 'housing' && c.housingId) return ctx.housing[c.housingId]?.nameZh ?? c.housingId
  if (c.kind === 'upgrade' && c.buildingId) {
    return `${ctx.buildings[c.buildingId]?.nameZh ?? c.buildingId} 升级`
  }
  return c.id
}

/**
 * 下单：只检查资源够不够并占住队列位，**不扣材料**（材料在开工时扣）。
 * 工期由 buildWork（建造力需求）决定，不再有固定天数。
 */
function order(
  state: GameState,
  ctx: ContentContext,
  c: Construction,
): AffordResult {
  const spec = costOf(c, state, ctx)
  if (!spec) return { ok: false, reason: '建筑定义缺失' }
  if (!canAfford(state, spec)) return { ok: false, reason: shortageReason(state, spec) }
  state.construction.push(c)
  return { ok: true }
}

/** 扩产：+1 级，进入施工队列，完工后次日黎明生效。 */
export function tryExpand(state: GameState, ctx: ContentContext, shopId: string): AffordResult {
  const shop = state.shops.find((s) => s.id === shopId)
  if (!shop) return { ok: false, reason: '建筑不存在' }
  const def = ctx.buildings[shop.defId]
  if (!def) return { ok: false, reason: '建筑定义缺失' }
  if (state.construction.some((c) => c.kind === 'upgrade' && c.shopId === shopId)) {
    return { ok: false, reason: '该建筑正在升级' }
  }

  // 升级工时：24 × 当前等级（见 docs/construction.md 三）
  const work = upgradeWork(shop.level)
  return order(state, ctx, {
    id: nextConstructionId(state, `up-${shopId}`),
    kind: 'upgrade',
    shopId,
    buildingId: shop.defId,
    remaining: work,
    totalRequired: work,
    started: false,
  })
}

/** 升级所需建造力：每 +1 级 = 24 × 当前等级。 */
export function upgradeWork(level: number): number {
  return ECONOMY.construction.upgradePerLevel * level
}

/** 建店：进入施工队列，材料在开工时扣（次日黎明启用）。 */
export function tryBuild(state: GameState, ctx: ContentContext, buildingId: string): AffordResult {
  if (!ctx.buildingSet.has(buildingId)) {
    return { ok: false, reason: '该建筑不在当前内容包内' }
  }
  const def = ctx.buildings[buildingId]
  if (!def) return { ok: false, reason: '建筑定义缺失' }

  if (usedSlots(state) >= ECONOMY.maxBuildingSlots) {
    return { ok: false, reason: '土地已满' }
  }

  return order(state, ctx, {
    id: nextConstructionId(state, buildingId),
    kind: 'shop',
    buildingId,
    remaining: def.buildWork,
    totalRequired: def.buildWork,
    started: false,
  })
}

/** 建房：进入施工队列，材料在开工时扣（次日黎明建成，提升人口上限）。 */
export function tryBuildHousing(state: GameState, ctx: ContentContext, goodId: string): AffordResult {
  if (!ctx.pack.housing.includes(goodId)) {
    return { ok: false, reason: '该住房不在当前内容包内' }
  }
  const def = ctx.housing[goodId]
  if (!def) return { ok: false, reason: '住房定义缺失' }

  if (usedSlots(state) >= ECONOMY.maxBuildingSlots) {
    return { ok: false, reason: '土地已满' }
  }

  return order(state, ctx, {
    id: nextConstructionId(state, `house-${goodId}`),
    kind: 'housing',
    housingId: goodId,
    remaining: def.buildWork,
    totalRequired: def.buildWork,
    started: false,
  })
}

/**
 * 该建筑是否某种产能来源（不产商品、只产每日产能）。见 docs/technology.md §6.2。
 */
export function isCapacityKind(def: BuildingDef, kind: 'build' | 'research'): boolean {
  return def.capacity?.kind === kind
}

/**
 * 当日施工产能（建造力 / 人·天）。
 *
 *   产能 = 失业人口 × construction.unemployedRate
 *        + Σ(建筑工坊在岗工人 × capacity.perWorker × (1 + levelBonus × (等级−1)) × 熟练度曲线)
 *
 * 熟练度曲线沿用产量那条（production.ts），不引入第二套熟练度语义。
 * 建筑工坊的 `perWorker` 取 2.5：新工坊熟练度 50 → 曲线 0.8 → `2.5 × 0.8 = 2.0`，
 * 正好「一人顶两个失业人口」。它的 `levelBonus` 是 0，所以升级不影响每人产能。
 */
export function constructionRate(state: GameState, ctx: ContentContext): number {
  const { unemployedRate } = ECONOMY.construction
  let rate = 0
  for (const r of state.residents) {
    if (!r.employed) rate += unemployedRate
  }
  for (const shop of state.shops) {
    const def = ctx.buildings[shop.defId]
    if (!def || !shop.active || !def.capacity || def.capacity.kind !== 'build') continue
    const skillEff = TUNING.skillEffectBase + TUNING.skillEffectSlope * (shop.skill / 100)
    const levelMul = 1 + def.capacity.levelBonus * (shop.level - 1)
    rate += assignedWorkers(state, shop.id) * def.capacity.perWorker * levelMul * skillEff
  }
  return round2(rate)
}

/**
 * 夜晚：把当日产能投入队首工程（先进先出，串行）。
 *
 * - 队首未开工 → 先扣材料；材料不足则停在队首等待，写日志，**不跳过**
 * - 产能没用完就溢给下一个工程；产能耗尽即停止
 * - 返回当日实际投入的建造力（人·天），并据此把相应失业人口标成「工地出工」
 */
export function settleConstruction(
  state: GameState,
  ctx: ContentContext,
  day: number,
): LogEntry[] {
  const logs: LogEntry[] = []
  let rate = constructionRate(state, ctx)
  let work = 0

  for (const c of state.construction) {
    if (rate <= 0) break

    if (!c.started) {
      const spec = costOf(c, state, ctx)
      if (!spec) {
        logs.push({ day, kind: 'invest', text: `${labelOf(c, ctx)} 定义缺失，施工停摆` })
        break
      }
      if (!canAfford(state, spec)) {
        logs.push({
          day,
          kind: 'invest',
          text: `${labelOf(c, ctx)} 等待材料（${shortageReason(state, spec)}）`,
        })
        break
      }
      payCost(state, spec)
      c.started = true
      logs.push({
        day,
        kind: 'invest',
        text: `${labelOf(c, ctx)} 开工（需建造力 ${round2(c.totalRequired)}）`,
      })
    }

    const used = Math.min(rate, c.remaining)
    c.remaining = round2(c.remaining - used)
    rate = round2(rate - used)
    work = round2(work + used)
  }

  // 当日出工的失业人口 → 建造工资（在当晚 payWages 里计发）
  markConstructionWorkers(state, work)
  return logs
}

/** 黎明：完工的施工启用（建店 / 升级 / 建房）。 */
export function activateCompleted(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []
  const remaining: Construction[] = []
  for (const c of state.construction) {
    if (c.remaining > 0) {
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
        toolBoost: 1,
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
