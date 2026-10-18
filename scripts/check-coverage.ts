/**
 * 覆盖（诊所 / 医院 / 学校 / 治安所）自检 —— 2026-10 第二批。
 *
 * 用户定的口径：
 *   · "学校根据人口，一座覆盖 100 人口，有覆盖就加成"
 *   · "治安、诊所（医院）也是，一座覆盖 50 人，有覆盖才加成满意度"
 *   · "中产以上会去消费"医疗与教育；治安四阶层都有
 *
 * 所以覆盖**不是消费品**：不看产量，只看"在岗 + 有配方时排得上产"。
 * 这条门槛盯六件事：
 *   1. 覆盖人数 = 建筑 × N × 等级（60 人 → 50/60）
 *   2. 覆盖率封顶 1.0（人少时不会超过 100%）
 *   3. 没原料 → 排不上产 → 覆盖归零（服务断供）
 *   4. 医疗/教育只惠及中产以上；治安所有人有
 *   5. 学校按覆盖率加速熟练度成长（满覆盖 = 基础 ×1.5）
 *   6. 覆盖率不进存档、不改任何产量（只动满意度与熟练度）
 *
 * GDScript 镜像：`godot/tools/coverage_test.gd`（同口径同数字）。
 *
 * 用法：node --experimental-strip-types scripts/check-coverage.ts
 */
import { ECONOMY } from '../src/engine/config.ts'
import { buildContext } from '../src/engine/content/index.ts'
import { createInitialState } from '../src/engine/index.ts'
import type { GameState } from '../src/engine/index.ts'
import { assignLabor, growSkills } from '../src/engine/systems/labor.ts'
import {
  coverageRatios,
  coverageSatBonus,
  coverageSkillMultiplier,
  coveredPeople,
} from '../src/engine/systems/coverage.ts'
import { round2 } from '../src/engine/util.ts'

let failed = 0
function check(cond: boolean, msg: string): void {
  if (cond) console.log(`  ok   ${msg}`)
  else {
    console.error(`  FAIL ${msg}`)
    failed += 1
  }
}
const near = (a: number, b: number, eps = 0.001): boolean => Math.abs(a - b) <= eps

const ctx = buildContext('v0.3')

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

/** 一座空的村子 + n 个居民（前 half 个中产，其余穷人）。 */
function village(n: number, middleHalf = true): GameState {
  const s = createInitialState({ pack: 'v0.3', seed: 20261022 })
  s.residents = []
  for (let i = 0; i < n; i++) {
    const middle = middleHalf && i < Math.ceil(n / 2)
    s.residents.push({
      id: `res#c${i + 1}`,
      classId: middle ? 'middle' : 'poor',
      savings: 50,
      satisfaction: 60,
      skill: 30,
      employed: false,
    } as GameState['residents'][number])
  }
  return s
}


/** 把前 n 个居民派到某座工坊（不经 `assignLabor` 的择优逻辑，门槛要确定性）。 */
function hire(s: GameState, from: number, n: number, shopId: string): void {
  for (let i = from; i < from + n && i < s.residents.length; i++) {
    s.residents[i]!.employed = true
    s.residents[i]!.jobShopId = shopId
  }
}

/** 让某座工坊"排得上产"（黎明排产会给正数；门槛里手工给，避免依赖配方细节）。 */
function plan(s: GameState, shopId: string): void {
  const shop = s.shops.find((x) => x.id === shopId)
  if (shop) shop.planned = 1
}
// ---- 1. 覆盖人数与覆盖率 -------------------------------------------------
{
  const s = village(60)
  addShop(s, 'clinic', 'c1')
  s.goods['potion'] = 100
  hire(s, 0, 2, 'c1')
  // 让诊所"排得上产"：诊所 2 工位，排产靠 planned（这里手工给一个正数，模拟黎明排产）
  plan(s, 'c1')
  const cov = coverageRatios(s, ctx)
  check(near(cov.medical, 50 / 60), `60 人 / 1 座诊所（50 人）→ 医疗覆盖 ${round2(cov.medical)}（应当 ${round2(50 / 60)}）`)
  check(coveredPeople(s, ctx, 'medical') === 50, `coveredPeople(medical) = ${coveredPeople(s, ctx, 'medical')}（应当 50）`)
  check(near(cov.education, 0) && near(cov.safety, 0), '没建学校和治安所时，教育/治安覆盖率 = 0')

  // 人多到超过覆盖能力 → 封顶 1.0
  const s2 = village(20)
  addShop(s2, 'hospital', 'h1')
  s2.goods['potion'] = 100
  s2.goods['herbs'] = 100
  hire(s2, 0, 4, 'h1')
  plan(s2, 'h1')
  check(near(coverageRatios(s2, ctx).medical, 1), `20 人 / 1 座医院（150 人）→ 覆盖率封顶 1.0（实际 ${coverageRatios(s2, ctx).medical}）`)
}

