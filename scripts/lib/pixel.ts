import { deflateSync, inflateSync } from 'node:zlib'
import { readFileSync } from 'node:fs'

// ---------------------------------------------------------------------------
// 无依赖 PNG 编解码 + 简易像素画布
//
// 项目不引入任何运行时依赖，所以自己实现：
//   encodePng  —— RGBA8888 → PNG（IHDR/IDAT/IEND，deflate）
//   decodePng  —— PNG → RGBA8888（支持 colorType 2/6，bitDepth 8）
// 生成的贴图都是像素画，只用「矩形填充 / 单点 / 带 alpha 的图块叠加」三种操作。
// ---------------------------------------------------------------------------

export type RGBA = readonly [number, number, number, number]

const CRC_TABLE = (() => {
  const t = new Uint32Array(256)
  for (let n = 0; n < 256; n++) {
    let c = n
    for (let k = 0; k < 8; k++) c = (c & 1) !== 0 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    t[n] = c >>> 0
  }
  return t
})()

function crc32(buf: Buffer): number {
  let c = 0xffffffff
  for (let i = 0; i < buf.length; i++) c = (CRC_TABLE[(c ^ buf[i]!) & 0xff]! ^ (c >>> 8)) >>> 0
  return (c ^ 0xffffffff) >>> 0
}

function chunk(type: string, data: Buffer): Buffer {
  const len = Buffer.alloc(4)
  len.writeUInt32BE(data.length, 0)
  const t = Buffer.from(type, 'ascii')
  const crc = Buffer.alloc(4)
  crc.writeUInt32BE(crc32(Buffer.concat([t, data])), 0)
  return Buffer.concat([len, t, data, crc])
}

/** RGBA8888 → PNG 字节。 */
export function encodePng(width: number, height: number, rgba: Uint8Array): Buffer {
  const stride = width * 4
  const raw = Buffer.alloc((stride + 1) * height)
  for (let y = 0; y < height; y++) {
    raw[y * (stride + 1)] = 0 // filter: none
    Buffer.from(rgba.buffer, rgba.byteOffset + y * stride, stride).copy(raw, y * (stride + 1) + 1)
  }
  const ihdr = Buffer.alloc(13)
  ihdr.writeUInt32BE(width, 0)
  ihdr.writeUInt32BE(height, 4)
  ihdr[8] = 8 // bit depth
  ihdr[9] = 6 // color type RGBA
  ihdr[10] = 0
  ihdr[11] = 0
  ihdr[12] = 0
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateSync(raw, { level: 9 })),
    chunk('IEND', Buffer.alloc(0)),
  ])
}

/** PNG 字节 → RGBA8888（支持 bitDepth 8 的 colorType 2/3/6）。 */
export function decodePng(buf: Buffer): { width: number; height: number; data: Uint8Array } {
  if (buf.readUInt32BE(0) !== 0x89504e47) throw new Error('不是 PNG')
  let off = 8
  let width = 0
  let height = 0
  let colorType = 6
  let palette: Uint8Array | null = null
  let trns: Uint8Array | null = null
  const idat: Buffer[] = []
  while (off < buf.length) {
    const len = buf.readUInt32BE(off)
    const type = buf.toString('ascii', off + 4, off + 8)
    const data = buf.subarray(off + 8, off + 8 + len)
    if (type === 'IHDR') {
      width = data.readUInt32BE(0)
      height = data.readUInt32BE(4)
      if (data[8] !== 8) throw new Error(`只支持 bitDepth 8，收到 ${data[8]}`)
      colorType = data[9]!
      if (colorType !== 2 && colorType !== 3 && colorType !== 6) {
        throw new Error(`只支持 colorType 2/3/6，收到 ${colorType}`)
      }
    } else if (type === 'PLTE') {
      palette = new Uint8Array(data)
    } else if (type === 'tRNS') {
      trns = new Uint8Array(data)
    } else if (type === 'IDAT') {
      idat.push(Buffer.from(data))
    } else if (type === 'IEND') {
      break
    }
    off += 12 + len
  }
  if (colorType === 3 && !palette) throw new Error('索引色 PNG 缺少 PLTE')
  const bpp = colorType === 6 ? 4 : colorType === 2 ? 3 : 1
  const stride = width * bpp
  const raw = inflateSync(Buffer.concat(idat))
  const out = new Uint8Array(width * height * 4)
  const prev = new Uint8Array(stride)
  const cur = new Uint8Array(stride)
  for (let y = 0; y < height; y++) {
    const ft = raw[y * (stride + 1)]!
    cur.set(raw.subarray(y * (stride + 1) + 1, y * (stride + 1) + 1 + stride))
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? cur[i - bpp]! : 0
      const b = prev[i]!
      const c = i >= bpp ? prev[i - bpp]! : 0
      let v = cur[i]!
      if (ft === 1) v = (v + a) & 0xff
      else if (ft === 2) v = (v + b) & 0xff
      else if (ft === 3) v = (v + ((a + b) >> 1)) & 0xff
      else if (ft === 4) {
        const p = a + b - c
        const pa = Math.abs(p - a)
        const pb = Math.abs(p - b)
        const pc = Math.abs(p - c)
        v = (v + (pa <= pb && pa <= pc ? a : pb <= pc ? b : c)) & 0xff
      }
      cur[i] = v
    }
    for (let x = 0; x < width; x++) {
      const s = x * bpp
      const d = (y * width + x) * 4
      if (colorType === 3) {
        const pi = cur[s]! * 3
        out[d] = palette![pi]!
        out[d + 1] = palette![pi + 1]!
        out[d + 2] = palette![pi + 2]!
        out[d + 3] = trns && cur[s]! < trns.length ? trns[cur[s]!]! : 255
      } else {
        out[d] = cur[s]!
        out[d + 1] = cur[s + 1]!
        out[d + 2] = cur[s + 2]!
        out[d + 3] = bpp === 4 ? cur[s + 3]! : 255
      }
    }
    prev.set(cur)
  }
  return { width, height, data: out }
}

