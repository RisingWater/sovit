import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { Canvas, type RGBA } from './lib/pixel.ts'

// ---------------------------------------------------------------------------
// 生成像素美术（全部由 content/*.json 的 art 字段驱动）
//
// 产物：
//   godot/assets/buildings/<id>.png    37 座建筑（33 产业 + 3 住房 + 仓库）
//   godot/assets/actors/<class>.png    4 阶层 x 4 向 x 4 帧（16px 网格）
//   godot/assets/tiny/extra.png        自绘地形图集（道路 / 水面 / 桥）
//
// 改 content/*.json 的 art 字段 → 重跑 `npm run gen:art` 即可，无需改代码。
// 纯自绘的部分（地形、角色、特征件）在本文件里，改常量即可。
// ---------------------------------------------------------------------------

const G = 16
const COLS = 12 // Tiny 图集列数

const ROOT = 'godot/assets'
const TOWN_PNG = `${ROOT}/tiny/town.png`
const FARM_PNG = `${ROOT}/tiny/farm.png`
// Super Retro World 的房屋原图（gitignore，不上库）
/** v3 成品建筑整图的入库副本（`scripts/import-building-sprites.py` 产出，已提交）。 */
const BUILDING_SRC = `${ROOT}/building_src`

type AtlasName = 'town' | 'farm'

interface Art {
  arch: string
  sprite?: string
  roof?: string
  wall?: string
  w?: number
  rows?: number
  chimney?: boolean
  feat?: string[]
  soil?: string
  crop?: string
}

// ---------------------------------------------------------------------------
// 图集
// ---------------------------------------------------------------------------
const atlasCache = new Map<AtlasName, Canvas>()

function atlas(name: AtlasName): Canvas {
  let c = atlasCache.get(name)
  if (!c) {
    c = Canvas.fromPng(name === 'town' ? TOWN_PNG : FARM_PNG)
    atlasCache.set(name, c)
  }
  return c
}

/** 取一块 16x16 tile（未做 alpha 处理）。 */
function tile(name: AtlasName, idx: number): Canvas {
  const a = atlas(name)
  const t = new Canvas(G, G)
  t.blit(a, 0, 0, (idx % COLS) * G, Math.floor(idx / COLS) * G, G, G)
  return t
}

/** 把 tile 叠到目标位置；flip=水平镜像；fill=先铺底色（门洞是透明的，必须填）。 */
function put(dst: Canvas, name: AtlasName, idx: number, dx: number, dy: number,
             flip = false, fill?: RGBA): void {
  const t = tile(name, idx)
  if (fill) {
    const b = new Canvas(G, G, fill)
    b.blit(t, 0, 0)
    dst.blit(flip ? flipX(b) : b, dx, dy)
    return
  }
  if (flip) dst.blit(flipX(t), dx, dy)
  else dst.blit(t, dx, dy)
}

function flipX(src: Canvas): Canvas {
  const out = new Canvas(src.w, src.h)
  for (let y = 0; y < src.h; y++) for (let x = 0; x < src.w; x++) out.set(src.w - 1 - x, y, src.get(x, y))
  return out
}

// ---------------------------------------------------------------------------
// 组合表（全部来自图集，无自绘）
// ---------------------------------------------------------------------------
const ROOFS: Record<string, { atlas: AtlasName; top: number[]; eave: number[] | null; chim: number | null }> = {
  blue: { atlas: 'town', top: [48, 49, 50], eave: [60, 61, 62], chim: 51 },
  red: { atlas: 'town', top: [52, 53, 54], eave: [64, 65, 66], chim: 55 },
  green: { atlas: 'farm', top: [93, 94, 95], eave: null, chim: null },
}

// 门用第 8 行的实门（85 木 / 89 石）—— 自带墙体背景、门扇已画好。
// 不要用 74/78：那是"透明门洞"的空白门框。
const WALLS: Record<string, { atlas: AtlasName; end: number; mid: number; door: number }> = {
  wood: { atlas: 'town', end: 72, mid: 73, door: 85 },
  stone: { atlas: 'town', end: 76, mid: 79, door: 89 },
  barn: { atlas: 'farm', end: 117, mid: 119, door: 118 },
  plank: { atlas: 'farm', end: 114, mid: 115, door: 116 },
}

const SOIL: Record<string, number[]> = { row5: [48, 49, 50], row6: [60, 61, 62] }
const CROPS: Record<string, { tiles: number[]; bag: number }> = {
  wheat: { tiles: [66, 67, 68], bag: 69 },
  cabbage: { tiles: [53, 54, 55, 56], bag: 57 },
  sprout: { tiles: [52, 64, 65], bag: 58 },
  bush: { tiles: [56, 28, 29], bag: 59 },
  corn: { tiles: [68, 32, 30], bag: 70 },
  tomato: { tiles: [42, 43, 41], bag: 71 },
}

// ---------------------------------------------------------------------------
// 自绘调色板（取自 Tiny 图集同色系）
// ---------------------------------------------------------------------------
const INK: RGBA = [63, 38, 49, 255]
const WOOD: RGBA = [201, 138, 90, 255]
const WOOD_D: RGBA = [150, 96, 58, 255]
const GREY: RGBA = [150, 158, 170, 255]
const GREY_D: RGBA = [110, 118, 130, 255]

const W_DEEP: RGBA = [62, 106, 158, 255]
const W_MID: RGBA = [86, 138, 192, 255]
const W_LIT: RGBA = [124, 180, 226, 255]
const SAND: RGBA = [222, 178, 138, 255]
const SAND_D: RGBA = [196, 152, 114, 255]
const SAND_L: RGBA = [238, 200, 162, 255]
const FOAM: RGBA = [238, 246, 242, 255]
const BR_WOOD: RGBA = [206, 146, 96, 255]
const BR_WOOD_D: RGBA = [166, 110, 68, 255]
const BR_RAIL: RGBA = [146, 94, 56, 255]
const BR_RAIL_L: RGBA = [232, 186, 138, 255]

const DOOR_FILL: RGBA = [92, 56, 44, 255]

// ---------------------------------------------------------------------------
// 特征件（图集里确实没有的部分，自绘）
// ---------------------------------------------------------------------------
function featWindmill(): Canvas {
  const c = new Canvas(26, 26)
  const m = 13
  for (const [dx, dy] of [[0, -11], [0, 11], [-11, 0], [11, 0]] as const) {
    // 2px 描边 + 1px 木色（先粗后细）
    step(c, m, m, m + dx, m + dy, INK, 2)
    step(c, m, m, m + dx, m + dy, WOOD, 1)
  }
  c.disc(m, m, 5, GREY)
  c.disc(m, m, 4, GREY)
  c.disc(m, m, 2, WOOD_D)
  return c
}

/** 从 (x0,y0) 到 (x1,y1) 画一条宽 w 的线段（轴对齐或 45°，够用）。 */
function step(c: Canvas, x0: number, y0: number, x1: number, y1: number, col: RGBA, w: number): void {
  const n = Math.max(Math.abs(x1 - x0), Math.abs(y1 - y0))
  for (let i = 0; i <= n; i++) {
    const t = n === 0 ? 0 : i / n
    const x = Math.round(x0 + (x1 - x0) * t)
    const y = Math.round(y0 + (y1 - y0) * t)
    c.rect(x - (w >> 1), y - (w >> 1), w, w, col)
  }
}

