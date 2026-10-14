import { mkdirSync, writeFileSync } from 'node:fs'
import { Canvas, type RGBA } from './lib/pixel.ts'

// ---------------------------------------------------------------------------
// 生成「新增 15 项科技」的卡片图标。
//
// 用法：node --experimental-strip-types scripts/gen-tech-icons.ts
//
// 产物：godot/assets/ui/tech/<techId>.png（32x32，与现有 29 张同尺寸）
//
// 设计约束（对应 godot/assets/ui/tech/README.md 的说明）：
//   1. 32x32，文件名 = 科技 id（UIKit.tech_icon() 直接按 id 取图，显示 32x32）
//   2. 16 位像素风、**硬边**：只用矩形 / 多边形 / 圆弧 / 单点整数像素写入，
//      不写任何半透明像素、不做抗锯齿、不做渐变或模糊阴影（脚本里有自检）
//   3. 配色取自现有 29 张图标：脚本从 PNG 里统计出代表色（出现次数排序 +
//      RGB 距离去重），下面 PALETTE 的每个值都标了原始十六进制
//   4. 每个图案最后统一补一圈 1px 深色描边（halo()），保证 15 张放一起是一套
//
// 纯程序化绘制，不用素材图，跑多少次结果都一样（无随机数）。
// ---------------------------------------------------------------------------

const OUT_DIR = 'godot/assets/ui/tech'
const SIZE = 32

// ---------------------------------------------------------------------------
// 调色板（括号内为现有图标里抠出来的原始色）
// ---------------------------------------------------------------------------
const PALETTE: Record<string, RGBA> = {
  // 描边 / 墨色
  '!': [34, 35, 38, 255],    // #222326 最深的墨（现有图标边缘最常出现的两色之一）
  '%': [62, 47, 57, 255],    // #3e2f39 暗紫墨
  // 木料（深 -> 浅）
  w: [85, 59, 42, 255],      // #553b2a
  v: [100, 68, 52, 255],     // #644434
  u: [123, 81, 49, 255],     // #7b5131
  W: [144, 93, 63, 255],     // #905d3f
  X: [165, 115, 65, 255],    // #a57341
  Y: [176, 128, 72, 255],    // #b08048
  Z: [189, 140, 80, 255],    // #bd8c50
  p: [201, 158, 103, 255],   // #c99e67
  l: [217, 191, 151, 255],   // #d9bf97
  // 砖 / 陶 / 火
  r: [112, 45, 40, 255],     // #702d28
  R: [147, 71, 56, 255],     // #934738
  T: [178, 92, 53, 255],     // #b25c35
  t: [207, 115, 63, 255],    // #cf733f
  f: [228, 143, 62, 255],    // #e48f3e
  F: [229, 196, 61, 255],    // #e5c43d
  g: [226, 176, 78, 255],    // #e2b04e
  // 植物
  c: [80, 115, 56, 255],     // #507338
  C: [97, 148, 78, 255],     // #61944e
  G: [120, 176, 76, 255],    // #78b04c
  h: [153, 179, 126, 255],   // #99b37e
  // 石 / 金属
  k: [62, 69, 59, 255],      // #3e453b
  s: [100, 93, 94, 255],     // #645d5e
  S: [130, 127, 126, 255],   // #827f7e
  m: [177, 173, 158, 255],   // #b1ad9e
  M: [204, 207, 203, 255],   // #cccfcb
  // 纸 / 布 / 大理石
  e: [223, 211, 198, 255],   // #dfd3c6
  q: [234, 223, 209, 255],   // #eadfd1
  E: [244, 239, 228, 255],   // #f4efe4
  // 水 / 蓝
  b: [57, 69, 98, 255],      // #394562
  B: [78, 91, 123, 255],     // #4e5b7b
  n: [104, 125, 159, 255],   // #687d9f
  N: [136, 168, 189, 255],   // #88a8bd
  A: [96, 177, 227, 255],    // #60b1e3
  i: [136, 229, 247, 255],   // #88e5f7
}

