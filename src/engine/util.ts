export function clamp(value: number, min: number, max: number): number {
  return value < min ? min : value > max ? max : value
}

export function round2(value: number): number {
  return Math.round(value * 100) / 100
}

/** 四位小数：小时累计的物料流量用它，避免逐小时四舍五入累积漂移。 */
export function round4(value: number): number {
  return Math.round(value * 10000) / 10000
}

export function sum(values: number[]): number {
  let total = 0
  for (const v of values) total += v
  return total
}
