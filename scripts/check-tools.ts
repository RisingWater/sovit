/**
 * 工具（石制工具）的 TS 侧自检：**消耗换产能**（用户 2026-10）。
 *
 * 用户原话："石制工具如果有可以消耗提升农业/工业/矿场产能的逻辑做一下。
 * 之前好像说一个工人 10 天消耗 1 工具。"
 *
 * 为什么单独测：golden 那 20 天里**一件工具都没造**（`tool_works` 不在脚本里），
 * 也就是说 `npm test` 的黄金对拍根本碰不到 `allocateTools`。汇率的单位（件/人/日）
 * 写错、把"投入"一起放大、或者只给某一个产业加成，都只有这里能抓。
 *
 * GDScript 那份镜像由 `godot/tools/tool_test.gd` 对拍（同口径同数字）。
 *
 * 用法：node --experimental-strip-types scripts/check-tools.ts
 */
import { ECONOMY } from '../src/engine/config.ts'
import { ALL_GOODS, buildContext } from '../src/engine/content/index.ts'
import { createInitialState } from '../src/engine/index.ts'
import type { GameState } from '../src/engine/index.ts'
import { assignLabor, assignedWorkers } from '../src/engine/systems/labor.ts'
import { runProductionStep } from '../src/engine/systems/production.ts'
import { allocateTools, toolPerWorker } from '../src/engine/systems/tools.ts'
import { techBonuses } from '../src/engine/systems/tech_bonus.ts'
import { round2 } from '../src/engine/util.ts'

let failed = 0
function check(cond: boolean, msg: string): void {
  if (cond) {
    console.log(`  ok   ${msg}`)
  } else {
    console.error(`  FAIL ${msg}`)
    failed += 1
  }
}

const ctx = buildContext('v0.3')
const near = (a: number, b: number, eps = 0.001): boolean => Math.abs(a - b) <= eps

/** 加一座工坊（字段与引擎造出来的完全一致，少一个 wageCap 夜间结算就会崩）。 */
function addShop(s: GameState, defId: string, id: string, workers?: number): void {
  const d = ctx.buildings[defId]!
  s.shops.push({
    id,
    defId,
    owner: 'state',
    targetWorkers: workers ?? d.workers,
    wage: ECONOMY.refWage,
    wageCap: ECONOMY.defaultWageCap,
    level: 1,
    active: true,
    profit: 0,
    skill: 50,
    planned: 0,
  })
}

function addResidents(s: GameState, n: number): void {
  for (let i = 0; i < n; i++) {
    s.residents.push({
      id: `res#tool${s.residents.length + 1}`,
      classId: 'poor',
      savings: 30,
      satisfaction: 70,
      skill: 50,
      employed: false,
      satisfactionParts: { food: 1, comfort: 1, price: 1 },
    } as GameState['residents'][number])
  }
}

function fresh(): GameState {
  const s = createInitialState({ pack: 'v0.3', seed: 20261019 })
  s.goods['stone_tools'] = 100
  return s
}

/** 让一座工坊以固定 toolBoost 跑一次生产步，返回主产出增量与本次投入量。 */
function produceOnce(
  s: GameState,
  shopId: string,
  boost: number,
): { out: number; inputs: Record<string, number> } {
  const shop = s.shops.find((x) => x.id === shopId)!
  const def = ctx.buildings[shop.defId]!
  const recipe = ctx.recipes[def.recipe!]!
  shop.toolBoost = boost
  shop.planned = 10
  for (const g of Object.keys(recipe.inputs)) s.goods[g] = Math.max(s.goods[g] ?? 0, 500)
  const beforeIn: Record<string, number> = {}
  for (const g of Object.keys(recipe.inputs)) beforeIn[g] = s.ledgerToday.consumed[g] ?? 0
  const gid = Object.keys(recipe.output)[0]!
  const before = s.goods[gid] ?? 0
  runProductionStep(s, ctx, 1)
  const inputs: Record<string, number> = {}
  for (const g of Object.keys(beforeIn)) inputs[g] = (s.ledgerToday.consumed[g] ?? 0) - beforeIn[g]!
  return { out: (s.goods[gid] ?? 0) - before, inputs }
}