/** 轮廓色：比现有图标里最深的墨略暖一点，压在深色卡片上轮廓更实。 */
const INK: RGBA = [43, 34, 48, 255]
const CLEAR: RGBA = [0, 0, 0, 0]

function col(ch: string): RGBA {
  const c = PALETTE[ch]
  if (!c) throw new Error(`调色板里没有字符 '${ch}'`)
  return c
}

// ---------------------------------------------------------------------------
// 绘制工具（全部是整数像素直写，没有 alpha 混合 = 没有软边）
// ---------------------------------------------------------------------------

/** 带斜面的方块：上/左为亮边，下/右为暗边。像素风里最常用的"立体块"。 */
function plate(c: Canvas, x: number, y: number, w: number, h: number,
               body: RGBA, light: RGBA, dark: RGBA): void {
  c.rect(x, y, w, h, body)
  if (h >= 3) {
    c.hline(x, x + w - 1, y, light)
    c.hline(x, x + w - 1, y + h - 1, dark)
  }
  if (w >= 3) {
    c.vline(x, y, y + h - 1, light)
    c.vline(x + w - 1, y, y + h - 1, dark)
  }
}

/** 一条横带：左右各 1px 描边，内部「左亮 / 中 / 右暗」三段。用于麻袋、木料。 */
function bandRow(c: Canvas, y: number, xl: number, xr: number,
                 edge: RGBA, light: RGBA, mid: RGBA, shadow: RGBA,
                 lw = 2, sw = 3): void {
  const n = xr - xl + 1
  if (n <= 0) return
  if (n <= 2) { c.hline(xl, xr, y, mid); return }
  c.set(xl, y, edge)
  c.set(xr, y, edge)
  const inner = n - 2
  for (let i = 0; i < inner; i++) {
    c.set(xl + 1 + i, y, i < lw ? light : i >= inner - sw ? shadow : mid)
  }
}

/** Bresenham 直线（1px）。 */
function line(c: Canvas, x0: number, y0: number, x1: number, y1: number, c0: RGBA): void {
  let x = x0
  let y = y0
  const dx = Math.abs(x1 - x0)
  const dy = -Math.abs(y1 - y0)
  const sx = x0 < x1 ? 1 : -1
  const sy = y0 < y1 ? 1 : -1
  let err = dx + dy
  for (;;) {
    c.set(x, y, c0)
    if (x === x1 && y === y1) break
    const e2 = 2 * err
    if (e2 >= dy) { err += dy; x += sx }
    if (e2 <= dx) { err += dx; y += sy }
  }
}

/** 粗线：把 line() 在 y 方向平行复制 w 份（适合近水平的斜撑）。 */
function hlineN(c: Canvas, x0: number, y0: number, x1: number, y1: number,
                c0: RGBA, w: number): void {
  for (let i = 0; i < w; i++) line(c, x0, y0 + i, x1, y1 + i, c0)
}

/** 多边形扫描线填充（边缘取整 = 天然硬边）。 */
function poly(c: Canvas, pts: ReadonlyArray<readonly [number, number]>, c0: RGBA): void {
  let ymin = Infinity
  let ymax = -Infinity
  for (const p of pts) { ymin = Math.min(ymin, p[1]); ymax = Math.max(ymax, p[1]) }
  for (let y = Math.round(ymin); y <= Math.round(ymax); y++) {
    const xs: number[] = []
    for (let i = 0; i < pts.length; i++) {
      const a = pts[i]!
      const b = pts[(i + 1) % pts.length]!
      if (a[1] === y && b[1] === y) { xs.push(a[0], b[0]); continue } // 水平边
      if ((a[1] <= y && b[1] > y) || (b[1] <= y && a[1] > y)) {
        xs.push(a[0] + ((y - a[1]) / (b[1] - a[1])) * (b[0] - a[0]))
      }
    }
    xs.sort((p, q) => p - q)
    for (let i = 0; i + 1 < xs.length; i += 2) {
      const xa = Math.round(xs[i]!)
      const xb = Math.round(xs[i + 1]!)
      for (let x = xa; x <= xb; x++) c.set(x, y, c0)
    }
  }
}

