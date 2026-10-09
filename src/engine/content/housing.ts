import type { HousingDef, GoodID } from '../types.ts'

// ---------------------------------------------------------------------------
// 住房表（v1.0）
// ---------------------------------------------------------------------------

const list: HousingDef[] = [
  { id: 'hut', nameZh: '茅屋', quality: 1, capacity: 4, classId: 'poor', buildCost: { wood: 4, brick: 3 }, salePrice: 10 },
  { id: 'wooden_house', nameZh: '木屋', quality: 2, capacity: 4, classId: 'middle', buildCost: { wood: 6, brick: 6 }, salePrice: 25 },
  { id: 'brick_house', nameZh: '砖房', quality: 3, capacity: 4, classId: 'rich', buildCost: { wood: 4, stone: 4, brick: 10 }, salePrice: 50 },
]

export const ALL_HOUSING: Record<GoodID, HousingDef> = Object.fromEntries(
  list.map((h) => [h.id, h]),
)
