import { TIME, advanceHour, createInitialState } from '../src/engine/index.ts'
import type { GameState, PackID } from '../src/engine/index.ts'
import { decide } from '../src/ai/heuristic.ts'

// ---------------------------------------------------------------------------
// 无头验收：用启发式基线 AI 跑 N 天（按小时推进），打印轨迹并断言。
// 用法：npm run sim -- [days] [seed] [pack]
//
// 时间模型：1 tick = 1 游戏小时；AI 每天 0 点决策一次，命令次日 06:00 生效。
// ---------------------------------------------------------------------------

interface RunResult {
  final: GameState
  startPop: number
  startMoney: number
  minSat: number
  minMoney: number
  maxHungry: number
}

function pad(value: string | number, width: number): string {
  return String(value).padStart(width, ' ')
}

function run(pack: PackID, seed: number, days: number): RunResult {
  let state = createInitialState({ pack, seed })
  const startPop = state.residents.length
  const startMoney = state.government.money

  let minSat = 100
  let minMoney = startMoney
  let maxHungry = 0

  console.log(
    `${pad('天', 4)} ${pad('人口', 6)} ${pad('满意度', 8)} ${pad('余额', 8)} ${pad('饥饿', 6)} ${pad('就业', 6)} ${pad('面包', 7)} ${pad('蔬菜', 7)} ${pad('小麦', 7)}`,
  )

  for (let i = 1; i <= days; i++) {
    for (let h = 0; h < TIME.hoursPerDay; h++) {
      const actions = state.hour === 0 ? decide(state) : []
      state = advanceHour(state, actions).state
    }
    const snap = state.history[state.history.length - 1]!
    minSat = Math.min(minSat, snap.avgSatisfaction)
    minMoney = Math.min(minMoney, snap.money)
    maxHungry = Math.max(maxHungry, snap.hungry)

    if (i <= 5 || i % 10 === 0) {
      console.log(
        `${pad(snap.day, 4)} ${pad(snap.population, 6)} ${pad(snap.avgSatisfaction.toFixed(1), 8)} ${pad(snap.money.toFixed(0), 8)} ${pad(snap.hungry, 6)} ${pad(snap.employed, 6)} ${pad((state.goods['coarse_bread'] ?? 0).toFixed(0), 7)} ${pad((state.goods['vegetable'] ?? 0).toFixed(0), 7)} ${pad((state.goods['wheat'] ?? 0).toFixed(0), 7)}`,
      )
    }
  }

  return { final: state, startPop, startMoney, minSat, minMoney, maxHungry }
}

function main(): void {
  const days = Number(process.argv[2] ?? '100')
  const seed = Number(process.argv[3] ?? '12345')
  const pack = (process.argv[4] as PackID | undefined) ?? 'v0.3'

  console.log(`\n=== Sovit 引擎验收  pack=${pack} seed=${seed} days=${days} ===\n`)
  const result = run(pack, seed, days)
  const finalSnap = result.final.history[result.final.history.length - 1]!

  // ---- 断言 -------------------------------------------------------------
  // v0.3 / v1.0 都带住房，所以统一按「有住房」判（v0.1 / v0.2 已删除）。
  const checks: Array<{ name: string; ok: boolean; detail: string }> = [
    {
      name: '人口不崩（≥ 开局 70%）',
      ok: finalSnap.population >= result.startPop * 0.7,
      detail: `${result.startPop} → ${finalSnap.population}`,
    },
    {
      name: '满意度终值 ≥ 45',
      ok: finalSnap.avgSatisfaction >= 45,
      detail: `终值 ${finalSnap.avgSatisfaction.toFixed(1)}，最低 ${result.minSat.toFixed(1)}`,
    },
    {
      name: '政府赤字（私有化代价，仅报告）',
      ok: finalSnap.money > -1e6,
      detail: `终值 ¥${finalSnap.money.toFixed(0)}，最低 ¥${result.minMoney.toFixed(0)}`,
    },
    {
      name: '可复现（同种子同结果）',
      ok: false,
      detail: '',
    },
    {
      name: '人口增长（住房 + 建材链，≥ 开局 1.3 倍）',
      ok: finalSnap.population >= result.startPop * 1.3,
      detail: `${result.startPop} → ${finalSnap.population}`,
    },
  ]

  // 复现性：再跑一次，比较终局快照
  const rerun = run(pack, seed, days)
  const a = JSON.stringify(result.final.history)
  const b = JSON.stringify(rerun.final.history)
  checks[3]!.ok = a === b
  checks[3]!.detail = a === b ? '两次运行完全一致' : '结果不一致！'

  console.log('\n--- 验收结果 ---')
  let allOk = true
  for (const c of checks) {
    if (!c.ok) allOk = false
    console.log(`${c.ok ? '✅' : '❌'} ${c.name}  (${c.detail})`)
  }
  console.log(`\n峰值饥饿：${result.maxHungry} 人`)
  console.log(allOk ? '\n全部通过 🎉\n' : '\n存在未通过项 ❌\n')

  if (!allOk) process.exitCode = 1
}

main()