/** 圆环的一段（角度：0 = 右，90 = 下，屏幕坐标）。 */
function arc(c: Canvas, cx: number, cy: number, rIn: number, rOut: number,
             a0: number, a1: number, c0: RGBA): void {
  const r = rOut + 1
  for (let y = Math.floor(cy - r); y <= Math.ceil(cy + r); y++) {
    for (let x = Math.floor(cx - r); x <= Math.ceil(cx + r); x++) {
      const dx = x - cx
      const dy = y - cy
      const d = Math.sqrt(dx * dx + dy * dy)
      if (d < rIn - 0.5 || d > rOut + 0.5) continue
      let a = (Math.atan2(dy, dx) * 180) / Math.PI
      while (a < a0) a += 360
      if (a <= a1) c.set(x, y, c0)
    }
  }
}

/** 齿轮：外圈方齿 + 实心盘 + 中心孔。 */
function gear(c: Canvas, cx: number, cy: number, r: number, teeth: number,
              body: RGBA, hub: RGBA): void {
  const to = r + Math.max(1.4, r * 0.42)
  const tw = Math.max(2.4, r * 0.55)
  for (let i = 0; i < teeth; i++) {
    const a = (i / teeth) * Math.PI * 2 + Math.PI / teeth
    const nx = Math.cos(a)
    const ny = Math.sin(a)
    const px = -ny * (tw / 2)
    const py = nx * (tw / 2)
    poly(c, [
      [cx + nx * (r - 1) - px, cy + ny * (r - 1) - py],
      [cx + nx * (r - 1) + px, cy + ny * (r - 1) + py],
      [cx + nx * to + px * 0.6, cy + ny * to + py * 0.6],
      [cx + nx * to - px * 0.6, cy + ny * to - py * 0.6],
    ], body)
  }
  c.disc(cx, cy, r, body)
  const rh = Math.max(1.2, r * 0.36)
  c.disc(cx, cy, rh, hub)
  c.disc(cx, cy, Math.max(0.6, rh - 1.4), CLEAR)
}

/** 圆锯片：三角尖齿 + 实心盘 + 轮毂。 */
function sawBlade(c: Canvas, cx: number, cy: number, r: number, teeth: number,
                  body: RGBA, hub: RGBA): void {
  for (let i = 0; i < teeth; i++) {
    const a = (i / teeth) * Math.PI * 2
    const nx = Math.cos(a)
    const ny = Math.sin(a)
    const px = -ny
    const py = nx
    const b = r * 0.18
    poly(c, [
      [cx + nx * (r - 1) - px * b, cy + ny * (r - 1) - py * b],
      [cx + nx * (r - 1) + px * b, cy + ny * (r - 1) + py * b],
      [cx + nx * (r + 2) + px * 0.25, cy + ny * (r + 2) + py * 0.25],
    ], body)
  }
  c.disc(cx, cy, r, body)
  c.disc(cx, cy, Math.max(1.5, r * 0.32), hub)
  c.disc(cx, cy, Math.max(0.5, r * 0.16), CLEAR)
}

/** 多行字符串 -> 等宽行数组（'.' = 透明）。 */
function art(s: string): string[] {
  const rows = s.trim().split('\n').map((r) => r.trimEnd())
  const w = rows[0]!.length
  rows.forEach((r, i) => {
    if (r.length !== w) throw new Error(`art 第 ${i} 行 ${r.length} 列，应与其他行一致（${w}）`)
  })
  return rows
}

/** 按行数组把细节画到 (dx, dy)。 */
function mask(c: Canvas, rows: string[], dx: number, dy: number): void {
  rows.forEach((row, y) => {
    for (let x = 0; x < row.length; x++) {
      const ch = row[x]!
      if (ch !== '.') c.set(dx + x, dy + y, col(ch))
    }
  })
}

