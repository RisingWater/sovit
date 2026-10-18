/**
 * 需求系统自检（2026-10 定稿，见 docs/needs.md）。
 *
 * 盯的是"内容与规则的**契约**"，改了需求/价格/产能/工资就要在这里同步：
 *   1. 三项服务是**独立商品**（各自价格、不可储存），绝不合并
 *   2. 四阶层的需求集合就是晋升阶梯（穷人只有治安；医疗从中学起；教育从富起）
 *   3. 单座建筑的产量足够养一大片（不会逼玩家铺满地图）
 *   4. 岗位工资：公共事业统一 3.6、私营按 tier
 *   5. 治安所**不吃武器**（否则开局到民兵之前没人能升中产）
 *
 * GDScript 镜像：`godot/tools/needs_test.gd`。
 *
 * 用法：node --experimental-strip-types scripts/check-needs.ts
 */
import { ECONOMY } from '../src/engine/config.ts'
import { ALL_BUILDINGS, ALL_GOODS, buildContext } from '../src/engine/content/index.ts'
import { defaultWageFor, isPublicService } from '../src/engine/systems/wages.ts'

let failed = 0
function check(cond: boolean, msg: string): void {
  if (cond) console.log(`  ok   ${msg}`)
  else {
    console.error(`  FAIL ${msg}`)
    failed += 1
  }
}

const ctx = buildContext('v0.3')

// ---- 1. 三项服务：独立商品、极便宜、不可储存 ------------------------------
{
  const want: [string, number][] = [
    ['safety', 0.3],
    ['medical_service', 0.5],
    ['education', 0.5],
  ]
  for (const [id, price] of want) {
    const g = ALL_GOODS[id]
    check(g !== undefined, `${id} 在内容里`)
    check(g?.category === 'service', `${id} 的 category = service（实际 ${g?.category}）`)
    check(g?.storable === false, `${id} 不可储存（当日归零）`)
    check((g?.perishRate ?? 0) >= 1, `${id} 的 perishRate = 1（当天不结转）`)
    check(g?.baseValue === price, `${id} 基准价 ${g?.baseValue}（应当 ${price} = 极便宜）`)
  }
  check(ctx.goodSet.has('weapons'), '武器也在内容里（留给以后的兵营）')
}

// ---- 2. 需求集合 = 晋升阶梯 ----------------------------------------------
{
  const need = (cls: string, gid: string): number =>
    (ctx.classes[cls]?.needs ?? []).filter((n) => n.good === gid).reduce((a, n) => a + n.perCapita, 0)

  check(need('poor', 'safety') > 0, `穷人要治安（${need('poor', 'safety')}）`)
  check(need('poor', 'medical_service') === 0, '穷人**不**要医疗')
  check(need('poor', 'education') === 0, '穷人**不**要教育')

  check(need('middle', 'safety') > 0, `中产要治安（${need('middle', 'safety')}）`)
  check(need('middle', 'medical_service') > 0, `中产要医疗（${need('middle', 'medical_service')}）`)
  check(need('middle', 'education') === 0, '中产**不**要教育')

  check(need('rich', 'education') > 0, `富人要教育（${need('rich', 'education')}）`)
  check(need('rich', 'entertainment') > 0, `富人要娱乐（${need('rich', 'entertainment')}）`)
  check(need('rich', 'entertainment') <= 0.05, `富人娱乐已砍到 0.05（实际 ${need('rich', 'entertainment')}）`)
  check(need('rich', 'domestic_service') === 0, '富人**不**要家政（只有老板要）')

  check(need('boss', 'domestic_service') > 0, `老板要家政（${need('boss', 'domestic_service')}）`)
  check(need('boss', 'domestic_service') <= 0.1, `老板家政已砍到 0.1（实际 ${need('boss', 'domestic_service')}）`)
  check(need('boss', 'entertainment') <= 0.1, `老板娱乐已砍到 0.1（实际 ${need('boss', 'entertainment')}）`)

  // 食物仍然是最贵的一项（"钱花在吃饭上"）
  const foodCost = (cls: string): number =>
    (ctx.classes[cls]?.needs ?? [])
      .filter((n) => ALL_GOODS[n.good]?.category === 'food')
      .reduce((a, n) => a + n.perCapita * (ALL_GOODS[n.good]?.baseValue ?? 1), 0)
  const serviceCost = (cls: string): number =>
    (ctx.classes[cls]?.needs ?? [])
      .filter((n) => ALL_GOODS[n.good]?.category === 'service')
      .reduce((a, n) => a + n.perCapita * (ALL_GOODS[n.good]?.baseValue ?? 1), 0)
  for (const cls of ['poor', 'middle', 'rich', 'boss']) {
    check(serviceCost(cls) < foodCost(cls),
      `${ctx.classes[cls]?.nameZh}：服务 ${serviceCost(cls).toFixed(2)}/日 < 食物 ${foodCost(cls).toFixed(2)}/日`)
  }
}

// ---- 3. 产能：一座管一大片 ------------------------------------------------
{
  const out = (bid: string): number => {
    const def = ALL_BUILDINGS[bid]
    const rec = ctx.recipes[def?.recipe ?? '']
    const key = Object.keys(rec?.output ?? {})[0] ?? ''
    return (rec?.output as Record<string, number> | undefined)?.[key] ?? 0
  }
  check(out('clinic') === 20, `诊所产医疗 ${out('clinic')}（应当 20）`)
  check(out('hospital') === 60, `医院产医疗 ${out('hospital')}（应当 60）`)
  check(out('school') === 20, `学校产教育 ${out('school')}（应当 20）`)
  check(out('guard_station') === 20, `治安所产治安 ${out('guard_station')}（应当 20）`)
  check(out('watchtower') === 10, `瞭望台产治安 ${out('watchtower')}（应当 10）`)
  // 治安所不吃武器（开局到民兵之前必须能建、能运转）
  const gs = ctx.recipes[ALL_BUILDINGS['guard_station']?.recipe ?? '']
  check(Object.keys(gs?.inputs ?? {}).length === 0, `治安所没有输入（实际 ${JSON.stringify(gs?.inputs ?? {})}）`)
}

// ---- 4. 岗位工资：公共统一 / 私营按档次 -----------------------------------
{
  const pub = ['research_institute', 'construction_works', 'clinic', 'hospital', 'school', 'guard_station', 'watchtower']
  for (const id of pub) {
    check(isPublicService(id), `${id} 是公共事业`)
    check(defaultWageFor(id) === ECONOMY.publicServiceWage,
      `${id} 默认工资 ${defaultWageFor(id)}（应当 ${ECONOMY.publicServiceWage}）`)
  }
  const privateTier: [string, number][] = [
    ['wheat_farm', 3.0],
    ['coarse_mill', 3.6],
    ['theater', 4.5],
  ]
  for (const [id, want] of privateTier) {
    check(defaultWageFor(id) === want, `${id}（tier ${ALL_BUILDINGS[id]?.tier}）默认工资 ${defaultWageFor(id)}（应当 ${want}）`)
  }
  check(ECONOMY.publicServiceWage > 3.0, `公共事业工资 ${ECONOMY.publicServiceWage} 高于 tier1 的 3.0`)
}

console.log(failed === 0 ? '\n需求系统自检通过 🎉\n' : `\n需求自检失败 ${failed} 项 ❌\n`)
if (failed > 0) process.exitCode = 1
