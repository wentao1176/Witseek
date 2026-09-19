import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import { MockProvider, textTurn, toolTurn } from '@witseek/provider-deepseek'
import type { AgentEvent, AgentStatus, ApprovalPrompt, ModelProvider } from '@witseek/protocol'
import { AgentHost, type HostSink } from '../../apps/desktop/src/main/host.js'

/** 把 sink 推出来的东西全收集下来，便于断言顺序与内容 */
class Recorder implements HostSink {
  events: AgentEvent[] = []
  approvals: ApprovalPrompt[] = []
  statuses: AgentStatus[] = []

  event(e: AgentEvent): void {
    this.events.push(e)
  }
  approval(p: ApprovalPrompt): void {
    this.approvals.push(p)
  }
  status(s: AgentStatus): void {
    this.statuses.push(s)
  }

  get types(): string[] {
    return this.events.map((e) => e.type)
  }
}

function makeHost(
  ws: string,
  sink: Recorder,
  provider: ModelProvider,
  autoApprove = true
): AgentHost {
  return new AgentHost({
    workspaceRoot: ws,
    provider,
    model: 'mock-model',
    sessionsDir: join(ws, 'sessions'),
    sink,
    autoApprove
  })
}

/** 轮询等待条件成立，避免用固定 sleep 造成偶发失败 */
async function waitFor(cond: () => boolean, timeoutMs = 3000): Promise<void> {
  const started = Date.now()
  while (!cond()) {
    if (Date.now() - started > timeoutMs) throw new Error('等待超时')
    await new Promise((r) => setTimeout(r, 10))
  }
}

let ws: string

beforeEach(async () => {
  ws = await mkdtemp(join(tmpdir(), 'witseek-host-'))
})

describe('AgentHost 事件流', () => {
  it('纯文本回答会依次发出 step-start / content / done', async () => {
    const sink = new Recorder()
    const provider = new MockProvider(() => textTurn('好的', '先想一想'))
    const host = makeHost(ws, sink, provider)

    await host.send('你好')

    expect(sink.types).toContain('step-start')
    expect(sink.types).toContain('reasoning')
    expect(sink.types).toContain('content')
    // done 必须是最后一个 —— 界面靠它把"运行中"改回"空闲"
    expect(sink.types[sink.types.length - 1]).toBe('done')
  })

  it('done 之前所有事件都已发出，且 done 只出现一次', async () => {
    const sink = new Recorder()
    const provider = new MockProvider(() => textTurn('ok'))
    const host = makeHost(ws, sink, provider)

    await host.send('你好')

    expect(sink.types.filter((t) => t === 'done')).toHaveLength(1)
  })

  it('运行前后状态被推送，running 会回到 false', async () => {
    const sink = new Recorder()
    const provider = new MockProvider(() => textTurn('ok'))
    const host = makeHost(ws, sink, provider)

    await host.send('你好')

    expect(sink.statuses.length).toBeGreaterThanOrEqual(2)
    expect(sink.statuses[0].running).toBe(true)
    expect(sink.statuses[sink.statuses.length - 1].running).toBe(false)
  })
})

describe('AgentHost 审批', () => {
  it('写操作会先弹审批请求，批准后才真正落盘', async () => {
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'write_file', args: { path: 'a.txt', content: 'hi' } }])
        : textTurn('写完了')
    )
    const host = makeHost(ws, sink, provider, false)

    const running = host.send('写个文件')
    await waitFor(() => sink.approvals.length > 0)

    expect(sink.approvals[0].tool).toBe('write_file')
    expect(sink.approvals[0].summary).toContain('a.txt')

    // 还没裁决，文件必须不存在 —— 审批要是没拦住，这一步就会挂
    await expect(readFile(join(ws, 'a.txt'), 'utf8')).rejects.toThrow()

    host.resolveApproval(sink.approvals[0].id, 'approve')
    await running

    expect(await readFile(join(ws, 'a.txt'), 'utf8')).toBe('hi')
    const approvalEvent = sink.events.find((e) => e.type === 'approval')
    expect(approvalEvent && approvalEvent.type === 'approval' && approvalEvent.decision).toBe(
      'approve'
    )
  })

  it('拒绝后文件不被写入，且工具结果标记为失败', async () => {
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'write_file', args: { path: 'b.txt', content: 'x' } }])
        : textTurn('好')
    )
    const host = makeHost(ws, sink, provider, false)

    const running = host.send('写个文件')
    await waitFor(() => sink.approvals.length > 0)
    host.resolveApproval(sink.approvals[0].id, 'deny')
    await running

    await expect(readFile(join(ws, 'b.txt'), 'utf8')).rejects.toThrow()
    const toolEnd = sink.events.find((e) => e.type === 'tool-end')
    expect(toolEnd && toolEnd.type === 'tool-end' && toolEnd.result.ok).toBe(false)
  })

  it('edit_file 会带上 diff 预览', async () => {
    await writeFile(join(ws, 'c.txt'), 'one\ntwo\nthree\n', 'utf8')
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([
            { name: 'edit_file', args: { path: 'c.txt', oldText: 'two', newText: 'TWO\n2.5' } }
          ])
        : textTurn('改完了')
    )
    const host = makeHost(ws, sink, provider, false)

    const running = host.send('改一下')
    await waitFor(() => sink.approvals.length > 0)

    const diff = sink.approvals[0].diff
    expect(diff).toBeDefined()
    expect(diff?.path).toBe('c.txt')
    expect(diff?.added).toBe(2)
    expect(diff?.removed).toBe(1)
    // 未变更的行要保留为 plain，否则用户看不出改动的上下文
    expect(diff?.lines.some((l) => l.kind === 'plain')).toBe(true)

    host.resolveApproval(sink.approvals[0].id, 'approve')
    await running
    expect(await readFile(join(ws, 'c.txt'), 'utf8')).toBe('one\nTWO\n2.5\nthree\n')
  })

  it('只读工具不触发审批', async () => {
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'read_file', args: { path: 'nonexistent.txt' } }])
        : textTurn('读不到')
    )
    const host = makeHost(ws, sink, provider, false)

    await host.send('读一下')

    expect(sink.approvals).toHaveLength(0)
  })

  it('dispose 会把挂起的审批判为拒绝，不让 Promise 永远悬着', async () => {
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'write_file', args: { path: 'd.txt', content: 'x' } }])
        : textTurn('好')
    )
    const host = makeHost(ws, sink, provider, false)

    const running = host.send('写')
    await waitFor(() => sink.approvals.length > 0)

    host.dispose()
    // 若 dispose 没处理挂起的审批，这里会一直等到 5 分钟超时
    await running

    await expect(readFile(join(ws, 'd.txt'), 'utf8')).rejects.toThrow()
  })

  it('对未知 id 裁决返回 false 而不是抛错', () => {
    const sink = new Recorder()
    const host = makeHost(ws, sink, new MockProvider(() => textTurn('x')))
    expect(host.resolveApproval('不存在', 'approve')).toBe(false)
  })
})

