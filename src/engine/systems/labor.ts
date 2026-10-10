import type { GameState } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ALL_GOODS } from '../content/index.ts'
import { ECONOMY, TUNING } from '../config.ts'

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

export function assignLabor(state: GameState, ctx: ContentContext): void {
  for (const r of state.residents) {
    r.employed = false
    r.jobShopId = undefined
  }

  const pop = state.residents.length
  const foodChain = foodChainGoods(ctx)

  const info = state.shops.map((shop) => {
    const def = ctx.buildings[shop.defId]
    const want = shop.active && def
      ? Math.max(0, Math.min(shop.targetWorkers, def.maxWorkers ?? def.workers))
      : 0
    let priority = false
    if (def) {
      const recipe = ctx.recipes[def.recipe]
      if (recipe) {
        for (const gid of Object.keys(recipe.output)) {
          if (foodChain.has(gid)) priority = true
        }
      }
    }
    return { want, priority }
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