// ---- 1. 耐久：石 10 天 / 铁 15 天；科技"寿命"取最高 ------------------------
{
  const stone = ALL_GOODS['stone_tools']
  const iron = ALL_GOODS['iron_tools']
  check(stone?.durabilityDays === 10, `石制工具耐久 = ${stone?.durabilityDays} 天（应当 10）`)
  check(iron?.durabilityDays === 15, `铁制工具耐久 = ${iron?.durabilityDays} 天（应当 15）`)
  check((iron?.toolBonus ?? 0) > (stone?.toolBonus ?? 0),
    `铁制工具加成 ${iron?.toolBonus} > 石制 ${stone?.toolBonus}（更耐用也更强）`)
  check(ECONOMY.tools.perWorkstation === 0.1, `perWorkstation 仍作兜底 = ${ECONOMY.tools.perWorkstation}（应当 0.1）`)

  const s = fresh()
  // 没人上工时 techBonuses 也要能算：直接看每工人日耗
  check(near(toolPerWorker(s, ctx, 'stone_tools'), 0.1), '石制：0.1 件/人/日（= 10 天 1 件）')
  check(near(toolPerWorker(s, ctx, 'iron_tools'), 1 / 15), `铁制：${toolPerWorker(s, ctx, 'iron_tools').toFixed(4)} 件/人/日（= 15 天 1 件）`)

  // 科技「淬火」+20%：寿命 ×1.2
  s.research.done.push('tempering' as never)
  check(near(toolPerWorker(s, ctx, 'iron_tools'), 1 / 18), `淬火后铁制 = ${(1 / 18).toFixed(4)}（15→18 天）`)
  // 科技「精炼」+50%：**取最高**，不是 +70%
  s.research.done.push('refining' as never)
  check(near(techBonuses(s, ctx).toolLife, 0.5), `两档都研究：toolLife = ${techBonuses(s, ctx).toolLife}（应当 0.5，取最高）`)
  check(near(toolPerWorker(s, ctx, 'iron_tools'), 1 / 22.5), `精炼后铁制 = ${(1 / 22.5).toFixed(4)}（15→22.5 天）`)
  check(near(toolPerWorker(s, ctx, 'stone_tools'), 1 / 15), `精炼后石制 = ${(1 / 15).toFixed(4)}（10→15 天）`)
}

