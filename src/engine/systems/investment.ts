import type { Construction, GameState, LogEntry, Shop } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import type { BuildingDef, HousingDef } from '../types.ts'
import { DEFAULTS, ECONOMY, TUNING } from '../config.ts'
import { round2, round4 } from '../util.ts'
import { markConstructionWorkers } from './labor.ts'
import { assignedWorkers } from './labor.ts'
import { effectiveSlots } from './labor.ts'
import { techBonuses } from './tech_bonus.ts'

// ---------------------------------------------------------------------------
// 投资：扩产 / 建店 / 建房 / 施工队列
//
// **建造力 = 每日施工产能（速率，不是库存）**，设计见 docs/construction.md：
//   每日产能 = 失业人口 × unemployedRate
//            + Σ(建筑工坊工人 × capacity.perWorker × (1 + levelBonus × (等级−1)) × 熟练度曲线)
//   一个工程需要「n 建造力」= n 个人·天，工期 = 需求量 ÷ 每日产能。
//   建造与升级共用一条**先进先出**队列，串行投入；当天没用完的产能作废（不结转）。
//
// **白天**在工作小时里按小时投入（`applyConstructionHours`，与生产同一节奏）：
//   每小时的量 = **黎明钉住的当日建造力**（`constructionRateToday`）÷ 工作小时数，
//   一眼能在工地上看见进度在爬；一天的总额仍是 产能（不结转）。
// **黎明**只做一件事（`planConstructionDay`）：把这个预算钉死，全天不再现算。
// **夜晚**只做收尾（`settleConstruction`）：诊断队首为什么没动 + 把当日累计投入
//   折成工地出工的建造工资。
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
export interface CostSpec {
  mats: Array<[string, number]>
  money: number
}

/**
 * 查询某个工程的开工成本（门槛与 UI 用；真正下单走 `order()` 里那一份）。
 * 对外暴露是为了让自检能验"引擎算出来的成本"，而不是只验公式助手。
 */
export function constructionCost(
  c: Construction,
  state: GameState,
  ctx: ContentContext,
): CostSpec | null {
  return costOf(c, state, ctx)
}

