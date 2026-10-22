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
import { updateCaravans } from './systems/caravan.ts'
import { updateRoutes } from './systems/routes.ts'
import { updateFactions } from './systems/factions.ts'
import { techBonuses } from './systems/tech_bonus.ts'

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

  // 商路（B3）：**先结算、后派车**。放在 applyActions 之后（今天的命令已落地）、
  // activateCompleted 之前 —— 买到的货在这一步就进了仓库，后面的排产当天就能用上。
  logs.push(...updateRoutes(state, ctx, techBonuses(state, ctx), state.day))

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
  // 游商：到货 / 离开（M4）。放在任务之后：章节奖励刚记上，这批就能按新章节来人。
  logs.push(...updateCaravans(state, ctx, state.day))
  logs.push(...checkQuests(state, ctx, state.day))
  // 邦交（B4）：剧情翻转要在**章节奖励记上之后**判 —— 本章刚完成，那几家才翻脸。
  // 与 quests / caravans 同一批（顺序见 docs/spec.md §22.3；镜像 sim_core.gd::_run_dawn）。
  logs.push(...updateFactions(state, state.day))
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
  // 需求满足率留一份给面板（**派生量、只读**：没人再拿它算东西，见 GameState.needScores）
  state.needScores = { ...consumption.needScores }

  logs.push(...runPrivateHousingMarket(state, ctx, day))
  assignTenure(state, ctx)

  updateSatisfaction(state, ctx, consumption.foodScore, consumption.comfortScore, consumption.priceScore)

  logs.push(...updatePopulation(state, ctx, rng, consumption.hungry, day))
  logs.push(...applyAdmission(state, ctx, rng, day))
  applySpoilage(state, ctx)
  // 仓储超限丢弃：紧接损耗之后（见 docs/town.md §3.3）——
  // 先损耗、后判上限，损耗腾出来的空间能救下本来会被丢掉的货
  logs.push(...applyStorageCap(state, ctx, day))
  growSkills(state, consumption.needScores['education'] ?? 0)
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
  // 任务判定：**每小时都扫一次**（用户 2026-10-20："提交了任务直接完成。任务完成不用等到
  // 6:00 吧，这样游戏体验很差"）。判定只读状态、幂等，扫一遍很便宜。
  // 黎明那一趟已经在 `runDawn` 末尾扫过，这里跳过（免得同一小时跑两遍、日志重复）。
  // GDScript 侧同一口径（`sim_core.gd::tick_hour`）。
  if (h !== TIME.dawnHour) logs.push(...checkQuests(state, ctx, state.day))

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
 * **即时生效**的动作：研究队列的增 / 撤 / 调序，以及**送物资**。
 *
 * 用户 2026-10："我白天点了一个研究…结果队列里没有，没有实时出现。要到第二天才能调整顺序
 * 太蠢了。" 这三个动作**不花任何资源**（材料是在**开工那一刻**才扣的），只动一条队列，
 * 所以没有理由等黎明。
 *
 * 2026-10-20 又加一条（用户："提交任务，要马上减少物资怎么能次日生效呢？……提交了任务
 * 直接完成。任务完成不用等到 6:00 吧，这样游戏体验很差。"）：`gift` 也走即时 ——
 * 玩家当面把东西交出去，货当场扣、任务当场结算（见 `queueActions` 里那一趟 `checkQuests`）。
 *
 * ⚠️ 其余动作（建造 / 拆除 / 改价 / 招工…）仍然**次日黎明生效** —— 那是"一天一结算"的核心口径，
 * 也是黄金轨迹的确定性来源。GDScript 侧同一份名单：`sim_core.gd::IMMEDIATE_ACTIONS`。
 */
export const IMMEDIATE_ACTIONS: readonly Action['type'][] = [
  'research',
  'cancel_research',
  'move_research',
  'gift',
  // 商路（B3）：派车 / 取消 / 改预算 / 改数量 —— 都不花资源，只动配置与"把货搬进搬出商队"，
  // 和研究队列、`gift` 同一条口径（用户："点完就该看到变化"）。
  'route_assign',
  'route_unassign',
  'route_set_budget',
  'route_set_sell',
  // 邦交（B4）：送礼 / 结盟 / 宣战 —— 钱当场扣、好感当场涨，和 `gift` 同一条口径
  'faction_gift',
  'faction_ally',
  'faction_attack',
]

/**
 * 把动作分流：即时生效的当场应用（研究队列那三条 + 送物资），其余进 `pending` 等黎明。
 * 返回即时那批的 `AppliedAction` / 日志，调用方并进本次 tick 的结果里。
 *
 * ⚠️ 即时动作应用完之后**顺手跑一趟任务判定**：玩家刚交完东西，那一条就该当场完成、
 * 钱当场到账 —— 不能让他等到下一个 6:00。判定是幂等的（只看状态），所以多跑一趟无副作用。
 */
function queueActions(
  state: GameState,
  ctx: ContentContext,
  actions: Action[],
  logs: LogEntry[],
): AppliedAction[] {
  if (actions.length === 0) return []
  const immediate = actions.filter((a) => IMMEDIATE_ACTIONS.includes(a.type))
  const deferred = actions.filter((a) => !IMMEDIATE_ACTIONS.includes(a.type))
  if (deferred.length > 0) state.pending.push(...deferred)
  if (immediate.length === 0) return []
  const applied = applyActions(state, ctx, immediate, logs)
  // 即时动作之后当场结算（只结算"刚刚变成已达成"的那些，`checkQuests` 自己幂等）
  logs.push(...checkQuests(state, ctx, state.day))
  // 公告：即时动作的日志**也**要进 `state.log`（它是公告的唯一真源，见 stepHour 末尾）。
  // 以前取消研究是在黎明应用的，日志跟着黎明那批进；现在当场应用，就得在这儿补一次。
  state.log = [...state.log, ...logs]
  if (state.log.length > 500) state.log = state.log.slice(-500)
  return applied
}

/**
 * 推进一个游戏小时（纯函数）。
 * 传入的 actions：研究队列那三条**当场生效**，其余进入「待生效队列」，次日黎明统一应用。
 */
export function advanceHour(state: GameState, actions: Action[] = []): TickResult {
  const draft: GameState = structuredClone(state)
  const ctx = buildContext(draft.pack)
  const rng = createRng(draft.rngState)
  const nowLogs: LogEntry[] = []
  const nowApplied = queueActions(draft, ctx, actions, nowLogs)

  const { logs, applied } = stepHour(draft, ctx, rng)
  draft.rngState = rng.state
  return { state: draft, log: [...nowLogs, ...logs], applied: [...nowApplied, ...applied] }
}

/**
 * 推进一整天（hoursPerDay 个小时）。研究队列那三条当场生效，其余在当天首个黎明生效。
 * 主要供测试 / 脚本使用。
 */
export function advanceDay(state: GameState, actions: Action[] = []): TickResult {
  const draft: GameState = structuredClone(state)
  const ctx = buildContext(draft.pack)
  const rng = createRng(draft.rngState)
  const logs: LogEntry[] = []
  const applied: AppliedAction[] = []
  applied.push(...queueActions(draft, ctx, actions, logs))

  for (let i = 0; i < TIME.hoursPerDay; i++) {
    const r = stepHour(draft, ctx, rng)
    logs.push(...r.logs)
    applied.push(...r.applied)
  }
  draft.rngState = rng.state
  return { state: draft, log: logs, applied }
}
