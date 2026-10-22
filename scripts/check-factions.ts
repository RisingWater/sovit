// 邦交内容门槛（B4）：content/factions.json + 城市归属 + 图标尺寸 + 使馆接线。
//
// 为什么要有这一条：邦交全部是"数据驱动"的（13 个势力的 initial / cap / flip / defeat
// 写在 JSON 里），写错一个字不会崩、只会**悄悄**把某个势力变成永远冷淡或永远敌对；
// 图标是脚本生成的，尺寸错了卡片上就是糊图。这条门槛把这两类错抓在 push 之前。
//
// 跑法：npm run check:factions（也在 `npm test` 里）
import { readFileSync } from 'node:fs'

const ROOT = new URL('../', import.meta.url)
const read = (p: string): string => readFileSync(new URL(p, ROOT), 'utf8')

interface Faction {
  id: string
  nameZh: string
  short: string
  lord: string
  cityIds: string[]
  initial: number
  cap: string
  allyable: boolean
  vassalable: boolean
  flip: { chapter: number; to: number; reason: string } | null
  defeat: { rep: number; cap: string; vassal: boolean } | null
  glyph: string
}
interface FactionFile {
  schemaVersion: number
  relation: {
    min: number
    max: number
    bands: { id: string; nameZh: string; max: number; incl?: boolean }[]
    vassalNameZh: string
    capByBand: Record<string, number>
    giftStep: number
    giftRate: number
    attackHit: number
    allyCost: number
    tradeBand: string
    tradeGain: number
  }
  factions: Faction[]
}
interface City {
  id: string
  nameZh: string
  faction: string
}

let fails = 0
function ok(cond: boolean, msg: string): void {
  if (!cond) {
    fails += 1
    console.error('  ✗ ' + msg)
  } else {
    console.log('  ok   ' + msg)
  }
}

const factions: FactionFile = JSON.parse(read('content/factions.json'))
const routes: { cities: City[] } = JSON.parse(read('content/routes.json'))
const techs: { technologies: { id: string; unlocks: { buildings: string[] }; trade?: Record<string, number> }[] } =
  JSON.parse(read('content/technologies.json'))
const buildings: { buildings: { id: string; utility?: boolean; art?: { foot?: number[] } }[] } =
  JSON.parse(read('content/buildings.json'))

// ---------------------------------------------------------------------------
console.log('=== 势力表（13 个）===')
const ids = factions.factions.map((f) => f.id)
ok(ids.length === 13, `势力应当 13 个，实际 ${ids.length}`)
ok(new Set(ids).size === ids.length, '势力 id 不重复')
const bosses = factions.factions.filter((f) => f.cityIds.length > 0).length
ok(bosses === 11, `有城的势力应当 11 个（另两个是精灵 / 女巫），实际 ${bosses}`)

// 档位表：七档，max 单调不减，负两档含上界、正三档不含（边界是用户口述的）
console.log('=== 好感档位 ===')
const bands = factions.relation.bands
ok(bands.length === 6, `档位表应当 6 档 + 附庸状态位，实际 ${bands.length}`)
ok(
  bands.map((b) => b.id).join(',') === 'enemy,cold,neutral,friendly,respect,ally',
  '档位顺序应当是 enemy → cold → neutral → friendly → respect → ally',
)
ok(bands[0]!.max === -6000 && bands[0]!.incl === true, '敌对：≤ -6000（含 -6000）')
ok(bands[1]!.max === -2000 && bands[1]!.incl === true, '冷淡：(-6000, -2000]（含 -2000）')
ok(bands[2]!.max === 2000 && !bands[2]!.incl, '中立：(-2000, 2000)（不含 2000）')
ok(bands[3]!.max === 6000 && !bands[3]!.incl, '友善：[2000, 6000)（不含 6000）')
ok(bands[4]!.max === 10000 && !bands[4]!.incl, '尊重：[6000, 10000)（不含 10000）')
ok(bands[5]!.incl === true, '同盟：≥ 10000（含 10000）')
ok(factions.relation.attackHit === -6000, '主动开战 = 直接打到 -6000')
ok(factions.relation.tradeBand === 'neutral', '商路门槛是「中立及以上」')
ok(factions.relation.giftStep === 100, '送礼最少 100')
ok(factions.relation.giftRate === 1, '1 钱 = 1 好感')
ok(factions.relation.allyCost === 2000, '结盟要 2000 钱')
ok(factions.relation.giftStep > 0, '送礼步长为正')

// 每个势力的 cap / initial / flip / defeat 都在合法范围内
for (const f of factions.factions) {
  ok(f.cap in factions.relation.capByBand, `${f.id} 的 cap = ${f.cap} 是合法档位`)
  ok(
    f.initial >= factions.relation.min && f.initial <= factions.relation.max,
    `${f.id} 的 initial = ${f.initial} 在值域内`,
  )
  if (f.flip) {
    ok(f.flip.chapter >= 1 && f.flip.chapter <= 17, `${f.id} 的翻转章号 ${f.flip.chapter} 在 1..17`)
  }
  if (f.defeat) {
    ok(f.defeat.cap in factions.relation.capByBand, `${f.id} 的 defeat.cap 合法`)
    ok(
      f.defeat.rep >= factions.relation.min && f.defeat.rep <= factions.relation.max,
      `${f.id} 的 defeat.rep 在值域内`,
    )
  }
}