/** 在圆环上放一个切向箭头：底边沿半径方向张开，尖朝切线方向（dir=+1 顺时针）。 */
function ringArrow(c: Canvas, cx: number, cy: number, r: number, aDeg: number,
                   dir: number, w: number, len: number, c0: RGBA): void {
  const a = (aDeg * Math.PI) / 180
  const nx = Math.cos(a)
  const ny = Math.sin(a)
  const tx = -ny * dir
  const ty = nx * dir
  const px = cx + nx * r
  const py = cy + ny * r
  poly(c, [
    [px + nx * w, py + ny * w],
    [px - nx * w, py - ny * w],
    [px + tx * len, py + ty * len],
  ], c0)
}

/** 给整个图案补一圈 1px 深色描边（只写透明像素，不动图案本体）。 */
function halo(c: Canvas, c0: RGBA): void {
  const add: Array<[number, number]> = []
  for (let y = 0; y < c.h; y++) {
    for (let x = 0; x < c.w; x++) {
      if (c.get(x, y)[3] !== 0) continue
      if ((c.inside(x + 1, y) && c.get(x + 1, y)[3] !== 0)
        || (c.inside(x - 1, y) && c.get(x - 1, y)[3] !== 0)
        || (c.inside(x, y + 1) && c.get(x, y + 1)[3] !== 0)
        || (c.inside(x, y - 1) && c.get(x, y - 1)[3] !== 0)) add.push([x, y])
    }
  }
  for (const [x, y] of add) c.set(x, y, c0)
}

// ---------------------------------------------------------------------------
// 15 张图标
//
// 设计上刻意避开现有 29 张的主形：toolmaking 是「交叉的锤 + 斧」，
// brickmaking 是「砖窑穹顶 + 火焰」，carpentry 是「木屋」，construction 是
// 「A 形木构架 + 火花」，research_institute 是「砖堆」，所以：
//   作坊分工 -> 竖着的锤 + 扳手（不做交叉）
//   窑炉改良 -> 竖长窑体 + 烟囱 + 金色升级箭头（不做穹顶）
//   木工机械 -> 圆锯压在木料上
//   学院    -> 柱廊 + 山花
// ---------------------------------------------------------------------------
type Draw = (c: Canvas) => void

const ICONS: Array<[string, Draw]> = []

// 1. 轮作：双向循环箭头 + 中央一块正在轮换的田 ---------------------------
ICONS.push(['crop_rotation', (c) => {
  // 两段圆弧 + 两个切向箭头 = 循环；缺口留在左右两侧
  arc(c, 16, 16, 9, 11.5, 200, 310, col('g'))
  arc(c, 16, 16, 9, 11.5, 20, 130, col('g'))
  arc(c, 16, 16, 9, 10.2, 200, 310, col('t'))
  arc(c, 16, 16, 9, 10.2, 20, 130, col('t'))
  ringArrow(c, 16, 16, 10.25, 310, 1, 5, 7, col('g'))
  ringArrow(c, 16, 16, 10.25, 130, 1, 5, 7, col('g'))
  mask(c, art(`
wwwwwwwwwwww
vFvFvFvvGvGv
vWvWvWvvcvcv
vWvWvWvvcvcv
uuuuuuuuuuuu
vvvvvvvvvvvv
uuuuuuuuuuuu
vvvvvvvvvvvv
uuuuuuuuuuuu
vvvvvvvvvvvv
uuuuuuuuuuuu
wwwwwwwwwwww
`), 10, 10)
}])

