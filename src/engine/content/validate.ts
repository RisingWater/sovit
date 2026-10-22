import type {
  BuildingArt,
  BuildingDef,
  BuildingID,
  BuildingTier,
  CapacityDef,
  CapBand,
  ClassDef,
  ClassID,
  ContentPack,
  FactionDef,
  FactionDefeat,
  FactionFlip,
  FactionID,
  FactionsConfig,
  GoodCategory,
  GoodDef,
  GoodID,
  GoodTier,
  HousingDef,
  NeedDef,
  PackID,
  PackStart,
  QuestChapterDef,
  QuestChoice,
  QuestDef,
  QuestGoal,
  QuestID,
  QuestKind,
  QuestOutro,
  RecipeDef,
  RecipeID,
  RouteCityDef,
  RoutesConfig,
  SceneDef,
  SceneWhen,
  Sector,
  StorageDef,
  TechDef,
  TechEffectKey,
  TechEffects,
  TradeEffects,
  TechID,
} from '../types.ts'
import type { DefaultsConfig, EconomyConfig, TimeConfig, TuningConfig } from '../config.ts'
import type { RawContent } from './load.ts'

// ---------------------------------------------------------------------------
// 内容校验 + 组装
//
// 把 JSON（unknown）逐个字段校验后转成引擎用的强类型表。
// 任何错误都带「字段路径」抛出，方便改 JSON 时定位。
// ---------------------------------------------------------------------------

export interface ParsedContent {
  goods: Record<GoodID, GoodDef>
  goodIds: GoodID[]
  buildings: Record<BuildingID, BuildingDef>
  buildingIds: BuildingID[]
  recipes: Record<RecipeID, RecipeDef>
  recipeByBuilding: Record<string, RecipeDef>
  classes: Record<ClassID, ClassDef>
  classIds: ClassID[]
  housing: Record<GoodID, HousingDef>
  housingIds: GoodID[]
  packs: Record<PackID, ContentPack>
  packIds: PackID[]
  economy: EconomyConfig
  defaults: DefaultsConfig
  tuning: TuningConfig
  time: TimeConfig
  technologies: Record<TechID, TechDef>
  techIds: TechID[]
  eraIds: number[]
  quests: Record<QuestID, QuestDef>
  questIds: QuestID[]
  chapters: QuestChapterDef[]
  scenes: Record<string, SceneDef>
  sceneIds: string[]
  /** 商路（B3）：目的地 + 距离价表 + 商队 / 市场数值，见 `docs/trade-routes.md`。 */
  routes: RoutesConfig
  /** 邦交（B4）：13 个势力 + 好感的档位表，见 `docs/diplomacy.md`。 */
  factions: FactionsConfig
}

const SCHEMA_VERSION = 1
/**
 * 一座建筑最多能开多少工位（`workers` / `maxWorkers` 的上限）。
 *
 * 用户 2026-10 看到采石场/伐木场写着「最多 100 人」当场否掉："太多了，和农田一样，
 * 要就多建造"。产出按 `在岗 / workers` **线性放大且不封顶**，所以这个上限一开大，
 * 玩家就会把整个村子塞进一座采石场 —— 正确玩法应该是"再建一座"。
 */
const MAX_WORKERS_CAP = 12
/**
 * `quests.json` 自己的 schema 版本（用户 2026-10 升到 **3**）。
 *
 * 与 `SCHEMA_VERSION` 分开，是因为两个文件各自演进：economy 还是 1，
 * 而 quests 加了 `giver` / `giverPortrait` / `chapters[].outro` / `building_repaired`（2），
 * 这一版又加了 `kind`（主线 / 支线 / 里程碑）、`chapters[].gapDays`（剧情时钟）与
 * `gifted` 目标（给瑟拉菲娜送物资）（3）。
 * ⚠️ 文档里写的目标版本是 4 —— 差的这一级是 B6 的 `reward` 对象写法（钱 + 商品），
 * 那一级还没落地，所以这里仍是 3（`docs/quests.md` §九 记着这件事）。
 * ⚠️ 版本一升，老存档就不兼容了 —— 那是有意的（`docs/quests.md` §九）。
 */
const QUESTS_SCHEMA_VERSION = 3
/** `scenes.json` 的 schema 版本（用户 2026-10 · A1）。 */
const SCENES_SCHEMA_VERSION = 1
/** `routes.json` 的 schema 版本（用户 2026-10 · B3 商路）。 */
const ROUTES_SCHEMA_VERSION = 1
/** `factions.json` 的 schema 版本（用户 2026-10 · B4 邦交）。 */
const FACTIONS_SCHEMA_VERSION = 1

const CATEGORIES: readonly GoodCategory[] = [
  'raw', 'food', 'clothing', 'household', 'fuel', 'material', 'housing', 'investment', 'service', 'entertainment', 'tool', 'military',
]

function fail(msg: string): never {
  throw new Error(`[content] ${msg}`)
}

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === 'object' && v !== null && !Array.isArray(v)
}

function asObj(v: unknown, p: string): Record<string, unknown> {
  if (!isRecord(v)) fail(`${p} 必须是对象`)
  return v
}

function asArr(v: unknown, p: string): unknown[] {
  if (!Array.isArray(v)) fail(`${p} 必须是数组`)
  return v
}

function asStr(v: unknown, p: string): string {
  if (typeof v !== 'string' || v.length === 0) fail(`${p} 必须是非空字符串`)
  return v
}

function asNum(v: unknown, p: string): number {
  if (typeof v !== 'number' || !Number.isFinite(v)) fail(`${p} 必须是数字`)
  return v
}

function asPos(v: unknown, p: string): number {
  const n = asNum(v, p)
  if (n <= 0) fail(`${p} 必须 > 0`)
  return n
}

function asNonNeg(v: unknown, p: string): number {
  const n = asNum(v, p)
  if (n < 0) fail(`${p} 不能为负`)
  return n
}

function asRate(v: unknown, p: string): number {
  const n = asNum(v, p)
  if (n < 0 || n > 1) fail(`${p} 必须在 0–1`)
  return n
}

function asBool(v: unknown, p: string): boolean {
  if (typeof v !== 'boolean') fail(`${p} 必须是布尔值`)
  return v
}

function asEnum<T extends string>(v: unknown, allowed: readonly T[], p: string): T {
  const s = asStr(v, p)
  if (!(allowed as readonly string[]).includes(s)) {
    fail(`${p} 取值非法：${s}（允许：${allowed.join(' / ')}）`)
  }
  return s as T
}

function asNumEnum<T extends number>(v: unknown, allowed: readonly T[], p: string): T {
  const n = asNum(v, p)
  if (!(allowed as readonly number[]).includes(n)) {
    fail(`${p} 取值非法：${n}（允许：${allowed.join(' / ')}）`)
  }
  return n as T
}

// ---------------------------------------------------------------------------
// 产业（sector）与效率科技加成（effects）
//
// 契约（与 GDScript `sim_core.gd::tech_bonuses()` / `_sector_output_boost()` 同口径）：
//   - sector 只有三个值，且**只属于有 recipe 的建筑**（无配方建筑不产商品）
//   - effects 的键只有那 6 个，值是**加成小数**（0.10 = +10%），必须 > 0 且有限
// ---------------------------------------------------------------------------

const SECTORS = ['agri', 'goods', 'material'] as const
/**
 * 效率科技允许的加成键（一处定义，引擎与 UI 共用）。
 *
 * `services` = 治安 / 医疗 / 教育这三样**公共服务商品的产出**加成 ——
 * 用户 2026-10："增加（治安、教育、医疗）的科技（三个一起加）"。
 * 它们没有独立 sector（那几座建筑的 sector 都是 goods），所以只能按"产出哪个商品"认。
 */
const TECH_EFFECT_KEYS: readonly TechEffectKey[] = [
  'agri',
  'goods',
  'material',
  'research',
  'build',
  'toolLife',
  'services',
]

function asSector(v: unknown, p: string): Sector {
  return asEnum(v, SECTORS, p)
}

/**
 * 效率科技的加成表。
 *
 * 为什么值必须 **> 0**：`techBonuses()` 只做加法，0（或负数）在面板上等于
 * 「研究了一项什么都没发生的科技」——那是内容写错了，不是合法的"无加成"
 * （无加成请直接省略 `effects`，或省略那个键）。
 */
function parseTechEffects(v: unknown, p: string): TechEffects {
  const o = asObj(v, p)
  const keys = Object.keys(o)
  if (keys.length === 0) fail(`${p} 不能为空对象（没有加成请省略 effects）`)
  const out: TechEffects = {}
  for (const k of keys) {
    if (!(TECH_EFFECT_KEYS as readonly string[]).includes(k)) {
      fail(`${p}.${k} 不是合法的加成键（允许：${TECH_EFFECT_KEYS.join(' / ')}）`)
    }
    const n = asPos(o[k], `${p}.${k}`)
    out[k as TechEffectKey] = n
  }
  return out
}

/**
 * 贸易科技的效果（B3）。量纲各自不同，所以单独校验：
 * `caravans` / `haggleBuy` / `haggleSell` 是加法，`cargo` / `purse` 是**取最高**的绝对值。
 */
function parseTradeEffects(v: unknown, p: string): TradeEffects {
  const o = asObj(v, p)
  const keys = Object.keys(o)
  if (keys.length === 0) fail(`${p} 不能为空对象（没有加成请省略 trade）`)
  const out: TradeEffects = {}
  for (const k of keys) {
    switch (k) {
      case 'caravans':
        out.caravans = asNonNeg(o[k], `${p}.caravans`)
        break
      case 'cargo':
        out.cargo = asPos(o[k], `${p}.cargo`)
        break
      case 'purse':
        out.purse = asNonNeg(o[k], `${p}.purse`)
        break
      case 'haggleBuy':
      case 'haggleSell': {
        const n = asNonNeg(o[k], `${p}.${k}`)
        if (n > 0.9) fail(`${p}.${k} 太大（${n}）：最多 0.9）`)
        out[k] = n
        break
      }
      // 商路好感加成（B4）：三级 0.5 / 0.5 / 1.0，**加法累计 +200%**
      // → 一趟 100 / 150 / 200 / 300 好感（见 docs/diplomacy.md §3.3）
      case 'goodwill': {
        const n = asNonNeg(o[k], `${p}.goodwill`)
        if (n > 2.0) fail(`${p}.goodwill 太大（${n}）：三级累计最多 2.0）`)
        out.goodwill = n
        break
      }
      default:
        fail(`${p}.${k} 不是合法的贸易加成键（允许：caravans / cargo / purse / haggleBuy / haggleSell）`)
    }
  }
  return out
}

/** 商品数量表（inputs / output / buildCost）。 */
function numMap(v: unknown, p: string, goodSet: Set<string>): Record<string, number> {
  if (v === undefined) return {}
  const o = asObj(v, p)
  const out: Record<string, number> = {}
  for (const [k, val] of Object.entries(o)) {
    if (!goodSet.has(k)) fail(`${p}.${k} 引用了未定义的商品`)
    out[k] = asNonNeg(val, `${p}.${k}`)
  }
  return out
}