function featWheel(): Canvas {
  const c = new Canvas(14, 14)
  c.disc(6, 6, 6, WOOD)
  c.disc(6, 6, 5, WOOD)
  for (let a = 1; a < 12; a += 3) c.hline(1, 11, a, WOOD_D)
  c.disc(6, 6, 2, GREY)
  return c
}

function featLogs(): Canvas {
  const c = new Canvas(20, 13)
  for (const [x, y] of [[0, 6], [7, 6], [3, 1]] as const) {
    c.rect(x, y, 9, 6, WOOD)
    c.stroke(x, y, 9, 6, INK)
    c.hline(x + 2, x + 5, y + 2, WOOD_D)
  }
  return c
}

function featRocks(): Canvas {
  const c = new Canvas(20, 13)
  // 左小右大两块碎石（阶梯三角）
  const tri = (cx: number, base: number, hgt: number, col: RGBA) => {
    for (let i = 0; i < hgt; i++) {
      const w = Math.round((i / hgt) * (hgt - i) * 0.9) + 1
      c.hline(cx - w, cx + w, base - i, col)
    }
    for (let i = 0; i < hgt; i++) {
      const w = Math.round((i / hgt) * (hgt - i) * 0.9) + 1
      c.set(cx - w, base - i, INK)
      c.set(cx + w, base - i, INK)
    }
  }
  tri(5, 11, 8, GREY)
  tri(13, 11, 10, GREY_D)
  return c
}

const FEATS: Record<string, () => Canvas> = {
  windmill: featWindmill,
  wheel: featWheel,
  logs: featLogs,
  rocks: featRocks,
}

// ---------------------------------------------------------------------------
// 建筑
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// 成品建筑整图（用户提供的素材，`building_src/<id>.png`；v3 一批 + v5 重绘批次）
//
// **尺寸规则：显示高度由「层数」决定。**
//   显示高度上限 = 层数 × 3 格 + 屋顶 2 格
//     1 层 -> 5 格(80px)   2 层 -> 8 格(128px)   3 层 -> 11 格(176px)
//   每座建筑取**满足上限的最大整数下采样倍率**（1 或 2），宽度按原图比例跟随。
//
// 为什么用"最大倍率"而不是"最接近某个目标高度"：
//   素材同宽(128)但高度差一倍多(62~131)。若一律按比例缩到同一目标高度，
//   矮图（研究所 128x73）会被缩成一条窄带 —— 这正是用户反馈的"研究所偏小"。
//   改成"能多大就多大、只要不超上限"，矮图就保持原生尺寸，看着不再单薄。
//
// 为什么要按层数分档、不能一律 ÷2：
//   木屋(1层) 和 砖房(2层) 的**原图高度都是 96**。一律 ÷2 会让二层楼和一层楼
//   显示成一样高 —— 用户明确要求"不能两层的建筑和一层楼的一样高"。
//   按层数给上限后：1 层被压到 ≤80px、2 层 96px、3 层 160px，层级就分开了。
//
// 例外见下面的 FORCE_HALF（同批素材必须同倍率）。
//
// 只做整数倍缩放：下采样前先把宽高裁成倍率的整数倍（最多丢 1px 边缘），
// 保证是真·整数倍，不会出现半像素、大小不一的像素块。
// ---------------------------------------------------------------------------
const STOREYS: Record<string, number> = {
  // 清单里写明层数的只有这 4 座，其余一律 1 层
  brick_house: 2, // 「正方形两层」
  villa: 2, // 「正方形两层」
  town_center: 3, // 「又宽又高 3 层」
  theater: 3, // 「又宽又高 3 层」
}
const STOREY_TILES = 3 // 每层 3 格
const ROOF_TILES = 2 // 屋顶 2 格

// 强制 ÷2 的建筑名单 = **"小建筑"档**：显示 64 宽，和伐木场(64x39)同一档。
//
// 为什么要显式列名单、不让上面的高度上限逐座判断：
//   1 层上限 80px 太松，源高 62~78 的建筑都会原样留在 128 宽，于是同一类建筑劈成
//   两档（128 宽的大房子 vs 64 宽的小房子），地图上看着就不像一套。用户要的是
//   "这些小建筑都按小档来"：
//     * v5 那批营地/工棚是 78~92px，其中伐木场/木柴坊只有 78 —— 不点名的话这两座
//       会留在 128 宽，而同批另外四座被 ÷2，**同一批素材一半大一半小**；
//     * 粘土坑源高 67，不点名就是 128x67（占地 8x5），比伐木场整整大一档
//       （面积 4 倍），用户要求它和伐木场对齐。
//
// ⚠️ 占地和贴图现在是**解耦**的（见 content 的 art.foot）：占地由 content 声明，
//    贴图可以比占地高，往上和身后的建筑互相遮挡。所以这里"压到 64 宽"纯粹是
//    造型选择（小房子就该小），不再是为了塞进格子 —— 以前是为了塞格子才不得不压。
const FORCE_HALF: Record<string, true> = {
  // v5 重绘批次（营地/工棚）
  hunting_camp: true,
  fishery: true,
  smokehouse: true,
  dried_meat_works: true,
  lumberjack: true,
  firewood_works: true,
  // 采集类，和伐木场对齐
  clay_pit: true,
}

// 强制按**原生尺寸**显示（不缩放）。用户指定的"大建筑"档：研究所 / 建筑工坊 /
// 家政工坊 / 仓库 这四座一样大。它们的源图是 128x73 / 84 / 64 / 62：
//   * 建筑工坊 84 超过 1 层上限 80，自动规则会把它 ÷2 成 64x42，必须点名留住；
//   * 其余三座源高 ≤80 本来就 ×1，一并写进来是为了让"这四座是同一档"这件事
//     在代码里看得见，而不是靠上限的巧合。
// 它们的占地在 content 里声明成 8x3，贴图比占地高（最多 36px），往上伸出去，
// 和身后的建筑按地面线 y 排序遮挡 —— 见 world_view._footprint / _apply_art_offset。
const FORCE_NATIVE: Record<string, true> = {
  research_institute: true,
  construction_works: true,
  domestic_service: true,
}

function storeysOf(id: string): number {
  return STOREYS[id] ?? 1
}

/** 该建筑的显示高度上限（像素）。 */
function maxDisplayH(id: string): number {
  return (STOREY_TILES * storeysOf(id) + ROOF_TILES) * G
}

/** 整数倍下采样：先裁到 f 的整数倍，再取每 f×f 块的左上像素（= 最近邻）。 */
function downscaleExact(src: Canvas, f: number): Canvas {
  if (f === 1) return src
  const w = Math.floor(src.w / f) * f
  const h = Math.floor(src.h / f) * f
  const out = new Canvas(w / f, h / f)
  for (let y = 0; y < out.h; y++)
    for (let x = 0; x < out.w; x++) out.set(x, y, src.get(x * f, y * f))
  return out
}