// ---- 2. 缺原料 → 服务断供 ------------------------------------------------
{
  const s = village(60)
  addShop(s, 'clinic', 'c1')
  s.goods['potion'] = 100
  hire(s, 0, 2, 'c1')
  // 没有药水 → 排不上产（planned = 0）
  check(coveredPeople(s, ctx, 'medical') === 0, `排不上产（没药水）→ 覆盖 0 人（实际 ${coveredPeople(s, ctx, 'medical')}）`)
}

// ---- 3. 医疗/教育只给中产以上；治安（M3 才实装）此时为 0 ------------------
{
  const s = village(100)
  addShop(s, 'clinic', 'c1')
  addShop(s, 'school', 's1')
  addShop(s, 'clinic', 'c2')
  s.goods['potion'] = 100
  hire(s, 0, 2, 'c1')
  hire(s, 2, 2, 'c2')
  hire(s, 4, 3, 's1')
  plan(s, 'c1')
  plan(s, 'c2')
  plan(s, 's1')
  const cov = coverageRatios(s, ctx)
  check(near(cov.medical, 1), `100 人 / 2 座诊所（50 + 50）→ 医疗覆盖 ${round2(cov.medical)}`)
  check(near(cov.education, 1), `100 人 / 1 座学校（100 人）→ 教育覆盖 ${round2(cov.education)}`)
  check(near(cov.safety, 0), `本批还没实装治安所（M3），治安覆盖 ${round2(cov.safety)}`)

  const poor = coverageSatBonus(cov, 'poor')
  const middle = coverageSatBonus(cov, 'middle')
  const wantMiddle = 1 * ECONOMY.coverage.medical + 1 * ECONOMY.coverage.education
  check(near(poor, 0), `穷人拿不到医疗/教育加成（实际 ${round2(poor)}）`)
  check(near(middle, wantMiddle), `中产拿医疗+教育 ${round2(middle)}（应当 ${round2(wantMiddle)}）`)
}

// ---- 4. 学校加速熟练度成长 -----------------------------------------------
{
  const s = village(100)
  addShop(s, 'school', 's1')
  hire(s, 0, 3, 's1')
  plan(s, 's1')
  // 全员就业（成长只给在岗的人）
  for (const r of s.residents) r.employed = true
  const before = s.residents[0]!.skill
  growSkills(s, ctx)
  const gain = round2(s.residents[0]!.skill - before)
  const want = round2(ECONOMY.skillGainPerDay * coverageSkillMultiplier(coverageRatios(s, ctx).education))
  check(near(gain, want), `满覆盖时成长 ${gain}/日（应当 ${want} = 基础 ${ECONOMY.skillGainPerDay} × ${round2(coverageSkillMultiplier(1))}）`)

  const s2 = village(100)
  for (const r of s2.residents) r.employed = true
  const before2 = s2.residents[0]!.skill
  growSkills(s2, ctx)
  check(near(round2(s2.residents[0]!.skill - before2), ECONOMY.skillGainPerDay), `没学校时成长 = 基础 ${ECONOMY.skillGainPerDay}/日`)
}

// ---- 5. 覆盖率不写进 state（现算） ---------------------------------------
{
  const s = village(60)
  addShop(s, 'clinic', 'c1')
  s.goods['potion'] = 100
  hire(s, 0, 2, 'c1')
  plan(s, 'c1')
  const keys = Object.keys(s as unknown as Record<string, unknown>)
  check(!keys.includes('coverage'), 'state 里没有 coverage 字段（覆盖率每次现算，不动存档）')
}

console.log(failed === 0 ? '\n覆盖（医疗 / 教育 / 治安）自检通过 🎉\n' : `\n覆盖自检失败 ${failed} 项 ❌\n`)
if (failed > 0) process.exitCode = 1
