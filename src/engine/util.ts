export function clamp(value: number, min: number, max: number): number {
  return value < min ? min : value > max ? max : value
}

export function round2(value: number): number {
  return Math.round(value * 100) / 100
}

export function sum(values: number[]): number {
  let total = 0
  for (const v of values) total += v
  return total
}
