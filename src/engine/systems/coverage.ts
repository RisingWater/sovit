import type { BuildingID, GameState } from '../types.ts'
import type { ContentContext } from '../content/index.ts'
import { ECONOMY } from '../config.ts'
import { clamp } from '../util.ts'
import { assignedWorkers } from './labor.ts'

// ---------------------------------------------------------------------------
// 覆盖率（2026-10 第二批）
//
// 用户："学校根据人口，一座覆盖 100 人口，有覆盖就加成"；
//       "治安、诊所（医院）也是，一座覆盖 50 人，有覆盖才加成满意度"。
//
// 所以这里是"一座建筑覆盖多少人"的口径，**不是**消费品：
//
//   覆盖人口[kind] = Σ over 在运转的覆盖建筑：coverage.people × 等级
//   覆盖率[kind]   = min(1, 覆盖人口 / 总人口)
//
// "在运转" = 在岗有人 +（有配方时）当天排得上产 —— 所以没药水的诊所、没武器的治安所
// 自然就覆盖不了（原料断了，服务就断，不需要另写一条规则）。
//
// 作用（`satisfaction.ts` / `labor.ts` 读它）：
//   · 医疗 / 教育：**只算中产以上**（用户："中产以上会去消费"）
//   · 治安：所有阶层
//   · 教育额外给"熟练度成长"加成（学校是人力投资）
//   · 加成数值在 `content/economy.json` 的 `coverage` 里
// ---------------------------------------------------------------------------

export type CoverageKind = 'medical' | 'education' | 'safety'

export type CoverageRatios = Record<CoverageKind, number>

const KINDS: readonly CoverageKind[] = ['medical', 'education', 'safety']

/** 某座建筑今天是否"开着门"：在岗有人，且有配方的要排得上产。 */
function isRunning(
  state: GameState,
  ctx: ContentContext,
  shopId: string,
  defId: BuildingID,
): boolean {
  const def = ctx.buildings[defId]
  if (!def) return false
  if (assignedWorkers(state, shopId) <= 0) return false
  const shop = state.shops.find((s) => s.id === shopId)
  // 有配方但今天排不上产（缺原料 / 缺工位）→ 不算运转
  if (def.recipe && shop && (shop.planned ?? 0) <= 0) return false
  return true
}

/** 某种覆盖今天覆盖了多少人（面板上显示"覆盖 120 / 250 人"）。 */
export function coveredPeople(
  state: GameState,
  ctx: ContentContext,
  kind: CoverageKind,
): number {
  let n = 0
  for (const shop of state.shops) {
    const def = ctx.buildings[shop.defId]
    if (!def || !def.coverage || def.coverage.kind !== kind || !shop.active) continue
    if (!isRunning(state, ctx, shop.id, shop.defId)) continue
    n += def.coverage.people * Math.max(1, shop.level ?? 1)
  }
  return n
}

/**
 * 当前各覆盖类型的**覆盖率**（0–1）。
 *
 * 纯函数、每次现算（不存 state）：夜里算两次（满意度 + 熟练度）代价可忽略，
 * 也免得给存档加字段。UI 也调这个（GD 侧 `sim_core.gd::coverage_ratios()`）。
 */
export function coverageRatios(state: GameState, ctx: ContentContext): CoverageRatios {
  const out: CoverageRatios = { medical: 0, education: 0, safety: 0 }
  const pop = state.residents.length
  if (pop <= 0) return out
  for (const k of KINDS) out[k] = clamp(coveredPeople(state, ctx, k) / pop, 0, 1)
  return out
}

/**
 * 某个阶层能拿到的覆盖满意度加成（直接加到满意度目标值上，单位是"满意度点"）。
 *
 * - 医疗 / 教育只给中产以上（穷人买不起药，也谈不上学）
 * - 治安四阶层都有
 */
export function coverageSatBonus(ratios: CoverageRatios, classId: string): number {
  const cfg = ECONOMY.coverage
  const rich = classId !== 'poor'
  const safety = ratios.safety * cfg.safety
  if (!rich) return safety
  return ratios.medical * cfg.medical + ratios.education * cfg.education + safety
}

/** 熟练度成长倍率：`1 + skillGrowth × 教育覆盖率`（满覆盖 = +50%）。 */
export function coverageSkillMultiplier(educationRatio: number): number {
  return 1 + ECONOMY.coverage.skillGrowth * clamp(educationRatio, 0, 1)
}