/** 从入库的整图生成建筑贴图（尺寸规则见上）。scale 显式指定时不再自动挑倍率。 */
function spriteBuilding(id: string, srcPath: string, forceScale?: number): Canvas {
  const src = Canvas.fromPng(srcPath)
  const cap = maxDisplayH(id)
  const f0 = forceScale ?? (FORCE_HALF[id] ? 2 : FORCE_NATIVE[id] ? 1 : undefined)
  let f = f0 ?? 1
  if (f0 === undefined) {
    // 倍率只取 2 的幂，这样"裁到整数倍"最多只丢 1px
    while (Math.floor(src.h / f) > cap && f < 8) f *= 2
  }
  return downscaleExact(src, f)
}

function renderField(art: Art): Canvas {
  const w = art.w ?? 6
  const rows = art.rows ?? 1
  const soilKey = art.soil ?? 'row5'
  const soil = SOIL[soilKey]!
  const alt = SOIL[soilKey === 'row5' ? 'row6' : 'row5']!
  const crop = CROPS[art.crop ?? 'wheat']!
  const cv = new Canvas(w * G, rows * G)
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < w; c++) {
      const set = (c * 3 + r * 5) % 2 === 1 ? alt : soil
      const idx = c === 0 ? set[0]! : c === w - 1 ? set[2]! : set[1]!
      const t = tile('farm', idx)
      if (r > 0) {
        // 土垄 tile 顶部 4 行是草边：非首行用同列土壤色覆盖 → 纵向无缝
        for (let y = 0; y < 4; y++) for (let x = 0; x < G; x++) t.set(x, y, t.get(x, 8))
      }
      cv.blit(t, c * G, r * G)
    }
  }
  let n = 0
  for (let r = 0; r < rows; r++) {
    for (let c = 1; c < w - 1; c++) {
      if ((c * 2 + r) % 3 === 2) continue // 留空隙，别太规整
      put(cv, 'farm', crop.tiles[n % crop.tiles.length]!, c * G, r * G)
      n++
    }
  }
  put(cv, 'farm', crop.bag, 0, (rows - 1) * G)
  return cv
}

function renderBuilding(art: Art): Canvas {
  if (art.arch === 'field') return renderField(art)

  const w = art.w ?? 3
  const m = w - 2
  const roof = ROOFS[art.roof ?? 'blue']!
  const wall = WALLS[art.wall ?? 'wood']!
  const rowsData: { atlas: AtlasName; cells: { idx: number; flip: boolean; fill?: RGBA }[] }[] = []

  // 屋顶上排（可换烟囱）
  const top: { idx: number; flip: boolean }[] = []
  for (let i = 0; i < w; i++) top.push({ idx: i === 0 ? roof.top[0]! : i === w - 1 ? roof.top[2]! : roof.top[1]!, flip: false })
  if (art.chimney && roof.chim !== null) top[Math.floor(w / 2)] = { idx: roof.chim, flip: false }
  rowsData.push({ atlas: roof.atlas, cells: top })

  // 檐口行
  if (roof.eave) {
    const cells: { idx: number; flip: boolean }[] = []
    for (let i = 0; i < w; i++) cells.push({ idx: i === 0 ? roof.eave[0]! : i === w - 1 ? roof.eave[2]! : roof.eave[1]!, flip: false })
    rowsData.push({ atlas: 'town', cells })
  }

  // 墙体行：左端原块、右端镜像、中间开门
  const wallCells: { idx: number; flip: boolean; fill?: RGBA }[] = []
  for (let i = 0; i < w; i++) {
    if (i === 0) wallCells.push({ idx: wall.end, flip: false })
    else if (i === w - 1) wallCells.push({ idx: wall.end, flip: true })
    else wallCells.push({ idx: wall.mid, flip: false })
  }
  if (w === 2) {
    wallCells[1] = { idx: wall.end, flip: true }
  } else {
    wallCells[Math.floor(w / 2)] = { idx: wall.door, flip: false, fill: DOOR_FILL }
  }
  rowsData.push({ atlas: wall.atlas, cells: wallCells })

  const cv = new Canvas(w * G, rowsData.length * G)
  rowsData.forEach((row, ry) => {
    row.cells.forEach((cell, rx) => {
      put(cv, row.atlas, cell.idx, rx * G, ry * G, cell.flip, cell.fill)
    })
  })

  for (const f of art.feat ?? []) {
    const img = FEATS[f]!()
    const dx = f === 'windmill' ? 2 : f === 'wheel' ? cv.w - 18 : 4
    const dy = f === 'windmill' ? -8 : cv.h - 15
    cv.blit(img, dx, dy)
  }
  return cv
}

// ---------------------------------------------------------------------------
// 角色（4 阶层 x 4 向 x 4 帧，全自绘）
// ---------------------------------------------------------------------------
const SKIN: RGBA = [247, 194, 130, 255]
const SKIN_D: RGBA = [214, 152, 96, 255]
const HAIR: RGBA = [120, 72, 48, 255]
const HAIR_D: RGBA = [86, 50, 34, 255]
const SHOE: RGBA = [86, 56, 42, 255]
const STRAW: RGBA = [226, 186, 106, 255]
const STRAW_D: RGBA = [186, 146, 74, 255]

interface ClassPal { shirt: RGBA; shirtD: RGBA; pants: RGBA; hair: RGBA; hat: RGBA | null }
const CLASSES: Record<string, ClassPal> = {
  poor: { shirt: [78, 112, 158, 255], shirtD: [56, 84, 122, 255], pants: [96, 78, 62, 255], hair: HAIR, hat: null },
  middle: { shirt: [122, 148, 122, 255], shirtD: [92, 116, 94, 255], pants: [84, 78, 70, 255], hair: HAIR, hat: null },
  rich: { shirt: [166, 78, 70, 255], shirtD: [128, 56, 52, 255], pants: [66, 62, 74, 255], hair: HAIR_D, hat: null },
  boss: { shirt: [206, 166, 74, 255], shirtD: [164, 128, 52, 255], pants: [70, 62, 56, 255], hair: HAIR_D, hat: STRAW },
}
const CLASS_IDS = ['poor', 'middle', 'rich', 'boss']
const DIRS = ['S', 'N', 'W', 'E'] as const
type Dir = (typeof DIRS)[number]

