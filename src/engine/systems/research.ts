import type { GameState, LogEntry, ResearchProject, TechDef, TechID } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ECONOMY, TUNING } from '../config.ts'
import { round2, round4 } from '../util.ts'
import { assignedWorkers } from './labor.ts'
import { isCapacityKind } from './investment.ts'
import { techBonuses } from './tech_bonus.ts'

// ---------------------------------------------------------------------------
// 研究（见 docs/technology.md）
//
// **科研力 = 每日产能（速率，不是库存）**，与建造力完全同构：
//   每日科研力 = research.baseRate（全村基础，无需建筑）
//              + Σ(研究所在岗工人 × perWorker × (1 + levelBonus × (等级−1)) × 熟练度曲线)
//
// 科技消耗「科研力 + 原材料」：原材料在**开工时**（队首开始投入科研力时）扣，
// 进度按先进先出队列逐日投入，产能不结转。研究完成在**次日黎明**生效（解锁建筑）。
//
// **白天**在工作小时里按小时投入（`applyResearchHours`，与生产 / 施工同一节奏、同一条件）：
//   每小时投入 科研力 / 工作小时数，研究所头顶的进度条白天能看见在爬；一天的总额仍是 科研力。
// **夜晚**只做收尾（`settleResearch`）：诊断队首为什么没动（每天最多一条，不逐小时刷屏）。
//
// 效率科技（抄书房 / 学院 / 印刷术）把**整条速率**乘 (1 + effects.research)，
// 见 docs/spec.md §10.1。
// ---------------------------------------------------------------------------

/** 当日科研力产能（人·天）。 */
export function researchRate(state: GameState, ctx: ContentContext): number {
  let rate = ECONOMY.research.baseRate
  for (const shop of state.shops) {
    const def = ctx.buildings[shop.defId]
    if (!def || !shop.active || !def.capacity || !isCapacityKind(def, 'research')) continue
    const skillEff = TUNING.skillEffectBase + TUNING.skillEffectSlope * (shop.skill / 100)
    const levelMul = 1 + def.capacity.levelBonus * (shop.level - 1)
    rate += assignedWorkers(state, shop.id) * def.capacity.perWorker * levelMul * skillEff
  }
  // 效率科技：**整条返回值**乘 (1 + 加成) —— 基础速率也一起放大。
  rate *= 1 + techBonuses(state, ctx).research
  return round2(rate)
}

/** 该科技是否已研究完成。 */
export function isResearched(state: GameState, techId: TechID): boolean {
  return state.research.done.includes(techId)
}

/** 该科技是否已在队列里。 */
export function isQueued(state: GameState, techId: TechID): boolean {
  return state.research.queue.some((p) => p.id === techId)
}

/** 该建筑当前是否可建：没有科技锁，或解锁它的科技已完成。 */
export function isBuildingUnlocked(state: GameState, ctx: ContentContext, buildingId: string): boolean {
  for (const id of Object.keys(ctx.technologies)) {
    const t = ctx.technologies[id]!
    if (!t.unlocks.buildings.includes(buildingId)) continue
    return state.research.done.includes(id)
  }
  return true // 没有任何科技解锁它 = 开局免费
}

/** 该住房当前是否可建。 */
export function isHousingUnlocked(state: GameState, ctx: ContentContext, housingId: string): boolean {
  for (const id of Object.keys(ctx.technologies)) {
    const t = ctx.technologies[id]!
    if (!t.unlocks.housing.includes(housingId)) continue
    return state.research.done.includes(id)
  }
  return true
}

/** 解锁该建筑 / 住房的科技定义（UI 显示「需要科技：X」用）；undefined = 免费。 */
export function techForBuilding(ctx: ContentContext, buildingId: string): TechDef | undefined {
  for (const id of Object.keys(ctx.technologies)) {
    const t = ctx.technologies[id]!
    if (t.unlocks.buildings.includes(buildingId)) return t
  }
  return undefined
}

export function techForHousing(ctx: ContentContext, housingId: string): TechDef | undefined {
  for (const id of Object.keys(ctx.technologies)) {
    const t = ctx.technologies[id]!
    if (t.unlocks.housing.includes(housingId)) return t
  }
  return undefined
}

export interface ResearchCheck {
  ok: boolean
  reason?: string
}

/**
 * 能否把某项科技加入队列。
 * 注意：**只检查**材料是否够，不扣（材料在开工时扣，与施工一致）。
 */
