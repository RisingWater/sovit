import {
  ALL_HOUSING,
  BUILDING_IDS,
  CLASS_IDS,
  GOOD_IDS,
  PACKS,
  PACK_IDS,
} from '../src/engine/index.ts'

// ---------------------------------------------------------------------------
// 内容自检：导入引擎即触发 content/*.json 的加载与校验（失败会抛错）。
// 这里只打印一份概览。
// ---------------------------------------------------------------------------

console.log('内容校验通过 ✅')
console.log(
  `商品 ${GOOD_IDS.length} · 建筑 ${BUILDING_IDS.length} · 阶层 ${CLASS_IDS.length} · 住房 ${Object.keys(ALL_HOUSING).length} · 内容包 ${PACK_IDS.length}`,
)
for (const id of PACK_IDS) {
  const p = PACKS[id]
  console.log(
    `  - ${id} ${p.nameZh}：商品 ${p.goods.length}，建筑 ${p.buildings.length}，阶层 ${p.classes.length}，住房 ${p.housing.length}`,
  )
}