function actor(cls: string, dir: Dir, frame: number): Canvas {
  const p = CLASSES[cls]!
  const c = new Canvas(G, G)
  const f = ((frame % 4) + 4) % 4
  const bob = f === 1 || f === 3 ? 1 : 0
  const stepv = [0, 1, 0, -1][f]!

  // 影子
  c.ellipse(7.5, 14.5, 3.5, 1, [0, 0, 0, 70])

  // 腿
  for (const lx of [6 + stepv, 9 - stepv]) {
    c.rect(lx - 1, 12 - bob, 2, 3, p.pants)
    c.rect(lx - 1, 15 - bob, 2, 1, SHOE)
  }

  // 身体
  const by0 = 7 - bob
  c.rect(5, by0, 6, 6, p.shirt)
  c.stroke(5, by0, 6, 6, INK)
  c.rect(5, by0 + 3, 6, 1, p.shirtD)

  // 手臂（侧面只露靠前的一只）
  const profile = dir === 'W' || dir === 'E'
  if (profile) {
    c.rect(7, by0 + 1 - stepv, 1, 4, p.shirt)
    c.rect(7, by0 + 5 - stepv, 1, 1, SKIN)
  } else {
    for (const [ax, sw] of [[4, -stepv], [11, stepv]] as const) {
      c.rect(ax, by0 + 1 + sw, 1, 4, p.shirt)
      c.rect(ax, by0 + 5 + sw, 1, 1, SKIN)
    }
  }

  // 头
  const hy0 = 1 - bob
  c.rect(5, hy0, 6, 6, SKIN)
  c.stroke(5, hy0, 6, 6, INK)
  for (const [cx, cy] of [[5, hy0], [10, hy0], [5, hy0 + 5], [10, hy0 + 5]] as const) {
    c.set(cx, cy, [0, 0, 0, 0])
  }

  if (dir === 'S') {
    c.rect(6, hy0 + 1, 4, 1, p.hair)
    c.set(6, hy0 + 3, INK)
    c.set(9, hy0 + 3, INK)
    c.set(7, hy0 + 4, SKIN_D)
    c.set(8, hy0 + 4, SKIN_D)
  } else if (dir === 'N') {
    c.rect(6, hy0 + 1, 4, 4, p.hair)
    c.set(6, hy0 + 4, HAIR_D)
    c.set(9, hy0 + 4, HAIR_D)
  } else {
    c.rect(6, hy0 + 1, 4, 1, p.hair)
    c.rect(8, hy0 + 1, 2, 4, p.hair)
    c.rect(5, hy0 + 1, 1, 4, p.hair)
    c.set(6, hy0 + 3, INK)
    c.set(9, hy0 + 3, HAIR_D)
  }

  if (p.hat) {
    c.rect(5, hy0 - 1, 6, 1, p.hat)
    c.rect(6, hy0 - 2, 3, 1, STRAW_D)
  }

  return dir === 'E' ? flipX(c) : c
}

/** 一个阶层一张 64x64 表：行 = 朝向，列 = 帧。 */
function actorSheet(cls: string): Canvas {
  const cv = new Canvas(G * 4, G * 4)
  DIRS.forEach((d, dy) => {
    for (let f = 0; f < 4; f++) cv.blit(actor(cls, d, f), f * G, dy * G)
  })
  return cv
}

// ---------------------------------------------------------------------------
// 地形 auto-tile（自绘：Tiny 图集没有水面，也没有转弯/十字路）
// ---------------------------------------------------------------------------
function waterTile(land: Record<string, boolean>, inner: Record<string, boolean>): Canvas {
  const c = new Canvas(G, G, W_MID)
  for (const [x, y] of [[2, 5], [9, 8], [4, 12], [11, 3]] as const) {
    c.hline(x, x + 4, y, W_LIT)
    c.set(x + 2, y + 1, W_DEEP)
  }
  const bank = (s: string) => {
    if (s === 'N') { c.rect(0, 0, 16, 4, SAND); c.rect(0, 0, 16, 2, SAND_L); c.rect(0, 4, 16, 1, FOAM) }
    if (s === 'S') { c.rect(0, 12, 16, 4, SAND); c.rect(0, 14, 16, 2, SAND_D); c.rect(0, 11, 16, 1, FOAM) }
    if (s === 'W') { c.rect(0, 0, 4, 16, SAND); c.rect(0, 0, 2, 16, SAND_L); c.rect(4, 0, 1, 16, FOAM) }
    if (s === 'E') { c.rect(12, 0, 4, 16, SAND); c.rect(14, 0, 2, 16, SAND_D); c.rect(11, 0, 1, 16, FOAM) }
  }
  for (const s of ['N', 'S', 'E', 'W']) if (land[s]) bank(s)
  for (const [a, b, box] of [['N', 'W', [0, 0, 4, 4]], ['N', 'E', [12, 0, 4, 4]],
                             ['S', 'W', [0, 12, 4, 4]], ['S', 'E', [12, 12, 4, 4]]] as const) {
    if (land[a] && land[b]) c.rect(box[0]!, box[1]!, box[2]!, box[3]!, SAND)
  }
  // 内凹圆角：两邻边是水但对角是陆地 → 四分之一圆沙洲
  const quarter: Record<string, [number, number, -1 | 1, -1 | 1]> = {
    NW: [0, 0, 1, 1], NE: [15, 0, -1, 1], SW: [0, 15, 1, -1], SE: [15, 15, -1, -1],
  }
  for (const [diag, v] of Object.entries(quarter)) {
    if (!inner[diag]) continue
    const [ox, oy, sx, sy] = v
    for (let y = 0; y < 8; y++) {
      for (let x = 0; x < 8; x++) {
        const dx = x + 0.5
        const dy = y + 0.5
        if (dx * dx + dy * dy <= 49) c.set(ox + sx * x, oy + sy * y, SAND)
      }
    }
  }
  return c
}

function roadTile(mask: Record<string, boolean>): Canvas {
  const c = new Canvas(G, G)
  c.rect(0, 0, 16, 16, SAND)
  for (const [x, y] of [[3, 4], [10, 6], [5, 11], [12, 13]] as const) c.set(x, y, SAND_L)
  for (const [x, y] of [[7, 2], [13, 8], [2, 9], [9, 14]] as const) c.set(x, y, SAND_D)
  if (!mask['N']) { c.rect(0, 0, 16, 1, SAND_L); c.rect(0, 1, 16, 1, SAND_D) }
  if (!mask['S']) { c.rect(0, 15, 16, 1, SAND_D); c.rect(0, 14, 16, 1, SAND_L) }
  if (!mask['W']) { c.rect(0, 0, 1, 16, SAND_L); c.rect(1, 0, 1, 16, SAND_D) }
  if (!mask['E']) { c.rect(15, 0, 1, 16, SAND_D); c.rect(14, 0, 1, 16, SAND_L) }
  // 外圆角：抹掉角，露出草地
  const corner: Record<string, [number, number, boolean]> = {
    NW: [0, 0, !mask['N'] && !mask['W']],
    NE: [15, 0, !mask['N'] && !mask['E']],
    SW: [0, 15, !mask['S'] && !mask['W']],
    SE: [15, 15, !mask['S'] && !mask['E']],
  }
  for (const [, [ox, oy, on]] of Object.entries(corner)) {
    if (!on) continue
    const sx = ox === 0 ? 1 : -1
    const sy = oy === 0 ? 1 : -1
    for (let y = 0; y < 3; y++) {
      for (let x = 0; x < 3; x++) {
        const dx = x + 0.5
        const dy = y + 0.5
        if (dx * dx + dy * dy > 10) c.set(ox + sx * x, oy + sy * y, [0, 0, 0, 0])
      }
    }
  }
  return c
}