function strArr(v: unknown, p: string, set?: Set<string>): string[] {
  return asArr(v, p).map((x, i) => {
    const s = asStr(x, `${p}[${i}]`)
    if (set && !set.has(s)) fail(`${p}[${i}] 引用了未定义的内容：${s}`)
    return s
  })
}

/** 字符串数组；缺省视为空数组（requires / unlocks 允许省略）。 */
function strList(v: unknown, p: string): string[] {
  return v === undefined ? [] : strArr(v, p)
}

// ---------------------------------------------------------------------------
// 外观规格
// ---------------------------------------------------------------------------

const ART_ARCHS = ['house', 'extract', 'mill', 'bakery', 'kiln', 'workshop', 'grand', 'warehouse', 'field', 'sprite'] as const
const ART_ROOFS = ['blue', 'red', 'green'] as const
const ART_WALLS = ['wood', 'stone', 'barn', 'plank'] as const
const ART_FEATS = ['windmill', 'wheel', 'logs', 'rocks'] as const
const ART_CROPS = ['wheat', 'cabbage', 'sprout', 'bush', 'corn', 'tomato'] as const
const ART_SOILS = ['row5', 'row6'] as const

/**
 * `art.doors` 是**表现层**的字段（门洞画在哪一格 / 从哪一格进屋），仿真层不读它。
 *
 * 为什么类型写在这里而不是 `src/engine/types.ts`：那样要动引擎类型文件，
 * 而这次改动限定在内容校验 + Godot 表现层。运行时对象上带着这个键就够了，
 * 返回时按 `BuildingArt` 向上转型。
 */
type ArtWithDoors = BuildingArt & { doors?: [number, number][] }

/**
 * 推导一栋建筑的**占地**（格），口径与
 * `godot/scripts/world/world_view.gd::_footprint()` 一致（不一致 = 引擎占的地
 * 和玩家看到的地错开）：
 *   - `arch='sprite'`：只认 `foot`。没声明时占地由**贴图尺寸**算，而校验器读不到
 *     PNG，只好返回 undefined —— 调用方据此判断"这个偏移能不能校验"。
 *   - `arch='field'` / 带 `rows`：`w × rows`
 *   - 其余：`w × (屋顶行数 + 1 行墙)`，绿顶（谷仓）只占 1 行屋顶
 */
function artFootprint(art: ArtWithDoors): [number, number] | undefined {
  if (art.arch === 'sprite') return art.foot
  const w = art.w ?? 3
  if (art.arch === 'field' || art.rows !== undefined) return [w, art.rows ?? 1]
  return [w, (art.roof === 'green' ? 1 : 2) + 1]
}

function parseArt(v: unknown, p: string): BuildingArt | undefined {
  if (v === undefined) return undefined
  const o = asObj(v, p)
  const arch = asEnum(o.arch, ART_ARCHS, `${p}.arch`)
  const art: ArtWithDoors = { arch }

  if (o.roof !== undefined) art.roof = asEnum(o.roof, ART_ROOFS, `${p}.roof`)
  if (o.wall !== undefined) art.wall = asEnum(o.wall, ART_WALLS, `${p}.wall`)
  if (o.w !== undefined) {
    const w = asNum(o.w, `${p}.w`)
    if (!Number.isInteger(w) || w < 2 || w > 12) fail(`${p}.w 必须是 2–12 的整数`)
    art.w = w
  }
  if (o.rows !== undefined) {
    const r = asNum(o.rows, `${p}.rows`)
    if (!Number.isInteger(r) || r < 1 || r > 12) fail(`${p}.rows 必须是 1–12 的整数`)
    art.rows = r
  }
  if (o.foot !== undefined) {
    const f = asArr(o.foot, `${p}.foot`)
    if (f.length !== 2) fail(`${p}.foot 必须是 [宽, 高] 两个数`)
    const fw = asNum(f[0], `${p}.foot[0]`)
    const fh = asNum(f[1], `${p}.foot[1]`)
    if (!Number.isInteger(fw) || fw < 2 || fw > 12) fail(`${p}.foot[0] 必须是 2–12 的整数`)
    if (!Number.isInteger(fh) || fh < 1 || fh > 12) fail(`${p}.foot[1] 必须是 1–12 的整数`)
    art.foot = [fw, fh]
  }
  if (o.chimney !== undefined) art.chimney = asBool(o.chimney, `${p}.chimney`)
  if (o.feat !== undefined) {
    art.feat = asArr(o.feat, `${p}.feat`).map((x, i) => asEnum(x, ART_FEATS, `${p}.feat[${i}]`))
  }
  if (o.soil !== undefined) art.soil = asEnum(o.soil, ART_SOILS, `${p}.soil`)
  if (o.crop !== undefined) art.crop = asEnum(o.crop, ART_CROPS, `${p}.crop`)
  if (o.sprite !== undefined) {
    const s = asStr(o.sprite, `${p}.sprite`)
    if (!/^[a-z0-9_]+$/.test(s)) fail(`${p}.sprite 只能用小写字母/数字/下划线：${s}`)
    art.sprite = s
  }

  // 门洞（表现层字段，见 content/README.md「art.doors」）。
  //
  // 语义：一串 `[dx, dy]`，相对**占地左上角**的格偏移；**第一项是主门**
  // （居民实际从这一格进屋，屋内落脚格由它推出来）。所有门格 + 每扇门**正下方**
  // 那一格（门前通行格）都会被 `map.reserved` 永久占住 —— 否则门会被别的建筑堵死。
  // 缺省（不写）= 占地底边横向居中那一格，见 world_view.gd::_default_door_offset()。
  //
  // 为什么 `arch='sprite'` 必须同时写 `foot`：占地缺省按贴图尺寸算，校验器读不到
  // PNG，就没法判断偏移有没有越界 —— 与其放行一个可能越界的门，不如要求写清楚。
  if (o.doors !== undefined) {
    const list = asArr(o.doors, `${p}.doors`)
    if (list.length === 0) fail(`${p}.doors 不能是空数组（不要门洞就整条省掉）`)
    const fp = artFootprint(art)
    if (fp === undefined) {
      fail(`${p}.doors 必须同时声明 art.foot：arch=sprite 的占地缺省按贴图尺寸算，校验器读不到贴图，无法确认偏移越界`)
    }
    const [fw, fh] = fp
    const seen = new Set<string>()
    art.doors = list.map((d, i) => {
      const dp = `${p}.doors[${i}]`
      const pair = asArr(d, dp)
      if (pair.length !== 2) fail(`${dp} 必须是 [dx, dy] 两个整数`)
      const nums = pair.map((n, k) => {
        if (typeof n !== 'number' || !Number.isInteger(n)) {
          fail(`${dp}[${k}] 必须是整数格偏移`)
        }
        return n as number
      })
      const [dx, dy] = nums as [number, number]
      if (dx < 0 || dy < 0 || dx >= fw || dy >= fh) {
        fail(`${dp} = [${dx}, ${dy}] 超出占地 ${fw}×${fh}（偏移必须落在 0..${fw - 1} / 0..${fh - 1}）`)
      }
      if (seen.has(`${dx},${dy}`)) fail(`${dp} = [${dx}, ${dy}] 与前面的门格重复`)
      seen.add(`${dx},${dy}`)
      return [dx, dy] as [number, number]
    })
  }

  if (arch === 'field') {
    if (!art.soil) fail(`${p}：arch=field 必须给 soil`)
    if (!art.crop) fail(`${p}：arch=field 必须给 crop`)
    if (art.roof || art.wall) fail(`${p}：arch=field 不应给 roof / wall`)
  } else if (arch === 'sprite') {
    // 成品整图：文件名就是建筑 id（godot/assets/building_src/<id>.png），所以**不需要**
    // sprite 字段。占地缺省按贴图尺寸算；要让贴图比占地高（往上伸长、和身后的建筑
    // 互相遮挡），用 foot 显式声明，而不是走 w/rows —— 那两个是程序化拼装的字段。
    if (art.w) fail(`${p}：arch=sprite 请不要用 w，占地要单独声明就用 foot`)
    if (art.rows) fail(`${p}：arch=sprite 请不要用 rows，占地要单独声明就用 foot`)
    if (art.roof || art.wall || art.soil || art.crop) {
      fail(`${p}：arch=sprite 不应给 roof / wall / soil / crop`)
    }
  } else {
    if (!art.roof) fail(`${p}：arch=${arch} 必须给 roof`)
    if (!art.wall) fail(`${p}：arch=${arch} 必须给 wall`)
    if (art.soil || art.crop) fail(`${p}：arch=${arch} 不应给 soil / crop`)
  }
  return art
}

// ---------------------------------------------------------------------------

function parseGoods(raw: unknown): { goods: Record<GoodID, GoodDef>; ids: GoodID[] } {
  const list = asArr(asObj(raw, 'goods.json').goods, 'goods.json.goods')
  const goods: Record<GoodID, GoodDef> = {}
  const ids: GoodID[] = []
  list.forEach((item, i) => {
    const p = `goods[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`)
    if (goods[id]) fail(`${p}.id 重复：${id}`)
    const perishRate = o.perishRate === undefined ? undefined : asNonNeg(o.perishRate, `${p}.perishRate`)
    if (perishRate !== undefined && perishRate > 1) fail(`${p}.perishRate 必须在 0–1`)
    const category = asEnum(o.category, CATEGORIES, `${p}.category`)
    // 工具品级：只有 category='tool' 才能带；tool 商品必须带（否则装了工具也没效果）
    const toolBonus = o.toolBonus === undefined ? undefined : asPos(o.toolBonus, `${p}.toolBonus`)
    if (category === 'tool' && toolBonus === undefined) {
      fail(`${p}（${id}）category=tool 必须给 toolBonus（产出加成，见 docs/technology.md §八）`)
    }
    if (category !== 'tool' && toolBonus !== undefined) {
      fail(`${p}（${id}）非 tool 商品不能有 toolBonus`)
    }
    // 工具**耐久**（2026-10）：每件能用几天（消耗率 = 1 / 有效天数）。
    // 只有 tool 能带；没写就退回 `economy.tools.perWorkstation`（老内容兼容）。
    const durabilityDays = o.durabilityDays === undefined ? undefined : asPos(o.durabilityDays, `${p}.durabilityDays`)
    if (category !== 'tool' && durabilityDays !== undefined) {
      fail(`${p}（${id}）非 tool 商品不能有 durabilityDays`)
    }
    goods[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      tier: asNumEnum(o.tier, [0, 1, 2, 3], `${p}.tier`) as GoodTier,
      category,
      storable: asBool(o.storable, `${p}.storable`),
      baseValue: asNonNeg(o.baseValue, `${p}.baseValue`),
      luxury: o.luxury === undefined ? false : asBool(o.luxury, `${p}.luxury`),
      ...(perishRate !== undefined ? { perishRate } : {}),
      ...(toolBonus !== undefined ? { toolBonus } : {}),
      ...(durabilityDays !== undefined ? { durabilityDays } : {}),
    }
    ids.push(id)
  })
  return { goods, ids }
}

