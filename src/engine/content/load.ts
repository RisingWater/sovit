import { readFileSync } from 'node:fs'

// ---------------------------------------------------------------------------
// 内容 JSON 读取
//
// 数据目录在仓库根的 content/。这里只负责「读文件 + JSON.parse」，不校验；
// 校验交给 validate.ts（带字段路径的报错）。
// ---------------------------------------------------------------------------

export interface RawContent {
  goods: unknown
  buildings: unknown
  classes: unknown
  housing: unknown
  packs: unknown
  economy: unknown
}

const CONTENT_DIR = new URL('../../../content/', import.meta.url)

function read(name: string): unknown {
  const url = new URL(name, CONTENT_DIR)
  try {
    return JSON.parse(readFileSync(url, 'utf8'))
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err)
    throw new Error(`[content] 读取 ${name} 失败：${msg}`)
  }
}

export function loadContentFiles(): RawContent {
  return {
    goods: read('goods.json'),
    buildings: read('buildings.json'),
    classes: read('classes.json'),
    housing: read('housing.json'),
    packs: read('packs.json'),
    economy: read('economy.json'),
  }
}