function bridgeTile(axis: 'h' | 'v'): Canvas {
  const c = new Canvas(G, G)
  if (axis === 'h') {
    c.rect(0, 2, 16, 12, BR_WOOD)
    for (let y = 4; y < 13; y += 3) c.hline(0, 15, y, BR_WOOD_D)
    c.rect(0, 2, 16, 2, BR_RAIL)
    c.rect(0, 12, 16, 2, BR_RAIL)
    c.rect(0, 2, 16, 1, BR_RAIL_L)
  } else {
    c.rect(2, 0, 12, 16, BR_WOOD)
    for (let x = 4; x < 13; x += 3) c.vline(x, 0, 15, BR_WOOD_D)
    c.rect(2, 0, 2, 16, BR_RAIL)
    c.rect(12, 0, 2, 16, BR_RAIL)
    c.rect(2, 0, 1, 16, BR_RAIL_L)
  }
  return c
}

function patchTile(kind: string): Canvas {
  const base: RGBA = kind === 'stone' ? [168, 168, 172, 255]
    : kind === 'clay' ? [186, 124, 80, 255] : [206, 198, 180, 255]
  const dark: RGBA = kind === 'stone' ? [136, 136, 142, 255]
    : kind === 'clay' ? [152, 98, 62, 255] : [176, 168, 150, 255]
  const lit: RGBA = kind === 'stone' ? [196, 196, 200, 255]
    : kind === 'clay' ? [214, 152, 104, 255] : [226, 220, 204, 255]
  const c = new Canvas(G, G, base)
  for (const [x, y] of [[3, 4], [10, 6], [5, 11], [12, 13]] as const) c.set(x, y, dark)
  for (const [x, y] of [[7, 2], [13, 8], [2, 9], [9, 14]] as const) c.set(x, y, lit)
  c.set(6, 6, dark)
  c.set(11, 4, dark)
  return c
}

/** 地板：砖石铺装（错缝砌法）。 */
function floorTile(): Canvas {
  const MORTAR: RGBA = [86, 90, 100, 255]
  const BR: RGBA = [166, 170, 180, 255]
  const BR_L: RGBA = [206, 210, 218, 255]
  const BR_D: RGBA = [132, 136, 146, 255]
  const c = new Canvas(G, G, MORTAR)
  // 上排：两块整砖，砖缝在 x=0 / 7-8 / 15
  c.rect(1, 1, 6, 6, BR)
  c.rect(9, 1, 6, 6, BR)
  // 下排：错半砖
  c.rect(1, 9, 3, 6, BR)
  c.rect(6, 9, 6, 6, BR)
  c.rect(14, 9, 2, 6, BR)
  // 顶面高光
  c.rect(1, 1, 6, 1, BR_L)
  c.rect(9, 1, 6, 1, BR_L)
  c.rect(1, 9, 3, 1, BR_L)
  c.rect(6, 9, 6, 1, BR_L)
  c.rect(14, 9, 2, 1, BR_L)
  // 底边阴影
  c.rect(1, 6, 6, 1, BR_D)
  c.rect(9, 6, 6, 1, BR_D)
  c.rect(1, 14, 3, 1, BR_D)
  c.rect(6, 14, 6, 1, BR_D)
  c.rect(14, 14, 2, 1, BR_D)
  return c
}

/** 树的装饰图集：4 种树，每种 16x32（上格树冠 + 下格树干）。 */
function decoAtlas(): Canvas {
  const variants: [number, number][] = [[3, 15], [4, 16], [5, 17], [7, 19]]
  const cv = new Canvas(G * variants.length, G * 2)
  variants.forEach(([top, bot], i) => {
    put(cv, 'town', top, i * G, 0)
    put(cv, 'town', bot, i * G, G)
  })
  return cv
}

function terrainAtlas(): Canvas {
  const cv = new Canvas(8 * G, 7 * G)
  // row0-1: 道路 16 种
  for (let m = 0; m < 16; m++) {
    const mask: Record<string, boolean> = { N: (m & 1) !== 0, S: (m & 2) !== 0, E: (m & 4) !== 0, W: (m & 8) !== 0 }
    cv.blit(roadTile(mask), (m % 8) * G, Math.floor(m / 8) * G)
  }
  // row2-5: 水面 32 种
  let k = 0
  for (let m = 0; m < 16; m++) {
    const land: Record<string, boolean> = { N: (m & 1) !== 0, S: (m & 2) !== 0, E: (m & 4) !== 0, W: (m & 8) !== 0 }
    for (const mode of [0, 1]) {
      const inner: Record<string, boolean> = {}
      for (const [diag, nb] of Object.entries({ NW: ['N', 'W'], NE: ['N', 'E'], SW: ['S', 'W'], SE: ['S', 'E'] })) {
        inner[diag] = mode === 1 && !land[nb[0]!] && !land[nb[1]!]
      }
      const x = (k % 8) * G
      const y = (2 + Math.floor(k / 8)) * G
      cv.blit(waterTile(land, inner), x, y)
      k++
    }
  }
  // row6: 桥 x2 + 地面补丁 x2（石矿 / 粘土）+ 地板 x1（砖石铺装）
  cv.blit(bridgeTile('h'), 0, 6 * G)
  cv.blit(bridgeTile('v'), G, 6 * G)
  cv.blit(patchTile('stone'), 2 * G, 6 * G)
  cv.blit(patchTile('clay'), 3 * G, 6 * G)
  cv.blit(floorTile(), 4 * G, 6 * G)
  return cv
}

/** 建造卡片用的缩略图：固定 100x72，取能放下的最大整数倍缩放后居中。 */
const THUMB_W = 100
const THUMB_H = 72

function thumbOf(src: Canvas): Canvas {
  const TW = THUMB_W
  const TH = THUMB_H
  let scale = 1
  while (src.w / scale > TW || src.h / scale > TH) scale *= 2
  const w = Math.max(1, Math.floor(src.w / scale))
  const h = Math.max(1, Math.floor(src.h / scale))
  const out = new Canvas(TW, TH)
  const ox = Math.floor((TW - w) / 2)
  const oy = Math.floor((TH - h) / 2)
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) out.set(ox + x, oy + y, src.get(x * scale, y * scale))
  }
  return out
}

/** 道路 / 地板的卡片缩略图：草地底上铺一小块。 */
function brushThumb(kind: 'road' | 'floor'): Canvas {
  const c = new Canvas(THUMB_W, THUMB_H)
  for (let y = 0; y < THUMB_H; y += G) {
    for (let x = 0; x < THUMB_W; x += G) put(c, 'town', 0, x, y)
  }
  const t = kind === 'road' ? roadTile({ N: true, S: true, E: true, W: true }) : floorTile()
  const cols = 3
  const rows = 2
  const ox = Math.floor((THUMB_W - cols * G) / 2)
  const oy = Math.floor((THUMB_H - rows * G) / 2)
  for (let j = 0; j < rows; j++) {
    for (let i = 0; i < cols; i++) c.blit(t, ox + i * G, oy + j * G)
  }
  return c
}

