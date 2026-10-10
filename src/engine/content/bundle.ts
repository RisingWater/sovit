import { loadContentFiles } from './load.ts'
import { parseContent } from './validate.ts'

// ---------------------------------------------------------------------------
// 内容单例：读 JSON → 校验 → 组装。全进程只做一次。
// content/index.ts 与 config.ts 都从这里取，避免重复读文件。
// ---------------------------------------------------------------------------

export const CONTENT = parseContent(loadContentFiles())
