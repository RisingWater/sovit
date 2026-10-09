import type { ClassDef, ClassID } from '../types.ts'

// ---------------------------------------------------------------------------
// 阶层需求表
//
// needs 中引用了不在当前 content pack 内的商品时，该需求会被引擎忽略；
// 有 fallbacks 的需求在首选商品缺货 / 买不起时会依次尝试替代品。
// ---------------------------------------------------------------------------

const list: ClassDef[] = [
  {
    id: 'poor',
    nameZh: '穷人',
    incomeBase: 3,
    needs: [
      { good: 'coarse_bread', perCapita: 1.0 },
      { good: 'vegetable', perCapita: 0.5 },
    ],
  },
  {
    id: 'middle',
    nameZh: '中产',
    incomeBase: 6,
    needs: [
      { good: 'white_bread', perCapita: 0.5, fallbacks: ['coarse_bread'] },
      { good: 'meat', perCapita: 0.2, fallbacks: ['fish', 'smoked_fish', 'dried_meat'] },
      { good: 'coarse_clothes', perCapita: 0.05, fallbacks: ['common_clothes'] },
      { good: 'pottery', perCapita: 0.03 },
    ],
  },
  {
    id: 'rich',
    nameZh: '富人',
    incomeBase: 15,
    needs: [
      { good: 'pastry', perCapita: 0.3, fallbacks: ['white_bread'] },
      { good: 'porcelain', perCapita: 0.05 },
      { good: 'common_clothes', perCapita: 0.1, fallbacks: ['coarse_clothes'] },
      { good: 'luxury_clothes', perCapita: 0.05, fallbacks: ['common_clothes'] },
      { good: 'leather_clothes', perCapita: 0.05, fallbacks: ['common_clothes'] },
    ],
  },
  {
    id: 'boss',
    nameZh: '老板',
    incomeBase: 30,
    needs: [
      { good: 'pastry', perCapita: 0.3 },
      { good: 'porcelain', perCapita: 0.1 },
      { good: 'luxury_clothes', perCapita: 0.1 },
    ],
  },
]

export const ALL_CLASSES: Record<ClassID, ClassDef> = Object.fromEntries(
  list.map((c) => [c.id, c]),
) as Record<ClassID, ClassDef>

export const CLASS_IDS: ClassID[] = list.map((c) => c.id)