// 用户口述的三条硬口径（改错这一条，游戏就会和用户说的不一样）
console.log('=== 与用户口径逐条对上 ===')
const byId = new Map(factions.factions.map((f) => [f.id, f]))
const peak = byId.get('peak')!
ok(peak.initial === -4000 && peak.cap === 'cold', '铁峰：开局冷淡、天花板冷淡')
ok(peak.defeat?.rep === 6000 && peak.defeat?.cap === 'respect' && !peak.defeat?.vassal,
  '铁峰：打赢了**自动变成尊重**（不是附庸、不是冷淡）')
const khan = byId.get('khan')!
ok(khan.flip?.chapter === 6 && khan.flip?.to === -6000, '沙海：章 6 翻脸到敌对')
ok(khan.defeat?.rep === -4000 && khan.defeat?.vassal === false, '沙海：打服回冷淡、不当附庸')
const rook = byId.get('iron_rook')!
ok(rook.vassalable && rook.defeat?.vassal === true, '铁鸦堡：打服变附庸')
ok(rook.cap === 'cold', '铁鸦堡：打服之前最高冷淡')
for (const id of ['holy_see', 'holy_flame']) {
  ok(byId.get(id)?.flip?.chapter === 13, `${id}：章 13 翻脸（圣战）`)
}
for (const id of ['court', 'iron_crown']) {
  ok(byId.get(id)?.cap === 'respect' && !byId.get(id)?.allyable, `${id}：能刷到尊重、不能结盟`)
}
for (const id of ['dawn', 'jade', 'golden_ear', 'blackstone', 'silverleaf', 'ashen_circle']) {
  ok(!!byId.get(id)?.allyable, `${id}：可以结盟`)
}

// 城 → 势力（唯一真源是 routes.json 的 faction 字段，两边必须互相认领）
console.log('=== 城市归属（11 座）===')
ok(routes.cities.length === 11, `商路城应当 11 座，实际 ${routes.cities.length}`)
const claimed = new Map<string, string>()
for (const c of routes.cities) {
  const f = byId.get(c.faction)
  ok(f !== undefined, `${c.nameZh} 的势力 ${c.faction} 存在`)
  ok(f?.cityIds.includes(c.id) === true, `${c.nameZh} 被 ${c.faction} 认领（cityIds 里有它）`)
  const prev = claimed.get(c.id)
  ok(prev === undefined, `${c.nameZh} 只归一家（${prev ?? c.faction}）`)
  claimed.set(c.id, c.faction)
}

// ---------------------------------------------------------------------------
// 图标：徽记 48、关系牌 / 动作按钮 32、面板 32、圆盘 48、科技 64
const pngSize = (p: string): [number, number] => {
  const buf = readFileSync(new URL(p, ROOT))
  return [buf.readUInt32BE(16), buf.readUInt32BE(20)]
}
const wantIcon = (p: string, w: number, h: number): void => {
  try {
    const [gw, gh] = pngSize(p)
    ok(gw === w && gh === h, `${p} 是 ${w}×${h}（实际 ${gw}×${gh}）`)
  } catch {
    ok(false, `缺图标 ${p}`)
  }
}
console.log('=== 图标 ===')
for (const f of factions.factions) {
  wantIcon(`godot/assets/ui/faction/${f.glyph}.png`, 48, 48)
}
for (const b of ['rel_enemy', 'rel_cold', 'rel_neutral', 'rel_friendly', 'rel_respect', 'rel_ally', 'rel_vassal']) {
  wantIcon(`godot/assets/ui/faction/${b}.png`, 32, 32)
}
for (const a of ['gift', 'treaty', 'war']) wantIcon(`godot/assets/ui/faction/${a}.png`, 32, 32)
for (const p of ['diplomacy', 'military']) {
  wantIcon(`godot/assets/ui/panel/${p}.png`, 32, 32)
  wantIcon(`godot/assets/ui/nav/${p}.png`, 48, 48)
}
for (const t of ['statecraft', 'trade_goodwill_1', 'trade_goodwill_2', 'trade_goodwill_3']) {
  wantIcon(`godot/assets/ui/tech/${t}.png`, 64, 64)
}

// ---------------------------------------------------------------------------
console.log('=== 使馆 ===')
const embassy = buildings.buildings.find((b) => b.id === 'embassy')
ok(embassy !== undefined, 'content/buildings.json 里有 embassy')
ok(embassy?.utility === true, '使馆是纯功能建筑（utility: true）')
ok(
  JSON.stringify(embassy?.art?.foot) === JSON.stringify([7, 3]),
  `使馆占地 [7,3]（实际 ${JSON.stringify(embassy?.art?.foot)}）`,
)
const statecraft = techs.technologies.find((t) => t.id === 'statecraft')
ok(statecraft !== undefined, 'content/technologies.json 里有 statecraft')
ok(statecraft?.unlocks.buildings.includes('embassy') === true, '「邦交」解锁使馆')
const unlocking = techs.technologies.filter((t) => t.unlocks.buildings.includes('embassy'))
ok(unlocking.length === 1, '使馆只被一项科技解锁')

if (fails > 0) {
  console.error(`\n邦交内容检查：${fails} 处不通过`)
  process.exit(1)
}
console.log('\n邦交内容检查：全部通过')
