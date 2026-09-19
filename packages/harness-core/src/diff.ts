import type { DiffHunk, DiffLine, DiffPreview } from '@witseek/protocol'

/**
 * 逐行 LCS 差异。
 *
 * 用 LCS 而不是"按行号硬比"：插入一行会让其后所有行号错位，
 * 硬比会把整段都标成变更，diff 就没法看了。
 *
 * 行数乘积超过阈值时退化为"整体删除 + 整体新增"：
 * LCS 的 DP 表是 O(n·m)，几万行的文件会把主进程卡住，
 * 而那种情况下用户本来也读不了逐行差异。
 */
const MAX_CELLS = 4_000_000

export function splitLines(text: string): string[] {
  if (text === '') return []
  // 末尾换行不算"多出一个空行"，否则每个正常文件都会挂一条无意义的差异
  const normalized = text.endsWith('\n') ? text.slice(0, -1) : text
  return normalized.split('\n')
}

export function diffLines(
  oldText: string,
  newText: string
): { lines: DiffLine[]; truncated: boolean } {
  const a = splitLines(oldText)
  const b = splitLines(newText)

  if ((a.length + 1) * (b.length + 1) > MAX_CELLS) {
    const lines: DiffLine[] = []
    a.forEach((text, i) => lines.push({ kind: 'del', oldNo: i + 1, text }))
    b.forEach((text, j) => lines.push({ kind: 'add', newNo: j + 1, text }))
    return { lines, truncated: true }
  }

  const n = a.length
  const m = b.length
  const w = m + 1
  // 从右下往左上填 LCS 长度表
  const t = new Uint32Array((n + 1) * w)
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      t[i * w + j] =
        a[i] === b[j]
          ? t[(i + 1) * w + (j + 1)] + 1
          : Math.max(t[(i + 1) * w + j], t[i * w + (j + 1)])
    }
  }

  const lines: DiffLine[] = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      lines.push({ kind: 'plain', oldNo: i + 1, newNo: j + 1, text: a[i] })
      i++
      j++
    } else if (t[(i + 1) * w + j] >= t[i * w + (j + 1)]) {
      lines.push({ kind: 'del', oldNo: i + 1, text: a[i] })
      i++
    } else {
      lines.push({ kind: 'add', newNo: j + 1, text: b[j] })
      j++
    }
  }
  while (i < n) lines.push({ kind: 'del', oldNo: i + 1, text: a[i++] })
  while (j < m) lines.push({ kind: 'add', newNo: j + 1, text: b[j++] })

  return { lines, truncated: false }
}

export interface HunkedDiff {
  /** 每行都可能带 hunkId（上下文行属于它相邻的 hunk） */
  lines: DiffLine[]
  hunks: DiffHunk[]
  /** 超大输入退化为整体替换时为 true，此时不提供 hunks */
  truncated: boolean
}

/**
 * 把扁平的差异行切成可独立接受/拒绝的 hunk。
 *
 * 连续的 add/del 归为一个变更段，段两侧各带 `context` 行未变更内容；
 * 两个段靠得太近（上下文重叠）时合并成一个 hunk —— 与 unified diff 的分块规则一致。
 *
 * truncated（超大文件退化结果）不做分组：那种情况下逐块审查没有意义，直接整体裁决。
 */
export function diffHunks(
  oldText: string,
  newText: string,
  context = 3
): HunkedDiff {
  const { lines, truncated } = diffLines(oldText, newText)
  if (truncated) return { lines, hunks: [], truncated }

  const changeIdx: number[] = []
  lines.forEach((l, idx) => {
    if (l.kind !== 'plain') changeIdx.push(idx)
  })
  if (changeIdx.length === 0) return { lines, hunks: [], truncated: false }

  // 1) 按上下文是否重叠把变更行聚成段
  const segments: Array<[number, number]> = []
  let segStart = changeIdx[0]
  let segEnd = changeIdx[0]
  for (const idx of changeIdx.slice(1)) {
    if (idx - segEnd <= 2 * context + 1) {
      segEnd = idx
    } else {
      segments.push([segStart, segEnd])
      segStart = idx
      segEnd = idx
    }
  }
  segments.push([segStart, segEnd])

  // 2) 扩上下文、切段、编号
  const annotated: DiffLine[] = lines.map((l) => ({ ...l }))
  const hunks: DiffHunk[] = []
  let hunkNo = 0

  for (const [cs, ce] of segments) {
    const start = Math.max(0, cs - context)
    const end = Math.min(lines.length - 1, ce + context)
    const id = `h${++hunkNo}`
    const hunkLines: DiffLine[] = []

    let oldStart = 0
    let newStart = 0
    let oldLines = 0
    let newLines = 0

    for (let k = start; k <= end; k++) {
      const line = { ...annotated[k], hunkId: id }
      annotated[k] = line
      hunkLines.push(line)
      if (line.oldNo !== undefined) {
        if (oldLines === 0) oldStart = line.oldNo
        oldLines++
      }
      if (line.newNo !== undefined) {
        if (newLines === 0) newStart = line.newNo
        newLines++
      }
    }

    // 纯新增（整段没有旧侧行号，例如空文件新增）：unified diff 约定旧侧起点为 0
    if (oldLines === 0) {
      oldStart = start > 0 ? lines[start - 1]?.oldNo ?? 0 : 0
    }
    if (newLines === 0) {
      newStart = start > 0 ? lines[start - 1]?.newNo ?? 0 : 0
    }

    hunks.push({ id, oldStart, oldLines, newStart, newLines, lines: hunkLines })
  }

  return { lines: annotated, hunks, truncated: false }
}

/**
 * 按 hunk 接受情况重建"新文件"文本。
 *
 * 规则：
 *   - plain 行始终保留；
 *   - add 行：所属 hunk 被接受才保留，否则丢弃；
 *   - del 行：所属 hunk 被接受则真的删除（不出现），被拒绝则把旧行留下来。
 *
 * 不变量（有测试守）：
 *   - 全部接受 → 严格等于 newText；
 *   - 全部拒绝 → 严格等于 oldText。
 */
export function rebuildText(
  lines: DiffLine[],
  acceptedHunkIds: ReadonlySet<string> | 'all',
  newTrailingNewline: boolean
): string {
  const out: string[] = []
  for (const l of lines) {
    if (l.kind === 'plain') {
      out.push(l.text)
    } else if (l.kind === 'add') {
      const keep = acceptedHunkIds === 'all' || (l.hunkId !== undefined && acceptedHunkIds.has(l.hunkId))
      if (keep) out.push(l.text)
    } else {
      // del：hunk 被接受意味着删除生效（不留）；拒绝则保留旧行
      const keepDeleted =
        acceptedHunkIds === 'all' || (l.hunkId !== undefined && acceptedHunkIds.has(l.hunkId))
      if (!keepDeleted) out.push(l.text)
    }
  }
  if (out.length === 0) return ''
  return out.join('\n') + (newTrailingNewline ? '\n' : '')
}

export function diffPreview(path: string, oldText: string, newText: string): DiffPreview {
  const hunked = diffHunks(oldText, newText)
  const { lines, hunks, truncated } = hunked
  let added = 0
  let removed = 0
  for (const l of lines) {
    if (l.kind === 'add') added++
    else if (l.kind === 'del') removed++
  }
  return { path, added, removed, lines, truncated, hunks }
}
