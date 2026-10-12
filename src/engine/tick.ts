import type { Action, Alert, AppliedAction, DaySnapshot, GameState, LogEntry, TickResult } from './types.ts'
import { buildContext } from './content/index.ts'
import type { ContentContext } from './content/index.ts'
import { createRng } from './rng.ts'
import { TIME } from './config.ts'
import { sum } from './util.ts'
import { emptyLedger } from './state.ts'
import { applyActions } from './actions.ts'
import { assignLabor, growSkills } from './systems/labor.ts'
import { planProduction, runProductionStep, applySpoilage } from './systems/production.ts'
import { payWages } from './systems/finance.ts'
import { collectRent, assignTenure, runPrivateHousingMarket } from './systems/housing.ts'
import { runConsumption } from './systems/consumption.ts'
import { updateSatisfaction } from './systems/satisfaction.ts'
import { updatePopulation, applyAdmission, computeArrivals } from './systems/population.ts'
import { advanceConstruction, activateCompleted } from './systems/investment.ts'

// ---------------------------------------------------------------------------
// 每日结算（小时制）
//
// 06:00 黎明：day++ → 应用「次日生效」队列 → 启用昨日完工 → 用工 → 排产
// 06–18 白天：每小执行今日计划 × 1/工作小时数
// 18:00 夜晚：工资 → 收租 → 消费 → 买房 → 满意度 → 人口 → 移民 → 损耗 → 技能 → 施工
// ---------------------------------------------------------------------------

const WORK_HOURS = TIME.workEnd - TIME.workStart

function avgSatisfaction(state: GameState): number {
  if (state.residents.length === 0) return 0
  return sum(state.residents.map((r) => r.satisfaction)) / state.residents.length
}

function makeSnapshot(state: GameState, hungry: number): DaySnapshot {
  const employed = state.residents.filter((r) => r.employed).length
  return {
    day: state.day,
    population: state.residents.length,
    avgSatisfaction: Math.round(avgSatisfaction(state) * 10) / 10,
    money: state.government.money,
    hungry,
    employed,
    // 当日实际流量台账（逐人账目则挂在每个 resident.account 上）
    ledger: state.ledgerToday,
  }
}

function buildAlerts(state: GameState, hungry: number): Alert[] {
  const alerts: Alert[] = []
  if (hungry > 0) {
    alerts.push({ type: 'hunger', count: hungry, text: `${hungry} 人处于饥饿` })
  }
  const avgSat = avgSatisfaction(state)
  if (avgSat < 45) {
    alerts.push({ type: 'low_satisfaction', count: Math.round(avgSat), text: '平均满意度偏低' })
  }
  return alerts
}

/** 黎明（day++）：应用待生效命令 → 启用完工 → 用工分配 → 排产。 */
export function runDawn(state: GameState, ctx: ContentContext): { logs: LogEntry[]; applied: AppliedAction[] } {
  const logs: LogEntry[] = []
  state.day += 1
  // 新的一天：台账清零（晚上结算时挂到当天快照）
  state.ledgerToday = emptyLedger(state.day)

  const applied = applyActions(state, ctx, state.pending)
  state.pending = []

  logs.push(...activateCompleted(state, ctx, state.day))
  assignLabor(state, ctx)
  planProduction(state, ctx)
  return { logs, applied }
}

/** 夜晚结算。 */
export function runNight(state: GameState, ctx: ContentContext, rng: ReturnType<typeof createRng>): LogEntry[] {
  const day = state.day
  const logs: LogEntry[] = []

  logs.push(...payWages(state, day))
  assignTenure(state, ctx)
  logs.push(...collectRent(state, ctx, day))

  const consumption = runConsumption(state, ctx, day)
  logs.push(...consumption.logs)

  logs.push(...runPrivateHousingMarket(state, ctx, day))
  assignTenure(state, ctx)

  updateSatisfaction(state, ctx, consumption.foodScore, consumption.comfortScore, consumption.priceScore)

  logs.push(...updatePopulation(state, ctx, rng, consumption.hungry, day))
  logs.push(...applyAdmission(state, ctx, rng, day))
  advanceConstruction(state)
  applySpoilage(state, ctx)
  growSkills(state)
  computeArrivals(state)
  state.reserved = {}

  state.history.push(makeSnapshot(state, consumption.hungry))
  if (state.history.length > 400) state.history = state.history.slice(-400)
  state.alerts = buildAlerts(state, consumption.hungry)
  state.log = [...state.log, ...logs]
  if (state.log.length > 500) state.log = state.log.slice(-500)

  return logs
}

/** 推进一个游戏小时。 */
function stepHour(
  state: GameState,
  ctx: ContentContext,
  rng: ReturnType<typeof createRng>,
): { logs: LogEntry[]; applied: AppliedAction[] } {
  const h = state.hour
  const logs: LogEntry[] = []
  let applied: AppliedAction[] = []

  if (h === TIME.dawnHour) {
    const r = runDawn(state, ctx)
    logs.push(...r.logs)
    applied = r.applied
  }
  if (h >= TIME.workStart && h < TIME.workEnd) {
    runProductionStep(state, ctx, 1 / WORK_HOURS)
  }
  if (h === TIME.settleHour) {
    logs.push(...runNight(state, ctx, rng))
  }

  state.hour = (h + 1) % TIME.hoursPerDay
  return { logs, applied }
}

/**
 * 推进一个游戏小时（纯函数）。
 * 传入的 actions 进入「待生效队列」，在次日黎明（dawnHour）统一应用。
 */
export function advanceHour(state: GameState, actions: Action[] = []): TickResult {
  const draft: GameState = structuredClone(state)
  const ctx = buildContext(draft.pack)
  const rng = createRng(draft.rngState)
  if (actions.length > 0) draft.pending.push(...actions)

  const { logs, applied } = stepHour(draft, ctx, rng)
  draft.rngState = rng.state
  return { state: draft, log: logs, applied }
}

/**
 * 推进一整天（hoursPerDay 个小时）。命令在起始处入队、于当天首个黎明生效。
 * 主要供测试 / 脚本使用。
 */
export function advanceDay(state: GameState, actions: Action[] = []): TickResult {
  const draft: GameState = structuredClone(state)
  const ctx = buildContext(draft.pack)
  const rng = createRng(draft.rngState)
  if (actions.length > 0) draft.pending.push(...actions)

  const logs: LogEntry[] = []
  const applied: AppliedAction[] = []
  for (let i = 0; i < TIME.hoursPerDay; i++) {
    const r = stepHour(draft, ctx, rng)
    logs.push(...r.logs)
    applied.push(...r.applied)
  }
  draft.rngState = rng.state
  return { state: draft, log: logs, applied }
}
