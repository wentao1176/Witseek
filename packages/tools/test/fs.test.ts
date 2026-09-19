import { mkdir, mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import type { ToolContext } from '@witseek/protocol'
import { applyEdit, editFileTool, listDirTool, readFileTool, writeFileTool } from '../src/fs.js'
import { resolveInWorkspace } from '../src/paths.js'

let root: string
let ctx: ToolContext

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'witseek-fs-'))
  ctx = { workspaceRoot: root }
})

afterEach(() => {
  // 临时目录由系统回收
})

describe('resolveInWorkspace', () => {
  it('识别工作区内的相对路径', () => {
    expect(resolveInWorkspace('/w', 'a/b.txt').outside).toBe(false)
  })

  it('识别越界路径', () => {
    expect(resolveInWorkspace('/w', '../outside.txt').outside).toBe(true)
    expect(resolveInWorkspace('/w', '/etc/passwd').outside).toBe(true)
  })

  it('不会被 a/../.. 之类的绕法骗过', () => {
    expect(resolveInWorkspace('/w/sub', '../../x').outside).toBe(true)
  })
})

describe('read_file', () => {
  it('返回带行号的内容', async () => {
    await writeFile(join(root, 'a.txt'), 'l1\nl2\nl3', 'utf8')
    const r = await readFileTool.execute({ path: 'a.txt' }, ctx)
    expect(r.ok).toBe(true)
    expect(r.output).toContain('1\tl1')
    expect(r.output).toContain('3\tl3')
  })

  it('支持 offset / limit', async () => {
    await writeFile(join(root, 'a.txt'), 'l1\nl2\nl3\nl4', 'utf8')
    const r = await readFileTool.execute({ path: 'a.txt', offset: 2, limit: 2 }, ctx)
    expect(r.output).toContain('2\tl2')
    expect(r.output).toContain('3\tl3')
    expect(r.output).not.toContain('l4')
  })

  it('文件不存在时报错而不是抛出', async () => {
    await expect(readFileTool.execute({ path: 'nope.txt' }, ctx)).rejects.toThrow()
  })

  it('缺少 path 参数时报错', async () => {
    await expect(readFileTool.execute({}, ctx)).rejects.toThrow(/path/)
  })
})

describe('write_file', () => {
  it('自动创建父目录', async () => {
    const r = await writeFileTool.execute({ path: 'deep/nested/x.txt', content: 'hi' }, ctx)
    expect(r.ok).toBe(true)
    expect(await readFile(join(root, 'deep/nested/x.txt'), 'utf8')).toBe('hi')
  })
})

describe('edit_file', () => {
  it('唯一匹配时替换成功', async () => {
    await writeFile(join(root, 'a.txt'), 'foo\nbar\nbaz', 'utf8')
    const r = await editFileTool.execute({ path: 'a.txt', oldText: 'bar', newText: 'BAR' }, ctx)
    expect(r.ok).toBe(true)
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('foo\nBAR\nbaz')
  })

  it('多处匹配且未指定 replaceAll 时拒绝', async () => {
    await writeFile(join(root, 'a.txt'), 'x\nx\nx', 'utf8')
    const r = await editFileTool.execute({ path: 'a.txt', oldText: 'x', newText: 'y' }, ctx)
    expect(r.ok).toBe(false)
    expect(r.output).toMatch(/3 次/)
    // 确认没有写坏文件
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('x\nx\nx')
  })

  it('replaceAll 时全部替换', async () => {
    await writeFile(join(root, 'a.txt'), 'x\nx\nx', 'utf8')
    const r = await editFileTool.execute({ path: 'a.txt', oldText: 'x', newText: 'y', replaceAll: true }, ctx)
    expect(r.ok).toBe(true)
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('y\ny\ny')
  })

  it('找不到原文时返回失败而非抛错', async () => {
    await writeFile(join(root, 'a.txt'), 'abc', 'utf8')
    const r = await editFileTool.execute({ path: 'a.txt', oldText: 'zzz', newText: 'q' }, ctx)
    expect(r.ok).toBe(false)
  })
})

describe('list_dir', () => {
  it('目录在前，且跳过 node_modules', async () => {
    // 夹具必须自己建父目录：node:fs 的 writeFile 不会补建中间路径，
    // 早先漏了 mkdir，报的是 ENOENT 而不是断言失败，很容易误判成实现有问题。
    await mkdir(join(root, 'zdir'), { recursive: true })
    await writeFile(join(root, 'b.txt'), '', 'utf8')
    await writeFile(join(root, 'a.txt'), '', 'utf8')
    await mkdir(join(root, 'node_modules'), { recursive: true })
    await writeFile(join(root, 'node_modules/x.txt'), '', 'utf8')
    const r = await listDirTool.execute({ path: '.', depth: 1 }, ctx)
    expect(r.output).not.toContain('node_modules')
    // zdir 字典序排在 a.txt / b.txt 之后，却必须显示在它们前面，这才叫"目录在前"
    expect(r.output.indexOf('zdir')).toBeLessThan(r.output.indexOf('a.txt'))
  })
})

describe('applyEdit', () => {
  // 这是 edit_file 的纯函数内核。UI 的 diff 预览直接调它，
  // 所以必须保证"预览所依据的替换"和"真正写入的替换"完全一致。
  it('唯一匹配时替换并给出结果文本', () => {
    const r = applyEdit('a\nb\nc', 'b', 'B')
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.text).toBe('a\nB\nc')
    expect(r.applied).toBe(1)
  })

  it('多处匹配且未开 replaceAll 时拒绝，并报出出现次数', () => {
    const r = applyEdit('x\nx\nx', 'x', 'y')
    expect(r.ok).toBe(false)
    if (r.ok) return
    expect(r.error).toContain('3')
  })

  it('replaceAll 时全部替换', () => {
    const r = applyEdit('x\nx\nx', 'x', 'y', true)
    expect(r.ok).toBe(true)
    if (!r.ok) return
    expect(r.text).toBe('y\ny\ny')
    expect(r.applied).toBe(3)
  })

  it('找不到原文时失败而不是原样返回', () => {
    const r = applyEdit('abc', 'zzz', 'y')
    expect(r.ok).toBe(false)
  })

  it('oldText 为空视为非法输入', () => {
    // 空串会被 split 成"每个字符之间"，能匹配出 len+1 处，
    // 若不拦下来会得到一个看似成功但毫无意义的替换
    const r = applyEdit('abc', '', 'y')
    expect(r.ok).toBe(false)
  })

  it('与 edit_file 工具的执行结果一致', async () => {
    const original = 'line1\nline2\nline3\n'
    await writeFile(join(root, 'sample.txt'), original, 'utf8')
    const pure = applyEdit(original, 'line2', 'LINE-TWO')
    expect(pure.ok).toBe(true)
    if (!pure.ok) return

    await editFileTool.execute({ path: 'sample.txt', oldText: 'line2', newText: 'LINE-TWO' }, ctx)
    expect(await readFile(join(root, 'sample.txt'), 'utf8')).toBe(pure.text)
  })
})
