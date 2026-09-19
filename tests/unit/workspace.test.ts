import { mkdir, mkdtemp, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import { listTree } from '../../apps/desktop/src/main/workspace.js'

let root: string

/** 按相对路径造文件，中间目录自动补建 */
async function put(rel: string, body = 'x'): Promise<void> {
  const abs = join(root, rel)
  await mkdir(dirname(abs), { recursive: true })
  await writeFile(abs, body, 'utf8')
}

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'witseek-tree-'))
})

describe('listTree', () => {
  it('深路径的源码文件必须进树', async () => {
    // 回归守卫：MAX_DEPTH 曾是 6，而 app/src/main/java/com/xwt 已经是 depth 5，
    // 于是 schedule/ 及其下所有 .java 被整段截掉 ——
    // 界面上表现为 xwt 画着展开箭头却没有子项，真实源码文件一个都点不到。
    const deep = 'app/src/main/java/com/xwt/schedule/HolidayUtils.java'
    await put(deep)

    const { entries } = await listTree(root)
    expect(entries.map((e) => e.path)).toContain(deep)
    expect(entries.find((e) => e.path === deep)?.depth).toBe(7)
  })

  it('目录排在文件前面，同级按名字排', async () => {
    await put('b.txt')
    await put('a.txt')
    await put('zdir/inner.txt')

    const top = (await listTree(root)).entries.filter((e) => e.depth === 0)
    expect(top.map((e) => e.name)).toEqual(['zdir', 'a.txt', 'b.txt'])
  })

  it('隐藏文件与隐藏目录不进树', async () => {
    await put('.env')
    await put('.git/config')
    await put('keep.txt')

    const paths = (await listTree(root)).entries.map((e) => e.path)
    expect(paths).toEqual(['keep.txt'])
  })

  it('依赖与构建产物目录被跳过', async () => {
    await put('node_modules/pkg/index.js')
    await put('dist/bundle.js')
    await put('src/main.ts')

    const paths = (await listTree(root)).entries.map((e) => e.path)
    expect(paths).toEqual(['src', 'src/main.ts'])
  })

  it('超过 maxDepth 的分支不再展开', async () => {
    await put('a/b/c/d.txt')
    const { entries } = await listTree(root, 2)
    // a(0) b(1) 入树，c 在 depth 2，不该出现
    expect(entries.map((e) => e.path)).toEqual(['a', 'a/b'])
  })

  it('超过 maxEntries 时截断并置位标记', async () => {
    for (let i = 0; i < 5; i++) await put(`f${i}.txt`)
    const { entries, truncated } = await listTree(root, 12, 2)
    expect(entries).toHaveLength(2)
    expect(truncated).toBe(true)
  })

  it('未截断时标记为 false', async () => {
    await put('only.txt')
    expect((await listTree(root)).truncated).toBe(false)
  })

  it('目录也带 size 0 与正确的 kind', async () => {
    await put('src/main.ts', 'hello')
    const byPath = new Map((await listTree(root)).entries.map((e) => [e.path, e]))
    expect(byPath.get('src')?.kind).toBe('dir')
    expect(byPath.get('src')?.size).toBe(0)
    expect(byPath.get('src/main.ts')?.kind).toBe('file')
    expect(byPath.get('src/main.ts')?.size).toBe(5)
  })
})