function parseBuildings(
  raw: unknown,
  goodSet: Set<string>,
): {
  buildings: Record<BuildingID, BuildingDef>
  ids: BuildingID[]
  recipes: Record<RecipeID, RecipeDef>
  recipeByBuilding: Record<string, RecipeDef>
} {
  const list = asArr(asObj(raw, 'buildings.json').buildings, 'buildings.json.buildings')
  const buildings: Record<BuildingID, BuildingDef> = {}
  const ids: BuildingID[] = []
  const recipes: Record<RecipeID, RecipeDef> = {}
  const recipeByBuilding: Record<string, RecipeDef> = {}

  list.forEach((item, i) => {
    const p = `buildings[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`)
    if (buildings[id]) fail(`${p}.id 重复：${id}`)

    // workers 允许为 0：城镇中心这种"被动"建筑不需要工人（只提供仓储/信息）。
    const workers = asNonNeg(o.workers, `${p}.workers`)
    const maxWorkers = o.maxWorkers === undefined ? undefined : asNonNeg(o.maxWorkers, `${p}.maxWorkers`)
    if (maxWorkers !== undefined && maxWorkers < workers) {
      fail(`${p}.maxWorkers（${maxWorkers}）不能小于 workers（${workers}）`)
    }
    // ⚠️ 一座建筑**吸走几十上百个人**是不对的（用户 2026-10 看到采石场写「最多 100 人」
    // 当场报的："太多了，和农田一样，要就多建造"）。产出与在岗人数成正比
    // （`staffing = 在岗 / workers`，**不封顶**），所以上限一开大，玩家就会把一整个村
    // 塞进一座采石场，而不是多建一座。这里把上限钉在 12（够 3 级研究所 + 升级工位）。
    if (maxWorkers !== undefined && maxWorkers > MAX_WORKERS_CAP) {
      fail(`${p}.maxWorkers = ${maxWorkers} 超过了上限 ${MAX_WORKERS_CAP}`
        + '（一座建筑不该吸走这么多人；要更多产出请多建一座，见 docs/spec.md §7.4）')
    }
    if (workers > MAX_WORKERS_CAP) {
      fail(`${p}.workers = ${workers} 超过了上限 ${MAX_WORKERS_CAP}（同上，多建一座）`)
    }

    // 配方可选：产商品的建筑必须有配方；「建筑工坊」这类产出*建造产能*而非商品的
    // 建筑没有配方（其产出由 docs/construction.md 的产能公式给出）。
    let recipeId: RecipeID | undefined
    if (o.recipe !== undefined) {
      const r = asObj(o.recipe, `${p}.recipe`)
      const output = numMap(r.output, `${p}.recipe.output`, goodSet)
      if (Object.keys(output).length === 0) fail(`${p}.recipe.output 不能为空`)
      const fuel = r.fuel === undefined ? undefined : asNonNeg(r.fuel, `${p}.recipe.fuel`)
      const recipe: RecipeDef = {
        id: `r_${id}`,
        building: id,
        inputs: numMap(r.inputs, `${p}.recipe.inputs`, goodSet),
        output,
        baseRate: asPos(r.baseRate, `${p}.recipe.baseRate`),
        ...(fuel !== undefined ? { fuel } : {}),
      }
      if (recipes[recipe.id]) fail(`${p}.recipe 与其它建筑 id 冲突：${recipe.id}`)
      recipes[recipe.id] = recipe
      recipeByBuilding[id] = recipe
      recipeId = recipe.id
    }

    // 产业：只有**有 recipe** 的建筑才谈得上"产出"。
    // 无配方建筑（研究所 / 建筑工坊 / 仓库 / 城镇中心）给 sector 是内容写错了 →
    // 直接报错（而不是只警告）：它永远不会被 `_sector_output_boost()` 读到，
    // 留着只会让改内容的人以为"我给它配了加成"。
    let sector: Sector | undefined
    if (o.sector !== undefined) {
      sector = asSector(o.sector, `${p}.sector`)
      if (recipeId === undefined) {
        fail(`${p}（${id}）没有 recipe 却给了 sector：产业只属于产商品的建筑`)
      }
    } else if (recipeId !== undefined) {
      fail(`${p}（${id}）有 recipe 就必须给 sector（agri / goods / material）`)
    }

    const buildCost = numMap(o.buildCost, `${p}.buildCost`, goodSet)
    const art = parseArt(o.art, `${p}.art`)
    // 施工工时（人·天）。设计见 docs/construction.md。
    const buildWork = o.buildWork === undefined ? undefined : asPos(o.buildWork, `${p}.buildWork`)
    if (buildWork === undefined) fail(`${p}.buildWork 缺失（施工工时，见 docs/construction.md）`)

    // 产能建筑：不产商品、只产每日产能（建筑工坊 / 研究所）。有 recipe 就不该有 capacity，反之亦然。
    let capacity: CapacityDef | undefined
    if (o.capacity !== undefined) {
      const c = asObj(o.capacity, `${p}.capacity`)
      const kind = asEnum(c.kind, ['build', 'research'] as const, `${p}.capacity.kind`)
      if (recipeId !== undefined) {
        fail(`${p} 同时有 recipe 和 capacity：产商品的建筑不该再产产能`)
      }
      capacity = {
        kind,
        perWorker: asPos(c.perWorker, `${p}.capacity.perWorker`),
        levelBonus: asNonNeg(c.levelBonus, `${p}.capacity.levelBonus`),
        slotsPerLevel: asNonNeg(c.slotsPerLevel, `${p}.capacity.slotsPerLevel`),
      }
    }
    // 仓储建筑（城镇中心 / 仓库）：既不产商品也不产产能，只提供仓储容量。
    let storage: StorageDef | undefined
    if (o.storage !== undefined) {
      const s = asObj(o.storage, `${p}.storage`)
      storage = {
        storage: asPos(s.storage, `${p}.storage.storage`),
        storagePerLevel: asNonNeg(s.storagePerLevel ?? 0, `${p}.storage.storagePerLevel`),
      }
    }
    // 纯功能建筑（B4 的使馆）：不产商品、不产产能、也不加仓储 —— 它的"产出"是
    // **解锁一个面板**（`tech.unlocks.buildings` + 面板入口）。必须显式写 `"utility": true`，
    // 不放宽成"三者都没有就放行"：那样"忘了写 recipe"会悄悄变成一座没用的房子。
    const utility = o.utility === undefined ? false : asBool(o.utility, `${p}.utility`)
    if (recipeId === undefined && capacity === undefined && storage === undefined && !utility) {
      fail(`${p} 既没有 recipe、也没有 capacity / storage：建筑总得产出点什么（纯功能建筑请写 "utility": true）`)
    }

    buildings[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      tier: asNumEnum(o.tier, [1, 2, 3], `${p}.tier`) as BuildingTier,
      workers,
      ...(maxWorkers !== undefined ? { maxWorkers } : {}),
      ...(recipeId !== undefined ? { recipe: recipeId } : {}),
      ...(sector !== undefined ? { sector } : {}),
      ...(capacity !== undefined ? { capacity } : {}),
      ...(storage !== undefined ? { storage } : {}),
      ...(utility ? { utility: true } : {}),
      buildWork,
      ...(Object.keys(buildCost).length > 0 ? { buildCost } : {}),
      ...(art !== undefined ? { art } : {}),
    }
    ids.push(id)
  })

  return { buildings, ids, recipes, recipeByBuilding }
}

function parseClasses(
  raw: unknown,
  goodSet: Set<string>,
): { classes: Record<ClassID, ClassDef>; ids: ClassID[] } {
  const list = asArr(asObj(raw, 'classes.json').classes, 'classes.json.classes')
  const classes = {} as Record<ClassID, ClassDef>
  const ids: ClassID[] = []

  list.forEach((item, i) => {
    const p = `classes[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`) as ClassID
    if (classes[id]) fail(`${p}.id 重复：${id}`)

    const needs: NeedDef[] = asArr(o.needs, `${p}.needs`).map((n, j) => {
      const np = `${p}.needs[${j}]`
      const no = asObj(n, np)
      const good = asStr(no.good, `${np}.good`)
      if (!goodSet.has(good)) fail(`${np}.good 引用了未定义的商品：${good}`)
      const fallbacks = no.fallbacks === undefined ? undefined : strArr(no.fallbacks, `${np}.fallbacks`, goodSet)
      return {
        good,
        perCapita: asPos(no.perCapita, `${np}.perCapita`),
        ...(fallbacks ? { fallbacks } : {}),
      }
    })

    classes[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      incomeBase: asNonNeg(o.incomeBase, `${p}.incomeBase`),
      satBonus: asNum(o.satBonus, `${p}.satBonus`),
      housingLevel: asNumEnum(o.housingLevel, [1, 2, 3], `${p}.housingLevel`),
      wealthThreshold: asNonNeg(o.wealthThreshold, `${p}.wealthThreshold`),
      needs,
    }
    ids.push(id)
  })

  return { classes, ids }
}

function parseHousing(
  raw: unknown,
  classSet: Set<string>,
  goodSet: Set<string>,
): { housing: Record<GoodID, HousingDef>; ids: GoodID[] } {
  const list = asArr(asObj(raw, 'housing.json').housing, 'housing.json.housing')
  const housing: Record<GoodID, HousingDef> = {}
  const ids: GoodID[] = []
  /** id → upgradeTo 的原始值；**全部读完再校验**（文件里的先后顺序不保证）。 */
  const upgradeToOf: Record<string, string> = {}

  list.forEach((item, i) => {
    const p = `housing[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`)
    if (housing[id]) fail(`${p}.id 重复：${id}`)
    const classId = asStr(o.classId, `${p}.classId`) as ClassID
    if (!classSet.has(classId)) fail(`${p}.classId 引用了未定义的阶层：${classId}`)
    const buildCost = numMap(o.buildCost, `${p}.buildCost`, goodSet)
    const salePrice = o.salePrice === undefined ? undefined : asNonNeg(o.salePrice, `${p}.salePrice`)
    const art = parseArt(o.art, `${p}.art`)
    const buildWork = o.buildWork === undefined ? undefined : asPos(o.buildWork, `${p}.buildWork`)
    if (buildWork === undefined) fail(`${p}.buildWork 缺失（施工工时，见 docs/construction.md）`)
    housing[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      quality: asNumEnum(o.quality, [1, 2, 3], `${p}.quality`),
      capacity: asPos(o.capacity, `${p}.capacity`),
      classId,
      buildWork,
      ...(Object.keys(buildCost).length > 0 ? { buildCost } : {}),
      ...(salePrice !== undefined ? { salePrice } : {}),
      ...(art !== undefined ? { art } : {}),
    }
    if (o.upgradeTo !== undefined) upgradeToOf[id] = asStr(o.upgradeTo, `${p}.upgradeTo`)
    ids.push(id)
  })

  // 改建链（见 docs/spec.md §5.4）：目标必须存在、不能自指、不能成环。
  // ⚠️ 必须**全部房间读完再校验**：housing.json 里谁在前谁在后不保证。
  for (const [id, target] of Object.entries(upgradeToOf)) {
    if (!housing[target]) {
      fail(`housing[${id}].upgradeTo 引用了未定义的住房：${target}`)
      continue
    }
    if (target === id) fail(`housing[${id}].upgradeTo 指向了自己`)
    const seen = new Set<string>([id])
    let cur: string | undefined = target
    while (cur !== undefined) {
      if (seen.has(cur)) {
        fail(`housing[${id}].upgradeTo 成环：${[...seen, cur].join(' → ')}`)
        break
      }
      seen.add(cur)
      cur = upgradeToOf[cur]
    }
  }
  for (const [id, target] of Object.entries(upgradeToOf)) {
    if (housing[id] && housing[target]) housing[id]!.upgradeTo = target
  }

  return { housing, ids }
}

