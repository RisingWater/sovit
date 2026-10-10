import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'

// ---------------------------------------------------------------------------
// 程序化生成美术（俯视方格）：地形图集 + 建筑/住房精灵 + 仓库。
// 读 content/*.json → 写 godot/assets/*.svg（Godot 原生导入 SVG）。
// 加内容 = 改 JSON + 跑 `npm run gen:art`。
// ---------------------------------------------------------------------------

const TILE = 48

function readJson(p: string): any {
  return JSON.parse(readFileSync(p, 'utf8'))
}

const goods = readJson('content/goods.json')
void goods
const buildingsFile = readJson('content/buildings.json')
const housingFile = readJson('content/housing.json')

// ---- 配色 -----------------------------------------------------------------
const CATEGORY_COLOR: Record<string, string> = {
  raw: '#7f8f4e',
  food: '#d9a441',
  material: '#9a7b4f',
  fuel: '#b06a3a',
  household: '#c98a5a',
  clothing: '#7d6bb0',
  entertainment: '#b0507a',
  service: '#4f9a8a',
  housing: '#c8a06a',
  investment: '#6a8fb0',
  default: '#8a8a8a',
}

const GOOD_BY_ID: Record<string, any> = {}
for (const g of readJson('content/goods.json').goods) GOOD_BY_ID[g.id] = g

function buildingColor(b: any): string {
  // 用产出商品的 category 上色
  const outKeys = Object.keys(b.recipe.output ?? {})
  const first = outKeys[0]
  const def = first !== undefined ? GOOD_BY_ID[first] : undefined
  const cat: string = def ? String(def.category) : 'default'
  return CATEGORY_COLOR[cat] ?? '#8a8a8a'
}

// ---- 地形图集 -------------------------------------------------------------
// 顺序：0 grass 1 forest 2 stone 3 clay 4 water 5 road 6 floor
const tiles: string[] = [
  `<rect width="48" height="48" fill="#6f9e4a"/>
   <circle cx="12" cy="16" r="2" fill="#638f42"/><circle cx="34" cy="30" r="2" fill="#638f42"/>
   <circle cx="22" cy="40" r="1.6" fill="#79a854"/>`,
  `<rect width="48" height="48" fill="#5f8f42"/>
   <circle cx="16" cy="16" r="9" fill="#2f5d24"/><circle cx="33" cy="30" r="11" fill="#356a28"/>
   <circle cx="22" cy="36" r="8" fill="#2f5d24"/>
   <rect x="15" y="20" width="2.5" height="6" fill="#5a3d22"/><rect x="32" y="35" width="3" height="6" fill="#5a3d22"/>`,
  `<rect width="48" height="48" fill="#8d8d8d"/>
   <polygon points="10,34 20,14 30,34" fill="#a8a8a8"/><polygon points="26,36 34,20 44,36" fill="#9a9a9a"/>
   <circle cx="14" cy="14" r="3" fill="#b5b5b5"/>`,
  `<rect width="48" height="48" fill="#a5714a"/>
   <ellipse cx="16" cy="18" rx="9" ry="5" fill="#8f5f3c"/><ellipse cx="34" cy="34" rx="10" ry="6" fill="#b57e52"/>`,
  `<rect width="48" height="48" fill="#4a7ec0"/>
   <path d="M4 16 q10 -6 20 0 t20 0" stroke="#6f9fd8" stroke-width="2" fill="none"/>
   <path d="M4 32 q10 -6 20 0 t20 0" stroke="#6f9fd8" stroke-width="2" fill="none"/>`,
  `<rect width="48" height="48" fill="#b8a070"/>
   <rect x="0" y="20" width="48" height="8" fill="#c8b487" opacity="0.6"/>`,
  `<rect width="48" height="48" fill="#cfc6b0"/>
   <rect x="1" y="1" width="46" height="46" fill="none" stroke="#b8ad92" stroke-width="2"/>`,
]

function tileAtlas(): string {
  const groups = tiles
    .map((t, i) => `<g transform="translate(${i * TILE},0)">${t}</g>`)
    .join('\n')
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${tiles.length * TILE}" height="${TILE}">
${groups}
</svg>`
}

// ---- 建筑精灵 -------------------------------------------------------------
function footprint(b: any): [number, number] {
  if (b.tier === 3) return [3, 3]
  return [2, 2]
}
function housingFootprint(h: any): [number, number] {
  return h.quality >= 3 ? [3, 3] : [2, 2]
}

function buildingSvg(nameZh: string, color: string, fw: number, fh: number): string {
  const w = fw * TILE
  const h = fh * TILE
  const inset = 4
  const roofColor = shade(color, -0.28)
  const wallColor = shade(color, 0.18)
  void nameZh
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">
  <rect x="${inset}" y="${inset}" width="${w - inset * 2}" height="${h - inset * 2}" rx="6" fill="${wallColor}" stroke="${shade(color, -0.4)}" stroke-width="3"/>
  <rect x="${inset + 6}" y="${inset + 6}" width="${w - inset * 2 - 12}" height="${h * 0.42}" rx="5" fill="${roofColor}"/>
  <circle cx="${w / 2}" cy="${h * 0.72}" r="${Math.min(w, h) * 0.12}" fill="${shade(color, -0.15)}"/>
</svg>`
}

function shade(hex: string, amt: number): string {
  const n = parseInt(hex.slice(1), 16)
  let r = (n >> 16) & 255
  let g = (n >> 8) & 255
  let b = n & 255
  const f = (v: number) => Math.max(0, Math.min(255, Math.round(v + 255 * amt)))
  r = f(r); g = f(g); b = f(b)
  return `#${((r << 16) | (g << 8) | b).toString(16).padStart(6, '0')}`
}

function main(): void {
  mkdirSync('godot/assets/buildings', { recursive: true })
  writeFileSync('godot/assets/tiles.svg', tileAtlas())

  for (const b of buildingsFile.buildings) {
    const [fw, fh] = footprint(b)
    writeFileSync(`godot/assets/buildings/${b.id}.svg`, buildingSvg(b.nameZh, buildingColor(b), fw, fh))
  }
  for (const hb of housingFile.housing) {
    const [fw, fh] = housingFootprint(hb)
    writeFileSync(`godot/assets/buildings/${hb.id}.svg`, buildingSvg(hb.nameZh, CATEGORY_COLOR['housing'] ?? '#c8a06a', fw, fh))
  }

  // 中央仓库 4×3
  const w = 4 * TILE
  const h = 3 * TILE
  writeFileSync(
    'godot/assets/warehouse.svg',
    `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}">
  <rect x="4" y="4" width="${w - 8}" height="${h - 8}" rx="6" fill="#9aa3ad" stroke="#5b636c" stroke-width="3"/>
  <rect x="12" y="12" width="${w - 24}" height="${h * 0.4}" rx="5" fill="#6b737c"/>
  <rect x="${w * 0.3}" y="${h * 0.6}" width="${w * 0.4}" height="${h * 0.25}" rx="4" fill="#c8cdd4"/>
</svg>`,
  )

  console.log(`art → godot/assets/（tiles + ${buildingsFile.buildings.length + housingFile.housing.length} 建筑 + 仓库）`)
}

main()