// 2. 灌溉：水渠剖面 + 落下的水滴 ------------------------------------------
ICONS.push(['irrigation', (c) => {
  const drop = art(`
..A..
.AAA.
AAAAA
iAAAA
AAAAA
.AAA.
..b..
`)
  mask(c, drop, 4, 8)
  mask(c, drop, 22, 8)
  mask(c, art(`
.A.
AAA
AiA
.b.
`), 14, 14)
  // 水渠：土壁 + 渠底 + 流水
  c.rect(2, 20, 28, 10, col('u'))
  c.hline(2, 29, 20, col('W'))
  c.hline(2, 29, 29, col('w'))
  c.vline(5, 21, 29, col('v'))
  c.vline(26, 21, 29, col('v'))
  c.rect(6, 22, 20, 8, col('A'))
  c.hline(6, 25, 22, col('N'))
  c.hline(6, 25, 23, col('N'))
  c.hline(6, 25, 26, col('n'))
  c.hline(6, 25, 27, col('b'))
  c.hline(6, 25, 28, col('b'))
  c.hline(8, 11, 24, col('i'))     // 水面反光
  c.hline(12, 15, 23, col('i'))
  c.hline(17, 20, 25, col('N'))
}])

// 3. 良种：扎口的种子袋 + 冒出的芽 + 撒出的谷粒 --------------------------
ICONS.push(['improved_seeds', (c) => {
  mask(c, art(`
...cGc..cGc...
..cGGGccGGGc..
..cGGGCCGGGc..
...cGGCCGGc...
......cC......
......cC......
......cC......
......cC......
......cC......
......cC......
......cC......
......cC......
......cC......
`), 9, 1)
  // 麻袋：扎口 + 溜肩 + 平底
  const bag: Array<[number, number, number]> = [
    [13, 14, 17], [14, 13, 18], [15, 11, 20], [16, 10, 21],
    [17, 9, 22], [18, 9, 22], [19, 9, 22], [20, 9, 22], [21, 9, 22],
    [22, 9, 22], [23, 9, 22], [24, 9, 22], [25, 9, 22], [26, 9, 22],
    [27, 10, 21], [28, 11, 20],
  ]
  bag.forEach(([y, xl, xr], i) => {
    // 隔行换一次中间色 = 粗麻布的织纹
    bandRow(c, y, xl, xr, col('v'), col('p'), i % 3 === 1 ? col('Y') : col('Z'), col('X'))
  })
  c.hline(13, 18, 14, col('w'))                              // 收口绳
  plate(c, 13, 11, 4, 3, col('v'), col('p'), col('w'))       // 绳结
  // 撒在旁边的谷粒
  mask(c, art(`
..FF..
.FggF.
FggggF
ggYggg
`), 2, 26)
  mask(c, art(`
.YY.
YllY
.YY.
`), 1, 22)
}])

// 4. 作坊分工：锤子 + 扳手，各占一个工位（刻意不做成交叉，避开 toolmaking）
ICONS.push(['workshop_division', (c) => {
  plate(c, 2, 5, 12, 7, col('S'), col('m'), col('s'))    // 锤头
  c.hline(3, 12, 6, col('M'))
  c.vline(7, 11, 29, col('X'))                           // 木柄
  c.vline(8, 11, 29, col('Z'))
  c.vline(9, 11, 29, col('u'))
  c.hline(7, 9, 15, col('u'))
  c.hline(7, 9, 21, col('u'))
  mask(c, art(`
mmmm.....mmmm
mSSm.....mSSm
mSSm.....mSSm
mSSm.....mSSm
.mSSm...mSSm.
..mSSmmmSSm..
...mSSSSSm...
..mSSSSSSSm..
.mSSSSSSSSSm.
.msSSSSSSSsm.
..msSSSSSsm..
...msSSSsm...
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sSSSs....
....sssss....
`), 17, 4)
}])

// 5. 标准化：游标卡尺 + 三件一模一样的木构件 ---------------------------
ICONS.push(['standardization', (c) => {
  plate(c, 3, 8, 26, 4, col('S'), col('m'), col('s'))    // 主尺
  plate(c, 18, 5, 7, 6, col('S'), col('m'), col('s'))    // 游标
  c.hline(20, 23, 7, col('s'))
  plate(c, 3, 12, 5, 6, col('S'), col('m'), col('s'))    // 固定爪
  plate(c, 20, 11, 5, 7, col('S'), col('m'), col('s'))   // 活动爪
  for (let x = 8; x <= 16; x += 2) c.set(x, 11, col('s')) // 刻度
  for (const x of [2, 12, 22]) {
    plate(c, x, 23, 8, 6, col('Y'), col('Z'), col('u'))
    c.hline(x + 2, x + 5, 25, col('u'))
  }
}])