function parseStart(
  raw: unknown,
  p: string,
  goodSet: Set<string>,
  buildingSet: Set<string>,
  housingSet: Set<string>,
  techSet: Set<string>,
): PackStart {
  const s = asObj(raw, p)
  const techs = s.techs === undefined ? [] : strArr(s.techs, `${p}.techs`, techSet)
  return {
    population: asNonNeg(s.population, `${p}.population`),
    money: asNonNeg(s.money, `${p}.money`),
    shops: numMap(s.shops, `${p}.shops`, buildingSet),
    housing: numMap(s.housing, `${p}.housing`, housingSet),
    goods: numMap(s.goods, `${p}.goods`, goodSet),
    techs,
  }
}

function parsePacks(
  raw: unknown,
  goodSet: Set<string>,
  buildingSet: Set<string>,
  classSet: Set<string>,
  housingSet: Set<string>,
  techSet: Set<string>,
): { packs: Record<PackID, ContentPack>; ids: PackID[] } {
  const list = asArr(asObj(raw, 'packs.json').packs, 'packs.json.packs')
  const packs = {} as Record<PackID, ContentPack>
  const ids: PackID[] = []

  list.forEach((item, i) => {
    const p = `packs[${i}]`
    const o = asObj(item, p)
    const id = asStr(o.id, `${p}.id`) as PackID
    if (packs[id]) fail(`${p}.id 重复：${id}`)
    packs[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      goods: strArr(o.goods, `${p}.goods`, goodSet),
      buildings: strArr(o.buildings, `${p}.buildings`, buildingSet),
      classes: strArr(o.classes, `${p}.classes`, classSet) as ClassID[],
      housing: strArr(o.housing, `${p}.housing`, housingSet),
      start: parseStart(o.start, `${p}.start`, goodSet, buildingSet, housingSet, techSet),
    }
    ids.push(id)
  })

  return { packs, ids }
}

function parsePerson(o: Record<string, unknown>, p: string): DefaultsConfig['newResident'] {
  return {
    savings: asNonNeg(o.savings, `${p}.savings`),
    satisfaction: asNonNeg(o.satisfaction, `${p}.satisfaction`),
    skillBase: asNonNeg(o.skillBase, `${p}.skillBase`),
    skillRandom: asNonNeg(o.skillRandom, `${p}.skillRandom`),
  }
}

function parseEconomy(
  raw: unknown,
  goodSet: Set<string>,
  classSet: Set<string>,
): { economy: EconomyConfig; defaults: DefaultsConfig; tuning: TuningConfig; time: TimeConfig } {
  const root = asObj(raw, 'economy.json')
  const sv = asNonNeg(root.schemaVersion, 'economy.json.schemaVersion')
  if (sv !== SCHEMA_VERSION) {
    fail(`content schemaVersion = ${sv}，本引擎只支持 ${SCHEMA_VERSION}`)
  }
  const e = asObj(root.economy, 'economy.json.economy')
  const d = asObj(root.defaults, 'economy.json.defaults')
  const t = asObj(root.tuning, 'economy.json.tuning')
  const tc = asObj(root.time, 'economy.json.time')

  const hoursPerDay = asPos(tc.hoursPerDay, 'time.hoursPerDay')
  const dawnHour = asNum(tc.dawnHour, 'time.dawnHour')
  const workStart = asNum(tc.workStart, 'time.workStart')
  const workEnd = asNum(tc.workEnd, 'time.workEnd')
  const settleHour = asNum(tc.settleHour, 'time.settleHour')
  for (const [k, v] of Object.entries({ dawnHour, workStart, workEnd, settleHour })) {
    if (!Number.isInteger(v) || v < 0 || v >= hoursPerDay) {
      fail(`time.${k} 必须是 [0,${hoursPerDay}) 内的整数`)
    }
  }
  if (workEnd <= workStart) fail('time.workEnd 必须大于 workStart')
  // 历法（用户 2026-10 · B0）：纯显示用，第 1 天 = AE 312 年 1 月 1 日。
  const cal = asObj(tc.calendar, 'time.calendar')
  const time: TimeConfig = {
    hoursPerDay,
    dawnHour,
    workStart,
    workEnd,
    settleHour,
    tickSec: asPos(tc.tickSec, 'time.tickSec'),
    calendar: {
      epochPrefix: asStr(cal.epochPrefix, 'time.calendar.epochPrefix'),
      epochYear: asPos(cal.epochYear, 'time.calendar.epochYear'),
      daysPerMonth: asPos(cal.daysPerMonth, 'time.calendar.daysPerMonth'),
      monthsPerYear: asPos(cal.monthsPerYear, 'time.calendar.monthsPerYear'),
    },
  }

  const weights = asObj(e.weights, 'economy.weights')
  const bmt = asObj(e.buildMoneyByTier, 'economy.buildMoneyByTier')
  const maxSlots =
    e.maxBuildingSlots === null || e.maxBuildingSlots === undefined
      ? Infinity
      : asNonNeg(e.maxBuildingSlots, 'economy.maxBuildingSlots')
  const c = asObj(e.construction, 'economy.construction')
  const rc = asObj(e.research, 'economy.research')
  const toolsCfg = asObj(e.tools, 'economy.tools')

  const economy: EconomyConfig = {
    refWage: asNonNeg(e.refWage, 'economy.refWage'),
    publicServiceWage: asNonNeg(e.publicServiceWage, 'economy.publicServiceWage'),
    defaultTaxBrackets: asArr(e.defaultTaxBrackets, 'economy.defaultTaxBrackets').map((b, i) => {
      const bp = `economy.defaultTaxBrackets[${i}]`
      const bo = asObj(b, bp)
      const upTo = bo.upTo === null || bo.upTo === undefined ? null : asNonNeg(bo.upTo, `${bp}.upTo`)
      const rate = asNum(bo.rate, `${bp}.rate`)
      if (rate < 0 || rate > 0.95) fail(`${bp}.rate 必须在 0–0.95`)
      return { upTo, rate }
    }),
    priceElasticity: asNonNeg(e.priceElasticity, 'economy.priceElasticity'),
    luxuryElasticity: asNonNeg(e.luxuryElasticity, 'economy.luxuryElasticity'),
    luxuryPriceMarkup: asNonNeg(e.luxuryPriceMarkup, 'economy.luxuryPriceMarkup'),
    satisfactionSmoothing: asRate(e.satisfactionSmoothing, 'economy.satisfactionSmoothing'),
    weights: {
      food: asNum(weights.food, 'economy.weights.food'),
      wage: asNum(weights.wage, 'economy.weights.wage'),
      price: asNum(weights.price, 'economy.weights.price'),
      employment: asNum(weights.employment, 'economy.weights.employment'),
      comfort: asNum(weights.comfort, 'economy.weights.comfort'),
    },
    priceIntercept: asNum(e.priceIntercept, 'economy.priceIntercept'),
    priceSlope: asNum(e.priceSlope, 'economy.priceSlope'),
    immigrationSatThreshold: asNum(e.immigrationSatThreshold, 'economy.immigrationSatThreshold'),
    immigrationRate: asNonNeg(e.immigrationRate, 'economy.immigrationRate'),
    immigrationHungryRate: asNonNeg(e.immigrationHungryRate, 'economy.immigrationHungryRate'),
    emigrationSatThreshold: asNum(e.emigrationSatThreshold, 'economy.emigrationSatThreshold'),
    hungerDeathRate: asRate(e.hungerDeathRate, 'economy.hungerDeathRate'),
    minPopulation: asNonNeg(e.minPopulation, 'economy.minPopulation'),
    buildMoneyByTier: {
      1: asNonNeg(bmt['1'], 'economy.buildMoneyByTier.1'),
      2: asNonNeg(bmt['2'], 'economy.buildMoneyByTier.2'),
      3: asNonNeg(bmt['3'], 'economy.buildMoneyByTier.3'),
    },
    expandMoneyBase: asNonNeg(e.expandMoneyBase, 'economy.expandMoneyBase'),
    maxBuildingSlots: maxSlots,
    construction: {
      unemployedRate: asNonNeg(c.unemployedRate, 'economy.construction.unemployedRate'),
      wageRate: asNonNeg(c.wageRate, 'economy.construction.wageRate'),
      upgradePerLevel: asPos(c.upgradePerLevel, 'economy.construction.upgradePerLevel'),
    },
    research: {
      baseRate: asNonNeg(rc.baseRate, 'economy.research.baseRate'),
    },
    tools: {
      perWorkstation: asNonNeg(toolsCfg.perWorkstation, 'economy.tools.perWorkstation'),
      order: strArr(toolsCfg.order, 'economy.tools.order', goodSet),
    },
    defaultRent: asNonNeg(e.defaultRent, 'economy.defaultRent'),
    privateHousingSatBonus: asNum(e.privateHousingSatBonus, 'economy.privateHousingSatBonus'),
    privateTenantSatBonus: asNum(e.privateTenantSatBonus, 'economy.privateTenantSatBonus'),
    rentSatPenalty: asNonNeg(e.rentSatPenalty, 'economy.rentSatPenalty'),
    privateHousingNeedThreshold: asNum(e.privateHousingNeedThreshold, 'economy.privateHousingNeedThreshold'),
    privateHousingPerDay: asNonNeg(e.privateHousingPerDay, 'economy.privateHousingPerDay'),
    skillIncomeBase: asNonNeg(e.skillIncomeBase, 'economy.skillIncomeBase'),
    defaultWageCap: asNonNeg(e.defaultWageCap, 'economy.defaultWageCap'),
    housingQualityPenalty: asNonNeg(e.housingQualityPenalty, 'economy.housingQualityPenalty'),
    skillGainPerDay: asNonNeg(e.skillGainPerDay, 'economy.skillGainPerDay'),
    skillMax: asNonNeg(e.skillMax, 'economy.skillMax'),
    promotionSavings: asNonNeg(e.promotionSavings, 'economy.promotionSavings'),
    promotionSatThreshold: asNonNeg(e.promotionSatThreshold, 'economy.promotionSatThreshold'),
  }

  const newShop = asObj(d.newShop, 'defaults.newShop')
  const defaults: DefaultsConfig = {
    newShop: {
      level: asPos(newShop.level, 'defaults.newShop.level'),
      skill: asNonNeg(newShop.skill, 'defaults.newShop.skill'),
    },
    newResident: parsePerson(asObj(d.newResident, 'defaults.newResident'), 'defaults.newResident'),
    startResident: parsePerson(asObj(d.startResident, 'defaults.startResident'), 'defaults.startResident'),
    startDistribution: strArr(d.startDistribution, 'defaults.startDistribution') as ClassID[],
  }

  const tuning: TuningConfig = {
    skillEffectBase: asNonNeg(t.skillEffectBase, 'tuning.skillEffectBase'),
    skillEffectSlope: asNonNeg(t.skillEffectSlope, 'tuning.skillEffectSlope'),
    unemployedEmploymentScore: asNonNeg(t.unemployedEmploymentScore, 'tuning.unemployedEmploymentScore'),
    wageScoreCap: asPos(t.wageScoreCap, 'tuning.wageScoreCap'),
    hungryThreshold: asRate(t.hungryThreshold, 'tuning.hungryThreshold'),
    priceFactorMin: asNonNeg(t.priceFactorMin, 'tuning.priceFactorMin'),
    priceFactorMax: asPos(t.priceFactorMax, 'tuning.priceFactorMax'),
    basicFoods: strArr(t.basicFoods, 'tuning.basicFoods'),
    foodChainSeedClass: asStr(t.foodChainSeedClass, 'tuning.foodChainSeedClass') as ClassID,
  }

  // 交叉引用
  for (const g of tuning.basicFoods) {
    if (!goodSet.has(g)) fail(`tuning.basicFoods 引用了未定义的商品：${g}`)
  }
  if (!classSet.has(tuning.foodChainSeedClass)) {
    fail(`tuning.foodChainSeedClass 引用了未定义的阶层：${tuning.foodChainSeedClass}`)
  }
  for (const c of defaults.startDistribution) {
    if (!classSet.has(c)) fail(`defaults.startDistribution 引用了未定义的阶层：${c}`)
  }

  return { economy, defaults, tuning, time }
}

