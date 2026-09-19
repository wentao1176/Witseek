import { describe, expect, it } from 'vitest'
import { diffLines, diffPreview, splitLines } from '../src/diff.js'

describe('splitLines', () => {
  it('空串得到零行', () => {
    expect(splitLines('')).toEqual([])
  })

  it('末尾换行不算多出一行空行', () => {
    // 这是最容易出错的地方：若把末尾 \n 当成分隔，每个正常文件都会多一条假差异
    expect(splitLines('a\nb\n')).toEqual(['a', 'b'])
    expect(splitLines('a\nb')).toEqual(['a', 'b'])
  })
})

describe('diffLines', () => {
  it('完全相同则全是 plain', () => {
    const { lines } = diffLines('a\nb', 'a\nb')
    expect(lines.every((l) => l.kind === 'plain')).toBe(true)
    expect(lines).toHaveLength(2)
  })

  it('单行替换标成 del + add', () => {
    const { lines } = diffLines('a\nb\nc', 'a\nB\nc')
    expect(lines.map((l) => l.kind)).toEqual(['plain', 'del', 'add', 'plain'])
  })

  it('插入一行不会把后续行全标成变更', () => {
    // 这正是选 LCS 而非按行号硬比的原因
    const { lines } = diffLines('a\nb\nc', 'a\nx\nb\nc')
    const kinds = lines.map((l) => l.kind)
    expect(kinds).toEqual(['plain', 'add', 'plain', 'plain'])
    expect(lines.filter((l) => l.kind === 'plain')).toHaveLength(3)
  })

  it('删除一行同理', () => {
    const { lines } = diffLines('a\nx\nb\nc', 'a\nb\nc')
    expect(lines.map((l) => l.kind)).toEqual(['plain', 'del', 'plain', 'plain'])
  })

  it('行号在两侧各自连续', () => {
    const { lines } = diffLines('a\nb\nc', 'a\nB\nc')
    const del = lines.find((l) => l.kind === 'del')
    const add = lines.find((l) => l.kind === 'add')
    expect(del?.oldNo).toBe(2)
    expect(del?.newNo).toBeUndefined()
    expect(add?.newNo).toBe(2)
    expect(add?.oldNo).toBeUndefined()
  })

  it('从空文件新增内容', () => {
    const { lines } = diffLines('', 'a\nb')
    expect(lines.map((l) => l.kind)).toEqual(['add', 'add'])
  })

  it('清空文件内容', () => {
    const { lines } = diffLines('a\nb', '')
    expect(lines.map((l) => l.kind)).toEqual(['del', 'del'])
  })

  it('超大输入退化为整体替换而不是卡死', () => {
    const big = Array.from({ length: 3000 }, (_, i) => `line ${i}`).join('\n')
    const other = Array.from({ length: 3000 }, (_, i) => `other ${i}`).join('\n')
    const { lines, truncated } = diffLines(big, other)
    expect(truncated).toBe(true)
    expect(lines).toHaveLength(6000)
  })
})

describe('diffPreview', () => {
  it('统计增删行数', () => {
    const p = diffPreview('a.ts', 'a\nb\nc', 'a\nB\nc\nd')
    expect(p.path).toBe('a.ts')
    expect(p.added).toBe(2)
    expect(p.removed).toBe(1)
    expect(p.truncated).toBe(false)
  })

  it('无变化时增删都是 0', () => {
    const p = diffPreview('a.ts', 'same', 'same')
    expect(p.added).toBe(0)
    expect(p.removed).toBe(0)
  })
})
