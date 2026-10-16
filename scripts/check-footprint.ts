import { existsSync, readFileSync, readdirSync } from 'node:fs'

// ---------------------------------------------------------------------------
// 占地（footprint）秒级校验 —— 改完 content 里的 `art.foot` 跑这一条就够了。
//
//   npm run check:footprint
//   node --experimental-strip-types scripts/check-footprint.ts
//
// 为什么不直接跑 Godot 的 footprint_test：那条要起一次引擎（几秒到几十秒）。
// 平时的循环是「改 content 的 foot → 这条 <1 秒 → 确认没问题」；Godot 那条门槛
// 留给出真画面/真贴图的问题（它走 `world_view._footprint()` 的真实代码路径）。
//
// 口径与 `godot/scripts/world/world_view.gd::_footprint()` **完全一致**（TILE = 16）：
//   · arch='sprite'：优先 `art.foot`；没写才 `floor(贴图px / 16)`
//     —— **高再减 1 行**（最上面那行是屋顶/塔尖，不占地），每维至少 1
//   · arch='field' 或写了 `rows`：`w × rows`
//   · 其余程序化：`w × (屋顶行数 + 1)`，roof='green' 只占 1 行屋顶，w 缺省 3（field 缺省 6）
//
// 判定分两档：
//   红（退出码 1）—— 贴图缺失 / foot 越界（宽 2-12、高 1-12）/ **顶部隐形行**
//                     （foot 比贴图高出来的行画面上什么都没有、却挡建造）/ 副本没同步
//   蓝（只提示）—— ①「显式覆盖」：foot 与贴图推导值不同（这是 art.foot 的正当用途，
//                     但**换了贴图之后要回来核对**，否则占地和画面会错位）；
//                   ② 贴图比占地高/宽（往上伸出、左右伸出，都是设计允许的常态）
// ---------------------------------------------------------------------------

const TILE = 16
const TEX_DIR = 'godot/assets/buildings'
/** 贴图也可能只存在于美术源目录（还没跑 gen:art 时）。 */
const TEX_FALLBACK_DIR = 'godot/assets/building_src'
const FILES = ['buildings', 'housing'] as const
const CONTENT_DIR = 'content'
const COPY_DIR = 'godot/content'

interface Png {
  path: string
  w: number
  h: number
}

function pngSize(path: string): Png | null {
  if (!existsSync(path)) return null
  const b = readFileSync(path)
  // PNG 签名 + IHDR：宽在 16..20、高在 20..24（大端）
  if (b.length < 24 || b.toString('latin1', 1, 4) !== 'PNG') return null
  return { path, w: b.readUInt32BE(16), h: b.readUInt32BE(20) }
}

function textureOf(id: string): Png | null {
  return pngSize(`${TEX_DIR}/${id}.png`) ?? pngSize(`${TEX_FALLBACK_DIR}/${id}.png`)
}

interface Row {
  file: string
  id: string
  arch: string
  tex: string
  derived: string
  declared: string
  notes: string[]
  badMsg: string
  overridden: boolean
}

const rows: Row[] = []
let spriteCount = 0
let declaredCount = 0

