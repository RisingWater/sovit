import type { HousingDef, GoodID } from '../types.ts'

// ---------------------------------------------------------------------------
// 住房表（v1.0）
// ---------------------------------------------------------------------------

const list: HousingDef[] = [
  { id: 'hut', nameZh: '茅屋', quality: 1, capacity: 4, classId: 'poor' },
  { id: 'wooden_house', nameZh: '木屋', quality: 2, capacity: 4, classId: 'middle' },
  { id: 'brick_house', nameZh: '砖房', quality: 3, capacity: 4, classId: 'rich' },
]

export const ALL_HOUSING: Record<GoodID, HousingDef> = Object.fromEntries(
  list.map((h) => [h.id, h]),
)