// ---------------------------------------------------------------------------
// 商路（content/routes.json，B3）
//
// 契约见 docs/trade-routes.md。这里的校验比别处更"硬"，因为商路**不平衡就崩**：
//   1. 每座城恰好特产 2 种、需求 3 种，且商品存在、可存储、不是军备 / 服务 / 工具
//   2. **特产 ∩ 全部需求 = ∅** —— 否则"在 A 城买、到 B 城卖"就是白刷钱
//   3. 天数必须落在距离价表里（1..5），价表必须齐全
// ---------------------------------------------------------------------------
function parseRoutes(raw: unknown, goods: Record<GoodID, GoodDef>): RoutesConfig {
  const root = asObj(raw, 'routes.json')
  if (root.schemaVersion !== ROUTES_SCHEMA_VERSION) {
    fail(`routes.json.schemaVersion 必须是 ${ROUTES_SCHEMA_VERSION}（实际 ${String(root.schemaVersion)}）`)
  }

  const distance: Record<number, { sellMul: number; buyMul: number }> = {}
  for (const [i, v] of asArr(root.distance, 'routes.json.distance').entries()) {
    const p = `routes.json.distance[${i}]`
    const o = asObj(v, p)
    const days = asNum(o.days, `${p}.days`)
    if (!Number.isInteger(days) || days < 1 || days > 5) fail(`${p}.days 必须是 1..5 的整数`)
    if (distance[days] !== undefined) fail(`${p}.days 重复：${days}`)
    distance[days] = {
      sellMul: asPos(o.sellMul, `${p}.sellMul`),
      buyMul: asPos(o.buyMul, `${p}.buyMul`),
    }
  }
  for (let d = 1; d <= 5; d++) {
    if (distance[d] === undefined) fail(`routes.json.distance 缺 ${d} 天那一档`)
  }

  const cv = asObj(root.caravan, 'routes.json.caravan')
  const caravan = {
    // 基础商队数可以是 0 —— 「常设商队」那项科技才是第一支（用户口径：研究完才有商队）
    count: asNonNeg(cv.count, 'routes.json.caravan.count'),
    maxCount: asPos(cv.maxCount, 'routes.json.caravan.maxCount'),
    cargo: asPos(cv.cargo, 'routes.json.caravan.cargo'),
    purse: asNonNeg(cv.purse, 'routes.json.caravan.purse'),
    roundTrip: cv.roundTrip !== false,
  }
  if (caravan.count > caravan.maxCount) {
    fail(`routes.json.caravan.count（${caravan.count}）不能大于 maxCount（${caravan.maxCount}）`)
  }

  const mk = asObj(root.market, 'routes.json.market')
  const market = {
    specialtyStock: asNonNeg(mk.specialtyStock, 'routes.json.market.specialtyStock'),
    specialtyDaily: asNonNeg(mk.specialtyDaily, 'routes.json.market.specialtyDaily'),
    specialtyCap: asNonNeg(mk.specialtyCap, 'routes.json.market.specialtyCap'),
    demandDaily: asNonNeg(mk.demandDaily, 'routes.json.market.demandDaily'),
    demandCap: asNonNeg(mk.demandCap, 'routes.json.market.demandCap'),
  }

  const goodsOf = (v: unknown, p: string): GoodID[] =>
    asArr(v, p).map((g, j) => {
      const id = asStr(g, `${p}[${j}]`) as GoodID
      const def = goods[id]
      if (!def) fail(`${p}[${j}] 引用了不存在的商品：${id}`)
      if (def.storable !== true) fail(`${p}[${j}]「${def.nameZh}」不可存储，不能进商路`)
      if (def.category === 'service' || def.category === 'military' || def.category === 'tool') {
        fail(`${p}[${j}]「${def.nameZh}」是 ${def.category}，不进商路市场`)
      }
      return id
    })

  const cities: RouteCityDef[] = []
  const cityIds: string[] = []
  const allDemand = new Set<string>()
  const allSpecialty = new Map<string, string>()
  for (const [i, v] of asArr(root.cities, 'routes.json.cities').entries()) {
    const p = `routes.json.cities[${i}]`
    const o = asObj(v, p)
    const id = asStr(o.id, `${p}.id`)
    if (cityIds.includes(id)) fail(`${p}.id 重复：${id}`)
    const days = asNum(o.days, `${p}.days`)
    if (distance[days] === undefined) fail(`${p}.days = ${days} 不在距离价表里（只能 1..5）`)
    const specialty = goodsOf(o.specialty, `${p}.specialty`)
    if (specialty.length !== 2) fail(`${p}.specialty 必须恰好 2 种（实际 ${specialty.length}）`)
    const demand = goodsOf(o.demand, `${p}.demand`)
    if (demand.length !== 3) fail(`${p}.demand 必须恰好 3 种（实际 ${demand.length}）`)
    for (const g of specialty) allSpecialty.set(g, id)
    for (const g of demand) allDemand.add(g)
    cities.push({
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      lord: asStr(o.lord, `${p}.lord`),
      // 邦交（B4）：城市归哪个势力。唯一真源是这个字段（见 parseFactions 的反向核对）
      faction: asStr(o.faction, `${p}.faction`),
      days,
      specialty,
      demand,
      unlockChapter: o.unlockChapter === undefined ? 0 : asNonNeg(o.unlockChapter, `${p}.unlockChapter`),
    })
    cityIds.push(id)
  }
  if (cities.length === 0) fail('routes.json.cities 不能为空')
  // 倒卖闸门：任何"特产"都不许出现在**任何**城的"需求"里
  for (const [good, city] of allSpecialty) {
    if (allDemand.has(good)) {
      fail(`商品 ${good} 既是「${city}」的特产、又是某座城的需求 —— 会出现"A 城买 B 城卖"的刷钱漏洞`)
    }
  }

  return { distance, caravan, market, cities, cityIds }
}

// ---------------------------------------------------------------------------
// 邦交（content/factions.json，B4）
//
// 设计见 docs/diplomacy.md。这里除了字段校验，还强制三条结构性规则：
//   1. 每座商路城**恰好**属于一个势力，且势力的 `cityIds` 与 `routes.json` 的
//      `faction` 字段互相对得上（唯一真源是 `routes.json` 那个字段，这里只是核对）
//   2. `cap` / `defeat.cap` 必须是 `capByBand` 的键（JSON 里写档位 id，不写 -2001 这种魔数）
//   3. 档位表的 `max` **严格递增**，且最后一档的上界 == 值域上界
// ---------------------------------------------------------------------------

const RELATION_BANDS = ['enemy', 'cold', 'neutral', 'friendly', 'respect', 'ally'] as const
const CAP_BANDS = ['cold', 'friendly', 'respect', 'ally'] as const

