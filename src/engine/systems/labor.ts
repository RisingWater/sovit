import type { GameState } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { ECONOMY, TUNING } from '../config.ts'
import { round2 } from '../util.ts'

// ---------------------------------------------------------------------------
// 用工分配
//
// 全国有：目标用工由玩家 / AI 设定，实际分配受人口约束。
// 规则：优先满足「食品产业链」建筑（从食品成品回溯到上游原料，保证吃饭），
// 剩余劳动力再按需求比例分给其余。这样即便扩产过快，也不会先饿死。
// ---------------------------------------------------------------------------

/** 基本口粮链：以最低阶层的食物需求为种子，向上游回溯（保证不饿死，但不含奢侈食品）。 */
function foodChainGoods(ctx: ContentContext): Set<string> {
  const set = new Set<string>()
  const poor = ctx.classes[TUNING.foodChainSeedClass]
  if (poor) {
    for (const n of poor.needs) {
      if (ALL_GOODS[n.good]?.category === 'food') set.add(n.good)
    }
  }
  if (set.size === 0) {
    for (const gid of ctx.pack.goods) if (ALL_GOODS[gid]?.category === 'food') set.add(gid)
  }
  let changed = true
  while (changed) {
    changed = false
    for (const recipe of Object.values(ctx.recipes)) {
      const outputs = Object.keys(recipe.output)
      if (!outputs.some((g) => set.has(g))) continue
      for (const inp of Object.keys(recipe.inputs)) {
        if (!set.has(inp) && ctx.goodSet.has(inp)) {
          set.add(inp)
          changed = true
        }
      }
    }
  }
  return set
}

/**
 * 食品产业链上的店铺 id 集合。
 * `assignLabor` 的用工优先级依据：先保证吃饭，再把人力给别处。
 */
export function foodChainShopIds(state: GameState, ctx: ContentContext): Set<string> {
  const chain = foodChainGoods(ctx)
  const out = new Set<string>()
  for (const shop of state.shops) {
    const def = ctx.buildings[shop.defId]
    const recipe = def?.recipe ? ctx.recipes[def.recipe] : undefined
    if (!recipe) continue
    if (Object.keys(recipe.output).some((g) => chain.has(g))) out.add(shop.id)
  }
  return out
}

export function assignLabor(state: GameState, ctx: ContentContext): void {
  for (const r of state.residents) {
    r.employed = false
    r.jobShopId = undefined
    r.constructionPay = undefined
  }

  const pop = state.residents.length
  const foodChainShops = foodChainShopIds(state, ctx)

  const info = state.shops.map((shop) => {
    const def = ctx.buildings[shop.defId]
    // 工位上限随等级增长（研究所这类产能建筑升级会加 slotsPerLevel 个工位）
    const slots = def
      ? (def.maxWorkers ?? def.workers) + (def.capacity?.slotsPerLevel ?? 0) * (shop.level - 1)
      : 0
    const want = shop.active && def ? Math.max(0, Math.min(shop.targetWorkers, slots)) : 0
    return { want, priority: foodChainShops.has(shop.id) }
  })

  const assign = new Array<number>(state.shops.length).fill(0)
  let budget = pop

  // 1. 食品链优先，逐一满足目标用工
  for (let i = 0; i < info.length; i++) {
    if (!info[i]!.priority) continue
    const a = Math.min(info[i]!.want, budget)
    assign[i] = a
    budget -= a
  }

  // 2. 其余建筑按需求比例分配剩余劳动力
  const others = info.map((_, i) => i).filter((i) => !info[i]!.priority)
  const totalWant = others.reduce((a, i) => a + info[i]!.want, 0)
  if (budget > 0 && totalWant > 0) {
    if (totalWant <= budget) {
      for (const i of others) assign[i] = info[i]!.want
    } else {
      const remainders: Array<{ i: number; rem: number }> = []
      let used = 0
      for (const i of others) {
        const exact = (info[i]!.want * budget) / totalWant
        const base = Math.floor(exact)
        assign[i] = base
        used += base
        remainders.push({ i, rem: exact - base })
      }
      remainders.sort((a, b) => b.rem - a.rem || a.i - b.i)
      for (const { i } of remainders) {
        if (used >= budget) break
        if (assign[i]! < info[i]!.want) {
          assign[i] = assign[i]! + 1
          used++
        }
      }
    }
  }

  // 应用到居民（按建筑顺序依次占用）
  let cursor = 0
  state.shops.forEach((shop, i) => {
    const want = assign[i]!
    const skills: number[] = []
    for (let k = 0; k < want && cursor < state.residents.length; k++) {
      const r = state.residents[cursor++]!
      r.employed = true
      r.jobShopId = shop.id
      skills.push(r.skill)
    }
    shop.skill = skills.length > 0 ? skills.reduce((a, b) => a + b, 0) / skills.length : 0
  })
}

/** 夜晚：在岗者长熟练度（每天一次）。 */
export function growSkills(state: GameState): void {
  for (const r of state.residents) {
    if (r.employed) r.skill = Math.min(ECONOMY.skillMax, r.skill + ECONOMY.skillGainPerDay)
  }
}

/** 某店铺当前实际到岗人数。 */
export function assignedWorkers(state: GameState, shopId: string): number {
  let n = 0
  for (const r of state.residents) if (r.jobShopId === shopId) n++
  return n
}

/**
 * 建造结算后：把当日实际投入的建造力折算成「在工地上出工」的失业人口。
 *
 * 每人每日出 1.0 建造力，故出工人数 = ⌈投入量⌉（不足一日的按半日算，仍占一个人）。
 * 工资按**实际投入量**计发（人·天 × refWage × wageRate），在出工者之间平均分配——
 * 与消费一样先用「平均分配」，将来要做差异化时不必再动数据结构。
 *
 * 标记 `employed = true` 是刻意的：出工者当天算是就业（影响就业满意度），
 * 且会通过 growSkills 长熟练度（第二步接进建造力）。次日黎明 assignLabor 会清空。
 */
export function markConstructionWorkers(state: GameState, work: number): void {
  if (work <= 0) return
  const idle = state.residents.filter((r) => !r.employed)
  if (idle.length === 0) return

  const n = Math.min(idle.length, Math.ceil(work - 1e-9))
  const bill = round2(work * ECONOMY.refWage * ECONOMY.construction.wageRate)
  const per = round2(bill / n)
  for (let i = 0; i < n; i++) {
    const r = idle[i]!
    r.employed = true
    r.constructionPay = per
  }
}
