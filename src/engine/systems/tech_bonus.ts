import type { GameState, Sector, TechEffectKey } from '../types.ts'
import type { ContentContext } from '../content/index.ts'

// ---------------------------------------------------------------------------
// 效率科技加成（见 docs/technology.md / docs/spec.md）
//
// 15 项「效率科技」在 content/technologies.json 里带 `effects`，形如
//   "effects": { "agri": 0.10 }
// 值是**加成小数**（0.10 = +10%），不是倍率。可用键只有 6 个：
//   agri / goods / material （产出）· research （科研速度）· build （建造速度）
//   · services （三项公共服务：治安 / 医疗 / 教育的**产出**）
//
// ⚠️ **加法**叠加，不是连乘：轮作 +10% + 灌溉 +15% + 良种 +20% = **+45%**。
//    连乘后期会滚雪球，而且玩家在面板上没法一眼算出"我现在是多少"。
//
// 本文件是 TS 侧的唯一实现；GDScript 侧的镜像在
//   godot/scripts/sim/sim_core.gd::tech_bonuses() / _sector_output_boost()
// 两者口径必须一致（golden 对拍会盯着）。
// ---------------------------------------------------------------------------

/** 五个加成键的固定顺序（只用于遍历；求和与顺序无关）。 */
const EFFECT_KEYS: readonly TechEffectKey[] = [
  'agri',
  'goods',
  'material',
  'research',
  'build',
  'services',
]
/** 这些键**取最高**（不是加法叠加）——工具寿命（2026-10：+20% 与 +50% 两档，取高的那一档）。 */
const MAX_KEYS: readonly TechEffectKey[] = ['toolLife']

/**
 * 三项公共服务对应的商品 id（治安 / 医疗 / 教育）。
 *
 * 它们是"三件独立商品、三条独立需求"（`docs/needs.md` §2.5），但**加成只有一个** ——
 * 用户 2026-10："增加（治安、教育、医疗）的科技（三个一起加）"。所以 `services`
 * 加成只放大这三样商品的**产出**，投入完全不动（与其余效率科技同一条"虚空产量"规则）。
 */
export const SERVICE_GOODS: readonly string[] = ['safety', 'medical_service', 'education']

export interface TechBonuses {
  /** 农业建筑产出加成（加法小数）。 */
  agri: number
  /** 加工建筑产出加成。 */
  goods: number
  /** 原料建筑产出加成。 */
  material: number
  /** 科研速度加成：`researchRate()` **整个返回值** × (1 + research)。 */
  research: number
  /** 建造速度加成：`constructionRate()` **整个返回值** × (1 + build)。 */
  build: number
  /** 三项公共服务（治安 / 医疗 / 教育）的**产出**加成（加法小数）。 */
  services: number
  /** 工具寿命加成（**取最高**，不叠加）：工具有效天数 × (1 + toolLife)。 */
  toolLife: number
}

/**
 * 已研究科技的效率加成合计。
 *
 * 遍历 `state.research.done`，把每项科技 `effects` 的每个键求和；
 * 没研究的 / 没有 `effects` 的 / 未定义的科技一律跳过。缺省 0。
 *
 * ⚠️ `MAX_KEYS`（目前只有 `toolLife`）**取最高**而不是求和：
 * 用户 2026-10 定的"工具寿命两档 +20% / +50%，取最高"，不是叠到 +70%。
 *
 * 注意这里**不做 round**：加成是小数量级，四舍五入到两位会把 0.05 抹成 0.05
 * 之外的东西，且没必要 —— 它只是个乘数，最终速率各自照常 round2。
 */
export function techBonuses(state: GameState, ctx: ContentContext): TechBonuses {
  const out: TechBonuses = {
    agri: 0,
    goods: 0,
    material: 0,
    research: 0,
    build: 0,
    services: 0,
    toolLife: 0,
  }
  for (const tid of state.research.done) {
    const tech = ctx.technologies[tid]
    const effects = tech?.effects
    if (!effects) continue
    // 按固定键序累加：不依赖 `effects` 对象里的键序（内容里怎么排都不影响结果）。
    for (const k of EFFECT_KEYS) {
      const v = effects[k]
      if (v !== undefined) out[k] += v
    }
    for (const k of MAX_KEYS) {
      const v = effects[k]
      if (v !== undefined) out[k] = Math.max(out[k], v)
    }
  }
  return out
}

/**
 * 某个产业的产出倍率 = 1 + `techBonuses()[sector]`。
 * `sector` 缺省（无配方建筑 / 产业未知）→ 1（不施加任何加成）。
 */
export function sectorOutputBoost(bonuses: TechBonuses, sector: Sector | undefined): number {
  return sector === undefined ? 1 : 1 + bonuses[sector]
}

/**
 * 某座建筑的产业产出倍率（`def.sector` → 加成）。
 * 无 `sector` 的返回 1。刻意做成"只要一个 def"，好让 `runProductionStep` 直接用它。
 */
export function buildingSectorBoost(
  def: { sector?: Sector },
  bonuses: TechBonuses,
): number {
  return sectorOutputBoost(bonuses, def.sector)
}

/**
 * 某个**产出商品**的公共服务加成倍率（治安 / 医疗 / 教育 → 1 + services，其余 1）。
 *
 * 与 `buildingSectorBoost` 并列、两者**相乘**：一座诊所的产出倍率 =
 * 工具 × 产业效率科技（sector 是 goods）× 公共服务科技。
 */
export function serviceOutputBoost(bonuses: TechBonuses, good: string): number {
  return SERVICE_GOODS.includes(good) ? 1 + bonuses.services : 1
}
