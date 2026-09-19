import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { MockProvider, textTurn, toolTurn } from '@witseek/provider-deepseek'
import { createDefaultTools } from '@witseek/tools'
import type { AgentEvent } from '@witseek/protocol'
import { runAgent } from '../src/agent.js'
import { PermissionEngine } from '../src/permission.js'
import { ToolRegistry } from '../src/registry.js'

let root: string

beforeEach(async () => {
  root = await mkdtemp(join(tmpdir(), 'witseek-agent-'))
})

function baseOpts(provider: MockProvider, over: Partial<Parameters<typeof runAgent>[0]> = {}) {
  const events: AgentEvent[] = []
  return {
    events,
    opts: {
      provider,
      model: 'mock-model',
      registry: new ToolRegistry(createDefaultTools()),
      workspaceRoot: root,
      permission: new PermissionEngine('auto'),
      onEvent: (e: AgentEvent) => events.push(e),
      ...over
    }
  }
}

describe('runAgent', () => {
  it('跑通 读文件 → 改文件 → 结论 的闭环', async () => {
    await writeFile(join(root, 'a.txt'), 'foo\nbar\n', 'utf8')

    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'read_file', args: { path: 'a.txt' } }])
      if (turn === 1) {
        return toolTurn([{ name: 'edit_file', args: { path: 'a.txt', oldText: 'bar', newText: 'BAR' } }])
      }
      return textTurn('已把 bar 改成 BAR。')
    })

    const { opts, events } = baseOpts(provider)
    const result = await runAgent(opts, '把 bar 改成 BAR')

    expect(result.stopReason).toBe('completed')
    expect(result.steps).toBe(3)
    expect(result.finalText).toBe('已把 bar 改成 BAR。')
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('foo\nBAR\n')

    const toolNames = events.filter((e) => e.type === 'tool-start').map((e) => (e as { call: { name: string } }).call.name)
    expect(toolNames).toEqual(['read_file', 'edit_file'])
  })

  it('工具结果被回灌进消息，模型能看到', async () => {
    await writeFile(join(root, 'a.txt'), 'UNIQUE_CONTENT', 'utf8')

    let sawToolResult = false
    const provider = new MockProvider((req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'read_file', args: { path: 'a.txt' } }])
      sawToolResult = req.messages.some((m) => m.role === 'tool' && m.content.includes('UNIQUE_CONTENT'))
      return textTurn('ok')
    })

    await runAgent(baseOpts(provider).opts, '读一下')
    expect(sawToolResult).toBe(true)
  })

  it('未知工具不中断循环', async () => {
    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'no_such_tool', args: {} }])
      return textTurn('我换个方式。')
    })
    const { opts, events } = baseOpts(provider)
    const result = await runAgent(opts, 'x')

    expect(result.stopReason).toBe('completed')
    const end = events.find((e) => e.type === 'tool-end')
    expect((end as { result: { ok: boolean; output: string } }).result.output).toMatch(/未知工具/)
  })

  it('参数不是合法 JSON 时把错误回给模型', async () => {
    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) {
        return [{ type: 'tool-call', call: { id: 'c1', name: 'read_file', arguments: '{bad json' } }, { type: 'done', finishReason: 'tool_calls' }]
      }
      return textTurn('收到，我修正参数。')
    })
    const { opts, events } = baseOpts(provider)
    const result = await runAgent(opts, 'x')

    expect(result.stopReason).toBe('completed')
    const end = events.find((e) => e.type === 'tool-end')
    expect((end as { result: { output: string } }).result.output).toMatch(/JSON/)
  })

  it('权限拒绝时不执行工具', async () => {
    await writeFile(join(root, 'a.txt'), 'orig', 'utf8')

    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) {
        return toolTurn([{ name: 'write_file', args: { path: 'a.txt', content: 'HACKED' } }])
      }
      return textTurn('好的，我不改了。')
    })

    const { opts, events } = baseOpts(provider, {
      permission: new PermissionEngine('confirm'),
      approver: async () => 'deny'
    })
    const result = await runAgent(opts, 'x')

    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('orig')
    const approval = events.find((e) => e.type === 'approval')
    expect((approval as { decision: string }).decision).toBe('deny')
    expect(result.stopReason).toBe('completed')
  })

  it('approve-always 之后同工具免询问', async () => {
    await writeFile(join(root, 'a.txt'), 'orig', 'utf8')
    const approver = vi.fn(async () => 'approve-always' as const)

    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'write_file', args: { path: 'a.txt', content: 'one' } }])
      if (turn === 1) return toolTurn([{ name: 'write_file', args: { path: 'a.txt', content: 'two' } }])
      return textTurn('done')
    })

    const { opts } = baseOpts(provider, { permission: new PermissionEngine('confirm'), approver })
    await runAgent(opts, 'x')

    expect(approver).toHaveBeenCalledTimes(1)
    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('two')
  })

  it('read-only 模式下写操作被直接拒绝', async () => {
    await writeFile(join(root, 'a.txt'), 'orig', 'utf8')
    const provider = new MockProvider((_req, turn) => {
      if (turn === 0) return toolTurn([{ name: 'write_file', args: { path: 'a.txt', content: 'X' } }])
      return textTurn('被拒绝了。')
    })
    const { opts, events } = baseOpts(provider, { permission: new PermissionEngine('read-only') })
    await runAgent(opts, 'x')

    expect(await readFile(join(root, 'a.txt'), 'utf8')).toBe('orig')
    // read-only 是拒绝而非询问，不应产生审批事件
    expect(events.some((e) => e.type === 'approval')).toBe(false)
  })

  it('达到步数上限会停下', async () => {
    const provider = new MockProvider(() => toolTurn([{ name: 'list_dir', args: {} }]))
    const { opts } = baseOpts(provider, { maxSteps: 3 })
    const result = await runAgent(opts, 'x')
    expect(result.steps).toBe(3)
    expect(result.stopReason).toBe('max-steps')
  })

  it('provider 抛错时返回 error 而不是崩溃', async () => {
    const provider = new MockProvider(() => {
      throw new Error('网络断了')
    })
    const { opts } = baseOpts(provider)
    const result = await runAgent(opts, 'x')
    expect(result.stopReason).toBe('error')
    expect(result.error).toContain('网络断了')
  })

  it('已取消的信号不会开始新一轮', async () => {
    const provider = new MockProvider(() => textTurn('不该被调用'))
    const ac = new AbortController()
    ac.abort()
    const { opts } = baseOpts(provider, { signal: ac.signal })
    const result = await runAgent(opts, 'x')
    expect(result.stopReason).toBe('aborted')
    expect(provider.turn).toBe(0)
  })

  it('reasoning 事件与 content 事件分开', async () => {
    const provider = new MockProvider(() => textTurn('答案', '思考过程'))
    const { opts, events } = baseOpts(provider)
    await runAgent(opts, 'x')

    const kinds = events.filter((e) => e.type === 'reasoning' || e.type === 'content').map((e) => e.type)
    expect(kinds).toEqual(['reasoning', 'content'])
  })

  it('system prompt 里带上工作区路径与工具清单', async () => {
    let sys = ''
    const provider = new MockProvider((req) => {
      sys = req.messages[0].content
      return textTurn('ok')
    })
    await runAgent(baseOpts(provider).opts, 'x')
    expect(sys).toContain(root)
    expect(sys).toContain('read_file')
  })

  it('history 会被带入上下文', async () => {
    let count = 0
    const provider = new MockProvider((req) => {
      count = req.messages.length
      return textTurn('ok')
    })
    const { opts } = baseOpts(provider, {
      history: [
        { role: 'user', content: '上一轮问题' },
        { role: 'assistant', content: '上一轮回答' }
      ]
    })
    await runAgent(opts, '这一轮')
    expect(count).toBe(4) // system + 2 历史 + 当前
  })
})
