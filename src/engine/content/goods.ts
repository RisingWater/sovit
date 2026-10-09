import type { GoodDef, GoodID } from '../types.ts'

// ---------------------------------------------------------------------------
// 全 v1.0 商品表
// tier 0 自然资源 / 1 加工品 / 2 消费品 / 3 投资品
// ---------------------------------------------------------------------------

const list: GoodDef[] = [
  // ---- tier 0: 自然资源 -------------------------------------------------
  { id: 'wheat', nameZh: '小麦', tier: 0, category: 'raw', storable: true, baseValue: 1 },
  { id: 'vegetable', nameZh: '蔬菜', tier: 0, category: 'food', storable: false, baseValue: 1.2, perishRate: 0.1 },
  { id: 'flax', nameZh: '亚麻', tier: 0, category: 'raw', storable: true, baseValue: 1.2 },
  { id: 'cotton', nameZh: '棉花', tier: 0, category: 'raw', storable: true, baseValue: 1.4 },
  { id: 'wood', nameZh: '木材', tier: 0, category: 'raw', storable: true, baseValue: 1.5 },
  { id: 'stone', nameZh: '石块', tier: 0, category: 'raw', storable: true, baseValue: 1.6 },
  { id: 'clay', nameZh: '粘土', tier: 0, category: 'raw', storable: true, baseValue: 1.2 },
  { id: 'meat', nameZh: '肉类', tier: 0, category: 'food', storable: false, baseValue: 3, perishRate: 0.15 },
  { id: 'fish', nameZh: '鱼类', tier: 0, category: 'food', storable: false, baseValue: 2.5, perishRate: 0.15 },
  { id: 'hide', nameZh: '兽皮', tier: 0, category: 'raw', storable: true, baseValue: 2 },
  { id: 'sugarcane', nameZh: '甘蔗', tier: 0, category: 'raw', storable: true, baseValue: 1.5 },
  { id: 'dye', nameZh: '染料', tier: 0, category: 'raw', storable: true, baseValue: 2.5 },

  // ---- tier 1: 加工品 ---------------------------------------------------
  { id: 'coarse_flour', nameZh: '粗面粉', tier: 1, category: 'food', storable: true, baseValue: 1.8 },
  { id: 'fine_flour', nameZh: '精面粉', tier: 1, category: 'food', storable: true, baseValue: 2.4 },
  { id: 'sugar', nameZh: '糖', tier: 1, category: 'food', storable: true, baseValue: 2.2 },
  { id: 'coarse_cloth', nameZh: '粗织物', tier: 1, category: 'material', storable: true, baseValue: 2.4 },
  { id: 'fine_cloth', nameZh: '细织物', tier: 1, category: 'material', storable: true, baseValue: 3.2 },
  { id: 'firewood', nameZh: '木柴', tier: 1, category: 'fuel', storable: true, baseValue: 1.6 },
  { id: 'brick', nameZh: '砖', tier: 1, category: 'material', storable: true, baseValue: 3 },
  { id: 'pottery', nameZh: '陶器', tier: 1, category: 'household', storable: true, baseValue: 3.5 },

  // ---- tier 2: 消费品 ---------------------------------------------------
  { id: 'coarse_bread', nameZh: '粗面包', tier: 2, category: 'food', storable: true, baseValue: 1.3 },
  { id: 'white_bread', nameZh: '白面包', tier: 2, category: 'food', storable: true, baseValue: 3 },
  { id: 'pastry', nameZh: '糕点', tier: 2, category: 'food', storable: true, baseValue: 5 },
  { id: 'coarse_clothes', nameZh: '粗布衣', tier: 2, category: 'clothing', storable: true, baseValue: 4 },
  { id: 'common_clothes', nameZh: '常服', tier: 2, category: 'clothing', storable: true, baseValue: 6 },
  { id: 'luxury_clothes', nameZh: '华服', tier: 2, category: 'clothing', storable: true, baseValue: 10 },
  { id: 'leather_clothes', nameZh: '皮衣', tier: 2, category: 'clothing', storable: true, baseValue: 7 },
  { id: 'smoked_fish', nameZh: '熏鱼', tier: 2, category: 'food', storable: true, baseValue: 4 },
  { id: 'dried_meat', nameZh: '肉干', tier: 2, category: 'food', storable: true, baseValue: 5 },
  { id: 'porcelain', nameZh: '瓷器', tier: 2, category: 'household', storable: true, baseValue: 9 },
  { id: 'domestic_service', nameZh: '家政服务', tier: 2, category: 'service', storable: false, baseValue: 3, perishRate: 1 },
  { id: 'entertainment', nameZh: '娱乐', tier: 2, category: 'entertainment', storable: false, baseValue: 4, perishRate: 1 },

  // ---- tier 3: 投资品 ---------------------------------------------------
  { id: 'build_power', nameZh: '建造力', tier: 3, category: 'investment', storable: true, baseValue: 6 },
  { id: 'hut', nameZh: '茅屋', tier: 3, category: 'housing', storable: true, baseValue: 15 },
  { id: 'wooden_house', nameZh: '木屋', tier: 3, category: 'housing', storable: true, baseValue: 30 },
  { id: 'brick_house', nameZh: '砖房', tier: 3, category: 'housing', storable: true, baseValue: 55 },
]

export const ALL_GOODS: Record<GoodID, GoodDef> = Object.fromEntries(
  list.map((g) => [g.id, g]),
)

export const GOOD_IDS: GoodID[] = list.map((g) => g.id)