// ---------------------------------------------------------------------------
// 速度控制图标（16x16，自绘）
//
// 找过了：Kenney UI Pack 的 Small tiles(161) 与 Large tiles(91) 里都没有
// 播放/暂停/快进的字形，Cursor Pixel Pack 也只有单个实心三角。
// 所以这四个按 UI 包的配色自绘：暂停 = 两条竖线，1x/2x/4x = 1/2/3 个箭羽。
// ---------------------------------------------------------------------------
// 图标画在 UI 包的米黄按钮上，所以必须用深色；用浅色会完全看不见。
const SP_INK: RGBA = [59, 41, 28, 255]

function speedIcon(kind: string): Canvas {
  const c = new Canvas(G, G)
  if (kind === 'pause') {
    for (const x of [4, 9]) c.rect(x, 3, 3, 9, SP_INK)
    return c
  }
  const n = kind === '1x' ? 1 : kind === '2x' ? 2 : 3
  const x0 = n === 1 ? 6 : n === 2 ? 3 : 1
  const widths = [1, 2, 3, 4, 4, 4, 3, 2, 1]
  for (let i = 0; i < n; i++) {
    const x = x0 + i * 5
    for (let r = 0; r < widths.length; r++) c.rect(x, 3 + r, widths[r]!, 1, SP_INK)
  }
  return c
}

// ---------------------------------------------------------------------------
// 左侧导航圆钮（16x16，自绘）
//
// 用户嫌原来的 StyleBoxFlat 几何圆"太精细、没有像素风"，要求：
//   边框加粗 / 颗粒度加大 / 边框内圈一圈高光 / 正上正下正左正右各一小段
//   灰色金属 / 整体像"金属把木头拼接箍在一起"。
//
// 所以这是一张**手绘像素贴图**：木盘 + 粗深色外框 + 内圈米色高光 +
// 四向金属卡扣（卡扣横跨边框、并向内咬进木头一点，才像"箍住"）。
//
// 半径分层（原生 16px，圆心 7.5,7.5，外缘半径 7.5）：
//   r > 6.5        外框（约 1px 原生 = 显示 3~4px，够粗）
//   5.9 < r <= 6.5 内圈高光
//   r <= 5.9       木盘
// 木盘半径 5.9 是**算出来的**：显示 48(3x) 时是 17.7px、55(3.4x) 时是 20.3px，
// 都要放得下 32px 的图标（半径 16），否则图标会把高光那一圈盖住。
// ---------------------------------------------------------------------------
const NB_FRAME: RGBA = [46, 30, 20, 255] // 粗外框（近黑棕）
const NB_HILITE: RGBA = [228, 204, 162, 255] // 边框内圈高光
// 内部填充：**单色平涂，不做木纹**（用户要求"内部不要做成木纹的"）。
// ⚠️ 别改成米色系：那样会和内圈高光 NB_HILITE 几乎同色，高光那一圈就看不见了。
const NB_FILL: RGBA = [148, 98, 56, 255]
const NB_METAL: RGBA = [140, 146, 154, 255] // 金属卡扣
const NB_METAL_L: RGBA = [198, 205, 213, 255] // 金属亮边
const NB_METAL_D: RGBA = [84, 90, 98, 255] // 金属暗边

/** 三态只靠整体明暗区分：常态 1.0 / 悬停亮一点 / 按下暗一点。 */
function navShade(c: RGBA, k: number): RGBA {
  const f = (v: number) => Math.max(0, Math.min(255, Math.round(v * k)))
  return [f(c[0]), f(c[1]), f(c[2]), 255]
}

/**
 * 用工拖动条的把手（8x12 像素）。
 *
 * 默认 HSlider 的把手是圆角渐变，放在这个像素画 UI 里非常出戏。
 * 这里做成一块**带金属箍的木头**，和左侧导航圆钮同一套配色与画法：
 * 深色描边 + 木色主体 + 上下两道金属亮/暗边（像手指捏的那圈金属）。
 */
function sliderGrabber(): Canvas {
  const c = new Canvas(8, 12)
  for (let y = 0; y < 12; y++) {
    for (let x = 0; x < 8; x++) {
      const edge = x === 0 || x === 7 || y === 0 || y === 11
      // 中间两道金属箍：第 4 行亮边、第 7 行暗边
      const metalL = y === 4
      const metalD = y === 7
      if (edge) c.set(x, y, NB_METAL_D)
      else if (metalL) c.set(x, y, NB_METAL_L)
      else if (metalD) c.set(x, y, NB_METAL)
      else c.set(x, y, NB_FILL)
    }
  }
  // 左侧一列提亮，做出一点立体感
  for (let y = 1; y < 11; y++) c.set(1, y, NB_HILITE)
  return c
}

function navButton(kind: string): Canvas {
  const c = new Canvas(G, G)
  const k = kind === 'hover' ? 1.14 : kind === 'pressed' ? 0.82 : 1.0
  const R_OUT = 7.5 // 圆的外缘半径
  const R_FRAME = 5.9 // 外框内边界（约 1.6px 厚）
  const R_HILITE = 5.1 // 高光内边界
  const cx = 7.5
  const cy = 7.5
  const rad = (x: number, y: number) => {
    const dx = x + 0.5 - cx
    const dy = y + 0.5 - cy
    return Math.sqrt(dx * dx + dy * dy)
  }

  for (let y = 0; y < G; y++) {
    for (let x = 0; x < G; x++) {
      const r = rad(x, y)
      if (r > R_OUT) continue // 圆外留透明
      if (r > R_FRAME) {
        c.set(x, y, navShade(NB_FRAME, k))
      } else if (r > R_HILITE) {
        c.set(x, y, navShade(NB_HILITE, k))
      } else {
        // 单色平涂（不做木纹）
        c.set(x, y, navShade(NB_FILL, k))
      }
    }
  }

  // 四向金属卡扣：横跨外框与高光、并向内咬进木头 1px，像把木盘"箍住"。
  // ⚠️ 每一格都必须**仍在圆内**（r <= R_OUT）—— 否则卡扣的边角会戳出圆外，
  // 整个剪影变成"圆 + 四个灰方块"，第一版就是这么画错的。
  // 外侧 1px 提亮、内侧 1px 压暗，做出金属反光。
  const clip = (x0: number, y0: number, w: number, h: number, vertical: boolean, brightOuter: boolean) => {
    for (let y = y0; y < y0 + h; y++) {
      for (let x = x0; x < x0 + w; x++) {
        if (rad(x, y) > R_OUT) continue
        // 沿"从圆外指向圆心"的方向：第一格是外侧，最后一格是内侧
        const isOuter = vertical
          ? (brightOuter ? y === y0 : y === y0 + h - 1)
          : brightOuter
            ? x === x0
            : x === x0 + w - 1
        const isInner = vertical
          ? (brightOuter ? y === y0 + h - 1 : y === y0)
          : brightOuter
            ? x === x0 + w - 1
            : x === x0
        const col = isOuter ? NB_METAL_L : isInner ? NB_METAL_D : NB_METAL
        c.set(x, y, navShade(col, k))
      }
    }
  }
  clip(6, 1, 4, 2, true, true) // 正上：亮边朝上
  clip(6, 13, 4, 2, true, false) // 正下：亮边朝下
  clip(1, 6, 2, 4, false, true) // 正左：亮边朝左
  clip(13, 6, 2, 4, false, false) // 正右：亮边朝右
  return c
}