function parseFactions(raw: unknown, routes: RoutesConfig): FactionsConfig {
  const root = asObj(raw, 'factions.json')
  if (root.schemaVersion !== FACTIONS_SCHEMA_VERSION) {
    fail(`factions.json.schemaVersion 必须是 ${FACTIONS_SCHEMA_VERSION}（实际 ${String(root.schemaVersion)}）`)
  }

  const rel = asObj(root.relation, 'factions.json.relation')
  const min = asNum(rel.min, 'factions.json.relation.min')
  const max = asNum(rel.max, 'factions.json.relation.max')
  if (!(min < 0 && max > 0 && min < max)) {
    fail(`factions.json.relation 的值域要跨过 0（min < 0 < max），实际 ${min}..${max}`)
  }

  const bands = asArr(rel.bands, 'factions.json.relation.bands').map((v, i) => {
    const p = `factions.json.relation.bands[${i}]`
    const o = asObj(v, p)
    return {
      id: asEnum(o.id, RELATION_BANDS, `${p}.id`),
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      max: asNum(o.max, `${p}.max`),
      incl: o.incl === undefined ? false : asBool(o.incl, `${p}.incl`),
    }
  })
  if (bands.length !== RELATION_BANDS.length) {
    fail(`factions.json.relation.bands 要恰好 ${RELATION_BANDS.length} 档（实际 ${bands.length}）`)
  }
  bands.forEach((b, i) => {
    if (b.id !== RELATION_BANDS[i]) {
      fail(`factions.json.relation.bands[${i}].id 必须是 ${RELATION_BANDS[i]}（实际 ${b.id}）`)
    }
    if (i > 0) {
      const prev = bands[i - 1]!
      // 上界必须**单调不减**，且相邻两档不许重叠（`10000` 那对是"尊重不含 / 同盟含"）
      const last = i === bands.length - 1
      if (!(b.max > prev.max || (last && b.max === prev.max))) {
        fail(`factions.json.relation.bands[${i}].max 要递增（第 ${i} 档 ${b.max} 不大于前一档 ${prev.max}）`)
      }
      if (!last && prev.incl && b.max === prev.max) fail(`factions.json.relation.bands 第 ${i}/${i + 1} 档重叠`)
    }
  })
  if (bands[bands.length - 1]!.max !== max) {
    fail(`factions.json.relation.bands 最后一档的 max（${bands[bands.length - 1]!.max}）要等于 relation.max（${max}）`)
  }
  if (!bands[bands.length - 1]!.incl) fail('factions.json.relation.bands 最后一档 must be 含上界（incl: true）')

  const capRaw = asObj(rel.capByBand, 'factions.json.relation.capByBand')
  const capByBand = {} as Record<CapBand, number>
  for (const k of CAP_BANDS) {
    const v = capRaw[k]
    if (v === undefined) fail(`factions.json.relation.capByBand 缺 ${k}`)
    const n = asNum(v, `factions.json.relation.capByBand.${k}`)
    if (n < min || n > max) fail(`factions.json.relation.capByBand.${k} = ${n} 超出 ${min}..${max}`)
    capByBand[k] = n
  }
  // 天花板要落在自己那一档里（`cold` → 冷淡的上界 −2001 之类），单调递增
  for (let i = 0; i < CAP_BANDS.length; i++) {
    const k = CAP_BANDS[i]!
    if (i > 0 && !(capByBand[k] > capByBand[CAP_BANDS[i - 1]!])) {
      fail(`factions.json.relation.capByBand 要随档位单调递增（${k} 不大于前一档）`)
    }
  }

  const tradeBand = asEnum(rel.tradeBand, RELATION_BANDS, 'factions.json.relation.tradeBand')
  const relation = {
    min,
    max,
    bands,
    vassalNameZh: asStr(rel.vassalNameZh, 'factions.json.relation.vassalNameZh'),
    capByBand,
    giftStep: asPos(rel.giftStep, 'factions.json.relation.giftStep'),
    giftRate: asPos(rel.giftRate, 'factions.json.relation.giftRate'),
    attackHit: asNum(rel.attackHit, 'factions.json.relation.attackHit'),
    allyCost: asNonNeg(rel.allyCost, 'factions.json.relation.allyCost'),
    tradeBand,
    tradeGain: asNonNeg(rel.tradeGain, 'factions.json.relation.tradeGain'),
  }
  if (relation.attackHit < min || relation.attackHit > max) {
    fail(`factions.json.relation.attackHit = ${relation.attackHit} 超出 ${min}..${max}`)
  }

  const routeCityIds = new Set(routes.cityIds)
  const factions: FactionDef[] = []
  const factionIds: FactionID[] = []
  /** cityId → factionId（查"一座城被两家认领"）。 */
  const cityOwner = new Map<string, string>()

  for (const [i, v] of asArr(root.factions, 'factions.json.factions').entries()) {
    const p = `factions.json.factions[${i}]`
    const o = asObj(v, p)
    const id = asStr(o.id, `${p}.id`)
    if (factionIds.includes(id)) fail(`${p}.id 重复：${id}`)

    const cap = asEnum(o.cap, CAP_BANDS, `${p}.cap`)
    const initial = asNum(o.initial, `${p}.initial`)
    // ⚠️ 开局好感**可以高于天花板**：沙海汗国就是"开局中立（能通商）、最高也就冷淡"，
    // 第 6 章翻脸之后一路掉到敌对，打服了才放开到尊重。所以这里只查值域，不拿 cap 卡开局。
    if (initial < min || initial > max) {
      fail(`${p}.initial = ${initial} 超出值域 ${min}..${max}`)
    }

    let flip: FactionFlip | null = null
    if (o.flip !== undefined && o.flip !== null) {
      const f = asObj(o.flip, `${p}.flip`)
      const chapter = asNum(f.chapter, `${p}.flip.chapter`)
      if (!Number.isInteger(chapter) || chapter < 1 || chapter > 17) {
        fail(`${p}.flip.chapter 必须是 1..17 的整数（实际 ${chapter}）`)
      }
      const to = asNum(f.to, `${p}.flip.to`)
      if (to < min || to > max) fail(`${p}.flip.to = ${to} 超出 ${min}..${max}`)
      flip = { chapter, to, reason: asStr(f.reason, `${p}.flip.reason`) }
    }

    let defeat: FactionDefeat | null = null
    if (o.defeat !== undefined && o.defeat !== null) {
      const d = asObj(o.defeat, `${p}.defeat`)
      const rep = asNum(d.rep, `${p}.defeat.rep`)
      const dcap = asEnum(d.cap, CAP_BANDS, `${p}.defeat.cap`)
      if (rep < min || rep > capByBand[dcap]) {
        fail(`${p}.defeat.rep = ${rep} 要落在 ${min}..${capByBand[dcap]}（defeat.cap = ${dcap}）里`)
      }
      defeat = {
        rep,
        cap: dcap,
        vassal: asBool(d.vassal, `${p}.defeat.vassal`),
        ...(d.reason === undefined ? {} : { reason: asStr(d.reason, `${p}.defeat.reason`) }),
      }
    }

    const cityIds = strArr(o.cityIds, `${p}.cityIds`)
    for (const cid of cityIds) {
      if (!routeCityIds.has(cid)) fail(`${p}.cityIds 里的 ${cid} 不在 routes.json 的城里`)
      const prev = cityOwner.get(cid)
      if (prev !== undefined) fail(`城 ${cid} 同时属于 ${prev} 和 ${id}（一座城只能归一个势力）`)
      cityOwner.set(cid, id)
    }

    const vassalable = asBool(o.vassalable, `${p}.vassalable`)
    if (defeat?.vassal === true && !vassalable) {
      fail(`${p}：defeat.vassal = true 但 vassalable = false（自相矛盾）`)
    }

    factions.push({
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      short: asStr(o.short, `${p}.short`),
      lord: asStr(o.lord, `${p}.lord`),
      cityIds,
      initial,
      cap,
      allyable: asBool(o.allyable, `${p}.allyable`),
      vassalable,
      flip,
      defeat,
      glyph: asStr(o.glyph, `${p}.glyph`),
    })
    factionIds.push(id)
  }
  if (factions.length === 0) fail('factions.json.factions 不能为空')

  // 反向核对：routes.json 每座城的 `faction` 都要存在，且那家也把这座城列进 cityIds
  for (const city of routes.cities) {
    const fid = city.faction
    if (fid === undefined || fid === null || String(fid) === '') {
      fail(`routes.json.cities「${city.id}」缺 faction 字段（邦交要靠它查好感）`)
    }
    if (!factionIds.includes(fid)) {
      fail(`routes.json.cities「${city.id}」的 faction = ${fid} 不在 factions.json 里`)
    }
    const owner = cityOwner.get(city.id)
    if (owner !== fid) {
      fail(`routes.json 说「${city.id}」归 ${fid}，但 factions.json 里 ${owner ?? '（没人）'} 认领了它`)
    }
  }

  return { relation, factions, factionIds }
}

// ---------------------------------------------------------------------------
// 科技树（content/technologies.json）
//
// 设计见 docs/technology.md。这里除了字段校验，还强制两条结构性规则：
//   1. 每座建筑 / 住房至多被一项科技解锁（否则「解锁」语义模糊）
//   2. §1.1：一项科技花费的每种原料，必须能由「开局免费建筑 + 它的传递前置解锁的建筑」产出
//      —— 这条直接挡住「要研究 X 却要先有 X 的产物」的死锁
// ---------------------------------------------------------------------------

