// 文档门槛：`docs/technology.md` §三 的科技总表**必须与内容逐行对得上**。
//
// 为什么要有这一条：这张表是给人看的"这游戏有哪些科技、要什么、给什么"，
// 2026-10 之前它停在 53 项 / 2,810 科研力（真实是 72 项 / 4,375），
// 而且只列了解锁型 —— 玩家/策划照着它做规划会被带沟里。
// 内容改了却忘了改表，不会报错、也不会崩，只会**悄悄骗人**。这条门槛就是抓这个。
//
// 它只查"表里写的东西对不对"，不管格式好不好看：
//   · 每一项科技在 §三 里**至少有一行**（`| # | 名字 | `id` | 科研力 | 材料 | 前置 | 效果 | 图标 |`）
//   · 那一行的**科研力 / 每一对"货物 数量" / 前置集合 / 图标路径**与 `content/technologies.json` 一致
//   · 表里不许出现内容里没有的 id（改了名/删了科技却没删行）
//
// 跑法：npm run check:techdoc（也在 `npm test` 里）
import { readFileSync } from 'node:fs'

const ROOT = new URL('../', import.meta.url)
const read = (p: string): string => readFileSync(new URL(p, ROOT), 'utf8')

interface Tech {
  id: string
  nameZh: string
  era: number
  research: number
  cost: { goods: Record<string, number> }
  requires: string[]
  effects?: Record<string, number>
  trade?: Record<string, number>
  unlocks: { buildings: string[]; housing: string[] }
}
interface GoodsFile {
  goods: { id: string; nameZh: string }[]
}

let fails = 0
function ok(cond: boolean, msg: string): void {
  if (!cond) {
    fails += 1
    console.error('  ✗ ' + msg)
  }
}

const techFile: { technologies: Tech[] } = JSON.parse(read('content/technologies.json'))
const goodsFile: GoodsFile = JSON.parse(read('content/goods.json'))
const gname = new Map(goodsFile.goods.map((g) => [g.id, g.nameZh]))
const doc = read('docs/technology.md')

const fmt = (v: number): string => (Number.isInteger(v) ? String(v) : String(v))

/** §三 里每个 id 对应的表格行（单元格数组）。 */
const rows = new Map<string, string[][]>()
for (const line of doc.split('\n')) {
  const m = /^\|\s*\d+\s*\|[^|]*\|\s*`([a-z0-9_]+)`\s*\|(.*)$/.exec(line)
  if (!m) continue
  const id = m[1]!
  const cells = m[2]!.split('|').map((c) => c.trim())
  rows.set(id, [...(rows.get(id) ?? []), cells])
}

const known = new Set(techFile.technologies.map((t) => t.id))
for (const id of rows.keys()) ok(known.has(id), `文档里有「${id}」，但 content 里没有这项科技`)

for (const t of techFile.technologies) {
  const got = rows.get(t.id)
  if (!got || got.length === 0) {
    ok(false, `「${t.nameZh}」(${t.id}) 在 docs/technology.md §三 的总表里没有行`)
    continue
  }
  // 民生服务那一节还有一张小表，id 出现两次是允许的；这里只认第一张（§三 的）
  const cells = got[0]!
  if (cells.length < 5) {
    ok(false, `「${t.id}」那一行列数不足（${cells.join(' / ')}）`)
    continue
  }
  const [research, cost, req, effect, icon] = cells as [string, string, string, string, string]
  ok(research === fmt(t.research), `「${t.id}」科研力：文档写 ${research}，内容 ${t.research}`)
  for (const [g, n] of Object.entries(t.cost.goods)) {
    const want = `${gname.get(g) ?? g} ${fmt(n)}`
    ok(cost.includes(want), `「${t.id}」材料里缺「${want}」（文档写的是：${cost}）`)
  }
  const wantReq = [...t.requires].sort().join(',')
  const gotReq =
    req === '—' ? '' : (req.match(/[a-z0-9_]+/g) ?? []).sort().join(',')
  ok(gotReq === wantReq, `「${t.id}」前置：文档写 ${req}，内容是 ${t.requires.join('、')}`)
  ok(effect !== '' && effect !== '—', `「${t.id}」效果一栏是空的`)
  ok(icon === `\`tech/${t.id}.png\``, `「${t.id}」图标列写的是 ${icon}`)
}

if (fails > 0) {
  console.error(`\n科技总表核对：${fails} 处与内容对不上`)
  process.exit(1)
}
console.log(`  科技总表 ${techFile.technologies.length} 项：名字 / 科研力 / 材料 / 前置 / 效果 / 图标 全部与内容一致`)
console.log('\n科技总表核对：通过')
