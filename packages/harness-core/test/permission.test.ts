import { describe, expect, it } from 'vitest'
import type { ToolDefinition } from '@witseek/protocol'
import { PermissionEngine, describeApproval } from '../src/permission.js'

const ro: ToolDefinition = {
  name: 'read_file',
  description: '',
  parameters: { type: 'object' },
  readOnly: true,
  execute: async () => ({ ok: true, output: '' })
}

const rw: ToolDefinition = {
  name: 'write_file',
  description: '',
  parameters: { type: 'object' },
  readOnly: false,
  execute: async () => ({ ok: true, output: '' })
}

const sh: ToolDefinition = { ...rw, name: 'run_command' }

describe('PermissionEngine', () => {
  it('只读工具在任何模式下都放行', () => {
    for (const mode of ['read-only', 'confirm', 'auto'] as const) {
      expect(new PermissionEngine(mode).verdict(ro, false)).toBe('allow')
    }
  })

  it('read-only 模式下写操作是拒绝而不是询问', () => {
    expect(new PermissionEngine('read-only').verdict(rw, false)).toBe('deny')
  })

  it('confirm 模式下写操作需要询问', () => {
    expect(new PermissionEngine('confirm').verdict(rw, false)).toBe('ask')
  })

  it('auto 模式下工作区内放行', () => {
    expect(new PermissionEngine('auto').verdict(rw, false)).toBe('allow')
  })

  it('auto 模式下越界仍然要询问', () => {
    // 工作区隔离是安全底线，auto 不能越过它
    expect(new PermissionEngine('auto').verdict(rw, true)).toBe('ask')
  })

  it('记住后免询问', () => {
    const e = new PermissionEngine('confirm')
    e.remember('write_file')
    expect(e.verdict(rw, false)).toBe('allow')
    e.forgetAll()
    expect(e.verdict(rw, false)).toBe('ask')
  })
})

describe('describeApproval', () => {
  it('为写文件生成摘要', () => {
    expect(describeApproval(rw, { path: 'a.txt' }, false).summary).toBe('写入文件 a.txt')
  })

  it('为命令生成摘要并截断长命令', () => {
    const long = 'x'.repeat(300)
    const s = describeApproval(sh, { command: long }, false).summary
    expect(s).toContain('执行命令')
    expect(s.length).toBeLessThan(200)
  })

  it('越界时加上警告', () => {
    expect(describeApproval(rw, { path: '/etc/x' }, true).summary).toContain('超出工作区')
  })
})