describe('AgentHost 会话', () => {
  it('发送后会话落盘，可被 listSessions 读到', async () => {
    const sink = new Recorder()
    const provider = new MockProvider(() => textTurn('收到'))
    const host = makeHost(ws, sink, provider)

    await host.send('第一个问题')

    const list = await host.listSessions()
    expect(list).toHaveLength(1)
    expect(list[0].title).toContain('第一个问题')
    expect(list[0].messages).toBeGreaterThan(0)
  })

  it('多轮对话会把历史带上，模型能看到上一轮', async () => {
    const sink = new Recorder()
    const seen: number[] = []
    const provider = new MockProvider((req) => {
      seen.push(req.messages.length)
      return textTurn('ok')
    })
    const host = makeHost(ws, sink, provider)

    await host.send('第一轮')
    await host.send('第二轮')

    // 第二轮请求里应当包含 system + 第一轮的 user/assistant + 本轮 user
    expect(seen[1]).toBeGreaterThan(seen[0])
  })

  it('startSession 后 listSessions 立刻能看到空会话', async () => {
    const sink = new Recorder()
    const host = makeHost(ws, sink, new MockProvider(() => textTurn('x')))

    const id = await host.startSession('手动开的会话')
    const list = await host.listSessions()

    expect(list.map((m) => m.id)).toContain(id)
    expect(list[0].messages).toBe(0)
  })

  it('运行中再次 send 会抛错，避免并发写同一份历史', async () => {
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'write_file', args: { path: 'e.txt', content: 'x' } }])
        : textTurn('好')
    )
    const host = makeHost(ws, sink, provider, false)

    const running = host.send('第一次')
    await waitFor(() => sink.approvals.length > 0)

    await expect(host.send('第二次')).rejects.toThrow(/还在执行中/)

    host.resolveApproval(sink.approvals[0].id, 'approve')
    await running
  })
})

describe('AgentHost 权限模式', () => {
  it('read-only 模式下写操作被直接拒绝，连审批都不弹', async () => {
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'write_file', args: { path: 'f.txt', content: 'x' } }])
        : textTurn('好')
    )
    const host = new AgentHost({
      workspaceRoot: ws,
      provider,
      model: 'mock-model',
      sessionsDir: join(ws, 'sessions'),
      sink,
      permissionMode: 'read-only',
      autoApprove: true
    })

    await host.send('写')

    expect(sink.approvals).toHaveLength(0)
    await expect(readFile(join(ws, 'f.txt'), 'utf8')).rejects.toThrow()
    const toolEnd = sink.events.find((e) => e.type === 'tool-end')
    expect(toolEnd && toolEnd.type === 'tool-end' && toolEnd.result.output).toContain('权限')
  })

  it('auto 模式下工作区内的写操作不再询问', async () => {
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'write_file', args: { path: 'g.txt', content: 'x' } }])
        : textTurn('好')
    )
    const host = new AgentHost({
      workspaceRoot: ws,
      provider,
      model: 'mock-model',
      sessionsDir: join(ws, 'sessions'),
      sink,
      permissionMode: 'auto',
      autoApprove: true
    })

    await host.send('写')

    expect(sink.approvals).toHaveLength(0)
    expect(await readFile(join(ws, 'g.txt'), 'utf8')).toBe('x')
  })
})