/** 已占用的土地名额：建筑 + 在建(建店/建房) + 已建住房（升级/住房改建不额外占地）。 */
export function usedSlots(state: GameState): number {
  let n = state.shops.length
  // ⚠️ `housing_upgrade` 是"原地改建"：改完 housing[from]−1 / housing[to]+1，总栋数不变，
  //    所以它**不能**算成一个新名额（否则改建一次就白白吃掉一格土地）。
  for (const c of state.construction) if (c.kind !== 'upgrade' && c.kind !== 'housing_upgrade') n += 1
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
  if (c.kind === 'housing_upgrade') {
    const from = c.housingId ? ctx.housing[c.housingId] : undefined
    const to = c.toHousingId ? ctx.housing[c.toHousingId] : undefined
    if (!from || !to) return null
    const spec = housingUpgradeSpec(from, to, ctx)
    return { mats: spec.mats, money: 0 }
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
  if (c.kind === 'housing_upgrade' && c.housingId) {
    const a = ctx.housing[c.housingId]?.nameZh ?? c.housingId
    const b = c.toHousingId ? (ctx.housing[c.toHousingId]?.nameZh ?? c.toHousingId) : '?'
    return `${a} 改建（→ ${b}）`
  }
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

/**
 * 住房**改建**（见 docs/spec.md §5.4）的材料与工期：**只算差价**。
 *
 * - 材料：对目标房型 `buildCost` 的每一项取 `max(0, 目标 − 原房型)`，只认当前包里的商品；
 *   原房型要、目标不要的材料（砖房要石头、木屋不要）**不退**。
 * - 工期：`max(1, 目标 buildWork − 原房型 buildWork)` —— 至少 1，免得出现"零工时秒改"。
 *
 * ⚠️ TS 与 GDScript 两份实现必须同口径（门槛 `housingupgrade` 拿真实数字对拍）。
 */
export function housingUpgradeSpec(
  from: HousingDef,
  to: HousingDef,
  ctx: ContentContext,
): { mats: Array<[string, number]>; work: number } {
  const mats: Array<[string, number]> = []
  for (const [gid, qty] of Object.entries(to.buildCost ?? {})) {
    if (!qty || !ctx.goodSet.has(gid)) continue
    const diff = round2(qty - (from.buildCost?.[gid] ?? 0))
    if (diff > 0) mats.push([gid, diff])
  }
  return { mats, work: Math.max(1, round2(to.buildWork - from.buildWork)) }
}

/**
 * 住房改建：下单进施工队列（材料在开工时才扣）。
 *
 * ⚠️ **只允许改建国有住房**：私有住房是居民买下的私产，改建会牵动 `privateHousing[gid]`
 * 和房主的 `ownedQuality`，口径复杂且容易算乱（用户拍板：私有住房不能改建）。
 * 在途的改建也算占用 —— 否则 2 栋茅屋能排 3 条改建，完工时凭空多出一栋木屋。
 */
export function tryUpgradeHousing(
  state: GameState,
  ctx: ContentContext,
  goodId: string,
): AffordResult {
  if (!ctx.pack.housing.includes(goodId)) {
    return { ok: false, reason: '该住房不在当前内容包内' }
  }
  const from = ctx.housing[goodId]
  if (!from) return { ok: false, reason: '住房定义缺失' }
  const toId = from.upgradeTo
  if (!toId) return { ok: false, reason: '这档住房不能改建' }
  const to = ctx.housing[toId]
  if (!to) return { ok: false, reason: '改建目标缺失' }

  const total = Math.floor(state.housing[goodId] ?? 0)
  const priv = Math.floor(state.privateHousing[goodId] ?? 0)
  const inFlight = state.construction.filter(
    (c) => c.kind === 'housing_upgrade' && c.housingId === goodId,
  ).length
  if (total - priv - inFlight < 1) {
    return {
      ok: false,
      reason: total - priv <= 0 ? '私有住房不能改建' : '没有空闲的国有住房可改建',
    }
  }

  const spec = housingUpgradeSpec(from, to, ctx)
  return order(state, ctx, {
    id: nextConstructionId(state, `re-${goodId}`),
    kind: 'housing_upgrade',
    housingId: goodId,
    toHousingId: toId,
    remaining: spec.work,
    totalRequired: spec.work,
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

// ---------------------------------------------------------------------------
// 修缮城镇中心（用户 2026-10：一开局那座城镇中心是废墟）
// ---------------------------------------------------------------------------

/**
 * 修缮价：木 30 + 石 20 + 砖 15。
 *
 * ⚠️ 这是**唯一一份**价格：判定够不够、面板上列材料都走它。
 * 内容里 `q10f_townhall_repair.hint` 那句「消耗木材 30 + 石块 20 + 砖 15」是**文字**，
 * 改价时只能人肉对齐（`check-quests.ts` 里有一条把两边对上的断言）。
 */
export const TOWN_CENTER_REPAIR_COST: Record<string, number> = { wood: 30, stone: 20, brick: 15 }

/**
 * 修缮城镇中心：扣料 + 把 `townCenter.ruined` 翻成 `false`。
 *
 * 材料不够就白下这一单（不扣东西、不发钱）—— 面板上把价写清楚了。
 * ⚠️ 真正的"看上去修好了"要等**黎明**：任务 `q10f_townhall_repair` 黎明结算、
 * 表现层认的是那条任务，不是这个标记（见 `docs/quests.md` §六）。
 */
export function repairTownCenter(state: GameState): AffordResult {
  if (!state.townCenter.ruined) return { ok: false, reason: '城镇中心已经修好了' }
  for (const [gid, qty] of Object.entries(TOWN_CENTER_REPAIR_COST)) {
    if ((state.goods[gid] ?? 0) + 1e-9 < qty) return { ok: false, reason: '材料不够' }
  }
  for (const [gid, qty] of Object.entries(TOWN_CENTER_REPAIR_COST)) {
    state.goods[gid] = round2((state.goods[gid] ?? 0) - qty)
  }
  state.townCenter.ruined = false
  return { ok: true }
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
 *
 * 效率科技（起重架 / 脚手架 / 预制件）把**整条速率**乘 (1 + effects.build)，
 * 见 docs/spec.md §9.1。
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
  // 效率科技：**整条返回值**乘 (1 + 加成) —— 失业人口那一项也一起放大。
  rate *= 1 + techBonuses(state, ctx).build
  return round2(rate)
}

/**
 * 黎明：钉死**当日建造力预算**。
 *
 * 为什么要有它（与 `planResearchDay` 是同一道闸，不是为了好看）：
 * 施工的账是按"这一天投了多少"（`constructionWorkToday`）记的，如果每个工作小时
 * 都现算一次 `constructionRate()`，"一天总量 = 当日建造力"这件事就押在
 * "同一天里 `constructionRate()` 不变"这个**隐含前提**上 —— 而它取决于失业人口
 * 与建筑工坊的在岗人数（黎明 `assignLabor` 之外，任何中途的人事变动都会当场
 * 改变现算值，当天的总量就不再是"今天有多少建造力"）。
 * 钉死之后，"当天的总量恰好等于黎明那一刻的建造力"是一条**硬闸**，没有隐含前提。
 *
 * 口径：**一天的预算 = 这一天黎明那一刻的 `constructionRate`**，全天不变
 * （与"产能不结转、当天没用完即作废"同一精神）。
 */
export function planConstructionDay(state: GameState, ctx: ContentContext): void {
  state.constructionWorkToday = 0
  state.constructionRateToday = constructionRate(state, ctx)
}

/**
 * 工作小时：把**固定的一份**建造力（`constructionRateToday × fraction`）投入队首工程。
 *
 * 与 `runProductionStep` **同一节奏、同一条件**（`workStart <= h < workEnd`，
 * fraction = 1/工作小时数），所以"一天 = 当日建造力（黎明钉住的值）"这个总量不变，
 * 只是摊平到 12 个工作小时里 —— 工地上白天能看见进度在爬。
 *
 * **每小时投入量是个常数**（`constructionRateToday / 工作小时数`），起手就不现算
 * `constructionRate()`：当天中途的人事变动（在岗人数 / 失业人口）不会动摇今天的量。
 *
 * 队列语义与从前逐字一致（先进先出、串行）：
 * - 队首未开工 → 先扣材料（**开工时刻 = 这一天第一个工作小时**）；
 *   材料不足则停在队首等待，**不跳过**（这条是契约）
 * - 产能没用完就溢给下一个工程；产能耗尽即停止
 * - 一天里每个工程可以只被投一点，所以 `remaining` 用 **r4** 累积：
 *   12 次 r2 会漂移（一天就不再恰好等于 constructionRate）
 * - 日志：`开工（需建造力 N）` 只在 `started` 翻转时写一次；「等待材料」的诊断
 *   留给夜晚（`settleConstruction`，每天最多一条），这里不刷屏
 */
export function applyConstructionHours(
  state: GameState,
  ctx: ContentContext,
  fraction: number,
): LogEntry[] {
  const logs: LogEntry[] = []
  // rate 是「这一个小时里的产能」：**黎明钉住的当日预算** × 这一份，不取整
  // （取整会让 12 小时加起来不等于日产能），只有落进状态的两处
  // （remaining / 当日累计）用 r4。
  // ⚠️ 用 `??` 而不是裸读：旧存档（或手搓的状态）没有这个键时，
  // 裸读会让 rate 变成 NaN，进而绕过"一天总量不变"这道闸。
  let rate = (state.constructionRateToday ?? 0) * fraction
  let work = 0

  for (const c of state.construction) {
    if (rate <= 0) break

    if (!c.started) {
      const spec = costOf(c, state, ctx)
      if (!spec) break // 定义缺失：夜晚写诊断，这里不刷屏
      if (!canAfford(state, spec)) break // 停在队首等待材料，**不跳过**
      payCost(state, spec)
      c.started = true
      logs.push({
        day: state.day,
        kind: 'invest',
        text: `${labelOf(c, ctx)} 开工（需建造力 ${round2(c.totalRequired)}）`,
      })
    }

    const used = Math.min(rate, c.remaining)
    c.remaining = round4(c.remaining - used)
    rate -= used
    work += used
  }

  // 当日累计投入：入夜时一次性折成「工地出工」（markConstructionWorkers）
  state.constructionWorkToday = round4(state.constructionWorkToday + work)
  return logs
}

/**
 * 夜晚：施工的**收尾**（产能已经在工作小时里按小时投完了，见 `applyConstructionHours`）。
 *
 * 只做两件事：
 * 1. 队首为什么没动 —— 写一条诊断（每天最多一条）。白天每小时都可能撞上材料不足，
 *    日志若写在小时里会刷 12 条屏，所以挪到这里。
 *    诊断对象是**第一条未开工**的工程，且它前面不能有"已开工但没干完"的工程
 *    （那说明产能是被前面的工程正常吃掉的，不是卡住）
 * 2. 把当日累计投入的建造力折成「工地出工」的失业人口（建造工资，在 `payWages` 之前）
 *    —— 顺序不能动：它决定当晚多少人算就业、领建造工资
 */
export function settleConstruction(
  state: GameState,
  ctx: ContentContext,
  day: number,
): LogEntry[] {
  const logs: LogEntry[] = []

  // 产能为 0 时队首本来就没机会开工（不是材料的问题），与旧口径一致：不写诊断
  if (constructionRate(state, ctx) > 0) {
    let blocked: Construction | null = null
    for (const c of state.construction) {
      if (!c.started) {
        blocked = c // 卡住的是**第一条未开工**的工程
        break
      }
      // 前面那几条已开工、还没干完 —— 今天的产能是被它们吃掉的，不是材料的问题，
      // 别误报"等待材料"（旧口径：产能耗尽就先 break 了，根本走不到后面那条）
      if (c.remaining > 0) break
    }
    if (blocked) {
      const spec = costOf(blocked, state, ctx)
      if (!spec) {
        logs.push({ day, kind: 'invest', text: `${labelOf(blocked, ctx)} 定义缺失，施工停摆` })
      } else if (!canAfford(state, spec)) {
        logs.push({
          day,
          kind: 'invest',
          text: `${labelOf(blocked, ctx)} 等待材料（${shortageReason(state, spec)}）`,
        })
      }
    }
  }

  markConstructionWorkers(state, state.constructionWorkToday)
  state.constructionWorkToday = 0
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
        const def = ctx.buildings[shop.defId]
        // 升级会改变**有效工位数**（capacity.slotsPerLevel），用工目标要跟着走：
        //   改之前是满员 → 改完仍然满员
        //   改之前不是满员 → **保留原来的绝对数字**（不按比例缩放）
        // 不减这一手的话，研究所从 L1 升到 L2 会"自动少 3 个工位"，
        // 玩家看着莫名其妙。
        const before = def ? effectiveSlots(def, shop.level) : 0
        const wasFull = shop.targetWorkers >= before
        shop.level += 1
        if (def && wasFull) shop.targetWorkers = effectiveSlots(def, shop.level)
        logs.push({ day, kind: 'invest', text: `${def?.nameZh ?? shop.defId} 升级至 Lv${shop.level}` })
      }
    } else if (c.kind === 'housing' && c.housingId) {
      const def = ctx.housing[c.housingId]
      state.housing[c.housingId] = (state.housing[c.housingId] ?? 0) + 1
      logs.push({ day, kind: 'invest', text: `${def?.nameZh ?? c.housingId} 建成` })
    } else if (c.kind === 'housing_upgrade' && c.housingId && c.toHousingId) {
      // 原地改建：栋数不变，只是从 from 挪到 to（土地名额因此也不变，见 usedSlots）。
      const from = ctx.housing[c.housingId]
      const to = ctx.housing[c.toHousingId]
      state.housing[c.housingId] = Math.max(0, (state.housing[c.housingId] ?? 0) - 1)
      state.housing[c.toHousingId] = (state.housing[c.toHousingId] ?? 0) + 1
      logs.push({
        day,
        kind: 'invest',
        text: `${from?.nameZh ?? c.housingId} 改建为 ${to?.nameZh ?? c.toHousingId}`,
      })
    }
  }
  state.construction = remaining
  return logs
}

// ---------------------------------------------------------------------------
// 建造队列：调序 / 取消（见 docs/construction.md 六）
//
// 队列本来就是**先进先出**的一条 `state.construction`：队首（index 0）先开工、
// 产能没用完才溢给下一条。以前玩家只能下单，**没法改顺序**；这两条动作把队列
// 变成可管理的：往上 / 往下挪一位、以及取消。
//
// ⚠️ 调序只改"谁先吃到建造力"，不改任何口径：不重算 `remaining`、不改 `started`、
//    也不退料。已经在建的工程被挪到后面时，它只是**暂停**（前面的工程先吃产能）。
// ---------------------------------------------------------------------------

/** 施工队列调序：把 `id` 这条按 `delta` 的方向挪**一位**（-1 上移 / +1 下移）。 */
export function moveConstruction(state: GameState, id: string, delta: number): AffordResult {
  const i = state.construction.findIndex((c) => c.id === id)
  if (i < 0) return { ok: false, reason: '该工程已不在队列里' }
  const step = Math.sign(delta)
  if (step === 0) return { ok: false, reason: '没有移动' }
  const j = i + step
  if (j < 0) return { ok: false, reason: '已经是队首' }
  if (j >= state.construction.length) return { ok: false, reason: '已经是队尾' }
  const a = state.construction[i]!
  state.construction[i] = state.construction[j]!
  state.construction[j] = a
  return { ok: true }
}

/** 取消建造的结果（给 `applyActions` 拼日志 / 给 UI 显示退料明细）。 */
export interface CancelResult extends AffordResult {
  /** 这一条开过工没有（**材料是开工那一刻才扣的**，没开过工就没什么可退）。 */
  started: boolean
  /** 已投入的建造力（= 总需求 − 还差的）。 */
  used: number
  /** 总建造力需求。 */
  total: number
  /** 该退回国库的实物（预览时**还没**并进 `state.goods`）。 */
  refund: Array<[string, number]>
  /** 该退回的金钱（预览时**还没**并进国库）。 */
  money: number
  /** 这一条的中文名。 */
  label: string
  /** 一句话摘要（公告用它；成功的 `reason` 也是它）。 */
  text: string
}

/** `planCancel()` 的返回值：多一个队列下标，落地时要用。 */
interface CancelPlan extends CancelResult {
  index: number
}

/**
 * 取消退料的**计算**部分（只算不改状态）。口径（见 docs/construction.md 六）：
 * 材料是开工那一刻才扣的，所以
 *   - 还没开工 → 一分钱都没扣过，退 0（材料原地不动，不需要"退回"）
 *   - 已开工   → 按**还没干的那部分**退：退回量 = 已扣材料 × (remaining / totalRequired)
 *
 * 直觉：已经投进去的建造力对应的人工/料拿不回来，剩下的原样还给你。
 * 建造力**本身**不退 —— 它是每日产能，不是库存（与 demolish 同口径）。
 */
function planCancel(state: GameState, ctx: ContentContext, id: string): CancelPlan {
  const i = state.construction.findIndex((c) => c.id === id)
  const miss: CancelPlan = {
    ok: false, reason: '该工程已不在队列里', index: -1, started: false, used: 0, total: 0,
    refund: [], money: 0, label: '', text: '',
  }
  if (i < 0) return miss
  const c = state.construction[i]!
  const spec = costOf(c, state, ctx)
  const label = labelOf(c, ctx)
  const total = c.totalRequired
  const used = Math.max(0, total - c.remaining)
  const ratio = c.started && total > 0 ? Math.max(0, Math.min(1, c.remaining / total)) : 0
  const refund: Array<[string, number]> = []
  let money = 0
  if (spec) {
    for (const [gid, qty] of spec.mats) {
      const back = round2(qty * ratio)
      if (back > 0) refund.push([gid, back])
    }
    if (spec.money > 0) money = round2(spec.money * ratio)
  }
  let text: string
  if (!c.started) {
    text = `取消「${label}」（还没开工，材料没扣过）`
  } else {
    const pct = total > 0 ? Math.round((used / total) * 100) : 0
    const parts = refund.map(([gid, q]) => `${ctx.goods[gid]?.nameZh ?? gid}×${round2(q)}`)
    if (money > 0) parts.push(`¥${round2(money)}`)
    text = parts.length
      ? `取消「${label}」（已投入 ${pct}%），退回 ${parts.join('、')}`
      : `取消「${label}」（已投入 ${pct}%），没有可退的材料`
  }
  return { ok: true, index: i, started: c.started, used, total, refund, money, label, text }
}

/** 取消的**预览**（只算不改）：确认对话框拿它显示"点了会退回什么"。 */
export function cancelRefundPreview(
  state: GameState,
  ctx: ContentContext,
  id: string,
): CancelResult {
  const p = planCancel(state, ctx, id)
  return {
    ok: p.ok, reason: p.reason, started: p.started, used: p.used, total: p.total,
    refund: p.refund, money: p.money, label: p.label, text: p.text,
  }
}

/**
 * 取消一个**还在队列里**的工程（已建成的建筑走 `demolish`，不走这条）。
 * 退料口径见 `planCancel()`。
 */
export function cancelConstruction(
  state: GameState,
  ctx: ContentContext,
  id: string,
): CancelResult {
  const plan = planCancel(state, ctx, id)
  if (!plan.ok) return plan
  for (const [gid, q] of plan.refund) {
    state.goods[gid] = round2((state.goods[gid] ?? 0) + q)
  }
  if (plan.money > 0) state.government.money = round2(state.government.money + plan.money)
  state.construction.splice(plan.index, 1)
  return plan
}
