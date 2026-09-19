#!/usr/bin/env bash
# scaffold_p3_tests.sh —— 生成 P3 的主进程单测
#
# 产物: tests/unit/{agent-host,transcript,util,workspace}.test.ts
#
# 为什么这些测试放在根目录的 tests/ 而不是 apps/desktop 里：
# AgentHost 刻意不 import electron（只认 HostSink），所以它能在纯 Node 下跑。
# 一旦有人在 host.ts 里写 import { app } from 'electron'，这些测试会立刻崩，
# 相当于给"内核与外壳解耦"这条设计约束加了一道自动守卫。
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
cd "$ROOT"

w() { mkdir -p "$(dirname "$1")"; cat > "$1"; echo "  + $1"; }

echo "== P3 主进程单测 =="

w tests/unit/agent-host.test.ts <<'EOF'
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
EOF

echo "== P3 事件归约器单测 =="

w tests/unit/transcript.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import type { AgentEvent } from '@witseek/protocol'
import {
  addUser,
  applyEvent,
  changedPaths,
  emptyTranscript,
  lastDiff,
  markDeciding,
  setPending,
  toggleReasoning,
  type Transcript
} from '../../apps/desktop/src/renderer/src/transcript.js'

function feed(t: Transcript, events: AgentEvent[]): Transcript {
  let out = t
  for (const e of events) out = applyEvent(out, e, 1000)
  return out
}

const call = (id: string, name: string, args: Record<string, unknown>): AgentEvent => ({
  type: 'tool-start',
  call: { id, name, arguments: JSON.stringify(args) }
})

describe('事件 → 块', () => {
  it('流式 content 追加到同一块，而不是每片一块', () => {
    // 模型是按 token 吐的，若每片都新建块，界面会被拆成几百个段落
    const t = feed(emptyTranscript, [
      { type: 'step-start', step: 1 },
      { type: 'content', text: '你' },
      { type: 'content', text: '好' },
      { type: 'content', text: '世界' }
    ])
    expect(t.blocks).toHaveLength(1)
    expect(t.blocks[0].kind).toBe('text')
    expect(t.blocks[0].kind === 'text' && t.blocks[0].text).toBe('你好世界')
  })

  it('流式 reasoning 同理', () => {
    const t = feed(emptyTranscript, [
      { type: 'reasoning', text: '先' },
      { type: 'reasoning', text: '想想' }
    ])
    expect(t.blocks).toHaveLength(1)
    expect(t.blocks[0].kind === 'reasoning' && t.blocks[0].text).toBe('先想想')
  })

  it('工具调用会把前后的文本切开', () => {
    const t = feed(emptyTranscript, [
      { type: 'content', text: '看一下' },
      call('c1', 'read_file', { path: 'a.txt' }),
      { type: 'content', text: '看完了' }
    ])
    expect(t.blocks.map((b) => b.kind)).toEqual(['text', 'tool', 'text'])
  })

  it('推理与正文不会粘成一块', () => {
    const t = feed(emptyTranscript, [
      { type: 'reasoning', text: '推理' },
      { type: 'content', text: '正文' }
    ])
    expect(t.blocks.map((b) => b.kind)).toEqual(['reasoning', 'text'])
  })

  it('tool-end 按 callId 回填结果与耗时', () => {
    const t = feed(emptyTranscript, [
      call('c1', 'read_file', { path: 'a.txt' }),
      {
        type: 'tool-end',
        call: { id: 'c1', name: 'read_file', arguments: '{}' },
        result: { ok: true, output: '内容' }
      }
    ])
    const tool = t.blocks[0]
    expect(tool.kind).toBe('tool')
    if (tool.kind !== 'tool') return
    expect(tool.state).toBe('ok')
    expect(tool.output).toBe('内容')
    expect(tool.ms).toBe(0)
  })

  it('失败的工具标记为 fail 而不是 ok', () => {
    const t = feed(emptyTranscript, [
      call('c1', 'read_file', { path: 'x' }),
      {
        type: 'tool-end',
        call: { id: 'c1', name: 'read_file', arguments: '{}' },
        result: { ok: false, output: '不存在' }
      }
    ])
    const tool = t.blocks[0]
    expect(tool.kind === 'tool' && tool.state).toBe('fail')
  })

  it('tool-end 找不到对应块时不会凭空插入', () => {
    const t = feed(emptyTranscript, [
      {
        type: 'tool-end',
        call: { id: 'ghost', name: 'read_file', arguments: '{}' },
        result: { ok: true, output: 'x' }
      }
    ])
    expect(t.blocks).toHaveLength(0)
  })

  it('usage 不进块，单独更新用量', () => {
    const t = feed(emptyTranscript, [
      { type: 'usage', usage: { promptTokens: 10, completionTokens: 5, totalTokens: 15 } }
    ])
    expect(t.blocks).toHaveLength(0)
    expect(t.usage?.totalTokens).toBe(15)
  })

  it('done 结束运行态并记录原因', () => {
    const t = feed(emptyTranscript, [{ type: 'step-start', step: 1 }, { type: 'done', reason: 'completed' }])
    expect(t.running).toBe(false)
    expect(t.stopReason).toBe('completed')
  })
})

