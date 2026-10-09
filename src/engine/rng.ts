// ---------------------------------------------------------------------------
// 确定性随机数（mulberry32）
//
// 引擎内所有随机行为都走这里，保证「同种子 → 同结果」，便于 100 天复现。
// ---------------------------------------------------------------------------

export interface Rng {
  next(): number
  /** 当前内部状态，可写回 GameState.rngState。 */
  readonly state: number
}

export function createRng(seed: number): Rng {
  let s = seed >>> 0
  return {
    get state() {
      return s
    },
    next() {
      s = (s + 0x6d2b79f5) >>> 0
      let t = s
      t = Math.imul(t ^ (t >>> 15), t | 1)
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61)
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296
    },
  }
}

/** 返回 [0, max) 的整数。 */
export function randInt(rng: Rng, max: number): number {
  return Math.floor(rng.next() * max)
}

/** 以概率 p 返回 true。 */
export function chance(rng: Rng, p: number): boolean {
  return rng.next() < p
}