// ---- 2/3. 农业 / 工业 / 矿场：黎明装配 + 扣料 + 台账拆分 -------------------
{
  const s = fresh()
  addShop(s, 'wheat_farm', 't_wheat_farm')
  addShop(s, 'coarse_bakery', 't_coarse_bakery')
  addShop(s, 'quarry', 't_quarry')
  addResidents(s, 8)
  // 黎明顺序：先派人上工，再发工具（`allocateTools` 读的是**在岗**人数）
  assignLabor(s, ctx)
  allocateTools(s, ctx, s.day)

  let boosted = 0
  let expected = 0
  let allSectors = true
  for (const [defId, sid] of [
    ['wheat_farm', 't_wheat_farm'],
    ['coarse_bakery', 't_coarse_bakery'],
    ['quarry', 't_quarry'],
  ] as const) {
    const shop = s.shops.find((x) => x.id === sid)!
    const workers = assignedWorkers(s, sid)
    if (workers <= 0) {
      allSectors = false
      continue
    }
    if (near(shop.toolBoost ?? 1, 1.25)) boosted++
    expected += ECONOMY.tools.perWorkstation * workers
    const sector = ctx.buildings[defId]!.sector
    if (!sector || !['agri', 'goods', 'material'].includes(sector)) allSectors = false
  }
  check(boosted === 3, `农业 / 工业 / 矿场三类都装配上了工具（${boosted}/3）`)
  check(allSectors, '三类的 sector 都在 agri / goods / material 里')

  const used = round2(100 - (s.goods['stone_tools'] ?? 0))
  check(near(used, round2(expected), 0.02), `扣了 ${used} 件，按 0.1×在岗人数应为 ${round2(expected)}`)

  const total = s.ledgerToday.consumed['stone_tools'] ?? 0
  check(near(total, used, 0.02), `台账 consumed[stone_tools] = ${total}（与实际扣料一致）`)
  const by = s.ledgerToday.consumedBy['stone_tools'] ?? {}
  const sum = Object.values(by).reduce((a, b) => a + b, 0)
  check(near(sum, total, 0.02), `台账 consumedBy 加起来 ${round2(sum)} = 总量 ${total}（面板明细不打架）`)
  for (const defId of ['wheat_farm', 'coarse_bakery', 'quarry']) {
    check((by[defId] ?? 0) > 0, `台账里记着「${defId}」吃了工具`)
  }

  // ---- 4. 产出 ×1.25、投入不变 -----------------------------------------
  const a = produceOnce(s, 't_coarse_bakery', 1.25)
  const b = produceOnce(s, 't_coarse_bakery', 1)
  check(b.out > 0, '没装工具时也产得出来（否则倍率无从比较）')
  const ratio = b.out > 0 ? a.out / b.out : 0
  check(near(ratio, 1.25, 0.01), `产出倍率 = ${ratio.toFixed(3)}（应当 1.25）`)
  const inputsSame = Object.keys(a.inputs).every((g) => near(a.inputs[g]!, b.inputs[g] ?? 0, 0.01))
  check(inputsSame, '投入没有跟着放大（工具只放大产出）')
}

// ---- 5. 边界：没工具不加成 / 空工坊不扣 / 不够时先到先得 --------------------
{
  const s = fresh()
  s.goods['stone_tools'] = 0
  addShop(s, 'wheat_farm', 't_wheat_farm')
  addResidents(s, 6)
  assignLabor(s, ctx)
  allocateTools(s, ctx, s.day)
  const farm = s.shops.find((x) => x.id === 't_wheat_farm')!
  check(near(farm.toolBoost ?? 1, 1), '库存 0 件工具 → 不加成')

  // 工位 0（没人上工）不该扣工具
  const s2 = fresh()
  addShop(s2, 'wheat_farm', 't_a', 0)
  addResidents(s2, 6)
  assignLabor(s2, ctx)
  const before2 = s2.goods['stone_tools'] ?? 0
  allocateTools(s2, ctx, s2.day)
  check(near(s2.goods['stone_tools'] ?? 0, before2, 0.0001), '工位 0 的工坊不扣工具')

  // 只够一座：按 shops 顺序先到先得（确定性）
  const s3 = fresh()
  addShop(s3, 'wheat_farm', 't_first')
  addShop(s3, 'coarse_bakery', 't_second')
  addResidents(s3, 8)
  assignLabor(s3, ctx)
  const w1 = assignedWorkers(s3, 't_first')
  s3.goods['stone_tools'] = round2(ECONOMY.tools.perWorkstation * w1 + 0.05)
  allocateTools(s3, ctx, s3.day)
  const first = s3.shops.find((x) => x.id === 't_first')!
  const second = s3.shops.find((x) => x.id === 't_second')!
  check(near(first.toolBoost ?? 1, 1.25), '只够一座时，排在前面的先拿到（确定性）')
  check(near(second.toolBoost ?? 1, 1), '排在后面的没拿到（不匀着分）')
}

console.log(failed === 0 ? '\n工具（消耗换产能）自检通过 🎉\n' : `\n工具自检失败 ${failed} 项 ❌\n`)
if (failed > 0) process.exitCode = 1