describe('审批的挂起与落定', () => {
  it('push:approval 只挂出待办，不产生块', () => {
    const t = setPending(emptyTranscript, {
      id: 'ap1',
      tool: 'write_file',
      args: { path: 'a.txt' },
      summary: '写入文件 a.txt',
      outsideWorkspace: false
    })
    expect(t.pending?.id).toBe('ap1')
    expect(t.blocks).toHaveLength(0)
  })

  it('AgentEvent 的 approval 把待办落成一条已裁决记录', () => {
    // 关键：内核的 approval 事件是**决策之后**才发的。
    // 若界面把它当成"询问"来处理，就会弹出一个永远等不到回应的卡片。
    const withPending = setPending(emptyTranscript, {
      id: 'ap1',
      tool: 'edit_file',
      args: { path: 'a.txt' },
      summary: '修改 a.txt',
      outsideWorkspace: false,
      diff: { path: 'a.txt', added: 1, removed: 1, lines: [], truncated: false }
    })
    const t = applyEvent(
      withPending,
      {
        type: 'approval',
        request: {
          tool: 'edit_file',
          args: { path: 'a.txt' },
          summary: '修改 a.txt',
          outsideWorkspace: false
        },
        decision: 'approve'
      },
      1000
    )

    expect(t.pending).toBeNull()
    expect(t.blocks).toHaveLength(1)
    const b = t.blocks[0]
    expect(b.kind).toBe('approval')
    if (b.kind !== 'approval') return
    expect(b.decision).toBe('approve')
    // diff 要从挂起的请求上继承下来，否则卡片上就没有改动摘要了
    expect(b.diff?.added).toBe(1)
  })

  it('done 会清掉残留的待办，避免卡片一直挂着', () => {
    const t = applyEvent(
      setPending(emptyTranscript, {
        id: 'ap1',
        tool: 'write_file',
        args: {},
        summary: 'x',
        outsideWorkspace: false
      }),
      { type: 'done', reason: 'aborted' },
      1000
    )
    expect(t.pending).toBeNull()
  })

  it('markDeciding 只改标记，不动待办本身', () => {
    const t = markDeciding(
      setPending(emptyTranscript, {
        id: 'ap1',
        tool: 'write_file',
        args: {},
        summary: 'x',
        outsideWorkspace: false
      })
    )
    expect(t.deciding).toBe(true)
    expect(t.pending?.id).toBe('ap1')
  })
})