// 6. 流水线：齿轮 + 传送带 + 带上的箱子 -----------------------------------
ICONS.push(['assembly_line', (c) => {
  gear(c, 23, 9, 4.6, 8, col('g'), col('t'))
  c.rect(6, 21, 20, 9, col('s'))          // 带身
  c.disc(6, 25, 4, col('s'))
  c.disc(25, 25, 4, col('s'))
  c.hline(6, 25, 21, col('k'))
  c.hline(6, 25, 29, col('k'))
  c.disc(6, 25, 3.2, col('S'))            // 两个滚筒
  c.disc(25, 25, 3.2, col('S'))
  c.disc(6, 25, 1.2, col('k'))
  c.disc(25, 25, 1.2, col('k'))
  for (const x of [3, 11]) {              // 待加工件
    plate(c, x, 15, 7, 6, col('Y'), col('Z'), col('u'))
    c.hline(x + 1, x + 5, 17, col('u'))
  }
}])

// 7. 窑炉改良：竖长砖窑 + 烟囱 + 火 + 金色升级箭头 -----------------------
ICONS.push(['kiln_upgrade', (c) => {
  plate(c, 4, 17, 24, 13, col('T'), col('t'), col('R'))  // 窑体（竖长，不做穹顶）
  for (const y of [20, 23, 26]) c.hline(5, 26, y, col('R'))
  for (const x of [8, 14, 20, 26]) c.vline(x, 18, 19, col('R'))
  for (const x of [11, 17, 23]) c.vline(x, 21, 22, col('R'))
  for (const x of [8, 14, 20, 26]) c.vline(x, 24, 25, col('R'))
  plate(c, 8, 5, 6, 12, col('R'), col('T'), col('r'))    // 烟囱
  plate(c, 7, 4, 8, 2, col('T'), col('t'), col('r'))
  c.disc(12, 25, 5, col('!'))                            // 拱形火口
  c.rect(7, 25, 11, 5, col('!'))
  mask(c, art(`
...f....
..ff....
..fFf...
.fFFFf..
.fFFFf..
ffFFFff.
fFFFFFf.
.fffff..
`), 9, 22)
  poly(c, [[18, 11], [26, 11], [22, 5]], col('g'))       // 升级箭头
  c.rect(21, 11, 3, 6, col('g'))
  c.vline(21, 11, 16, col('t'))
}])

// 8. 木工机械：圆锯压在木料上 ---------------------------------------------
ICONS.push(['sawmill_machinery', (c) => {
  plate(c, 2, 19, 18, 9, col('X'), col('Y'), col('u'))   // 木料
  c.hline(3, 19, 22, col('u'))
  c.hline(3, 19, 25, col('u'))
  sawBlade(c, 19, 15, 7.6, 14, col('m'), col('S'))       // 圆锯（咬进木料）
  arc(c, 19, 15, 4.4, 7.2, 150, 300, col('M'))
  arc(c, 19, 15, 6.6, 7.4, -30, 130, col('S'))
  c.set(6, 29, col('Z'))                                 // 锯屑
  c.set(8, 28, col('Y'))
  c.set(4, 29, col('p'))
}])

