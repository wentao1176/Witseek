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