describe('派生信息', () => {
  it('changedPaths 只统计成功的写操作', () => {
    const t = feed(emptyTranscript, [
      call('c1', 'write_file', { path: 'a.txt' }),
      {
        type: 'tool-end',
        call: { id: 'c1', name: 'write_file', arguments: '{}' },
        result: { ok: true, output: 'ok' }
      },
      call('c2', 'edit_file', { path: 'b.txt' }),
      {
        type: 'tool-end',
        call: { id: 'c2', name: 'edit_file', arguments: '{}' },
        result: { ok: false, output: '失败' }
      },
      call('c3', 'read_file', { path: 'c.txt' }),
      {
        type: 'tool-end',
        call: { id: 'c3', name: 'read_file', arguments: '{}' },
        result: { ok: true, output: 'ok' }
      }
    ])
    expect(changedPaths(t)).toEqual(['a.txt'])
  })

  it('参数不是合法 JSON 时 changedPaths 不抛错', () => {
    const t = applyEvent(
      emptyTranscript,
      { type: 'tool-start', call: { id: 'c1', name: 'write_file', arguments: '不是JSON' } },
      1000
    )
    const done = applyEvent(
      t,
      {
        type: 'tool-end',
        call: { id: 'c1', name: 'write_file', arguments: '不是JSON' },
        result: { ok: true, output: 'ok' }
      },
      1000
    )
    expect(() => changedPaths(done)).not.toThrow()
  })

  it('lastDiff 取最近一条带 diff 的审批', () => {
    let t = emptyTranscript
    t = applyEvent(
      setPending(t, {
        id: 'a',
        tool: 'edit_file',
        args: {},
        summary: 's1',
        outsideWorkspace: false,
        diff: { path: 'one.txt', added: 1, removed: 0, lines: [], truncated: false }
      }),
      {
        type: 'approval',
        request: { tool: 'edit_file', args: {}, summary: 's1', outsideWorkspace: false },
        decision: 'approve'
      },
      1000
    )
    t = applyEvent(
      setPending(t, {
        id: 'b',
        tool: 'edit_file',
        args: {},
        summary: 's2',
        outsideWorkspace: false,
        diff: { path: 'two.txt', added: 2, removed: 1, lines: [], truncated: false }
      }),
      {
        type: 'approval',
        request: { tool: 'edit_file', args: {}, summary: 's2', outsideWorkspace: false },
        decision: 'approve'
      },
      1000
    )
    expect(lastDiff(t)?.path).toBe('two.txt')
  })

  it('没有 diff 时 lastDiff 返回 null', () => {
    expect(lastDiff(emptyTranscript)).toBeNull()
  })
})

describe('其他', () => {
  it('addUser 会立刻把运行态置为 true', () => {
    expect(addUser(emptyTranscript, '你好').running).toBe(true)
  })

  it('toggleReasoning 只翻转目标块', () => {
    const t = feed(emptyTranscript, [{ type: 'reasoning', text: 'a' }])
    const id = t.blocks[0].id
    const closed = toggleReasoning(t, id)
    expect(closed.blocks[0].kind === 'reasoning' && closed.blocks[0].open).toBe(false)
    const reopened = toggleReasoning(closed, id)
    expect(reopened.blocks[0].kind === 'reasoning' && reopened.blocks[0].open).toBe(true)
  })

  it('块 id 不重复', () => {
    const t = feed(emptyTranscript, [
      { type: 'reasoning', text: 'a' },
      { type: 'content', text: 'b' },
      call('c1', 'read_file', { path: 'x' })
    ])
    const ids = t.blocks.map((b) => b.id)
    expect(new Set(ids).size).toBe(ids.length)
  })
})
EOF

echo "== P3 工具函数单测 =="

w tests/unit/util.test.ts <<'EOF'
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
EOF

echo "== P3 文件树单测 =="

w tests/unit/workspace.test.ts <<'EOF'
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
EOF

echo
echo "==> P3 测试已生成"
find tests -name "*.test.ts" | sort