export function canResearch(state: GameState, ctx: ContentContext, techId: TechID): ResearchCheck {
  const tech = ctx.technologies[techId]
  if (!tech) return { ok: false, reason: '科技不存在' }
  if (isResearched(state, techId)) return { ok: false, reason: '已经研究完成' }
  if (isQueued(state, techId)) return { ok: false, reason: '已在研究队列中' }
  for (const r of tech.requires) {
    if (!isResearched(state, r)) {
      return { ok: false, reason: `前置未完成：${ctx.technologies[r]?.nameZh ?? r}` }
    }
  }
  for (const [gid, qty] of Object.entries(tech.cost.goods)) {
    if ((state.goods[gid] ?? 0) < (qty ?? 0)) {
      return { ok: false, reason: `材料不足：${gid} 需 ${qty}` }
    }
  }
  return { ok: true }
}

/** 下单：入队（不扣材料）。 */
export function startResearch(state: GameState, ctx: ContentContext, techId: TechID): ResearchCheck {
  const check = canResearch(state, ctx, techId)
  if (!check.ok) return check
  const tech = ctx.technologies[techId]!
  const project: ResearchProject = {
    id: techId,
    remaining: tech.research,
    totalRequired: tech.research,
    started: false,
    waiting: false,
  }
  state.research.queue.push(project)
  return { ok: true }
}

/** 取消研究（从队列移除）。已扣的材料不退，与施工一致。 */
export function cancelResearch(state: GameState, techId: TechID): ResearchCheck {
  const i = state.research.queue.findIndex((p) => p.id === techId)
  if (i < 0) return { ok: false, reason: '不在研究队列中' }
  state.research.queue.splice(i, 1)
  return { ok: true }
}

/**
 * 黎明：钉死**当日科研力预算**。
 *
 * 为什么要有它（不是为了好看，是为了让"一天总量不变"有个**硬闸**）：
 * 科研进度在账上是按"这一天投了多少"（`researchWorkToday`）抵着预算走的 ——
 * 没有这个数就只能靠"每小时都现算一次 `researchRate`"，而那要依赖
 * "同一天里 `shop.skill` 不变"（它只在黎明 `assignLabor` 与入夜 `growSkills`
 * 两处变）。多一条依赖就多一个将来会被改坏的地方，何况施工那边
 * （`planConstructionDay`）钉的是同一道预算，两边完全同构。
 *
 * 顺带的好处：TS 与 GDScript 的熟练度成长时点并不完全一样（TS 在入夜、
 * GDScript 也在入夜，但两边的其它小时级改动各有可能），钉死之后两边天然对齐。
 *
 * 口径：**一天的预算 = 这一天黎明那一刻的 `researchRate`**，全天不变
 * （与"产能不结转、当天没用完即作废"同一精神）。
 */
export function planResearchDay(state: GameState, ctx: ContentContext): void {
  state.researchWorkToday = 0
  state.researchRateToday = researchRate(state, ctx)
}

/**
 * 工作小时：把**固定的一份**科研力（`researchRateToday × fraction`）投入队首科技。
 *
 * 与 `runProductionStep` / `applyConstructionHours` **同一节奏、同一条件**
 * （`workStart <= h < workEnd`，fraction = 1/工作小时数）。
 *
 * **每小时投入量是个常数**（`researchRateToday / 工作小时数`），**不是**"把队首
 * 剩下的需求摊到当天剩下的小时里"：队首只剩 5、日产能 12 时，就是每小时 1、
 * 走 5 个小时在**当天中途**跑完 —— 既不会 18:00 才跳完，也不会被压进一个小时。
 *
 * 队列语义（先进先出、串行）：
 * - 队首未开工 → 先扣材料（**开工时刻 = 这一天第一个工作小时**，不是夜晚）；
 *   材料不足则停在队首等待，**不跳过**（这条是契约）
 * - **队首中途跑完 → 这一小时剩下的产能继续投给下一条**（同小时、串行）：
 *   这是"一天总量 = 当天科研力"这个不变量成立的关键 —— 剩下的产能不许丢。
 *   队列空了就作废（**不结转到第二天**，与"当天没用完即作废"同一契约）
 * - 一天里队首可以只被投一点，所以 `remaining` 用 **r4** 累积：
 *   12 次 r2 会漂移（一天就不再恰好等于日产能）
 * - 日志：`开始研究` 只在 `started` 翻转时写一次；「等待材料」只在队首进入等待的
 *   那一刻写一条（`p.waiting` 去重），**不逐小时刷屏**
 *
 * ⚠️ 完工**不在这里激活**：跑完后仍然留在队列里，等夜晚（`settleHour`）之后的
 * 黎明 `activateResearch` 才出队生效 —— 见 `docs/spec.md` §10.5。
 */
