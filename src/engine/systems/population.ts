import type { ClassID, GameState, LogEntry, Resident } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import type { Rng } from '../rng.ts'
import { ECONOMY } from '../config.ts'
import { round2, sum } from '../util.ts'
import { housingCapacity } from './housing.ts'

// ---------------------------------------------------------------------------
// 人口
//
// 满意度高、无饥饿、且存在住房与岗位空缺时 → 迁入；
// 满意度低或有人饥饿 → 迁出 / 死亡。新居民默认进入穷人阶层。
// ---------------------------------------------------------------------------

function jobCapacity(state: GameState, ctx: ContentContext): number {
  let total = 0
  for (const shop of state.shops) {
    if (!shop.active) continue
    const def = ctx.buildings[shop.defId]
    // 岗位 = 该店实际开出的用工数（工位上限只是容量）
    if (def) total += Math.min(shop.targetWorkers, def.maxWorkers ?? def.workers)
  }
  return total
}

function nextResidentIndex(state: GameState): number {
  let max = state.residents.length
  for (const r of state.residents) {
    const m = /#(\d+)$/.exec(r.id)
    if (m) {
      const n = Number(m[1])
      if (Number.isFinite(n) && n > max) max = n
    }
  }
  return max + 1
}

function makeResident(state: GameState, rng: Rng, classId: ClassID): Resident {
  return {
    id: `res#${nextResidentIndex(state)}`,
    classId,
    savings: 12,
    satisfaction: 60,
    skill: 30 + Math.floor(rng.next() * 30),
    employed: false,
  }
}

/** 按财富（存款）分层：穷人 / 中产 / 富人 / 老板；不超过本 pack 允许的最高阶层。 */
function updateClasses(state: GameState, ctx: ContentContext): void {
  const { middle, rich, boss } = ECONOMY.classWealth
  const order: ClassID[] = ['poor', 'middle', 'rich', 'boss']
  const maxIdx = Math.max(0, ...ctx.pack.classes.map((c) => order.indexOf(c)))
  for (const r of state.residents) {
    const wealth = r.savings >= boss ? 3 : r.savings >= rich ? 2 : r.savings >= middle ? 1 : 0
    r.classId = order[Math.min(wealth, maxIdx)]!
  }
}

export function updatePopulation(
  state: GameState,
  ctx: ContentContext,
  rng: Rng,
  hungry: number,
  day: number,
): LogEntry[] {
  const logs: LogEntry[] = []
  const pop = state.residents.length
  if (pop === 0) return logs

  const avgSat = sum(state.residents.map((r) => r.satisfaction)) / pop
  const th = ECONOMY.immigrationSatThreshold

  // 迁入改由 applyAdmission 处理（“想来的人数”由 computeArrivals 写入 state.arrivals）。

  // ---- 死亡（饥饿） → 存款充公 -------------------------------------------
  if (hungry > 0) {
    let deaths = Math.max(0, Math.ceil(hungry * ECONOMY.hungerDeathRate))
    deaths = Math.min(deaths, Math.max(0, state.residents.length - ECONOMY.minPopulation))
    if (deaths > 0) {
      const doomed = [...state.residents]
        .sort((a, b) => a.satisfaction - b.satisfaction)
        .slice(0, deaths)
      let confiscated = 0
      for (const r of doomed) confiscated += r.savings
      const ids = new Set(doomed.map((r) => r.id))
      state.residents = state.residents.filter((r) => !ids.has(r.id))
      state.government.money = round2(state.government.money + confiscated)
      logs.push({
        day,
        kind: 'population',
        text: `${deaths} 人因饥饿死亡，遗产充公 ¥${round2(confiscated)}`,
      })
    }
  }

  // ---- 迁出（满意度低） → 带走存款 ----------------------------------------
  if (avgSat < ECONOMY.emigrationSatThreshold) {
    let leave = Math.max(1, Math.floor(state.residents.length * 0.02))
    leave = Math.min(leave, Math.max(0, state.residents.length - ECONOMY.minPopulation))
    if (leave > 0) {
      const doomed = [...state.residents]
        .sort((a, b) => a.satisfaction - b.satisfaction)
        .slice(0, leave)
      let taken = 0
      for (const r of doomed) taken += r.savings
      const ids = new Set(doomed.map((r) => r.id))
      state.residents = state.residents.filter((r) => !ids.has(r.id))
      logs.push({
        day,
        kind: 'population',
        text: `${leave} 人迁离村庄，带走存款 ¥${round2(taken)}`,
      })
    }
  }

  updateClasses(state, ctx)
  return logs
}

/** 计算本回合“想来”的移民人数（写入 state.arrivals），供下一回合由 AI 决定放行多少。 */
export function computeArrivals(state: GameState): void {
  const pop = state.residents.length
  const th = ECONOMY.immigrationSatThreshold
  if (pop === 0) {
    state.arrivals = 0
    return
  }
  const avgSat = sum(state.residents.map((r) => r.satisfaction)) / pop
  if (avgSat < th) {
    state.arrivals = 0
    return
  }
  state.arrivals = Math.max(
    0,
    Math.round((pop * ECONOMY.immigrationRate * (avgSat - th)) / (100 - th)),
  )
}

/** 放行移民：最多放行 min(想来人数, 允许上限, 住房余量, 岗位余量) 人。 */
export function applyAdmission(
  state: GameState,
  ctx: ContentContext,
  rng: Rng,
  day: number,
): LogEntry[] {
  const pop = state.residents.length
  if (pop === 0 || state.arrivals <= 0) return []
  const room = Math.max(
    0,
    Math.min(housingCapacity(state, ctx) - pop, jobCapacity(state, ctx) - pop),
  )
  const allow = Math.max(0, Math.floor(state.government.immigrationAllowance))
  const admit = Math.min(state.arrivals, allow, room)
  if (admit <= 0) return []
  for (let i = 0; i < admit; i++) {
    state.residents.push(makeResident(state, rng, 'poor'))
  }
  return [
    { day, kind: 'population', text: `${admit} 人获准迁入（本回合想来 ${state.arrivals} 人）` },
  ]
}
