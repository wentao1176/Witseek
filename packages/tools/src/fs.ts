import { mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { ToolDefinition, ToolResult } from '@witseek/protocol'
import { displayPath, resolveInWorkspace } from './paths.js'

const MAX_READ_BYTES = 512 * 1024

function str(args: Record<string, unknown>, key: string): string {
  const v = args[key]
  if (typeof v !== 'string' || v.length === 0) {
    throw new Error(`参数 ${key} 必须是非空字符串`)
  }
  return v
}

export const readFileTool: ToolDefinition = {
  name: 'read_file',
  description: '读取工作区内某个文本文件的内容，可指定行范围。返回带行号的内容。',
  readOnly: true,
  parameters: {
    type: 'object',
    properties: {
      path: { type: 'string', description: '相对于工作区的文件路径' },
      offset: { type: 'number', description: '起始行（从 1 开始，可选）' },
      limit: { type: 'number', description: '读取行数（可选）' }
    },
    required: ['path']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const raw = str(args, 'path')
    const { abs, outside } = resolveInWorkspace(ctx.workspaceRoot, raw)
    const info = await stat(abs)
    if (!info.isFile()) return { ok: false, output: `${raw} 不是文件` }
    if (info.size > MAX_READ_BYTES) {
      return { ok: false, output: `文件过大（${info.size} 字节），超过 ${MAX_READ_BYTES} 上限` }
    }

    const text = await readFile(abs, 'utf8')
    const all = text.split('\n')
    const offset = Math.max(1, Number(args.offset ?? 1))
    const limit = args.limit === undefined ? all.length : Math.max(0, Number(args.limit))
    const slice = all.slice(offset - 1, offset - 1 + limit)

    const width = String(offset + slice.length - 1).length
    const body = slice
      .map((line, i) => `${String(offset + i).padStart(width, ' ')}\t${line}`)
      .join('\n')

    return {
      ok: true,
      output: body,
      meta: { path: displayPath(ctx.workspaceRoot, abs), lines: all.length, outside, bytes: info.size }
    }
  }
}

export const writeFileTool: ToolDefinition = {
  name: 'write_file',
  description: '把内容写入工作区内的文件，文件不存在则创建，存在则整体覆盖。',
  readOnly: false,
  parameters: {
    type: 'object',
    properties: {
      path: { type: 'string', description: '相对于工作区的文件路径' },
      content: { type: 'string', description: '要写入的完整内容' }
    },
    required: ['path', 'content']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const raw = str(args, 'path')
    const content = typeof args.content === 'string' ? args.content : ''
    const { abs, outside } = resolveInWorkspace(ctx.workspaceRoot, raw)

    await mkdir(dirname(abs), { recursive: true })
    await writeFile(abs, content, 'utf8')

    return {
      ok: true,
      output: `已写入 ${displayPath(ctx.workspaceRoot, abs)}（${Buffer.byteLength(content, 'utf8')} 字节）`,
      meta: { path: displayPath(ctx.workspaceRoot, abs), outside }
    }
  }
}

export type EditOutcome =
  | { ok: true; text: string; occurrences: number; applied: number }
  | { ok: false; error: string }

/**
 * 精确字符串替换的**纯函数**版本。
 *
 * 抽出来是为了让 UI 的 diff 预览和真正执行的替换走同一份逻辑。
 * 如果主进程自己再实现一遍替换规则，预览就可能与实际写入的结果不一致 ——
 * 那种"预览说改了 3 行、实际改了 1 行"的偏差比没有预览更糟。
 */
export function applyEdit(
  text: string,
  oldText: string,
  newText: string,
  replaceAll = false
): EditOutcome {
  if (oldText === '') return { ok: false, error: 'oldText 不能为空' }
  const occurrences = text.split(oldText).length - 1
  if (occurrences === 0) return { ok: false, error: '未找到待替换的原文' }
  if (occurrences > 1 && !replaceAll) {
    return {
      ok: false,
      error: `原文出现了 ${occurrences} 次，不唯一。请扩大上下文，或显式设置 replaceAll。`
    }
  }
  const applied = replaceAll ? occurrences : 1
  const next = replaceAll ? text.split(oldText).join(newText) : text.replace(oldText, newText)
  return { ok: true, text: next, occurrences, applied }
}

export const editFileTool: ToolDefinition = {
  name: 'edit_file',
  description:
    '对文件做精确字符串替换。默认要求 oldText 在文件中唯一出现，否则报错；如需替换全部请设 replaceAll。',
  readOnly: false,
  parameters: {
    type: 'object',
    properties: {
      path: { type: 'string', description: '相对于工作区的文件路径' },
      oldText: { type: 'string', description: '要被替换的原文（需与文件内容完全一致）' },
      newText: { type: 'string', description: '替换后的文本' },
      replaceAll: { type: 'boolean', description: '是否替换全部匹配（默认 false）' }
    },
    required: ['path', 'oldText', 'newText']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const raw = str(args, 'path')
    const oldText = str(args, 'oldText')
    const newText = typeof args.newText === 'string' ? args.newText : ''
    const replaceAll = args.replaceAll === true

    const { abs, outside } = resolveInWorkspace(ctx.workspaceRoot, raw)
    const text = await readFile(abs, 'utf8')

    const outcome = applyEdit(text, oldText, newText, replaceAll)
    if (!outcome.ok) {
      return { ok: false, output: `${outcome.error}（${raw}）` }
    }
    await writeFile(abs, outcome.text, 'utf8')

    const added = newText === '' ? 0 : newText.split('\n').length
    const removed = oldText === '' ? 0 : oldText.split('\n').length

    return {
      ok: true,
      output: `已修改 ${displayPath(ctx.workspaceRoot, abs)}（替换 ${outcome.applied} 处）`,
      meta: {
        path: displayPath(ctx.workspaceRoot, abs),
        outside,
        occurrences: outcome.applied,
        added,
        removed
      }
    }
  }
}

export const listDirTool: ToolDefinition = {
  name: 'list_dir',
  description: '列出工作区内某个目录的内容，可控制递归深度。',
  readOnly: true,
  parameters: {
    type: 'object',
    properties: {
      path: { type: 'string', description: '相对工作区的目录路径，默认为工作区根' },
      depth: { type: 'number', description: '递归深度，默认 2，最大 5' }
    },
    required: []
  },
  async execute(args, ctx): Promise<ToolResult> {
    const raw = typeof args.path === 'string' && args.path ? args.path : '.'
    const depth = Math.min(5, Math.max(1, Number(args.depth ?? 2)))
    const { abs, outside } = resolveInWorkspace(ctx.workspaceRoot, raw)

    const lines: string[] = []
    let count = 0

    async function walk(dir: string, level: number): Promise<void> {
      if (level > depth) return
      const entries = await readdir(dir, { withFileTypes: true })
      entries.sort((a, b) => {
        if (a.isDirectory() !== b.isDirectory()) return a.isDirectory() ? -1 : 1
        return a.name.localeCompare(b.name)
      })
      for (const e of entries) {
        if (e.name === 'node_modules' || e.name === '.git') continue
        count++
        lines.push(`${'  '.repeat(level - 1)}${e.isDirectory() ? '[D]' : '   '} ${e.name}`)
        if (e.isDirectory()) await walk(join(dir, e.name), level + 1)
      }
    }

    const info = await stat(abs)
    if (!info.isDirectory()) return { ok: false, output: `${raw} 不是目录` }
    await walk(abs, 1)

    return {
      ok: true,
      output: lines.join('\n') || '(空目录)',
      meta: { path: displayPath(ctx.workspaceRoot, abs), entries: count, outside }
    }
  }
}
