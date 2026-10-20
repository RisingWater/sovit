// 商路内容门槛（B3）：content/routes.json + technologies.json 里的贸易科技。
//
// 它与 `validate.ts::parseRoutes` 分工不同：
//   · parseRoutes 是**加载时**的结构校验（引擎不崩）
//   · 这里是**平衡与一致性**的体检（人看的）：城市表、价表、特产/需求互斥、
//     科技链、图标是否齐全 —— 它直接读原始 JSON + 面板上的据点表，能抓到"内容没毛病
//     但和别处对不上"的问题。
//
// 跑法：npm run check:routes （也在 `npm test` 里）
import { readFileSync } from 'node:fs'

const ROOT = new URL('../', import.meta.url)
const read = (p: string): string => readFileSync(new URL(p, ROOT), 'utf8')

interface City {
  id: string
  nameZh: string
  days: number
  specialty: string[]
  demand: string[]
}
interface RoutesFile {
  schemaVersion: number
  distance: { days: number; sellMul: number; buyMul: number }[]
  caravan: { count: number; maxCount: number; cargo: number; purse: number; roundTrip: boolean }
  market: Record<string, number>
  cities: City[]
}
interface GoodsFile {
  goods: { id: string; nameZh: string; storable: boolean; category: string }[]
}
interface TechFile {
  technologies: { id: string; requires: string[]; trade?: Record<string, number>; cost?: { goods?: Record<string, number> } }[]
}

let fails = 0
function ok(cond: boolean, msg: string): void {
  if (!cond) {
    fails += 1
    console.error('  ✗ ' + msg)
  }
}

const routes: RoutesFile = JSON.parse(read('content/routes.json'))
const goodsDef: GoodsFile = JSON.parse(read('content/goods.json'))
const techs: TechFile = JSON.parse(read('content/technologies.json'))
const goods = new Map(goodsDef.goods.map((g) => [g.id, g]))
const techById = new Map(techs.technologies.map((t) => [t.id, t]))

console.log('=== 商路内容（content/routes.json）===')

// 1) 距离价表：1..5 齐全，且单调（越远越赚）
ok(routes.schemaVersion === 1, `schemaVersion 应为 1（实际 ${routes.schemaVersion}）`)
const daysSet = new Set(routes.distance.map((d) => d.days))
for (let d = 1; d <= 5; d++) ok(daysSet.has(d), `距离价表缺 ${d} 天那一档`)
const sorted = [...routes.distance].sort((a, b) => a.days - b.days)
for (let i = 1; i < sorted.length; i++) {
  ok(sorted[i]!.sellMul > sorted[i - 1]!.sellMul, `卖价倍率应当随距离递增（${sorted[i]!.days} 天处没增）`)
  ok(sorted[i]!.buyMul < sorted[i - 1]!.buyMul, `买价倍率应当随距离递减（${sorted[i]!.days} 天处没降）`)
}
ok(sorted[0]?.sellMul === 1 && sorted[0]?.buyMul === 2, '1 天档应当是 卖 1.0 / 买 2.0（用户口径）')
ok(sorted[sorted.length - 1]?.sellMul === 6 && sorted[sorted.length - 1]?.buyMul === 0.6,
  '5 天档应当是 卖 6.0 / 买 0.6（用户口径）')

// 2) 商队参数
ok(routes.caravan.count >= 0 && routes.caravan.count <= routes.caravan.maxCount,
  `商队基础数 ${routes.caravan.count} 应在 0..maxCount(${routes.caravan.maxCount}) 之间`)
ok(routes.caravan.cargo > 0, '载货上限要 > 0')
ok(routes.caravan.purse >= 0, '带钱上限要 ≥ 0')

// 3) 市场参数
for (const k of ['specialtyStock', 'specialtyDaily', 'specialtyCap', 'demandDaily', 'demandCap']) {
  ok(typeof routes.market[k] === 'number', `market.${k} 缺失`)
  if (k.endsWith('Cap')) {
    const base = k.replace('Cap', '')
    ok(routes.market[k]! >= (routes.market[base + 'Daily'] ?? 0) * 2,
      `market.${k}（${routes.market[k]}）至少要能装下两天的补给，否则"攒池子"没意义`)
  }
}

// 4) 城市表
ok(routes.cities.length === 11, `目的地应当 11 座（4 国首都 + 本国 7 城），实际 ${routes.cities.length}`)
const ids = new Set<string>()
const specialtyAll = new Map<string, string>()
const demandAll = new Set<string>()
for (const c of routes.cities) {
  ok(!ids.has(c.id), `城市 id 重复：${c.id}`)
  ids.add(c.id)
  ok(c.specialty.length === 2, `${c.id} 的特产应当 2 种（实际 ${c.specialty.length}）`)
  ok(c.demand.length === 3, `${c.id} 的需求应当 3 种（实际 ${c.demand.length}）`)
  ok(daysSet.has(c.days), `${c.id} 的 ${c.days} 天不在价表里`)
  for (const g of [...c.specialty, ...c.demand]) {
    const def = goods.get(g)
    ok(def !== undefined, `${c.id} 引用了不存在的商品 ${g}`)
    if (!def) continue
    ok(def.storable === true, `${c.id} 的 ${g}（${def.nameZh}）不可存储`)
    ok(!['service', 'military', 'tool'].includes(def.category),
      `${c.id} 的 ${g}（${def.nameZh}）是 ${def.category}，不该进商路`)
  }
  for (const g of c.specialty) {
    // 同一个商品可以是多座城的特产（铁锭、煤、药水都是），这里只记账
    specialtyAll.set(g, (specialtyAll.get(g) ? specialtyAll.get(g) + ',' : '') + c.id)
  }
  for (const g of c.demand) demandAll.add(g)
}
for (const [g, city] of specialtyAll) {
  ok(!demandAll.has(g), `${g} 既是「${city}」的特产又是某城的需求 —— "A 城买 B 城卖"的刷钱漏洞`)
}
const far = routes.cities.filter((c) => c.days === 5)
ok(far.length >= 1, '得有一座 5 天城（不然 6 倍价那档白写）')
const near = routes.cities.filter((c) => c.days === 1)
ok(near.length >= 1, '得有一座 1 天城（"次日结算"那条要能验）')