for (const file of FILES) {
  const data = JSON.parse(readFileSync(`${CONTENT_DIR}/${file}.json`, 'utf8')) as Record<
    string,
    Array<Record<string, unknown>>
  >
  for (const item of data[file] ?? []) {
    const art = (item['art'] ?? {}) as Record<string, unknown>
    const arch = String(art['arch'] ?? '')
    const id = String(item['id'])
    const foot = Array.isArray(art['foot']) ? (art['foot'] as number[]) : null
    let declared = foot ? `${foot[0]}×${foot[1]}` : '—'
    let tex = '—'
    let derived = '—'
    const notes: string[] = []
    let badMsg = ''
    let overridden = false

    if (arch === 'sprite') {
      spriteCount += 1
      if (foot) declaredCount += 1
      const png = textureOf(id)
      if (!png) {
        badMsg = '贴图缺失'
      } else {
        tex = `${png.w}×${png.h}`
        const dw = Math.max(1, Math.floor(png.w / TILE))
        const dh = Math.max(1, Math.floor(png.h / TILE) - 1)
        derived = `${dw}×${dh}`
        const fp = foot ?? [dw, dh]
        const fw = fp[0]!
        const fh = fp[1]!
        if (foot) {
          if (fw < 2 || fw > 12) badMsg = `foot 宽 ${fw} 越界（合法 2-12）`
          else if (fh < 1 || fh > 12) badMsg = `foot 高 ${fh} 越界（合法 1-12）`
        }
        const invisible = fh * TILE - png.h
        if (!badMsg && invisible > 0) badMsg = `顶部 ${invisible}px 隐形（占地比贴图高）`
        if (foot && (dw !== fw || dh !== fh)) {
          overridden = true
          notes.push(`显式覆盖：贴图推导 ${dw}×${dh}`)
        }
        const up = png.h - fh * TILE
        if (up > 0) notes.push(`贴图比占地高 ${up}px`)
        const dx = fw * TILE - png.w
        if (dx > 0) notes.push(`贴图比占地窄 ${dx}px（左右留白）`)
        else if (dx < 0) notes.push(`贴图比占地宽 ${-dx}px`)
      }
    } else {
      // 程序化拼装：口径同 world_view._footprint()
      const w = Number(art['w'] ?? (arch === 'field' ? 6 : 3))
      const isField = arch === 'field' || art['rows'] !== undefined
      const h = isField
        ? Number(art['rows'] ?? 1)
        : (String(art['roof'] ?? '') === 'green' ? 1 : 2) + 1
      derived = `${w}×${h}`
      declared = `w=${w}${art['rows'] !== undefined ? ` rows=${art['rows']}` : ''}`
      tex = '程序化'
      notes.push(isField ? 'field/rows' : `roof=${String(art['roof'] ?? '—')}`)
    }

    rows.push({ file, id, arch, tex, derived, declared, notes, badMsg, overridden })
  }
}

console.log('\n 文件      id                      arch      贴图        推导    声明           判定')
for (const r of rows) {
  const mark = r.badMsg ? '✗' : r.overridden ? '*' : ' '
  console.log(
    [
      mark,
      r.file.padEnd(8),
      r.id.padEnd(23),
      r.arch.padEnd(10),
      r.tex.padEnd(11),
      r.derived.padEnd(7),
      r.declared.padEnd(14),
      [r.badMsg, ...r.notes].filter(Boolean).join('；'),
    ].join(' '),
  )
}

// ---- 副本同步：godot/content 必须是 content 的逐字节副本（AGENTS §6）--------
const copyProblems: string[] = []
for (const f of readdirSync(CONTENT_DIR)) {
  if (!f.endsWith('.json')) continue
  const src = readFileSync(`${CONTENT_DIR}/${f}`, 'utf8')
  const dstPath = `${COPY_DIR}/${f}`
  const dst = existsSync(dstPath) ? readFileSync(dstPath, 'utf8') : null
  if (dst === null) copyProblems.push(`${f}：godot/content 里没有这个文件`)
  else if (dst !== src) copyProblems.push(`${f}：副本与源不一致（${src.length} vs ${dst.length} 字节）`)
}

const bads = rows.filter((r) => r.badMsg)
const overrides = rows.filter((r) => r.overridden)

console.log(
  `\nsprite ${spriteCount} 座（都显式写了 foot；其中 foot 与贴图推导不同的 ${overrides.length} 座）` +
    ` ＋ 程序化 ${rows.filter((r) => r.arch !== 'sprite').length} 座`,
)
if (overrides.length > 0) {
  console.log(`* 显式覆盖 ${overrides.length} 座 —— 这几次的占地是手写的，**换过这几张贴图就要回来核对**：`)
  for (const o of overrides)
    console.log(`   ${o.file}/${o.id}: 声明 ${o.declared}，贴图推导 ${o.derived}（贴图 ${o.tex}）`)
}
if (bads.length > 0) {
  console.log(`\n✗ 有问题的 ${bads.length} 条（必须改）：`)
  for (const b of bads) console.log(`   ${b.file}/${b.id}: ${b.badMsg}（贴图 ${b.tex}，占地 ${b.declared}）`)
}
if (copyProblems.length > 0) {
  console.log('\n✗ godot/content 副本没同步（跑 npm run sync:content）：')
  for (const p of copyProblems) console.log('   ' + p)
}
const failed = bads.length > 0 || copyProblems.length > 0
console.log(failed ? '\n占地校验不通过 ❌\n' : '\n占地校验通过 ✅\n')
if (failed) process.exitCode = 1
