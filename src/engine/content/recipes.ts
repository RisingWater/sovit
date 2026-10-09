import type { RecipeDef, RecipeID } from '../types.ts'

// ---------------------------------------------------------------------------
// 全 v1.0 配方表
//
// baseRate = 满员每日批次；inputs/output 为「每批次」数量。
// 一级产业无投入；二级加工消耗原料；三级为投资品。
// ---------------------------------------------------------------------------

const list: RecipeDef[] = [
  // ---- tier 1: 一级产业（固定产出） ------------------------------------
  { id: 'r_wheat_farm', building: 'wheat_farm', inputs: {}, output: { wheat: 12 }, baseRate: 1 },
  { id: 'r_vegetable_farm', building: 'vegetable_farm', inputs: {}, output: { vegetable: 12 }, baseRate: 1 },
  { id: 'r_flax_farm', building: 'flax_farm', inputs: {}, output: { flax: 8 }, baseRate: 1 },
  { id: 'r_cotton_farm', building: 'cotton_farm', inputs: {}, output: { cotton: 8 }, baseRate: 1 },
  { id: 'r_sugarcane_farm', building: 'sugarcane_farm', inputs: {}, output: { sugarcane: 8 }, baseRate: 1 },
  { id: 'r_dye_farm', building: 'dye_farm', inputs: {}, output: { dye: 5 }, baseRate: 1 },
  { id: 'r_lumberjack', building: 'lumberjack', inputs: {}, output: { wood: 10 }, baseRate: 1 },
  { id: 'r_quarry', building: 'quarry', inputs: {}, output: { stone: 8 }, baseRate: 1 },
  { id: 'r_clay_pit', building: 'clay_pit', inputs: {}, output: { clay: 8 }, baseRate: 1 },
  { id: 'r_hunting_camp', building: 'hunting_camp', inputs: {}, output: { meat: 6, hide: 3 }, baseRate: 1 },
  { id: 'r_fishery', building: 'fishery', inputs: {}, output: { fish: 10 }, baseRate: 1 },

  // ---- tier 2: 二级加工 -------------------------------------------------
  { id: 'r_coarse_mill', building: 'coarse_mill', inputs: { wheat: 12 }, output: { coarse_flour: 12 }, baseRate: 1 },
  { id: 'r_fine_mill', building: 'fine_mill', inputs: { wheat: 12 }, output: { fine_flour: 10 }, baseRate: 1 },
  { id: 'r_coarse_bakery', building: 'coarse_bakery', inputs: { coarse_flour: 12 }, output: { coarse_bread: 24 }, baseRate: 1 },
  { id: 'r_white_bakery', building: 'white_bakery', inputs: { fine_flour: 10 }, output: { white_bread: 20 }, baseRate: 1 },
  { id: 'r_pastry_shop', building: 'pastry_shop', inputs: { fine_flour: 8, sugar: 4 }, output: { pastry: 12 }, baseRate: 1 },
  { id: 'r_sugar_works', building: 'sugar_works', inputs: { sugarcane: 8 }, output: { sugar: 6 }, baseRate: 1 },
  { id: 'r_coarse_weaver', building: 'coarse_weaver', inputs: { flax: 8 }, output: { coarse_cloth: 8 }, baseRate: 1 },
  { id: 'r_fine_weaver', building: 'fine_weaver', inputs: { cotton: 8 }, output: { fine_cloth: 6 }, baseRate: 1 },
  { id: 'r_coarse_clothes_shop', building: 'coarse_clothes_shop', inputs: { coarse_cloth: 8 }, output: { coarse_clothes: 6 }, baseRate: 1 },
  { id: 'r_common_clothes_shop', building: 'common_clothes_shop', inputs: { fine_cloth: 6 }, output: { common_clothes: 5 }, baseRate: 1 },
  { id: 'r_luxury_clothes_shop', building: 'luxury_clothes_shop', inputs: { fine_cloth: 5, dye: 3 }, output: { luxury_clothes: 4 }, baseRate: 1 },
  { id: 'r_leather_shop', building: 'leather_shop', inputs: { hide: 3 }, output: { leather_clothes: 2 }, baseRate: 1 },
  { id: 'r_firewood_works', building: 'firewood_works', inputs: { wood: 10 }, output: { firewood: 12 }, baseRate: 1 },
  { id: 'r_brick_kiln', building: 'brick_kiln', inputs: { clay: 8 }, output: { brick: 6 }, baseRate: 1, fuel: 4 },
  { id: 'r_pottery_works', building: 'pottery_works', inputs: { clay: 8 }, output: { pottery: 6 }, baseRate: 1, fuel: 3 },
  { id: 'r_porcelain_works', building: 'porcelain_works', inputs: { clay: 6 }, output: { porcelain: 4 }, baseRate: 1, fuel: 6 },
  { id: 'r_domestic_service', building: 'domestic_service', inputs: {}, output: { domestic_service: 4 }, baseRate: 1 },
  { id: 'r_smokehouse', building: 'smokehouse', inputs: { fish: 10 }, output: { smoked_fish: 8 }, baseRate: 1, fuel: 4 },
  { id: 'r_dried_meat_works', building: 'dried_meat_works', inputs: { meat: 6 }, output: { dried_meat: 5 }, baseRate: 1, fuel: 4 },

  // ---- tier 3: 三级投资 -------------------------------------------------
  { id: 'r_construction_works', building: 'construction_works', inputs: { wood: 6, stone: 4, brick: 2 }, output: { build_power: 4 }, baseRate: 1 },
  { id: 'r_housing_works', building: 'housing_works', inputs: { wood: 6, brick: 3 }, output: { hut: 1 }, baseRate: 1 },
]

export const ALL_RECIPES: Record<RecipeID, RecipeDef> = Object.fromEntries(
  list.map((r) => [r.id, r]),
)

/** 按建筑取配方（每建筑恰好一条）。 */
export const RECIPE_BY_BUILDING: Record<string, RecipeDef> = Object.fromEntries(
  list.map((r) => [r.building, r]),
)
