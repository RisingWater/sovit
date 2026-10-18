/**
 * 燃料（煤 / 木柴）与煤矿的 TS 侧自检（用户 2026-10："地图上添加煤矿"）。
 *
 * 以前燃料写死是木柴；有了煤矿之后 `FUEL_ORDER = ['coal', 'firewood']`：
 * 每座有 `recipe.fuel` 的工坊在**黎明排产**时挑一种（`shop.fuelGood`），全天不变。
 *
 * 为什么单独测：golden 那 20 天里**没有任何烧燃料的建筑**（只有农田/磨坊/面包房），
 * 也就是说 `npm test` 的黄金对拍碰不到这条路径。挑错燃料、扣错商品、或者没燃料也能产，
 * 都只有这里能抓。
 *
 * GDScript 那份镜像由 `godot/tools/coal_test.gd` 对拍（同口径同数字）。
 *
 * 用法：node --experimental-strip-types scripts/check-fuels.ts
 */
import { readFileSync } from 'node:fs'
import { ECONOMY } from '../src/engine/config.ts'
import { buildContext } from '../src/engine/content/index.ts'
import { createInitialState } from '../src/engine/index.ts'
import type { GameState } from '../src/engine/index.ts'
import { assignLabor } from '../src/engine/systems/labor.ts'
import { FUEL_ORDER, planProduction, runProductionStep } from '../src/engine/systems/production.ts'
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

function addShop(s: GameState, defId: string, id: string): void {
  const d = ctx.buildings[defId]!
  s.shops.push({
    id,
    defId,
    owner: 'state',
    targetWorkers: d.workers,
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
      id: `res#fuel${s.residents.length + 1}`,
      classId: 'poor',
      savings: 30,
      satisfaction: 70,
      skill: 50,
      employed: false,
    } as GameState['residents'][number])
  }
}

/** 一座烧燃料的砖窑 + 原料 + 若干人，返回砖窑实例。 */
function kilnState(coal: number, firewood: number): GameState {
  const s = createInitialState({ pack: 'v0.3', seed: 20261020 })
  addShop(s, 'brick_kiln', 't_kiln')
  addResidents(s, 4)
  s.goods['clay'] = 500
  s.goods['coal'] = coal
  s.goods['firewood'] = firewood
  assignLabor(s, ctx)
  return s
}

const kilnOf = (s: GameState) => s.shops.find((x) => x.id === 't_kiln')!

// ---- 1. 取料顺序：先煤后木柴 ---------------------------------------------
{
  check(FUEL_ORDER[0] === 'coal' && FUEL_ORDER[1] === 'firewood',
    `燃料顺序 = ${FUEL_ORDER.join(' → ')}（应当先煤后木柴）`)
  check(ctx.goodSet.has('coal'), 'content 里有 coal 这个商品')
  check((ctx.goods['coal'] as { category?: string } | undefined)?.category === 'fuel', 'coal 的类别是 fuel')
}

// ---- 2. 有煤 → 挑煤、只扣煤、台账记来源 ---------------------------------
{
  const s = kilnState(100, 100)
  planProduction(s, ctx)
  const kiln = kilnOf(s)
  check(kiln.fuelGood === 'coal', `有煤时 fuelGood = ${kiln.fuelGood}（应为 coal）`)
  check((kiln.planned ?? 0) > 0, `砖窑排产 ${kiln.planned} 批（应当 > 0）`)

  const coal0 = s.goods['coal'] ?? 0
  const wood0 = s.goods['firewood'] ?? 0
  runProductionStep(s, ctx, 1)
  const coalUsed = round2(coal0 - (s.goods['coal'] ?? 0))
  const woodUsed = round2(wood0 - (s.goods['firewood'] ?? 0))
  check(coalUsed > 0, `扣了煤 ${coalUsed}（应当 > 0）`)
  check(near(woodUsed, 0, 0.001), `木柴一件没动（实际 ${woodUsed}）`)
  const by = s.ledgerToday.consumedBy['coal'] ?? {}
  check((by['brick_kiln'] ?? 0) > 0, '台账 consumedBy[coal] 里记着 brick_kiln（资源页能看出谁烧的）')
  check(near(s.ledgerToday.consumed['coal'] ?? 0, coalUsed, 0.02),
    `台账 consumed[coal] = ${s.ledgerToday.consumed['coal']}（与实际扣料一致）`)
}

// ---- 3. 没煤 → 改烧木柴 -------------------------------------------------
{
  const s = kilnState(0, 100)
  planProduction(s, ctx)
  const kiln = kilnOf(s)
  check(kiln.fuelGood === 'firewood', `没煤时 fuelGood = ${kiln.fuelGood}（应为 firewood）`)
  const wood0 = s.goods['firewood'] ?? 0
  runProductionStep(s, ctx, 1)
  check((s.goods['firewood'] ?? 0) < wood0, `扣了木柴（${wood0} → ${s.goods['firewood']}）`)
}

// ---- 4. 两种都没有 → 不排产、不产出（不能凭空烧） ------------------------
{
  const s = kilnState(0, 0)
  planProduction(s, ctx)
  const kiln = kilnOf(s)
  check(near(kiln.planned ?? 0, 0, 0.001), `没有燃料时 planned = ${kiln.planned}（应当 0）`)
  const brick0 = s.goods['brick'] ?? 0
  runProductionStep(s, ctx, 1)
  check(near(s.goods['brick'] ?? 0, brick0, 0.001), '没有燃料却产出了砖（凭空烧）')
}

// ---- 5. 内容：煤矿场建在煤矿上、产煤 -------------------------------------
{
  const b = ctx.buildings['coal_mine']
  check(b !== undefined, 'content 里有煤矿场 coal_mine')
  // `terrain` 不在 ContentContext 里（校验器只挑仿真要用的字段），所以回内容 JSON 里核对
  const bjson = JSON.parse(readFileSync(new URL('../content/buildings.json', import.meta.url), 'utf8')) as {
    buildings: { id: string; terrain?: string }[]
  }
  const terrainOf = bjson.buildings.find((x) => x.id === 'coal_mine')?.terrain
  check(terrainOf === 'coal', `煤矿场的 terrain = ${terrainOf}（应为 coal）`)
  const rec = ctx.recipes[(b as { recipe?: string }).recipe ?? '']
  check((rec?.output['coal'] ?? 0) > 0, `煤矿场产煤 ${rec?.output['coal']}/日`)
  // 谁解锁煤矿场：从内容 JSON 里读（ContentContext 不暴露 techs 树）
  const techsJson = readFileSync(new URL('../content/technologies.json', import.meta.url), 'utf8')
  const techs = (JSON.parse(techsJson) as { technologies: { id: string; unlocks?: { buildings?: string[] } }[] }).technologies
  const unlockedBy = techs.filter((t) => (t.unlocks?.buildings ?? []).includes('coal_mine')).map((t) => t.id)
  check(unlockedBy.join(',') === 'brickmaking', `煤矿场由「烧砖」解锁（实际 ${unlockedBy.join(',') || '无人解锁'}）`)
}

console.log(failed === 0 ? '\n燃料（煤 / 木柴）自检通过 🎉\n' : `\n燃料自检失败 ${failed} 项 ❌\n`)
if (failed > 0) process.exitCode = 1