// ---------------------------------------------------------------------------
// 商品图标（16x16，全自绘）
// ---------------------------------------------------------------------------
const I_DARK: RGBA = [58, 40, 30, 255]
const I_WOOD: RGBA = [166, 110, 68, 255]
const I_WOOD_L: RGBA = [210, 156, 106, 255]
const I_STONE: RGBA = [150, 156, 166, 255]
const I_STONE_L: RGBA = [190, 196, 204, 255]
const I_GREEN: RGBA = [104, 172, 88, 255]
const I_GREEN_D: RGBA = [72, 128, 62, 255]
const I_GOLD: RGBA = [232, 182, 72, 255]
const I_GOLD_D: RGBA = [186, 136, 44, 255]
const I_CREAM: RGBA = [244, 236, 216, 255]
const I_RED: RGBA = [188, 82, 74, 255]
const I_RED_D: RGBA = [142, 56, 52, 255]
const I_BLUE: RGBA = [96, 140, 190, 255]
const I_CLAY: RGBA = [186, 124, 80, 255]
const I_PURPLE: RGBA = [150, 96, 168, 255]
const I_GREY: RGBA = [128, 134, 144, 255]

function sack(c: Canvas, body: RGBA, tie: RGBA): void {
  c.rect(4, 5, 8, 9, body)
  c.stroke(4, 5, 8, 9, I_DARK)
  c.rect(5, 3, 6, 2, body)
  c.rect(5, 3, 6, 1, tie)
}

function loaf(c: Canvas, body: RGBA, crust: RGBA): void {
  c.rect(3, 6, 10, 6, body)
  c.rect(3, 6, 10, 2, crust)
  c.stroke(3, 6, 10, 6, I_DARK)
  c.rect(5, 9, 2, 1, crust)
  c.rect(9, 9, 2, 1, crust)
}

function shirt(c: Canvas, body: RGBA, trim: RGBA): void {
  c.rect(5, 4, 6, 9, body)
  c.rect(2, 5, 3, 3, body)
  c.rect(11, 5, 3, 3, body)
  c.stroke(5, 4, 6, 9, I_DARK)
  c.rect(5, 4, 6, 1, trim)
  c.rect(7, 5, 2, 3, trim)
}

function ingot(c: Canvas, body: RGBA, lit: RGBA): void {
  c.rect(3, 9, 10, 4, body)
  c.rect(4, 7, 8, 2, lit)
  c.rect(5, 6, 6, 1, lit)
  c.stroke(3, 9, 10, 4, I_DARK)
}

function jug(c: Canvas, body: RGBA, lit: RGBA): void {
  c.rect(5, 3, 3, 2, body)
  c.rect(4, 5, 8, 7, body)
  c.rect(3, 7, 1, 4, body)
  c.rect(12, 7, 1, 4, body)
  c.stroke(4, 5, 8, 7, I_DARK)
  c.rect(5, 6, 2, 5, lit)
}

function goodIcon(id: string): Canvas {
  const c = new Canvas(G, G)
  switch (id) {
    case 'wheat': case 'coarse_flour': case 'fine_flour':
      sack(c, id === 'wheat' ? I_GOLD : I_CREAM, I_WOOD)
      if (id === 'wheat') { c.rect(6, 6, 1, 1, I_GOLD_D); c.rect(9, 9, 1, 1, I_GOLD_D) }
      break
    case 'vegetable':
      c.rect(4, 5, 8, 8, I_GREEN); c.stroke(4, 5, 8, 8, I_DARK)
      c.rect(5, 6, 3, 3, I_GREEN_D); c.rect(6, 4, 4, 1, I_GREEN_D)
      break
    case 'flax':
      c.rect(7, 5, 2, 9, I_GREEN_D)
      c.rect(5, 3, 6, 3, I_BLUE); c.rect(7, 2, 2, 1, I_BLUE)
      c.rect(5, 8, 3, 1, I_GREEN); c.rect(8, 10, 3, 1, I_GREEN)
      break
    case 'cotton':
      c.rect(4, 6, 8, 7, I_CREAM); c.stroke(4, 6, 8, 7, I_DARK)
      c.rect(3, 4, 4, 3, I_CREAM); c.rect(9, 4, 4, 3, I_CREAM)
      c.rect(6, 8, 4, 3, I_STONE_L)
      break
    case 'wood':
      c.rect(2, 6, 12, 6, I_WOOD); c.stroke(2, 6, 12, 6, I_DARK)
      c.rect(2, 6, 12, 1, I_WOOD_L)
      c.disc(5, 9, 2, I_WOOD_L)
      break
    case 'firewood':
      for (const [x, y] of [[2, 9], [7, 9], [4, 5], [9, 5]] as const) {
        c.rect(x, y, 5, 4, I_WOOD); c.stroke(x, y, 5, 4, I_DARK)
      }
      c.rect(6, 2, 4, 2, I_RED)
      break
    case 'stone': case 'clay':
      c.rect(3, 6, 10, 7, id === 'stone' ? I_STONE : I_CLAY)
      c.rect(5, 4, 6, 3, id === 'stone' ? I_STONE_L : I_CLAY)
      c.stroke(3, 6, 10, 7, I_DARK)
      break
    case 'meat': case 'dried_meat':
      c.rect(3, 5, 10, 8, I_RED); c.stroke(3, 5, 10, 8, I_DARK)
      c.rect(4, 6, 5, 3, I_RED_D)
      c.rect(10, 9, 3, 3, I_CREAM)
      break
    case 'fish': case 'smoked_fish':
      c.rect(4, 7, 8, 5, id === 'fish' ? I_BLUE : I_CLAY)
      c.rect(2, 6, 2, 7, id === 'fish' ? I_BLUE : I_CLAY)
      c.rect(3, 9, 1, 2, I_CREAM)
      c.stroke(4, 7, 8, 5, I_DARK)
      c.set(10, 8, I_DARK)
      break
    case 'hide':
      c.rect(3, 3, 10, 10, I_CLAY); c.stroke(3, 3, 10, 10, I_DARK)
      c.rect(5, 5, 6, 6, I_WOOD_L)
      break
    case 'sugarcane':
      c.rect(4, 4, 2, 10, I_GREEN); c.rect(9, 3, 2, 11, I_GREEN_D)
      c.rect(3, 6, 4, 1, I_GREEN_D); c.rect(8, 9, 4, 1, I_GREEN)
      break
    case 'dye':
      jug(c, I_PURPLE, I_BLUE)
      break
    case 'sugar':
      c.rect(3, 8, 10, 5, I_CREAM); c.stroke(3, 8, 10, 5, I_DARK)
      c.rect(5, 5, 6, 3, I_CREAM)
      c.rect(7, 3, 3, 2, I_CREAM)
      break
    case 'coarse_cloth': case 'fine_cloth': case 'coarse_clothes':
    case 'common_clothes': case 'luxury_clothes': case 'leather_clothes':
      shirt(c,
        id.includes('luxury') ? I_PURPLE : id === 'leather_clothes' ? I_WOOD : id.includes('fine') ? I_BLUE : I_CREAM,
        id.includes('luxury') ? I_GOLD : I_WOOD_L)
      break
    case 'brick':
      for (const [x, y] of [[2, 8], [7, 8], [4, 4]] as const) {
        c.rect(x, y, 5, 4, I_CLAY); c.stroke(x, y, 5, 4, I_DARK)
      }
      break
    case 'pottery': case 'porcelain':
      jug(c, id === 'pottery' ? I_CLAY : I_CREAM, id === 'pottery' ? I_WOOD_L : I_BLUE)
      break
    case 'coarse_bread': case 'white_bread':
      loaf(c, id === 'white_bread' ? I_CREAM : I_GOLD, I_WOOD)
      break
    case 'pastry':
      loaf(c, I_RED, I_CREAM)
      c.rect(7, 3, 2, 2, I_RED)
      break
    case 'domestic_service':
      c.rect(7, 3, 2, 8, I_WOOD)
      c.rect(5, 11, 6, 3, I_GOLD)
      c.rect(6, 2, 5, 2, I_GOLD_D)
      break
    case 'entertainment':
      c.rect(6, 3, 1, 8, I_DARK)
      c.rect(7, 3, 5, 1, I_DARK)
      c.rect(11, 3, 1, 4, I_DARK)
      c.disc(5, 11, 2, I_PURPLE)
      break
    case 'hut': case 'wooden_house': case 'brick_house':
      c.rect(3, 8, 10, 5, id === 'brick_house' ? I_CLAY : I_WOOD)
      c.rect(2, 5, 12, 3, id === 'hut' ? I_RED_D : I_STONE)
      c.rect(7, 10, 2, 3, I_DARK)
      break
    case 'stone_tools':
      // 石锤：木柄 + 石块锤头（工具坊的产出）
      c.rect(3, 3, 10, 4, I_STONE)
      c.rect(3, 3, 10, 1, I_STONE_L)
      c.rect(7, 7, 2, 8, I_WOOD)
      c.stroke(3, 3, 10, 4, I_DARK)
      c.stroke(7, 7, 2, 8, I_DARK)
      break
    default:
      ingot(c, I_GOLD, I_GOLD_D)
  }
  return c
}