function parseTechnologies(
  raw: unknown,
  goodSet: Set<string>,
  buildingSet: Set<string>,
  housingSet: Set<string>,
  buildings: Record<BuildingID, BuildingDef>,
  recipes: Record<RecipeID, RecipeDef>,
): { technologies: Record<TechID, TechDef>; techIds: TechID[]; eraIds: number[] } {
  const root = asObj(raw, 'technologies.json')
  const eraList = asArr(root.eras, 'technologies.json.eras')
  const eraIds: number[] = []
  const eraNames = new Map<number, string>()
  eraList.forEach((e, i) => {
    const p = `eras[${i}]`
    const o = asObj(e, p)
    const id = asPos(o.id, `${p}.id`)
    if (eraNames.has(id)) fail(`${p}.id 重复：${id}`)
    eraNames.set(id, asStr(o.nameZh, `${p}.nameZh`))
    eraIds.push(id)
  })

  const list = asArr(root.technologies, 'technologies.json.technologies')
  const technologies: Record<TechID, TechDef> = {}
  const techIds: TechID[] = []
  for (let i = 0; i < list.length; i++) {
    const p = `technologies[${i}]`
    const o = asObj(list[i], p)
    const id = asStr(o.id, `${p}.id`)
    if (technologies[id]) fail(`${p}.id 重复：${id}`)
    const era = asPos(o.era, `${p}.era`)
    if (!eraNames.has(era)) fail(`${p}.era 引用了未定义的纪元：${era}`)
    const costObj = asObj(o.cost, `${p}.cost`)
    const goods = numMap(costObj.goods, `${p}.cost.goods`, goodSet)
    const unlocksRaw = asObj(o.unlocks, `${p}.unlocks`)
    const unlocks = {
      buildings: strList(unlocksRaw.buildings, `${p}.unlocks.buildings`),
      housing: strList(unlocksRaw.housing, `${p}.unlocks.housing`),
    }
    for (const b of unlocks.buildings) {
      if (!buildingSet.has(b)) fail(`${p}.unlocks.buildings 引用了未定义的建筑：${b}`)
    }
    for (const h of unlocks.housing) {
      if (!housingSet.has(h)) fail(`${p}.unlocks.housing 引用了未定义的住房：${h}`)
    }
    if (unlocks.buildings.length + unlocks.housing.length === 0) {
      // 纯效率科技（只给 effects、不解锁任何东西）也是合法的 —— 它的价值在加成上。
      // 但两者都没有 = 一项什么都不做的科技，直接报错。
      if (o.effects === undefined && o.trade === undefined && o.diplomacy === undefined) {
        fail(`${p} 既没有 unlocks 也没有 effects / trade：科技至少要解锁一座建筑 / 一种住房，或给一项加成（effects / trade / diplomacy）`)
      }
    }
    const effects = o.effects === undefined ? undefined : parseTechEffects(o.effects, `${p}.effects`)
    const trade = o.trade === undefined ? undefined : parseTradeEffects(o.trade, `${p}.trade`)
    // 外交（B4）：`tab` 决定进哪一页；`diplomacy.range` = 外交范围（2 / 4 / 0=全图）
    const tab = o.tab === undefined ? undefined : asEnum(o.tab, ['diplomacy'] as const, `${p}.tab`)
    let diplomacy: { range: number } | undefined
    if (o.diplomacy !== undefined) {
      const d = asObj(o.diplomacy, `${p}.diplomacy`)
      const range = asNonNeg(d.range, `${p}.diplomacy.range`)
      if (![0, 2, 4].includes(range)) {
        fail(`${p}.diplomacy.range 只能是 0（全图）/ 2 / 4，实际 ${range}`)
      }
      diplomacy = { range }
    }
    technologies[id] = {
      id,
      nameZh: asStr(o.nameZh, `${p}.nameZh`),
      era,
      research: asPos(o.research, `${p}.research`),
      cost: { goods },
      requires: strList(o.requires, `${p}.requires`),
      ...(effects !== undefined ? { effects } : {}),
      ...(trade !== undefined ? { trade } : {}),
      ...(tab !== undefined ? { tab } : {}),
      ...(diplomacy !== undefined ? { diplomacy } : {}),
      unlocks,
    }
    techIds.push(id)
  }

  // requires 存在 + 无环（Kahn 拓扑）
  for (const id of techIds) {
    for (const r of technologies[id]!.requires) {
      if (!technologies[r]) fail(`technologies.${id}.requires 引用了未定义的科技：${r}`)
    }
  }
  {
    const indeg = new Map(techIds.map((id) => [id, technologies[id]!.requires.length]))
    const edges = new Map<string, string[]>(techIds.map((id) => [id, []]))
    for (const id of techIds) for (const r of technologies[id]!.requires) edges.get(r)!.push(id)
    const queue = techIds.filter((id) => indeg.get(id) === 0)
    let seen = 0
    while (queue.length > 0) {
      const id = queue.shift()!
      seen++
      for (const nx of edges.get(id)!) {
        indeg.set(nx, indeg.get(nx)! - 1)
        if (indeg.get(nx) === 0) queue.push(nx)
      }
    }
    if (seen !== techIds.length) fail('technologies.json 的 requires 存在环（无法拓扑排序）')
  }

  // 唯一解锁：每座建筑 / 住房至多被一项科技解锁
  const owner = new Map<string, string>()
  for (const id of techIds) {
    const t = technologies[id]!
    for (const b of [...t.unlocks.buildings, ...t.unlocks.housing]) {
      const prev = owner.get(b)
      if (prev) fail(`「${b}」被多项科技解锁：${prev} 与 ${id}（每座建筑至多一项）`)
      owner.set(b, id)
    }
  }

  // §1.1：花费的原料必须来自「免费建筑 + 传递前置解锁的建筑」
  // 「免费」= 没有任何科技解锁它的建筑（开局即可建造）
  //
  // ⚠️ **纯效率科技**（有 effects、但什么都不解锁）不适用这一条，见下面的说明。
  const freeBuildings = [...buildingSet].filter((b) => !owner.has(b))
  const outputsOf = (bid: string): string[] => {
    const def = buildings[bid]
    if (!def || !def.recipe) return []
    return Object.keys(recipes[def.recipe]?.output ?? {})
  }
  const closureOf = (id: string): Set<string> => {
    const seen = new Set<string>()
    const walk = (x: string): void => {
      if (seen.has(x)) return
      seen.add(x)
      for (const r of technologies[x]!.requires) walk(r)
    }
    walk(id)
    return seen
  }
  for (const id of techIds) {
    const t = technologies[id]!

    // ⚠️ 效率科技**同样要过这道闸门**，不许放行。
    //
    // 一开始有 11 项过不了：它们的 `requires` 是"速度树"前置（轮作 → 灌溉），
    // 这条链什么都不解锁，闭包恒空 → 花掉的石头 / 砖永远不可达。
    // 当时的第一版处理是"纯效率科技跳过闸门、把够不够料留给下单时判"——
    // **那等于把安全规则挖掉一块**：真走到那一步才发现料不够，就是一次静默的下单失败。
    // 正确的修法是**改内容**（`content/technologies.json`）：
    //   1. 五个 L1 都挂 `stonework` → 采石场进闭包，石头顺着链被 L2/L3 继承；
    //   2. 五个 L3 的花费去掉砖（砖要靠 `brickmaking`，跟速度树无关）。
    // 于是"前置闭包里原料可达"这条不变量对所有科技一视同仁。
    const avail = new Set<string>(freeBuildings.flatMap(outputsOf))
    for (const pre of closureOf(id)) {
      for (const b of technologies[pre]!.unlocks.buildings) for (const g of outputsOf(b)) avail.add(g)
    }
    for (const g of Object.keys(t.cost.goods)) {
      if (!avail.has(g)) {
        fail(
          `technologies.${id}（${t.nameZh}）花费里有「${g}」，但它的前置解锁不出这种原料` +
            `（违反 docs/technology.md §1.1，会形成死锁）`,
        )
      }
    }
  }

  return { technologies, techIds, eraIds }
}

// ---------------------------------------------------------------------------
// 任务（content/quests.json）
//
// 契约见 docs/quests.md。校验盯三件事：
//   1. 引用的东西必须存在（建筑 / 商品 / 住房 / 阶层 / 科技）
//   2. `requires` 不能有环、不能指向不存在的任务、不能依赖支线
//   3. 每条任务的 `chapter` 必须在 chapters 里
// ---------------------------------------------------------------------------

interface QuestSets {
  goodSet: Set<string>
  buildingSet: Set<string>
  classSet: Set<string>
  housingSet: Set<string>
  techIds: Set<string>
}

function asRef(v: unknown, set: Set<string>, p: string, what: string): string {
  const id = asStr(v, p)
  if (!set.has(id)) fail(`${p} 引用了不存在的${what}：${id}`)
  return id
}

function parseQuestGoal(v: unknown, p: string, sets: QuestSets): QuestGoal {
  const g = asObj(v, p)
  const type = asStr(g.type, `${p}.type`)
  const need = (): number => asPos(g.min, `${p}.min`)
  switch (type) {
    case 'building':
      // `repaired: true` = 换口径数"这座修好了吗"（只对城镇中心有意义）。
      // 内容里的主写法是 `building_repaired`，这个别名收着是给换写法用的。
      if (g.repaired === true) {
        const raw = asStr(g.id, `${p}.id`)
        const id = raw === 'townhall' ? 'town_center' : raw
        if (id !== 'town_center') fail(`${p}.id 只能是 townhall 或 town_center（实际 ${raw}）`)
        return { type, id: id as BuildingID, min: need(), repaired: true }
      }
      return { type, id: asRef(g.id, sets.buildingSet, `${p}.id`, '建筑'), min: need() }
    case 'building_repaired': {
      // 塌了的建筑目前只有城镇中心这一座。内容里两个写法都认：
      // `townhall`（口语名）与 `town_center`（建筑表 id）。
      const id = asStr(g.id, `${p}.id`)
      if (id !== 'townhall' && id !== 'town_center') {
        fail(`${p}.id 只能是 townhall 或 town_center（实际 ${id}）`)
      }
      // `stage`：`patched`（初步修缮，第三章）/ 缺省 = `restored`（修好，第四章）
      const stage = g.stage === undefined ? undefined : asStr(g.stage, `${p}.stage`)
      if (stage !== undefined && stage !== 'patched' && stage !== 'restored' && stage !== 'ruined') {
        fail(`${p}.stage 只能是 patched 或 restored（实际 ${stage}）`)
      }
      return {
        type,
        id,
        min: need(),
        ...(stage === undefined ? {} : { stage: stage as 'ruined' | 'patched' | 'restored' }),
      }
    }
    case 'housing':
      return { type, id: asRef(g.id, sets.housingSet, `${p}.id`, '住房'), min: need() }
    case 'housing_capacity':
      return { type, min: need() }
    case 'population':
      return { type, min: need() }
    case 'class':
      return { type, id: asRef(g.id, sets.classSet, `${p}.id`, '阶层'), min: need() }
    case 'tech':
      return { type, id: asRef(g.id, sets.techIds, `${p}.id`, '科技') }
    case 'tech_count':
      return { type, min: need() }
    case 'good':
      return { type, id: asRef(g.id, sets.goodSet, `${p}.id`, '商品'), min: need() }
    case 'produced':
      return { type, id: asRef(g.id, sets.goodSet, `${p}.id`, '商品'), min: need() }
    case 'avg_satisfaction':
      return { type, min: need() }
    case 'private_housing':
      return { type, min: need() }
    case 'gifted':
      // 送物资（用户 2026-10 · A4）：判的是**累计送出**的量，不是库存。
      return {
        type,
        to: asStr(g.to, `${p}.to`),
        id: asRef(g.id, sets.goodSet, `${p}.id`, '商品'),
        min: need(),
      }
    case 'caravan_trade':
      // 和游商成交过几次（B4 章 3）：`side` = sell（卖给游商）/ buy（从他那儿买）。
      return {
        type,
        side: asEnum(g.side, ['sell', 'buy'] as const, `${p}.side`),
        min: need(),
      }
    case 'route_created':
      // 累计创建过几条商路（B4 章 4）—— 取消不减，问的是"会不会用这套系统"。
      return { type, min: need() }
    case 'faction_gift':
      // 给某个势力送过几次钱（B4 章 5）；`id` 留空 = 任意势力。
      return {
        type,
        ...(g.id === undefined ? {} : { id: asStr(g.id, `${p}.id`) }),
        min: need(),
      }
    default:
      fail(`${p}.type 取值非法：${type}`)
  }
}

/**
 * 一段对话里的选项（章节收尾与场次共用）。
 *
 * `action` 只有两个合法值：`free_prophecy`（送一次免费预言）/ `close`（关掉，缺省）。
 * ⚠️ 玩家 2026-10 把第一章收尾那两个选项删了（"她送的预言不许拒绝"），
 * 机制本身留着 —— 后面的分支剧情还要用（见 `docs/spec.md` §16.7）。
 */
function parseChoices(v: unknown, p: string): QuestChoice[] {
  const cs = asArr(v, p).map((c, i) => {
    const q = asObj(c, `${p}[${i}]`)
    const action = q.action === undefined ? undefined : asStr(q.action, `${p}[${i}].action`)
    if (action !== undefined && action !== 'free_prophecy' && action !== 'close') {
      fail(`${p}[${i}].action 只能是 free_prophecy 或 close（实际 ${action}）`)
    }
    return {
      id: asStr(q.id, `${p}[${i}].id`),
      text: asStr(q.text, `${p}[${i}].text`),
      ...(action ? { action: action as 'free_prophecy' | 'close' } : {}),
    }
  })
  if (cs.length === 0) fail(`${p} 给了就得至少有一个`)
  return cs
}

/**
 * 章节收尾那段对话（`chapters[].outro`，用户 2026-10）。
 *
 * 结构与任务发布对话同形；`choices` 可选，`action` 只有两个合法值。
 * ⚠️ 这些字是**直接画在屏幕上的台词**：像素字体里没有的字会静默变空白，
 * 所以 Godot 侧的 `glyph` 门槛会扫整个 `quests.json`。
 */
function parseOutro(v: unknown, p: string): QuestOutro {
  const o = asObj(v, p)
  const lines = asArr(o.lines, `${p}.lines`).map((l, i) => asStr(l, `${p}.lines[${i}]`))
  if (lines.length === 0) fail(`${p}.lines 不能为空`)
  const outro: QuestOutro = {
    speaker: asStr(o.speaker, `${p}.speaker`),
    portrait: asStr(o.portrait, `${p}.portrait`),
    lines,
  }
  if (o.choices !== undefined) outro.choices = parseChoices(o.choices, `${p}.choices`)
  return outro
}

