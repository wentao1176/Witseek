import { mkdtemp } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import type { ToolContext } from '@witseek/protocol'
import { runCommandTool } from '../src/shell.js'

let ctx: ToolContext

beforeEach(async () => {
  ctx = { workspaceRoot: await mkdtemp(join(tmpdir(), 'witseek-sh-')) }
})

describe('run_command', () => {
  it('成功命令返回退出码 0', async () => {
    const r = await runCommandTool.execute({ command: 'echo hello' }, ctx)
    expect(r.ok).toBe(true)
    expect(r.output).toContain('hello')
    expect(r.meta?.exitCode).toBe(0)
  })

  it('失败命令 ok=false 但仍有输出', async () => {
    const r = await runCommandTool.execute({ command: 'exit 3' }, ctx)
    expect(r.ok).toBe(false)
    expect(r.meta?.exitCode).toBe(3)
  })

  it('stderr 被捕获', async () => {
    const r = await runCommandTool.execute({ command: 'echo oops 1>&2' }, ctx)
    expect(r.output).toContain('stderr')
    expect(r.output).toContain('oops')
  })

  it('超时被杀掉', async () => {
    const r = await runCommandTool.execute({ command: 'sleep 5', timeoutMs: 800 }, ctx)
    expect(r.ok).toBe(false)
    expect(r.meta?.timedOut).toBe(true)
  }, 10_000)

  it('缺少 command 返回失败', async () => {
    const r = await runCommandTool.execute({}, ctx)
    expect(r.ok).toBe(false)
  })
})
