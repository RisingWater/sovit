import { TIME } from './config.ts'

// ---------------------------------------------------------------------------
// 历法（用户 2026-10：B0 · AE 纪元日期）
//
// 玩家看到的时间从「第 37 天」改成 `AE 312 年 2 月 7 日`：
// 第 1 天 = AE 312 年 1 月 1 日（AE = 帝国纪元 = After Empire）。
//
// 三条口径：
//   1. **纯派生**：`state.day` 一个字节都不动 —— 日历只是"把天数读成人话"，
//      不升存档版本、不影响黄金轨迹。
//   2. **唯一实现**：TS 是这儿，GDScript 是 `sim_core.gd::date_of()`。
//      UI **一个字都不许自己拼**（拼了就会两边长得不一样，历史上吃过这个亏）。
//   3. **日期不驱动剧情**：剧情节奏靠任务与章节间隔（`gapDays`），历法只是显示。
//      所以这一层没有"某月某日该发生什么"的任何判断。
//
// 常量来自 `content/economy.json` 的 `time.calendar`（12 个月 × 30 天 = 360 天/年）。
// ---------------------------------------------------------------------------

/** 游戏内的一天（1 月 1 日 = 第 1 天）。 */
export interface GameDate {
  year: number
  month: number
  day: number
}

/** 第 `day` 天是几月几日（`day` 从 1 起；小于 1 的按第 1 天算）。 */
export function dateOf(day: number): GameDate {
  const cal = TIME.calendar
  const dpm = Math.max(1, Math.floor(cal.daysPerMonth))
  const mpy = Math.max(1, Math.floor(cal.monthsPerYear))
  const zero = Math.max(0, Math.floor(day) - 1)
  return {
    year: Math.floor(cal.epochYear + Math.floor(zero / (dpm * mpy))),
    month: Math.floor(zero / dpm) % mpy + 1,
    day: (zero % dpm) + 1,
  }
}

/** 纪元前缀（`AE`）。全项目只有 `intro.gd` 那一处写中文全称「帝国纪元（AE）」。 */
export function epochPrefix(): string {
  return TIME.calendar.epochPrefix
}

/**
 * `AE 312年4月20日` —— 顶栏、公告、任务面板、存档、预言 tooltip 都用它。
 *
 * ⚠️ 只有 `AE` 与年份之间留一个空格，其余**不空格**（用户 2026-10-20：
 * 顶栏那个框只有 112px 宽，`AE 312 年 4 月 20 日` 会顶出框外）。
 */
export function dateLabel(day: number): string {
  const d = dateOf(day)
  return `${epochPrefix()} ${d.year}年${d.month}月${d.day}日`
}

/** `AE 312年4月20日 13:00` —— 需要连时刻一起说的地方。 */
export function dateTimeLabel(day: number, hour: number): string {
  return `${dateLabel(day)} ${String(Math.max(0, Math.floor(hour))).padStart(2, '0')}:00`
}