function parseQuests(
  raw: unknown,
  sets: QuestSets,
): { quests: Record<QuestID, QuestDef>; questIds: QuestID[]; chapters: QuestChapterDef[] } {
  const root = asObj(raw, 'quests.json')
  if (root.schemaVersion !== QUESTS_SCHEMA_VERSION) {
    fail(`quests.json.schemaVersion 必须是 ${QUESTS_SCHEMA_VERSION}（实际 ${String(root.schemaVersion)}）`)
  }

  const chapters: QuestChapterDef[] = []
  const chapterIds = new Set<number>()
  for (const [i, v] of asArr(root.chapters, 'quests.json.chapters').entries()) {
    const p = `quests.json.chapters[${i}]`
    const c = asObj(v, p)
    const id = asNum(c.id, `${p}.id`)
    if (chapterIds.has(id)) fail(`${p}.id 重复：${id}`)
    chapterIds.add(id)
    chapters.push({
      id,
      title: asStr(c.title, `${p}.title`),
      reward: asNonNeg(c.reward, `${p}.reward`),
      // 剧情时钟（用户 2026-10 · B1）：上一章领奖那天起再隔几天才开这一章。
      // 章 1–5 写 0（或整条省掉）；3–5 是给章 6 之后的固定值（不随机）。
      gapDays: c.gapDays === undefined ? 0 : asNonNeg(c.gapDays, `${p}.gapDays`),
      ...(c.outro === undefined ? {} : { outro: parseOutro(c.outro, `${p}.outro`) }),
    })
  }
  if (chapters.length === 0) fail('quests.json.chapters 不能为空')

  const quests: Record<QuestID, QuestDef> = {}
  const questIds: QuestID[] = []
  for (const [i, v] of asArr(root.quests, 'quests.json.quests').entries()) {
    const p = `quests.json.quests[${i}]`
    const q = asObj(v, p)
    const id = asStr(q.id, `${p}.id`)
    if (quests[id]) fail(`${p}.id 重复：${id}`)
    const chapter = asNum(q.chapter, `${p}.chapter`)
    if (!chapterIds.has(chapter)) fail(`${p}.chapter 指向不存在的章节：${chapter}`)
    const rawGoals = asArr(q.goals, `${p}.goals`)
    if (rawGoals.length === 0) fail(`${p}.goals 不能为空`)
    // 任务种类（用户 2026-10 · B2）：`main` / `side` / `milestone`。
    // 老内容写的是 `"side": true` —— 两种写法都收，但**只留一份真相**（`kind`），
    // `side` 由它派生，免得引擎里两处判断打架。
    let kind: QuestKind = 'main'
    if (q.kind !== undefined) {
      kind = asEnum(q.kind, ['main', 'side', 'milestone'] as const, `${p}.kind`)
      if (q.side === true && kind !== 'side') {
        fail(`${p}: kind = ${kind} 与 side: true 打架（支线只写一种）`)
      }
    } else if (q.side === true) {
      kind = 'side'
    }
    const reward = asNonNeg(q.reward, `${p}.reward`)
    // 里程碑**不发钱**（用户 2026-10 · B2）：目标故意设得很远，发钱就成了躺赚。
    if (kind === 'milestone' && reward > 0) {
      fail(`${p}.reward：里程碑不发钱（kind = milestone 时必须是 0 或整条省掉）`)
    }
    quests[id] = {
      id,
      chapter,
      kind,
      // 发布人 + 立绘（用户 2026-10）：任务触发时要暂停时间、弹一段 galgame 对话，
      // 说话的就是这位。**必填** —— 少了就是"任务静静地出现"，没人会注意到。
      giver: asStr(q.giver, `${p}.giver`),
      giverPortrait: asStr(q.giverPortrait, `${p}.giverPortrait`),
      title: asStr(q.title, `${p}.title`),
      hint: asStr(q.hint, `${p}.hint`),
      // 任务面板右侧的描述（智囊口吻）。**必填**：漏了的话面板上会空一块，
      // 而那是"没人会注意到"的一类问题 —— 所以让内容校验器直接拦下来。
      brief: asStr(q.brief, `${p}.brief`),
      reward,
      requires: asArr(q.requires ?? [], `${p}.requires`).map((r, j) =>
        asStr(r, `${p}.requires[${j}]`),
      ),
      goals: rawGoals.map((g, j) => parseQuestGoal(g, `${p}.goals[${j}]`, sets)),
      side: kind === 'side' ? true : undefined,
    }
    questIds.push(id)
  }
  if (questIds.length === 0) fail('quests.json.quests 不能为空')

  // requires：必须指向存在的任务，且不能有环（顺带把定义顺序固定下来）
  const mark = new Map<string, 1 | 2>()
  const visit = (id: string, path: string[]): void => {
    const m = mark.get(id)
    if (m === 2) return
    if (m === 1) fail(`quests.json 的 requires 存在环：${[...path, id].join(' -> ')}`)
    mark.set(id, 1)
    for (const pre of quests[id]!.requires) {
      if (pre === id) fail(`quests.${id}.requires 不能指向自己`)
      if (!quests[pre]) fail(`quests.${id}.requires 指向不存在的任务：${pre}`)
      visit(pre, [...path, id])
    }
    mark.set(id, 2)
  }
  for (const id of questIds) visit(id, [])

  // 支线与里程碑不挡任何东西：**主线**不能依赖它们，否则「章节全绿」的语义会被拖死。
  // 支线之间可以互相串（17 条送物资就是一条链），但那不叫"挡主线"。
  for (const id of questIds) {
    const kind = quests[id]!.kind
    if (kind === 'side' || kind === 'milestone') continue
    for (const pre of quests[id]!.requires) {
      const pk = quests[pre]!.kind
      if (pk === 'side' || pk === 'milestone') {
        fail(`quests.${id}.requires 依赖了${pk === 'side' ? '支线' : '里程碑'}任务 ${pre}（它们不挡主线）`)
      }
    }
  }

  return { quests, questIds, chapters }
}

/**
 * 场次（"不挂任务的戏"，用户 2026-10 · A1）—— `content/scenes.json`。
 *
 * 契约见 `docs/quests.md` §八。校验盯三件事：
 *   1. `id` 不重复（记账键是 `s:<id>`，重了就永远播不到第二条）
 *   2. `when` 里引用的建筑 / 科技 / 阶层必须存在
 *   3. `lines` 不能为空（空台词会让播放器当场关掉，看起来像"没播"）
 */
function parseScenes(
  raw: unknown,
  sets: QuestSets,
): { scenes: Record<string, SceneDef>; sceneIds: string[] } {
  const root = asObj(raw, 'scenes.json')
  if (root.schemaVersion !== SCENES_SCHEMA_VERSION) {
    fail(`scenes.json.schemaVersion 必须是 ${SCENES_SCHEMA_VERSION}（实际 ${String(root.schemaVersion)}）`)
  }
  const scenes: Record<string, SceneDef> = {}
  const sceneIds: string[] = []
  for (const [i, v] of asArr(root.scenes, 'scenes.json.scenes').entries()) {
    const p = `scenes.json.scenes[${i}]`
    const o = asObj(v, p)
    const id = asStr(o.id, `${p}.id`)
    if (scenes[id] !== undefined) fail(`${p}.id 重复：${id}`)
    const w = o.when === undefined ? {} : asObj(o.when, `${p}.when`)
    const when: SceneWhen = {}
    if (w.chapter !== undefined) when.chapter = asNum(w.chapter, `${p}.when.chapter`)
    if (w.afterDays !== undefined) when.afterDays = asNonNeg(w.afterDays, `${p}.when.afterDays`)
    if (w.minDay !== undefined) when.minDay = asNum(w.minDay, `${p}.when.minDay`)
    if (w.pop !== undefined) when.pop = asNonNeg(w.pop, `${p}.when.pop`)
    if (w.building !== undefined) {
      when.building = asRef(w.building, sets.buildingSet, `${p}.when.building`, '建筑') as BuildingID
    }
    if (w.tech !== undefined) {
      when.tech = asRef(w.tech, sets.techIds, `${p}.when.tech`, '科技') as TechID
    }
    if (w.class !== undefined) {
      when.class = asRef(w.class, sets.classSet, `${p}.when.class`, '阶层') as ClassID
      when.classMin = w.classMin === undefined ? 1 : asPos(w.classMin, `${p}.when.classMin`)
    }
    const lines = asArr(o.lines, `${p}.lines`).map((l, j) => asStr(l, `${p}.lines[${j}]`))
    if (lines.length === 0) fail(`${p}.lines 不能为空`)
    scenes[id] = {
      id,
      when,
      speaker: asStr(o.speaker, `${p}.speaker`),
      portrait: asStr(o.portrait, `${p}.portrait`),
      lines,
      ...(o.choices === undefined ? {} : { choices: parseChoices(o.choices, `${p}.choices`) }),
    }
    sceneIds.push(id)
  }
  return { scenes, sceneIds }
}

/**
 * 校验并组装全部内容表。
 */
export function parseContent(files: RawContent): ParsedContent {
  const { goods, ids: goodIds } = parseGoods(files.goods)
  const goodSet = new Set(goodIds)

  const { buildings, ids: buildingIds, recipes, recipeByBuilding } = parseBuildings(files.buildings, goodSet)
  const buildingSet = new Set(buildingIds)

  const { classes, ids: classIds } = parseClasses(files.classes, goodSet)
  const classSet = new Set(classIds)

  const { housing, ids: housingIds } = parseHousing(files.housing, classSet, goodSet)
  const housingSet = new Set(housingIds)

  // 科技要在 packs 之前解析：packs 的 start.techs 要引用科技 id
  const { technologies, techIds, eraIds } = parseTechnologies(
    files.technologies,
    goodSet,
    buildingSet,
    housingSet,
    buildings,
    recipes,
  )

  const { packs, ids: packIds } = parsePacks(
    files.packs,
    goodSet,
    buildingSet,
    classSet,
    housingSet,
    new Set(techIds),
  )
  const { economy, defaults, tuning, time } = parseEconomy(files.economy, goodSet, classSet)

  const { quests, questIds, chapters } = parseQuests(files.quests, {
    goodSet,
    buildingSet,
    classSet,
    housingSet,
    techIds: new Set(techIds),
  })
  const { scenes, sceneIds } = parseScenes(files.scenes, {
    goodSet,
    buildingSet,
    classSet,
    housingSet,
    techIds: new Set(techIds),
  })

  const routes = parseRoutes(files.routes, goods)

  // 邦交（B4）要在 routes 之后解析：势力的 `cityIds` 要拿 routes.json 的城去核。
  const factions = parseFactions(files.factions, routes)

  if (packIds.length === 0) fail('packs.json 至少要有一个内容包')

  return {
    goods, goodIds,
    buildings, buildingIds,
    recipes, recipeByBuilding,
    classes, classIds,
    housing, housingIds,
    packs, packIds,
    economy, defaults, tuning, time,
    technologies, techIds, eraIds,
    quests, questIds, chapters,
    scenes, sceneIds,
    routes,
    factions,
  }
}
