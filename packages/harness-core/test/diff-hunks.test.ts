import { describe, expect, it } from 'vitest'
import { diffHunks, diffLines, rebuildText } from '../src/diff.js'

describe('diffHunks 分块', () => {
  it('两处相隔很远的改动被切成两个 hunk', () => {
    const oldText = Array.from({ length: 40 }, (_, i) => `line${i}`).join('\n')
    const newLines = Array.from({ length: 40 }, (_, i) => `line${i}`)
    newLines[2] = 'CHANGED_TOP'
    newLines[35] = 'CHANGED_BOTTOM'
    const newText = newLines.join('\n')

    const { hunks } = diffHunks(oldText, newText)
    expect(hunks.length).toBe(2)
    expect(hunks[0].id).not.toBe(hunks[1].id)
    // 每个 hunk 的行都带自己的 hunkId
    for (const l of hunks[0].lines) {
      if (l.kind !== 'plain') expect(l.hunkId).toBe(hunks[0].id)
    }
  })

  it('相邻改动（上下文重叠）合并为一个 hunk', () => {
    const oldText = ['a', 'b', 'c', 'd', 'e'].join('\n')
    const newText = ['a', 'B', 'C', 'd', 'e'].join('\n')
    const { hunks } = diffHunks(oldText, newText)
    expect(hunks.length).toBe(1)
  })

  it('没有变更时返回空 hunk 列表', () => {
    const text = 'a\nb\nc\n'
    const { hunks, lines } = diffHunks(text, text)
    expect(hunks).toHaveLength(0)
    expect(lines.every((l) => l.kind === 'plain')).toBe(true)
  })

  it('hunk 头行号符合 unified diff 语义', () => {
    const oldText = ['a', 'b', 'c', 'd', 'e'].join('\n')
    const newText = ['a', 'b', 'c2', 'c3', 'd', 'e'].join('\n')
    const { hunks } = diffHunks(oldText, newText, 1)
    expect(hunks.length).toBe(1)
    const h = hunks[0]
    // oldStart 从 1 开始；oldLines/newLines 为该块（含上下文）覆盖的行数
    expect(h.oldStart).toBeGreaterThanOrEqual(1)
    expect(h.newStart).toBeGreaterThanOrEqual(1)
    expect(h.newLines).toBeGreaterThan(h.oldLines)
  })
})

describe('rebuildText 逐块重建', () => {
  it('全部接受严格等于新文本（含尾换行）', () => {
    const oldText = 'one\ntwo\nthree\n'
    const newText = 'one\nTWO\nthree\nfour\n'
    const { lines, hunks } = diffHunks(oldText, newText)
    const rebuilt = rebuildText(lines, new Set(hunks.map((h) => h.id)), true)
    expect(rebuilt).toBe(newText)
  })

  it('全部拒绝严格等于旧文本', () => {
    const oldText = 'one\ntwo\nthree\n'
    const newText = 'one\nTWO\nthree\nfour\n'
    const { lines } = diffHunks(oldText, newText)
    const rebuilt = rebuildText(lines, new Set(), true)
    expect(rebuilt).toBe(oldText)
  })

  it("'all' 与全选集合结果一致", () => {
    const oldText = 'a\nb\nc\n'
    const newText = 'a\nB\nc\n'
    const { lines, hunks } = diffHunks(oldText, newText)
    expect(rebuildText(lines, 'all', true)).toBe(
      rebuildText(lines, new Set(hunks.map((h) => h.id)), true)
    )
  })

  it('只接受第二个 hunk 时，第一个改动被还原', () => {
    const oldText = Array.from({ length: 40 }, (_, i) => `line${i}`).join('\n')
    const newLines = Array.from({ length: 40 }, (_, i) => `line${i}`)
    newLines[2] = 'CHANGED_TOP'
    newLines[35] = 'CHANGED_BOTTOM'
    const newText = newLines.join('\n')

    const { lines, hunks } = diffHunks(oldText, newText)
    expect(hunks.length).toBe(2)
    // 只接受底部那块
    const rebuilt = rebuildText(lines, new Set([hunks[1].id]), false)
    expect(rebuilt).toContain('line2') // 顶部改动被还原
    expect(rebuilt).not.toContain('CHANGED_TOP')
    expect(rebuilt).toContain('CHANGED_BOTTOM') // 底部改动生效
  })

  it('纯新增文件：拒绝唯一 hunk 得到空文件', () => {
    const oldText = ''
    const newText = 'brand\nnew\nfile\n'
    const { lines, hunks } = diffHunks(oldText, newText)
    expect(hunks.length).toBe(1)
    expect(rebuildText(lines, new Set(), true)).toBe('')
    expect(rebuildText(lines, 'all', true)).toBe(newText)
  })

  it('无尾换行的文件重建后仍无尾换行', () => {
    const oldText = 'a\nb'
    const newText = 'a\nB'
    const { lines } = diffHunks(oldText, newText)
    const rebuilt = rebuildText(lines, 'all', false)
    expect(rebuilt).toBe(newText)
    expect(rebuilt.endsWith('\n')).toBe(false)
  })

  it('与底层 diffLines 的行数统计一致', () => {
    const oldText = 'x\ny\nz\n'
    const newText = 'x\nY\nz\n'
    const flat = diffLines(oldText, newText)
    const hunked = diffHunks(oldText, newText)
    expect(hunked.lines.length).toBe(flat.lines.length)
  })
})
