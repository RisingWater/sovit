import type { GameState, LogEntry, ResearchProject, TechDef, TechID } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ECONOMY, TUNING } from '../config.ts'
import { round2 } from '../util.ts'
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
 * 夜晚：把当日科研力投入队首科技（先进先出）。
 * 队首未开工 → 先扣材料；材料不足 → 停在队首等待，不跳过。
 */
export function settleResearch(state: GameState, ctx: ContentContext, day: number): LogEntry[] {
  const logs: LogEntry[] = []
  let rate = researchRate(state, ctx)
  for (const p of state.research.queue) {
    if (rate <= 0) break
    const tech = ctx.technologies[p.id]
    if (!tech) break

    if (!p.started) {
      let short = false
      for (const [gid, qty] of Object.entries(tech.cost.goods)) {
        if ((state.goods[gid] ?? 0) < (qty ?? 0)) {
          logs.push({
            day,
            kind: 'invest',
            text: `研究「${tech.nameZh}」等待材料（${gid} 需 ${qty}）`,
          })
          short = true
          break
        }
      }
      if (short) break
      for (const [gid, qty] of Object.entries(tech.cost.goods)) {
        state.goods[gid] = round2((state.goods[gid] ?? 0) - (qty ?? 0))
      }
      p.started = true
      logs.push({
        day,
        kind: 'invest',
        text: `开始研究「${tech.nameZh}」（需科研力 ${round2(p.totalRequired)}）`,
      })
    }

    const used = Math.min(rate, p.remaining)
    p.remaining = round2(p.remaining - used)
    rate = round2(rate - used)
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
