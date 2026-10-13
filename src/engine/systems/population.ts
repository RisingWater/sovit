import type { ClassID, ClassDef, GameState, LogEntry, Resident } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import type { Rng } from '../rng.ts'
import { DEFAULTS, ECONOMY } from '../config.ts'
import { round2, sum } from '../util.ts'
import { housingCapacity } from './housing.ts'

// ---------------------------------------------------------------------------
// 人口
//
// 满意度高、无饥饿、且存在住房与岗位空缺时 → 迁入；
// 满意度低或有人饥饿 → 迁出 / 死亡。新居民默认进入穷人阶层。
//
// 迁入**不看岗位数**：岗位可以后补，卡它会让村子永远长不大。
// 规模由玩家设定的「人口上限」控制（防止一口气涌进来一堆人、粮食跟不上饿死）。
// ---------------------------------------------------------------------------

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
  const rd = DEFAULTS.newResident
  return {
    id: `res#${nextResidentIndex(state)}`,
    classId,
    savings: rd.savings,
    satisfaction: rd.satisfaction,
    skill: rd.skillBase + Math.floor(rng.next() * rd.skillRandom),
    employed: false,
  }
}

/** 按财富（存款）分层：依 pack 允许的阶层、按 wealthThreshold 升序逐级上升。 */
function updateClasses(state: GameState, ctx: ContentContext): void {
  const ladder = ctx.pack.classes
    .map((c) => ctx.classes[c])
    .filter((c): c is ClassDef => c !== undefined)
    .sort((a, b) => a.wealthThreshold - b.wealthThreshold)
  if (ladder.length === 0) return
  for (const r of state.residents) {
    let cls = ladder[0]!
    for (const c of ladder) {
      if (r.savings >= c.wealthThreshold) cls = c
    }
    r.classId = cls.id
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

/**
 * 计算本回合"想来"的移民人数（写入 state.arrivals）。
 *
 * 只看两件事：**满意度够不够**，以及**昨天有没有闹饥荒**。
 * 岗位数**不参与**——岗位是可以后补的，卡它会让村子永远长不大
 * （见 docs/spec.md §8「迁入不再看岗位」）。
 */
export function computeArrivals(state: GameState): void {
  const pop = state.residents.length
  const th = ECONOMY.immigrationSatThreshold
  if (pop === 0) {
    state.arrivals = 0
    return
  }
  // 食物充足：昨天的饥饿比例超过阈值就没有人来（饿着肚子还招人只会更糟）
  const hungry = state.history[state.history.length - 1]?.hungry ?? 0
  if (hungry > Math.max(1, pop * ECONOMY.immigrationHungryRate)) {
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

/**
 * 放行移民：`admit = min(想来人数, 住房余量, 人口上限 − 人口)`。
 *
 * **不看岗位数**：岗位是可以后补的（盖房/建店都行），而人口上限由玩家设定，
 * 用来防止"一口气涌进来一堆人、粮食跟不上饿死"。见 docs/spec.md §8。
 */
export function applyAdmission(
  state: GameState,
  ctx: ContentContext,
  rng: Rng,
  day: number,
): LogEntry[] {
  const pop = state.residents.length
  if (pop === 0 || state.arrivals <= 0) return []
  const cap = state.government.populationCap
  const room = Math.max(0, Math.min(housingCapacity(state, ctx) - pop, cap - pop))
  const admit = Math.min(state.arrivals, room)
  if (admit <= 0) return []
  for (let i = 0; i < admit; i++) {
    state.residents.push(makeResident(state, rng, 'poor'))
  }
  return [
    { day, kind: 'population', text: `${admit} 人获准迁入（本回合想来 ${state.arrivals} 人）` },
  ]
}
