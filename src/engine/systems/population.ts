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
    if (def) total += def.workers
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

  // ---- 迁入（同时受住房容量与岗位空缺限制） -----------------------------
  const housingRoom = Math.max(0, housingCapacity(state, ctx) - pop)
  const vacancies = Math.max(0, jobCapacity(state, ctx) - pop)
  const room = Math.min(housingRoom, vacancies)
  if (hungry === 0 && avgSat >= th && room > 0) {
    const expected = Math.min(
      room,
      (pop * ECONOMY.immigrationRate * (avgSat - th)) / (100 - th),
    )
    const whole = Math.floor(expected)
    const arrivals = whole + (rng.next() < expected - whole ? 1 : 0)
    if (arrivals > 0) {
      for (let i = 0; i < arrivals; i++) {
        state.residents.push(makeResident(state, rng, 'poor'))
      }
      logs.push({ day, kind: 'population', text: `${arrivals} 人迁徙而来` })
    }
  }

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