// ---------------------------------------------------------------------------
function main(): void {
  mkdirSync(`${ROOT}/buildings`, { recursive: true })
  mkdirSync(`${ROOT}/thumbs`, { recursive: true })
  mkdirSync(`${ROOT}/actors`, { recursive: true })
  mkdirSync(`${ROOT}/goods`, { recursive: true })
  mkdirSync(`${ROOT}/ui`, { recursive: true })

  const buildings = (JSON.parse(readFileSync('content/buildings.json', 'utf8')) as { buildings: { id: string; art?: Art }[] }).buildings
  const housing = (JSON.parse(readFileSync('content/housing.json', 'utf8')) as { housing: { id: string; art?: Art }[] }).housing

  let n = 0
  const missing: string[] = []
  const spriteMissing: string[] = []
  for (const b of [...buildings, ...housing]) {
    if (!b.art) { missing.push(b.id); continue }

    if (b.art.arch === 'sprite') {
      // v3 成品整图：素材副本已入库，干净检出也能跑
      const srcPath = `${BUILDING_SRC}/${b.id}.png`
      if (!existsSync(srcPath)) { spriteMissing.push(b.id); continue }
      const cv = spriteBuilding(b.id, srcPath)
      writeFileSync(`${ROOT}/buildings/${b.id}.png`, cv.toPng())
      writeFileSync(`${ROOT}/thumbs/${b.id}.png`, thumbOf(cv).toPng())
      n++
      continue
    }

    const cv = renderBuilding(b.art)
    writeFileSync(`${ROOT}/buildings/${b.id}.png`, cv.toPng())
    writeFileSync(`${ROOT}/thumbs/${b.id}.png`, thumbOf(cv).toPng())
    n++
  }
  // 地图上的固定仓库结构。用户要求它和研究所/建筑工坊/家政工坊**一样大**，
  // 所以也按原生 128x62 显示；占地由 game_map 的 warehouse Rect 声明成 8x3，
  // 贴图比占地高 14px，往上伸出去（见 world_view._build_warehouse）。
  {
    const whSrc = `${BUILDING_SRC}/warehouse.png`
    if (existsSync(whSrc)) {
      const wh = spriteBuilding('warehouse', whSrc, 1)
      writeFileSync(`${ROOT}/buildings/_warehouse.png`, wh.toPng())
      writeFileSync(`${ROOT}/thumbs/_warehouse.png`, thumbOf(wh).toPng())
    }
  }

  for (const cls of CLASS_IDS) {
    writeFileSync(`${ROOT}/actors/${cls}.png`, actorSheet(cls).toPng())
  }

  writeFileSync(`${ROOT}/tiny/extra.png`, terrainAtlas().toPng())
  writeFileSync(`${ROOT}/tiny/deco.png`, decoAtlas().toPng())

  const goods = (JSON.parse(readFileSync('content/goods.json', 'utf8')) as { goods: { id: string }[] }).goods
  for (const g of goods) writeFileSync(`${ROOT}/goods/${g.id}.png`, goodIcon(g.id).toPng())

  // 速度控制图标 + 笔刷卡片缩略图
  for (const k of ['pause', '1x', '2x', '4x']) {
    writeFileSync(`${ROOT}/ui/speed_${k}.png`, speedIcon(k).toPng())
  }
  // 左侧导航圆钮（木盘 + 金属卡扣）
  for (const k of ['normal', 'hover', 'pressed']) {
    writeFileSync(`${ROOT}/ui/nav_btn_${k}.png`, navButton(k).toPng())
  }
  // 用工拖动条的把手
  writeFileSync(`${ROOT}/ui/slider_grabber.png`, sliderGrabber().toPng())
  writeFileSync(`${ROOT}/thumbs/_road.png`, brushThumb('road').toPng())
  writeFileSync(`${ROOT}/thumbs/_floor.png`, brushThumb('floor').toPng())

  console.log(`art → ${ROOT}/`)
  console.log(`  建筑 ${n} 座${missing.length ? `（缺 art：${missing.join(', ')}）` : ''}`)
  if (spriteMissing.length) {
    console.log(`  !! 缺成品整图，跳过 ${spriteMissing.length} 座：`)
    console.log(`     ${spriteMissing.join(', ')}`)
    console.log(`     跑 scripts/import-building-sprites.py 从素材包重新导入`)
  }
  console.log(`  商品图标 ${goods.length} 个`)
  console.log(`  速度图标 4 个 + 笔刷缩略图 2 个`)
  console.log(`  角色 ${CLASS_IDS.length} 阶层 x 4 向 x 4 帧`)
  console.log(`  地形图集 extra.png（道路 16 + 水面 32 + 桥 2 + 补丁 2 + 地板 1）`)
  console.log(`  装饰图集 deco.png（树 4 种，16x32）`)
}

main()
