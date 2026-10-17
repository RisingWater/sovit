import {
  ALL_BUILDINGS,
  ALL_HOUSING,
  ALL_QUESTS,
  BUILDING_IDS,
  CLASS_IDS,
  ECONOMY,
  GOOD_IDS,
  PACKS,
  PACK_IDS,
  QUEST_CHAPTERS,
  QUEST_IDS,
  TUNING,
} from '../src/engine/index.ts'

// ---------------------------------------------------------------------------
// 内容自检：导入引擎即触发 content/*.json 的加载与校验（失败会抛错）。
// 这里只打印一份概览。
// ---------------------------------------------------------------------------

console.log('内容校验通过 ✅')
console.log(
  `商品 ${GOOD_IDS.length} · 建筑 ${BUILDING_IDS.length} · 阶层 ${CLASS_IDS.length} · 住房 ${Object.keys(ALL_HOUSING).length} · 内容包 ${PACK_IDS.length}`,
)
console.log(
  `参数：refWage ${ECONOMY.refWage} · 税表 ${ECONOMY.defaultTaxBrackets.length} 档 · 失业人口建造力 ${ECONOMY.construction.unemployedRate}/日 · 基础食物 ${TUNING.basicFoods.join('、')} · 口粮链种子 ${TUNING.foodChainSeedClass}`,
)
console.log(
  `任务（引导系统）：${QUEST_IDS.length} 条 / ${QUEST_CHAPTERS.length} 章 · 合计奖励 ¥${QUEST_IDS.reduce((n, id) => n + ALL_QUESTS[id]!.reward, 0) + QUEST_CHAPTERS.reduce((n, c) => n + c.reward, 0)}（见 docs/quests.md）`,
)
for (const id of PACK_IDS) {
  const p = PACKS[id]
  console.log(
    `  - ${id} ${p.nameZh}：商品 ${p.goods.length}，建筑 ${p.buildings.length}，阶层 ${p.classes.length}，住房 ${p.housing.length}，开局 ${p.start.population} 人 / ¥${p.start.money}`,
  )
}

// ---------------------------------------------------------------------------
// 用工上限（用户 2026-10：「采石场/伐木场用工是 100 个人？？？？太多了，
// 和农田一样，要就多建造」）
//
// 产出按 `在岗 / workers` **线性放大且不封顶**，所以 `maxWorkers` 一开大，
// 玩家就会把整个村子塞进一座采石场，而不是多建一座。农田是 6，这三个照它来。
// ⚠️ 通用上限（≤ 12）在 `validate.ts::MAX_WORKERS_CAP`；这里钉的是"这三个 = 6"。
// ---------------------------------------------------------------------------
const EXTRACT_CAP = 6
let cap_failed = 0
for (const id of ['lumberjack', 'quarry', 'clay_pit']) {
  const def = ALL_BUILDINGS[id]
  if (!def) {
    console.error(`  ✗ 找不到建筑 ${id}`)
    cap_failed++
    continue
  }
  const slots = def.maxWorkers ?? def.workers
  if (slots > EXTRACT_CAP) {
    console.error(
      `  ✗ ${id}（${def.nameZh}）的工位上限是 ${slots}，应当 ≤ ${EXTRACT_CAP}（与农田同档；要更多产出请多建一座）`,
    )
    cap_failed++
  }
}
if (cap_failed > 0) process.exit(1)
console.log(`用工上限：伐木场 / 采石场 / 粘土坑 = ${EXTRACT_CAP}（与农田同档，见 docs/content.md）`)
