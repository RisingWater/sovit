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
import { applyStorageCap, storageCapacity, storedTotal } from './systems/storage.ts'
import { payWages } from './systems/finance.ts'
import { collectRent, assignTenure, runPrivateHousingMarket } from './systems/housing.ts'
import { runConsumption } from './systems/consumption.ts'
import { updateSatisfaction } from './systems/satisfaction.ts'
import { updatePopulation, applyAdmission, computeArrivals } from './systems/population.ts'
import { applyConstructionHours, planConstructionDay, settleConstruction, activateCompleted } from './systems/investment.ts'
import { applyResearchHours, planResearchDay, settleResearch, activateResearch } from './systems/research.ts'
import { allocateTools } from './systems/tools.ts'
import { checkQuests } from './systems/quests.ts'

// ---------------------------------------------------------------------------
// 每日结算（小时制）
//
// 06:00 黎明：day++ → 应用「次日生效」队列 → 启用昨日完工 → 用工 → 排产
// 06–18 白天：每小时执行今日计划 × 1/工作小时数；施工、科研也在同一节奏里按小时投入
// 18:00 夜晚：施工收尾（诊断 + 建造工资）→ 研究收尾（诊断）→ 工资 → 收租 → 消费 → 买房
//             → 满意度 → 人口 → 移民 → 损耗 → 技能
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

function buildAlerts(state: GameState, ctx: ContentContext, hungry: number): Alert[] {
  const alerts: Alert[] = []
  if (hungry > 0) {
    alerts.push({ type: 'hunger', count: hungry, text: `${hungry} 人处于饥饿` })
  }
  // 仓储满了必须报警：否则货凭空消失，玩家会以为是 bug（docs/town.md §3.3）
  const cap = storageCapacity(state, ctx)
  const used = storedTotal(state, ctx)
  if (cap > 0 && used >= cap) {
    alerts.push({
      type: 'storage_full',
      count: Math.round(used),
      text: `仓储已满（${Math.round(used)} / ${Math.round(cap)}）`,
    })
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

  // 取消建造要往公告里写「退回了什么」，所以把 logs 传进去（见 applyActions 的说明）
  const applied = applyActions(state, ctx, state.pending, logs)
  state.pending = []

  logs.push(...activateCompleted(state, ctx, state.day))
  logs.push(...activateResearch(state, ctx, state.day))
  assignLabor(state, ctx)
  // 工具必须在排产之前分配：它决定今天各工坊的产出倍率（shop.toolBoost）
  logs.push(...allocateTools(state, ctx, state.day))
  planProduction(state, ctx)
  // 当日建造力预算：必须在**用工之后**（建造力取决于失业人口与建筑工坊的在岗人数），
  // 且必须在第一个工作小时之前 —— 全天按这个数投入，不每小时现算（见 planConstructionDay）
  planConstructionDay(state, ctx)
  // 当日科研力预算：同样在**用工之后**、第一个工作小时之前 —— 全天按这个数投入
  // （见 planResearchDay）。顺序固定为**先施工、后科研**，与白天、夜晚两处一致。
  planResearchDay(state, ctx)
  // 任务（引导系统）放在**最后**：完工的建筑、生效的科技、刚放行的人口都已经写进 state，
  // 判定就是"看眼前这个村子有没有"，所以玩家先干了、任务后出现也照样算完成。
  // 见 docs/quests.md。
  logs.push(...checkQuests(state, ctx, state.day))
  return { logs, applied }
}

/**
 * 夜晚结算。
 *
 * ⚠️ 这里**不**往 `state.log` 写日志：公告的累积统一发生在 `stepHour()` 里
 * （唯一入口，见那里的注释）。直接调本函数只会拿到返回值，不会进存档。
 */
export function runNight(state: GameState, ctx: ContentContext, rng: ReturnType<typeof createRng>): LogEntry[] {
  const day = state.day
  const logs: LogEntry[] = []

  // 施工收尾必须在工资之前：它把**白天已经投进去的**建造力折算成
  // 「在工地上出工」的失业人口（建造工资，见 docs/spec.md §9.4）。
  logs.push(...settleConstruction(state, ctx, day))
  // 研究独立成队、不占人口：科研力已经在白天按小时投完了，这里只诊断队首为什么没动
  // （见 docs/spec.md §10.4）
  logs.push(...settleResearch(state, ctx, day))
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
  applySpoilage(state, ctx)
  // 仓储超限丢弃：紧接损耗之后（见 docs/town.md §3.3）——
  // 先损耗、后判上限，损耗腾出来的空间能救下本来会被丢掉的货
  logs.push(...applyStorageCap(state, ctx, day))
  growSkills(state)
  computeArrivals(state)
  state.reserved = {}

  state.history.push(makeSnapshot(state, consumption.hungry))
  if (state.history.length > 400) state.history = state.history.slice(-400)
  state.alerts = buildAlerts(state, ctx, consumption.hungry)

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
    const fraction = 1 / WORK_HOURS
    // 生产 / 施工 / 科研**同一条件、同一节奏**（都在工作小时里按小时推进）。
    // 顺序固定为**先生产、再施工、后科研**：
    //   1. 生产：当小时刚产出的木石粘土，当小时就能用于下面两步扣料
    //   2. 施工：工地开工优先吃当小时的产出
    //   3. 科研：研究所在岗工人不参与建造力，两条队列互不争抢
    runProductionStep(state, ctx, fraction)
    logs.push(...applyConstructionHours(state, ctx, fraction))
    logs.push(...applyResearchHours(state, ctx, fraction))
  }
  if (h === TIME.settleHour) {
    logs.push(...runNight(state, ctx, rng))
  }

  state.hour = (h + 1) % TIME.hoursPerDay
  // 公告（`state.log`）**逐小时累积当小时的日志**（黎明 / 白天 / 夜晚三批都算），上限 500。
  //
  // ⚠️ 这里必须管全部三批，不能只在这里补黎明那批：以前只有 `runNight()` 往里写，
  //    于是「建成投产」「研究完成」「X 改建为 Y」这类**黎明**日志根本进不了存档
  //    —— 玩家退出再进来，公告就基本是空的（2026-10 用户报的）。`state.log` 是公告的
  //    **唯一真源**（表现层直接读它），所以它必须等于「玩家这一天见过的全部消息」。
  state.log = [...state.log, ...logs]
  if (state.log.length > 500) state.log = state.log.slice(-500)

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
