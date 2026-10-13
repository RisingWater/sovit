import { mkdirSync, writeFileSync } from 'node:fs'
import { TIME, advanceHour, createInitialState } from '../src/engine/index.ts'
import type { Action, GameState } from '../src/engine/index.ts'

// ---------------------------------------------------------------------------
// 黄金轨迹（golden）：用**固定命令脚本**（不含 AI）跑 N 天，逐日记录状态摘要。
// Godot 的 GDScript 仿真核心必须复现同一份摘要 → 保证跨语言移植不漂移。
//
// 运行：npm run golden   →  godot/tests/golden/<pack>-<seed>.json
// ---------------------------------------------------------------------------

const PACK = 'v0.3'
const SEED = 12345
const DAYS = 20

/** 固定脚本：tick = 自开局起的绝对小时数（0 起）。命令在下一个黎明生效。 */
const SCRIPT: Array<{ tick: number; actions: Action[] }> = [
  {
    tick: 0,
    actions: [
      // 人口上限钉在开局人口 = 这一局不接移民，让对拍只反映生产/财政
      { type: 'set_population_cap', value: 12 },
      { type: 'build', buildingId: 'wheat_farm' },
      { type: 'build', buildingId: 'vegetable_farm' },
      { type: 'build', buildingId: 'coarse_mill' },
      { type: 'build', buildingId: 'coarse_bakery' },
      { type: 'build', buildingId: 'lumberjack' },
      { type: 'build', buildingId: 'quarry' },
      { type: 'build', buildingId: 'clay_pit' },
      { type: 'build', buildingId: 'firewood_works' },
      { type: 'build', buildingId: 'brick_kiln' },
      { type: 'build', buildingId: 'construction_works' },
      { type: 'build_housing', goodId: 'hut' },
      { type: 'build_housing', goodId: 'hut' },
      { type: 'build_housing', goodId: 'hut' },
    ],
  },
  {
    tick: 72, // day 3（建筑已于黎明启用）
    actions: [
      { type: 'set_workers', shopId: 'lumberjack#1', value: 8 },
      { type: 'set_workers', shopId: 'quarry#1', value: 6 },
      { type: 'set_workers', shopId: 'clay_pit#1', value: 6 },
      { type: 'build_housing', goodId: 'hut' },
      { type: 'build_housing', goodId: 'hut' },
      { type: 'build_housing', goodId: 'hut' },
    ],
  },
  {
    tick: 120,
    actions: [
      { type: 'build', buildingId: 'wheat_farm' },
      { type: 'build', buildingId: 'coarse_mill' },
      { type: 'build', buildingId: 'coarse_bakery' },
      { type: 'set_workers', shopId: 'coarse_mill#1', value: 4 },
      { type: 'build_housing', goodId: 'hut' },
      { type: 'build_housing', goodId: 'hut' },
    ],
  },
  {
    tick: 168,
    actions: [
      { type: 'expand', shopId: 'coarse_bakery#1' },
      { type: 'set_workers', shopId: 'coarse_bakery#1', value: 4 },
      { type: 'build_housing', goodId: 'hut' },
      { type: 'build_housing', goodId: 'hut' },
    ],
  },
  {
    tick: 264,
    actions: [
      { type: 'build', buildingId: 'wheat_farm' },
      { type: 'build', buildingId: 'coarse_mill' },
      { type: 'set_workers', shopId: 'wheat_farm#1', value: 8 },
      { type: 'build_housing', goodId: 'hut' },
      { type: 'build_housing', goodId: 'hut' },
    ],
  },
  {
    tick: 360,
    actions: [
      { type: 'build', buildingId: 'coarse_bakery' },
      { type: 'set_workers', shopId: 'coarse_bakery#1', value: 4 },
      { type: 'build', buildingId: 'vegetable_farm' },
      { type: 'build_housing', goodId: 'hut' },
      { type: 'build_housing', goodId: 'hut' },
    ],
  },
]

const byTick = new Map<number, Action[]>(SCRIPT.map((s) => [s.tick, s.actions]))

function r3(n: number): number {
  return Math.round(n * 1000) / 1000
}

function summarize(state: GameState) {
  const goods: Record<string, number> = {}
  for (const g of Object.keys(state.goods)) goods[g] = r3(state.goods[g] ?? 0)

  const housing: Record<string, number> = {}
  for (const g of Object.keys(state.housing)) housing[g] = state.housing[g] ?? 0

  const prices: Record<string, number> = {}
  for (const g of Object.keys(state.prices)) prices[g] = r3(state.prices[g] ?? 0)

  const shops = state.shops
    .map((s) => ({ id: s.id, defId: s.defId, level: s.level, workers: s.targetWorkers, active: s.active }))
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))

  const pop = state.residents.length
  const satisfaction = pop > 0 ? state.residents.reduce((a, r) => a + r.satisfaction, 0) / pop : 0

  return {
    day: state.day,
    hour: state.hour,
    population: pop,
    satisfaction: r3(satisfaction),
    hungry: state.history[state.history.length - 1]?.hungry ?? 0,
    money: r3(state.government.money),
    goods,
    prices,
    housing,
    shops,
  }
}

function main(): void {
  let state = createInitialState({ pack: PACK, seed: SEED })
  const daily = [summarize(state)]

  const totalHours = DAYS * TIME.hoursPerDay
  for (let t = 0; t < totalHours; t++) {
    const actions = byTick.get(t) ?? []
    state = advanceHour(state, actions).state
    if (state.hour === 0) daily.push(summarize(state))
  }

  const out = {
    schemaVersion: 1,
    pack: PACK,
    seed: SEED,
    days: DAYS,
    hoursPerDay: TIME.hoursPerDay,
    script: SCRIPT,
    daily,
  }

  mkdirSync('godot/tests/golden', { recursive: true })
  const path = `godot/tests/golden/${PACK}-${SEED}.json`
  writeFileSync(path, JSON.stringify(out, null, 2))

  const last = daily[daily.length - 1]!
  console.log(`golden → ${path}`)
  console.log(`  days=${daily.length - 1}  pop=${last.population}  money=${last.money}  shops=${last.shops.length}`)
}

main()