// 5) 和地图对得上（`panel_map.gd::MARKS` 里的据点 id）
const mapSrc = read('godot/scripts/ui/panel_map.gd')
const markIds = [...mapSrc.matchAll(/\{"id": "([a-z_]+)", "kind"/g)].map((m) => m[1]!)
for (const c of routes.cities) {
  ok(markIds.includes(c.id), `地图据点表里没有 ${c.id}（贸易地图页点不到它）`)
}

console.log(`  城市 ${routes.cities.length} 座；1 天 ${near.length} / 5 天 ${far.length}；` +
  `特产 ${specialtyAll.size} 种、需求 ${demandAll.size} 种`)

// ---------------------------------------------------------------------------
console.log('=== 贸易科技（content/technologies.json）===')
const tradeTechs = techs.technologies.filter((t) => t.trade !== undefined)
ok(tradeTechs.length === 16, `贸易科技应当 16 项（商队 4 + 货箱 3 + 钱箱 3 + 议价买 3 + 议价卖 3），实际 ${tradeTechs.length}`)

const count = (pred: (id: string) => boolean): number => tradeTechs.filter((t) => pred(t.id)).length
ok(count((id) => id.startsWith('trade_caravan_')) === 4, '商队科技应当 4 项')
ok(count((id) => id.startsWith('cargo_hold_')) === 3, '货箱科技应当 3 项')
ok(count((id) => id.startsWith('strongbox_')) === 3, '钱箱科技应当 3 项')
ok(count((id) => id.startsWith('haggle_buy_')) === 3, '买价科技应当 3 项')
ok(count((id) => id.startsWith('haggle_sell_')) === 3, '卖价科技应当 3 项')

// 商队数：累加后应当正好等于 maxCount
let caravans = 0
let cargo = 0
let purse = 0
let haggleBuy = 0
let haggleSell = 0
for (const t of tradeTechs) {
  const tr = t.trade!
  if (tr.caravans) caravans += tr.caravans
  if (tr.cargo) cargo = Math.max(cargo, tr.cargo)
  if (tr.purse) purse = Math.max(purse, tr.purse)
  if (tr.haggleBuy) haggleBuy += tr.haggleBuy
  if (tr.haggleSell) haggleSell += tr.haggleSell
}
ok(caravans === routes.caravan.maxCount, `商队科技合计 +${caravans} 应当正好等于 maxCount(${routes.caravan.maxCount})`)
ok(cargo > routes.caravan.cargo, `载货科技的最高档（${cargo}）要大于基础值（${routes.caravan.cargo}）`)
ok(purse > routes.caravan.purse, `钱箱科技的最高档（${purse}）要大于基础值（${routes.caravan.purse}）`)
ok(Math.abs(haggleBuy - 0.3) < 1e-9, `买价三级应当合计 -30%（实际 ${haggleBuy}）`)
ok(Math.abs(haggleSell - 0.3) < 1e-9, `卖价三级应当合计 +30%（实际 ${haggleSell}）`)

// 前置必须存在 + 根节点挂在「通商」上
const root = techById.get('trade_caravan_1')
ok(root !== undefined, '缺 trade_caravan_1（贸易页的根）')
ok(!!root && root.requires.includes('trade'), 'trade_caravan_1 的前置应当是「通商」')
for (const t of tradeTechs) {
  for (const r of t.requires) ok(techById.has(r), `${t.id} 的前置 ${r} 不存在`)
}

// 图标：16 项都该有 64×64 的图（`assets/ui/tech/<id>.png`），议价三档复用同一张
const ICON_ALIAS: Record<string, string> = {
  haggle_buy_2: 'haggle_buy_1', haggle_buy_3: 'haggle_buy_1',
  haggle_sell_2: 'haggle_sell_1', haggle_sell_3: 'haggle_sell_1',
}
for (const t of tradeTechs) {
  const iconId = ICON_ALIAS[t.id] ?? t.id
  const p = `godot/assets/ui/tech/${iconId}.png`
  try {
    const buf = readFileSync(new URL(p, ROOT))
    const w = buf.readUInt32BE(16)
    const h = buf.readUInt32BE(20)
    ok(w === 64 && h === 64, `${p} 应当是 64×64（实际 ${w}×${h}）`)
  } catch {
    ok(false, `缺图标 ${p}`)
  }
}

console.log(`  贸易科技 ${tradeTechs.length} 项：商队 +${caravans}、载货 ${cargo}、带钱 ${purse}、` +
  `议价 -${Math.round(haggleBuy * 100)}% / +${Math.round(haggleSell * 100)}%`)

if (fails > 0) {
  console.error(`\n商路内容检查：${fails} 处不通过`)
  process.exit(1)
}
console.log('\n商路内容检查：全部通过')
