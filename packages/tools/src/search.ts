import { readdir, readFile, stat } from 'node:fs/promises'
import { join, relative } from 'node:path'
import type { ToolDefinition, ToolResult } from '@witseek/protocol'
import { globToRegExp } from './glob.js'
import { displayPath, resolveInWorkspace } from './paths.js'

const SKIP_DIRS = new Set(['node_modules', '.git', 'dist', 'out', '.cache', '.runtime', '.tools'])
const MAX_FILE_BYTES = 1024 * 1024

async function* walkFiles(root: string, maxFiles: number): AsyncGenerator<string> {
  let yielded = 0
  const stack: string[] = [root]
  while (stack.length) {
    const dir = stack.pop() as string
    let entries
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      continue
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name)) continue
        stack.push(join(dir, e.name))
      } else if (e.isFile()) {
        if (yielded++ >= maxFiles) return
        yield join(dir, e.name)
      }
    }
  }
}

export const globTool: ToolDefinition = {
  name: 'glob',
  description: '按 glob 模式查找文件。支持 ** * ? 与 {a,b}，例如 src/**/*.ts。',
  readOnly: true,
  parameters: {
    type: 'object',
    properties: {
      pattern: { type: 'string', description: 'glob 模式，相对工作区' },
      cwd: { type: 'string', description: '搜索起点，默认工作区根' },
      maxResults: { type: 'number', description: '最多返回条数，默认 200' }
    },
    required: ['pattern']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const pattern = typeof args.pattern === 'string' ? args.pattern : ''
    if (!pattern) return { ok: false, output: '缺少 pattern 参数' }
    const cwd = typeof args.cwd === 'string' && args.cwd ? args.cwd : '.'
    const maxResults = Math.max(1, Number(args.maxResults ?? 200))

    const { abs: root, outside } = resolveInWorkspace(ctx.workspaceRoot, cwd)
    const re = globToRegExp(pattern)
    const hits: string[] = []

    for await (const file of walkFiles(root, 20000)) {
      const rel = relative(root, file).split('\\').join('/')
      if (re.test(rel)) {
        hits.push(rel)
        if (hits.length >= maxResults) break
      }
    }
    hits.sort()

    return {
      ok: true,
      output: hits.length ? hits.join('\n') : '(无匹配)',
      meta: { count: hits.length, outside, pattern }
    }
  }
}

export const grepTool: ToolDefinition = {
  name: 'grep',
  description: '在文件内容中按正则搜索，返回文件、行号与匹配行。',
  readOnly: true,
  parameters: {
    type: 'object',
    properties: {
      pattern: { type: 'string', description: 'JavaScript 正则表达式' },
      glob: { type: 'string', description: '限定文件范围，默认 **/*' },
      cwd: { type: 'string', description: '搜索起点，默认工作区根' },
      ignoreCase: { type: 'boolean', description: '是否忽略大小写' },
      maxResults: { type: 'number', description: '最多返回条数，默认 100' }
    },
    required: ['pattern']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const pattern = typeof args.pattern === 'string' ? args.pattern : ''
    if (!pattern) return { ok: false, output: '缺少 pattern 参数' }

    let re: RegExp
    try {
      re = new RegExp(pattern, args.ignoreCase === true ? 'i' : '')
    } catch (e) {
      return { ok: false, output: `正则无效: ${(e as Error).message}` }
    }

    const fileGlob = typeof args.glob === 'string' && args.glob ? args.glob : '**/*'
    const cwd = typeof args.cwd === 'string' && args.cwd ? args.cwd : '.'
    const maxResults = Math.max(1, Number(args.maxResults ?? 100))

    const { abs: root, outside } = resolveInWorkspace(ctx.workspaceRoot, cwd)
    const fileRe = globToRegExp(fileGlob)
    const hits: string[] = []

    outer: for await (const file of walkFiles(root, 20000)) {
      const rel = relative(root, file).split('\\').join('/')
      if (!fileRe.test(rel)) continue

      let info
      try {
        info = await stat(file)
      } catch {
        continue
      }
      if (info.size > MAX_FILE_BYTES) continue

      let text: string
      try {
        text = await readFile(file, 'utf8')
      } catch {
        continue
      }
      if (text.includes('\u0000')) continue // 二进制

      const lines = text.split('\n')
      for (let i = 0; i < lines.length; i++) {
        if (re.test(lines[i])) {
          hits.push(`${rel}:${i + 1}: ${lines[i].trim().slice(0, 300)}`)
          if (hits.length >= maxResults) break outer
        }
      }
    }

    return {
      ok: true,
      output: hits.length ? hits.join('\n') : '(无匹配)',
      meta: { count: hits.length, outside, pattern }
    }
  }
}

export { displayPath }