// 9. 制砖机械：冲压式砖机（压头 + 砖模 + 成品砖） -------------------------
ICONS.push(['brick_press', (c) => {
  plate(c, 6, 3, 13, 3, col('S'), col('m'), col('s'))    // 顶梁手柄
  plate(c, 11, 6, 4, 10, col('S'), col('m'), col('s'))   // 压杆
  for (const y of [8, 11, 14]) c.hline(11, 14, y, col('s'))
  plate(c, 6, 16, 14, 4, col('S'), col('m'), col('s'))   // 压头
  c.hline(7, 18, 17, col('s'))
  // 砖模：两片侧板 + 模底 + 模里的泥
  plate(c, 4, 22, 3, 5, col('X'), col('Y'), col('u'))
  plate(c, 19, 22, 3, 5, col('X'), col('Y'), col('u'))
  plate(c, 7, 23, 12, 4, col('T'), col('t'), col('R'))
  plate(c, 4, 27, 18, 3, col('X'), col('Y'), col('u'))
  // 旁边两块成品砖
  plate(c, 23, 21, 7, 4, col('T'), col('t'), col('R'))
  plate(c, 23, 26, 7, 4, col('T'), col('t'), col('R'))
}])

// 10. 抄书房：卷轴 + 羽毛笔 -----------------------------------------------
ICONS.push(['scriptorium', (c) => {
  plate(c, 3, 7, 18, 4, col('e'), col('q'), col('s'))    // 上卷轴
  plate(c, 3, 25, 18, 4, col('e'), col('q'), col('s'))   // 下卷轴
  plate(c, 4, 11, 16, 14, col('q'), col('E'), col('e'))  // 纸面
  for (const [y, x0, x1] of [[13, 6, 17], [15, 6, 17], [17, 6, 14],
    [19, 6, 17], [21, 6, 12], [23, 6, 16]] as const) {
    c.hline(x0, x1, y, col('s'))                         // 抄写的行
  }
  c.ellipse(27, 11, 3.4, 8, col('e'))                    // 羽毛
  c.vline(26, 4, 17, col('E'))
  c.vline(27, 4, 18, col('q'))
  c.set(24, 8, CLEAR)                                    // 羽枝缺口
  c.set(30, 9, CLEAR)
  c.set(24, 13, CLEAR)
  c.set(30, 14, CLEAR)
  c.vline(27, 19, 23, col('e'))                          // 笔杆
  poly(c, [[27, 29], [25, 22], [29, 22]], col('s'))      // 笔尖
}])

// 11. 学院：柱廊 + 山花 ---------------------------------------------------
ICONS.push(['academy', (c) => {
  poly(c, [[16, 2], [2, 10], [30, 10]], col('m'))        // 山花
  c.hline(6, 26, 6, col('M'))
  plate(c, 2, 10, 28, 3, col('m'), col('M'), col('s'))   // 额枋
  for (const x of [3, 12, 21]) plate(c, x, 13, 8, 2, col('m'), col('M'), col('s'))
  for (const x of [4, 13, 22]) {
    plate(c, x, 15, 6, 12, col('q'), col('E'), col('e')) // 柱身
    c.vline(x + 2, 16, 25, col('e'))                     // 凹槽
    c.vline(x + 4, 16, 25, col('e'))
  }
  plate(c, 2, 27, 28, 3, col('m'), col('M'), col('s'))   // 台基
}])

// 12. 印刷术：印好的纸 + 印版 + 活字块 ------------------------------------
ICONS.push(['printing_press', (c) => {
  plate(c, 3, 4, 26, 12, col('E'), col('q'), col('e'))   // 印好的纸
  for (const [y, x0, x1] of [[7, 6, 25], [9, 6, 20], [11, 6, 25],
    [13, 6, 16]] as const) {
    c.hline(x0, x1, y, col('s'))                         // 排好的字行
  }
  c.rect(21, 12, 4, 3, col('R'))                         // 朱印
  c.set(22, 12, col('T'))
  plate(c, 6, 17, 20, 3, col('S'), col('m'), col('s'))   // 压印版
  // 三枚活字块，字面各不相同
  const glyphs = [
    ['.m.', 'm.m', 'mmm'],
    ['mmm', 'm.m', 'mmm'],
    ['mmm', '.m.', '.m.'],
  ]
  ;[2, 11, 20].forEach((x, i) => {
    plate(c, x, 22, 8, 7, col('s'), col('m'), col('!'))
    mask(c, glyphs[i]!, x + 2, 24)
  })
}])

