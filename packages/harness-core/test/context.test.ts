import { describe, expect, it } from 'vitest'
import type { ChatMessage } from '@witseek/protocol'
import { ContextManager, conversationTokens, estimateTokens } from '../src/context.js'

describe('estimateTokens', () => {
  it('中文按字计', () => {
    expect(estimateTokens('你好世界')).toBe(4)
  })

  it('英文按 4 字符计', () => {
    expect(estimateTokens('abcdefgh')).toBe(2)
  })

  it('空串为 0', () => {
    expect(estimateTokens('')).toBe(0)
  })
})

describe('ContextManager', () => {
  it('未超预算时原样返回', () => {
    const msgs: ChatMessage[] = [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'hi' }
    ]
    const r = new ContextManager({ maxTokens: 10_000 }).fit(msgs)
    expect(r.trimmed).toBe(false)
    expect(r.messages).toHaveLength(2)
  })

  it('先裁剪工具结果而不是直接丢消息', () => {
    // 夹具要让 tool 结果落在保护窗口之外。keepRecent=3 保护末尾 3 条，
    // 所以 tool 之后必须再垫够消息 —— 否则它在保护区内，本就不该被裁，
    // 断言 stubbed > 0 就成了不可能满足的要求。
    const big = 'x'.repeat(4000)
    const msgs: ChatMessage[] = [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'task' },
      { role: 'assistant', content: '', toolCalls: [{ id: 'c1', name: 'read_file', arguments: '{}' }] },
      { role: 'tool', content: big, toolCallId: 'c1' },
      { role: 'assistant', content: 'done' },
      { role: 'user', content: 'more1' },
      { role: 'user', content: 'more2' },
      { role: 'user', content: 'more3' }
    ]
    const r = new ContextManager({ maxTokens: 500, keepRecent: 3 }).fit(msgs)
    expect(r.trimmed).toBe(true)
    expect(r.stubbedToolResults).toBe(1)
    // 只降质不减量：光把工具结果换成占位符就该够用，一条消息都不该丢
    expect(r.droppedMessages).toBe(0)
    expect(r.messages).toHaveLength(msgs.length)
    // 结构必须留着：role 与 toolCallId 不能被一起抹掉，否则后续 tool_calls 配对会断
    expect(r.messages[3].role).toBe('tool')
    expect(r.messages[3].toolCallId).toBe('c1')
    expect(r.messages[3].content).not.toBe(big)
    expect(r.finalTokens).toBeLessThan(conversationTokens(msgs))
  })

  it('保留 system 消息', () => {
    const msgs: ChatMessage[] = [
      { role: 'system', content: 'IMPORTANT' },
      ...Array.from({ length: 40 }, (_, i): ChatMessage => ({ role: 'user', content: `m${i} ${'y'.repeat(200)}` }))
    ]
    const r = new ContextManager({ maxTokens: 300, keepRecent: 4 }).fit(msgs)
    expect(r.messages[0].content).toBe('IMPORTANT')
    expect(r.droppedMessages).toBeGreaterThan(0)
  })

  it('裁剪后不再超预算', () => {
    const msgs: ChatMessage[] = [
      { role: 'system', content: 's' },
      ...Array.from({ length: 60 }, (_, i): ChatMessage => ({ role: 'user', content: `${i} ${'z'.repeat(300)}` }))
    ]
    const r = new ContextManager({ maxTokens: 400, keepRecent: 5 }).fit(msgs)
    expect(r.finalTokens).toBeLessThanOrEqual(400)
  })

  it('思维链在裁剪时被丢弃', () => {
    const msgs: ChatMessage[] = [
      { role: 'system', content: 's' },
      { role: 'assistant', content: 'a', reasoning: 'r'.repeat(3000) },
      { role: 'user', content: 'u' },
      { role: 'user', content: 'u2' },
      { role: 'user', content: 'u3' },
      { role: 'user', content: 'u4' }
    ]
    const r = new ContextManager({ maxTokens: 200, keepRecent: 2 }).fit(msgs)
    expect(r.messages[1].reasoning).toBeUndefined()
  })
})
