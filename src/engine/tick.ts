import type { Action, Alert, DaySnapshot, GameState, LogEntry, TickResult } from './types.ts'
import { buildContext } from './content/index.ts'
import type { ContentContext } from './content/index.ts'
import { createRng } from './rng.ts'
import { sum } from './util.ts'
import { applyActions } from './actions.ts'
import { assignLabor } from './systems/labor.ts'
import { runProduction } from './systems/production.ts'
import { payWages } from './systems/finance.ts'
import { collectRent, runPrivateHousingMarket } from './systems/housing.ts'
import { runConsumption } from './systems/consumption.ts'
import { updateSatisfaction } from './systems/satisfaction.ts'
import { updatePopulation } from './systems/population.ts'
import { processConstruction } from './systems/investment.ts'

// ---------------------------------------------------------------------------
// 每日结算
// ---------------------------------------------------------------------------

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
  }
}

function buildAlerts(state: GameState, hungry: number): Alert[] {
  const alerts: Alert[] = []
  if (hungry > 0) {
    alerts.push({ type: 'hunger', count: hungry, text: `${hungry} 人处于饥饿` })
  }
  if (state.government.money < 0) {
    alerts.push({
      type: 'bankruptcy',
      count: Math.ceil(-state.government.money),
      text: '政府余额为负，财政告急',
    })
  }
  const employed = state.residents.filter((r) => r.employed).length
  const unemployed = state.residents.length - employed
  if (unemployed > employed && unemployed > 0) {
    alerts.push({ type: 'unemployment', count: unemployed, text: `失业 ${unemployed} 人` })
  }
  const avgSat = avgSatisfaction(state)
  if (avgSat < 40) {
    alerts.push({
      type: 'low_satisfaction',
      count: Math.round(avgSat),
      text: '平均满意度偏低',
    })
  }
  return alerts
}

/** 结算一天。就地修改 state，返回当日日志。 */
export function runDay(state: GameState, ctx: ContentContext): LogEntry[] {
  const day = state.day + 1
  const rng = createRng(state.rngState)
  const logs: LogEntry[] = []

  assignLabor(state, ctx)
  logs.push(...runProduction(state, ctx, day))
  logs.push(...payWages(state, day))
  logs.push(...collectRent(state, ctx, day))

  const consumption = runConsumption(state, ctx, day)
  logs.push(...consumption.logs)

  updateSatisfaction(state, ctx, consumption.foodScore, consumption.priceScore)
  logs.push(...updatePopulation(state, ctx, rng, consumption.hungry, day))
  logs.push(...processConstruction(state, ctx, day))
  logs.push(...runPrivateHousingMarket(state, ctx, day))

  state.day = day
  state.rngState = rng.state
  state.history.push(makeSnapshot(state, consumption.hungry))
  if (state.history.length > 400) state.history = state.history.slice(-400)
  state.alerts = buildAlerts(state, consumption.hungry)
  state.log = [...state.log, ...logs]
  if (state.log.length > 500) state.log = state.log.slice(-500)

  return logs
}

/**
 * 引擎主入口：应用动作，若含 end_turn 则结算一天。
 * 纯函数：不修改传入的 state，返回新对象。
 */
export function advanceDay(state: GameState, actions: Action[] = []): TickResult {
  const draft: GameState = structuredClone(state)
  const ctx = buildContext(draft.pack)
  const applied = applyActions(draft, ctx, actions)
  const log = actions.some((a) => a.type === 'end_turn') ? runDay(draft, ctx) : []
  return { state: draft, log, applied }
}