export function applyResearchHours(
  state: GameState,
  ctx: ContentContext,
  fraction: number,
): LogEntry[] {
  const logs: LogEntry[] = []
  // 这一个小时的产能：**常数**（当日科研力 × 1/工作小时数）。
  // 再拿当日累计兜一道底（同一小时被多调一次不会多投），两道都不取整。
  // ⚠️ 用 `??` 而不是裸读：旧存档（或手搓的状态）没有这两个键时，
  // 裸读会让 `left` 变成 NaN，进而绕过"一天总量不变"这道闸。
  const rateToday = state.researchRateToday ?? 0
  const rate = rateToday * fraction
  let left = Math.min(rate, rateToday - (state.researchWorkToday ?? 0))
  if (!(left > 0)) return logs

  for (const p of state.research.queue) {
    // 产能用完了就停（队首跑完时从这里溢到下一条，不是 break）
    if (left <= 0) break
    const tech = ctx.technologies[p.id]
    if (!tech) break // 科技定义缺失：这里不刷屏（与施工的 break 同口径）

    if (!p.started) {
      const gap = shortageOf(state, tech)
      if (gap) {
        // 停在队首等待材料，**不跳过**。同一个"等待"只写一条日志
        //（白天每小时都会撞上同一个缺口；有 `waiting` 标志才不刷屏）
        if (!p.waiting) {
          p.waiting = true
          logs.push({
            day: state.day,
            kind: 'invest',
            text: `研究「${tech.nameZh}」等待材料（${gap}）`,
          })
        }
        break
      }
      for (const [gid, qty] of Object.entries(tech.cost.goods)) {
        state.goods[gid] = round2((state.goods[gid] ?? 0) - (qty ?? 0))
      }
      p.started = true
      p.waiting = false
      logs.push({
        day: state.day,
        kind: 'invest',
        text: `开始研究「${tech.nameZh}」（需科研力 ${round2(p.totalRequired)}）`,
      })
    }

    const used = Math.min(left, p.remaining)
    p.remaining = Math.max(0, round4(p.remaining - used))
    left = round4(left - used)
    state.researchWorkToday = round4(state.researchWorkToday + used)
  }
  return logs
}

/** 队首缺哪种材料（够则返回 null）；等待诊断的文案与判定只有这一份。 */
function shortageOf(state: GameState, tech: TechDef): string | null {
  for (const [gid, qty] of Object.entries(tech.cost.goods)) {
    if ((state.goods[gid] ?? 0) < (qty ?? 0)) return `${gid} 需 ${qty}`
  }
  return null
}

/**
 * 夜晚：研究的**收尾**（科研力已经在工作小时里按小时投完了，见 `applyResearchHours`）。
 *
 * 只做一件事：队首为什么没动 —— 写一条诊断（每天最多一条）。
 * 白天每小时都可能撞上材料不足，日志若写在小时里会刷 12 条屏，所以挪到这里，
 * 与施工的 `settleConstruction` 同一套口径（见 docs/spec.md §9.4 / §10.4）。
 */
export function settleResearch(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []
  // 科研力为 0 时队首本来就没机会开工（不是材料的问题）：不写诊断，与施工同口径
  if (researchRate(state, ctx) <= 0) return logs

  const p = state.research.queue[0]
  if (!p) return logs
  const tech = ctx.technologies[p.id]
  if (!tech) return logs
  // 队首已经跑完（在等黎明生效）：今天的科研力是被它正常吃掉的，不是卡住
  if (p.started && p.remaining <= 0) return logs

  const gap = shortageOf(state, tech)
  if (gap) {
    logs.push({ day, kind: 'invest', text: `研究「${tech.nameZh}」等待材料（${gap}）` })
  }
  return logs
}

/** 黎明：跑完的科技生效（解锁建筑），其余留队。 */
export function activateResearch(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []
  while (state.research.queue.length > 0 && state.research.queue[0]!.remaining <= 0) {
    const done = state.research.queue.shift()!
    state.research.done.push(done.id)
    const tech = ctx.technologies[done.id]
    logs.push({ day, kind: 'invest', text: `研究完成：${tech?.nameZh ?? done.id}` })
  }
  return logs
}
