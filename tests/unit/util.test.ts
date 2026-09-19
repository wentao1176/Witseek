import { describe, expect, it } from 'vitest'
import type { FileEntry } from '@witseek/protocol'
import {
  AUTO_FOLD_MIN_ENTRIES,
  basename,
  defaultCollapsed,
  formatBytes,
  relativeTime,
  visibleTree
} from '../../apps/desktop/src/renderer/src/util.js'

function e(path: string, depth: number, kind: 'dir' | 'file' = 'file'): FileEntry {
  return { name: path.split('/').pop() ?? path, path, kind, size: 0, depth }
}

describe('visibleTree', () => {
  const tree = [
    e('app', 0, 'dir'),
    e('app/src', 1, 'dir'),
    e('app/src/Main.java', 2),
    e('app/build.gradle', 1),
    e('README.md', 0)
  ]

  it('没有折叠时原样返回', () => {
    expect(visibleTree(tree, new Set())).toHaveLength(5)
  })

  it('折叠目录会隐藏其后所有更深的条目', () => {
    const rows = visibleTree(tree, new Set(['app/src']))
    expect(rows.map((r) => r.path)).toEqual(['app', 'app/src', 'app/build.gradle', 'README.md'])
  })

  it('折叠顶层目录只留下它自己', () => {
    const rows = visibleTree(tree, new Set(['app']))
    expect(rows.map((r) => r.path)).toEqual(['app', 'README.md'])
  })

  it('隐藏范围在遇到同级条目时结束', () => {
    // 这是扁平结构最容易写错的地方：隐藏不能一路吃到结尾
    const rows = visibleTree(tree, new Set(['app/src']))
    expect(rows.some((r) => r.path === 'README.md')).toBe(true)
  })

  it('折叠不存在的路径没有副作用', () => {
    expect(visibleTree(tree, new Set(['nope']))).toHaveLength(5)
  })

  it('空树返回空数组', () => {
    expect(visibleTree([], new Set(['a']))).toEqual([])
  })
})

describe('defaultCollapsed', () => {
  it('小工程不折叠，全展开', () => {
    const small = [e('app', 0, 'dir'), e('app/src', 1, 'dir'), e('app/src/Main.java', 2)]
    expect(defaultCollapsed(small).size).toBe(0)
  })

  it('工程够大时折叠深层目录，保留前两层展开', () => {
    const big: FileEntry[] = [e('app', 0, 'dir'), e('app/src', 1, 'dir')]
    for (let i = 0; i < AUTO_FOLD_MIN_ENTRIES; i++) {
      big.push(e(`app/src/p${i}`, 2, 'dir'), e(`app/src/p${i}/Main.java`, 3))
    }

    const folded = defaultCollapsed(big)
    expect(folded.has('app')).toBe(false)
    expect(folded.has('app/src')).toBe(false)
    expect(folded.has('app/src/p0')).toBe(true)
    expect(folded.size).toBe(AUTO_FOLD_MIN_ENTRIES)
  })

  it('文件永远不进折叠集合', () => {
    const rows: FileEntry[] = []
    for (let i = 0; i < AUTO_FOLD_MIN_ENTRIES; i++) {
      rows.push(e(`p${i}`, 2, 'dir'), e(`p${i}/f.java`, 3))
    }

    const folded = defaultCollapsed(rows)
    expect(folded.size).toBe(AUTO_FOLD_MIN_ENTRIES)
    expect([...folded].some((p) => p.endsWith('.java'))).toBe(false)
  })

  it('阈值边界：刚好少一条就不折叠', () => {
    const rows: FileEntry[] = []
    for (let i = 0; i < AUTO_FOLD_MIN_ENTRIES - 1; i++) rows.push(e(`d${i}/x`, 2, 'dir'))
    expect(defaultCollapsed(rows).size).toBe(0)
  })
})

describe('relativeTime', () => {
  const now = Date.parse('2026-09-18T12:00:00.000Z')

  it('一分钟内显示刚刚', () => {
    expect(relativeTime('2026-09-18T11:59:30.000Z', now)).toBe('刚刚')
  })

  it('分钟级', () => {
    expect(relativeTime('2026-09-18T11:30:00.000Z', now)).toBe('30 分钟前')
  })

  it('小时级', () => {
    expect(relativeTime('2026-09-18T06:00:00.000Z', now)).toBe('6 小时前')
  })

  it('天级', () => {
    expect(relativeTime('2026-09-15T12:00:00.000Z', now)).toBe('3 天前')
  })

  it('非法时间串返回空串而不是 NaN', () => {
    expect(relativeTime('不是时间', now)).toBe('')
  })
})

describe('basename / formatBytes', () => {
  it('取路径末段', () => {
    expect(basename('app/src/Main.java')).toBe('Main.java')
    expect(basename('README.md')).toBe('README.md')
  })

  it('字节数按量级切换单位', () => {
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(2048)).toBe('2.0 KB')
    expect(formatBytes(3 * 1024 * 1024)).toBe('3.0 MB')
  })
})
