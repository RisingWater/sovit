import type { BuildingDef, BuildingID } from '../types.ts'

// ---------------------------------------------------------------------------
// 全 v1.0 建筑表
//
// workers 严格按产业链文档；buildCost 为建店 / 扩产的材料消耗（含建造力）。
// ---------------------------------------------------------------------------

// 建造成本以「可再生产的实物原料」为主，避免在建店时出现鸡生蛋死锁：
// 一级只花木材；二级需要木材 + 石块；三级再加粘土。
const TIER1_COST = { wood: 4 }
const TIER2_COST = { wood: 6, stone: 3 }
const TIER3_COST = { wood: 8, stone: 6, clay: 4 }

const list: BuildingDef[] = [
  // ---- tier 1: 一级产业 -------------------------------------------------
  { id: 'wheat_farm', nameZh: '小麦农场', tier: 1, workers: 6, recipe: 'r_wheat_farm', buildCost: TIER1_COST },
  { id: 'vegetable_farm', nameZh: '蔬菜农场', tier: 1, workers: 4, recipe: 'r_vegetable_farm', buildCost: TIER1_COST },
  { id: 'flax_farm', nameZh: '亚麻农场', tier: 1, workers: 4, recipe: 'r_flax_farm', buildCost: TIER1_COST },
  { id: 'cotton_farm', nameZh: '棉花农场', tier: 1, workers: 4, recipe: 'r_cotton_farm', buildCost: TIER1_COST },
  { id: 'sugarcane_farm', nameZh: '甘蔗园', tier: 1, workers: 4, recipe: 'r_sugarcane_farm', buildCost: TIER1_COST },
  { id: 'dye_farm', nameZh: '染料园', tier: 1, workers: 3, recipe: 'r_dye_farm', buildCost: TIER1_COST },
  { id: 'lumberjack', nameZh: '伐木场', tier: 1, workers: 3, recipe: 'r_lumberjack', buildCost: TIER1_COST },
  { id: 'quarry', nameZh: '采石场', tier: 1, workers: 3, recipe: 'r_quarry', buildCost: TIER1_COST },
  { id: 'clay_pit', nameZh: '粘土坑', tier: 1, workers: 3, recipe: 'r_clay_pit', buildCost: TIER1_COST },
  { id: 'hunting_camp', nameZh: '狩猎营地', tier: 1, workers: 3, recipe: 'r_hunting_camp', buildCost: TIER1_COST },
  { id: 'fishery', nameZh: '渔场', tier: 1, workers: 4, recipe: 'r_fishery', buildCost: TIER1_COST },

  // ---- tier 2: 二级加工 -------------------------------------------------
  { id: 'coarse_mill', nameZh: '粗面粉磨坊', tier: 2, workers: 2, recipe: 'r_coarse_mill', buildCost: TIER2_COST },
  { id: 'fine_mill', nameZh: '精面粉磨坊', tier: 2, workers: 3, recipe: 'r_fine_mill', buildCost: TIER2_COST },
  { id: 'coarse_bakery', nameZh: '粗面包房', tier: 2, workers: 2, recipe: 'r_coarse_bakery', buildCost: TIER2_COST },
  { id: 'white_bakery', nameZh: '白面包房', tier: 2, workers: 3, recipe: 'r_white_bakery', buildCost: TIER2_COST },
  { id: 'pastry_shop', nameZh: '糕点房', tier: 2, workers: 4, recipe: 'r_pastry_shop', buildCost: TIER2_COST },
  { id: 'sugar_works', nameZh: '糖坊', tier: 2, workers: 2, recipe: 'r_sugar_works', buildCost: TIER2_COST },
  { id: 'coarse_weaver', nameZh: '粗织坊', tier: 2, workers: 3, recipe: 'r_coarse_weaver', buildCost: TIER2_COST },
  { id: 'fine_weaver', nameZh: '细织坊', tier: 2, workers: 4, recipe: 'r_fine_weaver', buildCost: TIER2_COST },
  { id: 'coarse_clothes_shop', nameZh: '粗布衣坊', tier: 2, workers: 3, recipe: 'r_coarse_clothes_shop', buildCost: TIER2_COST },
  { id: 'common_clothes_shop', nameZh: '常服坊', tier: 2, workers: 3, recipe: 'r_common_clothes_shop', buildCost: TIER2_COST },
  { id: 'luxury_clothes_shop', nameZh: '华服坊', tier: 2, workers: 4, recipe: 'r_luxury_clothes_shop', buildCost: TIER2_COST },
  { id: 'leather_shop', nameZh: '皮衣坊', tier: 2, workers: 3, recipe: 'r_leather_shop', buildCost: TIER2_COST },
  { id: 'firewood_works', nameZh: '木柴坊', tier: 2, workers: 2, recipe: 'r_firewood_works', buildCost: TIER2_COST },
  { id: 'brick_kiln', nameZh: '砖窑', tier: 2, workers: 2, recipe: 'r_brick_kiln', buildCost: TIER2_COST },
  { id: 'pottery_works', nameZh: '陶器坊', tier: 2, workers: 3, recipe: 'r_pottery_works', buildCost: TIER2_COST },
  { id: 'porcelain_works', nameZh: '瓷窑', tier: 2, workers: 3, recipe: 'r_porcelain_works', buildCost: TIER2_COST },
  { id: 'smokehouse', nameZh: '熏鱼坊', tier: 2, workers: 3, recipe: 'r_smokehouse', buildCost: TIER2_COST },
  { id: 'dried_meat_works', nameZh: '肉干坊', tier: 2, workers: 3, recipe: 'r_dried_meat_works', buildCost: TIER2_COST },

  // ---- tier 3: 三级投资 -------------------------------------------------
  { id: 'construction_works', nameZh: '建筑工坊', tier: 3, workers: 3, recipe: 'r_construction_works', buildCost: TIER3_COST },
  { id: 'housing_works', nameZh: '住房坊', tier: 3, workers: 4, recipe: 'r_housing_works', buildCost: TIER3_COST },
]

export const ALL_BUILDINGS: Record<BuildingID, BuildingDef> = Object.fromEntries(
  list.map((b) => [b.id, b]),
)

export const BUILDING_IDS: BuildingID[] = list.map((b) => b.id)
