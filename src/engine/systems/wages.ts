import { ALL_BUILDINGS } from '../content/index.ts'
import type { BuildingID } from '../types.ts'
import { ECONOMY } from '../config.ts'

// ---------------------------------------------------------------------------
// 岗位工资（2026-10，用户："公共事业的工资都一样，研究所、建筑工坊、医院、治安、学校"）
//
// 两类：
//   · **公共事业**：研究 / 建造产能建筑 + 医疗 / 教育 / 治安 / 仓储 —— 一律 `publicService`（3.6）
//     （国家雇人、公共开支；补贴台账按它算）
//   · **私营**：按建筑档次 tier —— 1 → 3.0 / 2 → 3.6 / 3 → 4.5
//
// 玩家/AI 仍然能逐店改工资（`set_wage`）；这里只决定**新建一座店时的默认值**。
// GDScript 同口径：`content_db.gd::default_wage()`。
// ---------------------------------------------------------------------------

/** 公共事业的 id 白名单：产能建筑 + 服务建筑 + 仓储建筑。 */
const PUBLIC_SERVICE: ReadonlySet<string> = new Set([
  'town_center',
  'warehouse',
  'research_institute',
  'construction_works',
  'clinic',
  'hospital',
  'school',
  'guard_station',
  'watchtower',
])

/** 私营建筑按档次给的默认工资。 */
const TIER_WAGE: Record<number, number> = { 1: 3.0, 2: 3.6, 3: 4.5, 4: 6.0 }

/** 这座建筑是公共事业吗（工资统一、有补贴）。 */
export function isPublicService(defId: BuildingID | string): boolean {
  return PUBLIC_SERVICE.has(String(defId))
}

/**
 * 新建这座建筑时的默认工资。
 *
 * 未知建筑退回 `ECONOMY.refWage`（3.6），与老行为一致。
 */
export function defaultWageFor(defId: BuildingID | string): number {
  if (isPublicService(defId)) return ECONOMY.publicServiceWage
  const def = ALL_BUILDINGS[String(defId)]
  const tier = def?.tier ?? 2
  return TIER_WAGE[tier] ?? ECONOMY.refWage
}
