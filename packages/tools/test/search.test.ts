import { mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import type { ToolContext } from '@witseek/protocol'
import { globTool, grepTool } from '../src/search.js'

let root: string
let ctx: ToolContext

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'witseek-search-'))
  await writeFile(join(root, 'a.ts'), 'const x = 1\nexport default x\n', 'utf8')
  // sub/ 必须显式创建：writeFile 不会补建中间路径。
  // 少了这一行，7 个用例会一起报 ENOENT，看起来像实现挂了，其实只是夹具缺目录。
  await mkdir(join(root, 'sub'), { recursive: true })
  await writeFile(join(root, 'sub/b.ts'), 'const y = 2\n', 'utf8')
  await writeFile(join(root, 'c.md'), '# title\nconst inMarkdown = 3\n', 'utf8')
  // ctx 必须赋值。漏了这一行，只有"提前返回"的用例（缺 pattern、非法正则）
  // 能侥幸通过，其余全在 ctx.workspaceRoot 上抛 TypeError —— 很容易被误读成实现 bug。
  ctx = { workspaceRoot: root }
})

describe('glob 工具', () => {
  it('按扩展名查找', async () => {
    const r = await globTool.execute({ pattern: '**/*.ts' }, ctx)
    expect(r.ok).toBe(true)
    expect(r.output).toContain('a.ts')
    expect(r.output).toContain('sub/b.ts')
    expect(r.output).not.toContain('c.md')
  })

  it('无匹配时返回提示而非空串', async () => {
    const r = await globTool.execute({ pattern: '**/*.zzz' }, ctx)
    expect(r.output).toBe('(无匹配)')
  })

  it('缺少 pattern 时返回失败', async () => {
    const r = await globTool.execute({}, ctx)
    expect(r.ok).toBe(false)
  })
})

describe('grep 工具', () => {
  it('返回文件与行号', async () => {
    const r = await grepTool.execute({ pattern: 'const', glob: '**/*.ts' }, ctx)
    expect(r.ok).toBe(true)
    expect(r.output).toContain('a.ts:1:')
    expect(r.output).toContain('sub/b.ts:1:')
    expect(r.output).not.toContain('c.md')
  })

  it('glob 限定生效', async () => {
    const r = await grepTool.execute({ pattern: 'const', glob: '**/*.md' }, ctx)
    expect(r.output).toContain('c.md:2:')
  })

  it('非法正则返回失败而不是抛错', async () => {
    const r = await grepTool.execute({ pattern: '([' }, ctx)
    expect(r.ok).toBe(false)
    expect(r.output).toMatch(/正则/)
  })

  it('忽略大小写', async () => {
    const noCase = await grepTool.execute({ pattern: 'CONST', glob: '**/*.ts' }, ctx)
    expect(noCase.output).toBe('(无匹配)')
    const withCase = await grepTool.execute({ pattern: 'CONST', glob: '**/*.ts', ignoreCase: true }, ctx)
    expect(withCase.output).toContain('a.ts:1:')
  })
})
