import { describe, expect, it } from 'vitest'
import type { ChatMessage, StreamEvent } from '@witseek/protocol'
import { DeepSeekClient } from '../src/client.js'

function sseStream(lines: string[]): ReadableStream<Uint8Array> {
  const enc = new TextEncoder()
  return new ReadableStream({
    start(c) {
      for (const l of lines) c.enqueue(enc.encode(`data: ${l}\n\n`))
      c.close()
    }
  })
}

function fakeFetch(lines: string[], capture?: { body?: unknown }): typeof fetch {
  return (async (_url: string | URL | Request, init?: RequestInit) => {
    if (capture && init?.body) capture.body = JSON.parse(init.body as string)
    return new Response(sseStream(lines), { status: 200 })
  }) as unknown as typeof fetch
}

async function collect(gen: AsyncIterable<StreamEvent>): Promise<StreamEvent[]> {
  const out: StreamEvent[] = []
  for await (const e of gen) out.push(e)
  return out
}

describe('DeepSeekClient', () => {
  it('分离 reasoning 与 content', async () => {
    const client = new DeepSeekClient({
      apiKey: 'k',
      fetchImpl: fakeFetch([
        '{"choices":[{"delta":{"reasoning_content":"想一想"}}]}',
        '{"choices":[{"delta":{"content":"答案"}}]}',
        '{"choices":[{"delta":{},"finish_reason":"stop"}]}'
      ])
    })

    const events = await collect(
      client.stream({ model: 'deepseek-reasoner', messages: [{ role: 'user', content: 'hi' }] })
    )

    const reasoning = events.filter((e) => e.type === 'reasoning-delta').map((e) => (e as { text: string }).text)
    const content = events.filter((e) => e.type === 'content-delta').map((e) => (e as { text: string }).text)
    expect(reasoning.join('')).toBe('想一想')
    expect(content.join('')).toBe('答案')
  })

  it('按 index 拼装分片的 tool_calls', async () => {
    const client = new DeepSeekClient({
      apiKey: 'k',
      fetchImpl: fakeFetch([
        // id/name 只在首片出现，arguments 跨多片累加
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"read_file","arguments":"{\\"pa"}}]}}]}',
        '{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"th\\":\\"a.txt\\"}"}}]}}]}',
        '{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}'
      ])
    })

    const events = await collect(
      client.stream({ model: 'deepseek-chat', messages: [{ role: 'user', content: 'x' }] })
    )
    const call = events.find((e) => e.type === 'tool-call')
    expect(call).toBeDefined()
    expect((call as { call: { id: string; name: string; arguments: string } }).call).toEqual({
      id: 'c1',
      name: 'read_file',
      arguments: '{"path":"a.txt"}'
    })
  })

  it('不回传 reasoning_content', async () => {
    const capture: { body?: unknown } = {}
    const client = new DeepSeekClient({ apiKey: 'k', fetchImpl: fakeFetch([], capture) })

    const history: ChatMessage[] = [
      { role: 'assistant', content: '上一轮回答', reasoning: '上一轮的思维链' }
    ]
    await collect(client.stream({ model: 'deepseek-reasoner', messages: history }))

    const body = capture.body as { messages: Array<Record<string, unknown>> }
    expect(body.messages[0].content).toBe('上一轮回答')
    expect(body.messages[0].reasoning_content).toBeUndefined()
  })

  it('API 报错时抛出带状态码的错误', async () => {
    const client = new DeepSeekClient({
      apiKey: 'k',
      fetchImpl: (async () =>
        new Response('{"error":"bad key"}', { status: 401, statusText: 'Unauthorized' })) as unknown as typeof fetch
    })
    await expect(
      collect(client.stream({ model: 'deepseek-chat', messages: [{ role: 'user', content: 'x' }] }))
    ).rejects.toThrow(/401/)
  })

  it('构造时缺少 apiKey 直接报错', () => {
    expect(() => new DeepSeekClient({ apiKey: '' })).toThrow(/apiKey/)
  })
})