// 13. 起重架：塔身 + 吊臂 + 吊钩 ------------------------------------------
ICONS.push(['crane', (c) => {
  plate(c, 8, 26, 17, 4, col('X'), col('Y'), col('u'))   // 底座
  plate(c, 2, 5, 28, 4, col('X'), col('Y'), col('u'))    // 吊臂
  plate(c, 13, 8, 5, 18, col('X'), col('Y'), col('u'))   // 塔身
  for (const y of [11, 14, 17, 20, 23]) c.hline(13, 17, y, col('u'))
  hlineN(c, 17, 14, 26, 9, col('X'), 2)                  // 斜拉杆
  plate(c, 2, 9, 5, 6, col('s'), col('S'), col('k'))     // 配重
  c.vline(25, 9, 16, col('s'))                           // 吊索
  c.rect(24, 15, 2, 4, col('s'))                         // 钩颈
  arc(c, 24, 21, 1.4, 3.6, 0, 210, col('s'))             // 钩身
}])

// 14. 脚手架：立杆 + 脚手板 + 剪刀撑 + 梯子 -------------------------------
ICONS.push(['scaffolding', (c) => {
  for (const y of [8, 19]) plate(c, 2, y, 27, 3, col('Y'), col('Z'), col('u'))
  for (const x of [3, 14, 25]) plate(c, x, 4, 3, 26, col('X'), col('Y'), col('u'))
  hlineN(c, 17, 19, 25, 11, col('u'), 2)                 // 右跨剪刀撑
  hlineN(c, 17, 11, 25, 19, col('u'), 2)
  plate(c, 8, 11, 2, 18, col('Y'), col('Z'), col('u'))   // 左跨梯子
  plate(c, 12, 11, 2, 18, col('Y'), col('Z'), col('u'))
  for (const y of [13, 16, 22, 25, 28]) c.hline(8, 13, y, col('X'))
}])

// 15. 预制件：成捆的构件 + 金属绑带 + 吊环 --------------------------------
ICONS.push(['prefab_parts', (c) => {
  for (const y of [8, 14, 20]) {                         // 三根一样的梁
    plate(c, 3, y, 26, 5, col('Y'), col('Z'), col('u'))
    c.hline(4, 27, y + 2, col('X'))
  }
  for (const x of [9, 20]) plate(c, x, 6, 3, 22, col('S'), col('m'), col('s'))
  arc(c, 16, 4, 1.4, 2.8, 0, 359, col('S'))              // 吊环
  c.rect(15, 6, 2, 2, col('S'))
}])

// ---------------------------------------------------------------------------
// 主流程 + 自检
// ---------------------------------------------------------------------------
function main(): void {
  mkdirSync(OUT_DIR, { recursive: true })
  const ids: string[] = []
  for (const [id, draw] of ICONS) {
    const c = new Canvas(SIZE, SIZE)
    draw(c)
    // 描边补之前先确认图案本体没顶到画布边缘，否则有一边会没有轮廓
    for (let i = 0; i < SIZE; i++) {
      if (c.get(i, 0)[3] !== 0 || c.get(i, SIZE - 1)[3] !== 0
        || c.get(0, i)[3] !== 0 || c.get(SIZE - 1, i)[3] !== 0) {
        throw new Error(`${id}: 图案顶到画布边缘，1px 描边会被裁掉`)
      }
    }
    halo(c, INK)
    for (let y = 0; y < SIZE; y++) {
      for (let x = 0; x < SIZE; x++) {
        const a = c.get(x, y)[3]
        if (a !== 0 && a !== 255) {
          throw new Error(`${id}: (${x},${y}) 是半透明像素 alpha=${a}，违反硬边要求`)
        }
      }
    }
    writeFileSync(`${OUT_DIR}/${id}.png`, c.toPng())
    ids.push(id)
  }
  console.log(`科技图标 ${ids.length} 张 -> ${OUT_DIR}/（${SIZE}x${SIZE}）`)
  for (const id of ids) console.log(`   ${id}.png`)
}

main()