// ---------------------------------------------------------------------------
export class Canvas {
  readonly w: number
  readonly h: number
  readonly data: Uint8Array

  constructor(w: number, h: number, fill: RGBA = [0, 0, 0, 0]) {
    this.w = w
    this.h = h
    this.data = new Uint8Array(w * h * 4)
    if (fill[3] !== 0) this.rect(0, 0, w, h, fill)
  }

  static fromPng(path: string): Canvas {
    const { width, height, data } = decodePng(readFileSync(path))
    const c = new Canvas(width, height)
    c.data.set(data)
    return c
  }

  idx(x: number, y: number): number {
    return (y * this.w + x) * 4
  }

  inside(x: number, y: number): boolean {
    return x >= 0 && y >= 0 && x < this.w && y < this.h
  }

  /** 直接写像素（覆盖，不做 alpha 混合）。 */
  set(x: number, y: number, c: RGBA): void {
    if (!this.inside(x, y)) return
    const i = this.idx(x, y)
    this.data[i] = c[0]
    this.data[i + 1] = c[1]
    this.data[i + 2] = c[2]
    this.data[i + 3] = c[3]
  }

  get(x: number, y: number): RGBA {
    if (!this.inside(x, y)) return [0, 0, 0, 0]
    const i = this.idx(x, y)
    return [this.data[i]!, this.data[i + 1]!, this.data[i + 2]!, this.data[i + 3]!]
  }

  rect(x: number, y: number, w: number, h: number, c: RGBA): void {
    for (let yy = y; yy < y + h; yy++) for (let xx = x; xx < x + w; xx++) this.set(xx, yy, c)
  }

  /** 矩形描边。 */
  stroke(x: number, y: number, w: number, h: number, c: RGBA): void {
    this.rect(x, y, w, 1, c)
    this.rect(x, y + h - 1, w, 1, c)
    this.rect(x, y, 1, h, c)
    this.rect(x + w - 1, y, 1, h, c)
  }

  hline(x0: number, x1: number, y: number, c: RGBA): void {
    this.rect(Math.min(x0, x1), y, Math.abs(x1 - x0) + 1, 1, c)
  }

  vline(x: number, y0: number, y1: number, c: RGBA): void {
    this.rect(x, Math.min(y0, y1), 1, Math.abs(y1 - y0) + 1, c)
  }

  /** 实心圆（像素风，按行取整）。 */
  disc(cx: number, cy: number, r: number, c: RGBA): void {
    for (let y = Math.floor(cy - r); y <= Math.ceil(cy + r); y++) {
      const dy = y - cy
      const dx = Math.sqrt(Math.max(0, r * r - dy * dy))
      this.hline(Math.round(cx - dx), Math.round(cx + dx), y, c)
    }
  }

  ellipse(cx: number, cy: number, rx: number, ry: number, c: RGBA): void {
    for (let y = Math.floor(cy - ry); y <= Math.ceil(cy + ry); y++) {
      const dy = (y - cy) / ry
      if (Math.abs(dy) > 1) continue
      const dx = rx * Math.sqrt(Math.max(0, 1 - dy * dy))
      this.hline(Math.round(cx - dx), Math.round(cx + dx), y, c)
    }
  }

  /** 带 alpha 的图块叠加（source-over）。 */
  blit(src: Canvas, dx: number, dy: number, sx = 0, sy = 0, sw = src.w, sh = src.h): void {
    for (let y = 0; y < sh; y++) {
      for (let x = 0; x < sw; x++) {
        const s = src.idx(sx + x, sy + y)
        const a = src.data[s + 3]!
        if (a === 0) continue
        const tx = dx + x
        const ty = dy + y
        if (!this.inside(tx, ty)) continue
        const d = this.idx(tx, ty)
        if (a === 255) {
          this.data[d] = src.data[s]!
          this.data[d + 1] = src.data[s + 1]!
          this.data[d + 2] = src.data[s + 2]!
          this.data[d + 3] = 255
        } else {
          const t = a / 255
          const u = 1 - t
          this.data[d] = Math.round(src.data[s]! * t + this.data[d]! * u)
          this.data[d + 1] = Math.round(src.data[s + 1]! * t + this.data[d + 1]! * u)
          this.data[d + 2] = Math.round(src.data[s + 2]! * t + this.data[d + 2]! * u)
          this.data[d + 3] = Math.max(this.data[d + 3]!, a)
        }
      }
    }
  }

  /** 把 src 水平镜像后叠加。 */
  blitFlipped(src: Canvas, dx: number, dy: number, sx = 0, sy = 0, sw = src.w, sh = src.h): void {
    const tmp = new Canvas(sw, sh)
    for (let y = 0; y < sh; y++) {
      for (let x = 0; x < sw; x++) tmp.set(sw - 1 - x, y, src.get(sx + x, sy + y))
    }
    this.blit(tmp, dx, dy)
  }

  /** 复制一份。 */
  clone(): Canvas {
    const c = new Canvas(this.w, this.h)
    c.data.set(this.data)
    return c
  }

  toPng(): Buffer {
    return encodePng(this.w, this.h, this.data)
  }
}
