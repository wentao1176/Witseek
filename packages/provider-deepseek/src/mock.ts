import type { ChatRequest, ModelProvider, StreamEvent, ToolCall } from '@witseek/protocol'

/** 给定请求与轮次，返回这一轮要产出的流式事件 */
export type MockResponder = (
  req: ChatRequest,
  turn: number
) => StreamEvent[] | Promise<StreamEvent[]>

/**
 * 测试与离线演示用的提供方。
 * 有了它，内核可以在没有任何 API Key 的情况下被完整验证 ——
 * 这也是把 provider 抽象出来的意义。
 */
export class MockProvider implements ModelProvider {
  readonly id = 'mock'
  #responder: MockResponder
  #turn = 0
  #models: string[]

  constructor(responder: MockResponder, models: string[] = ['mock-model']) {
    this.#responder = responder
    this.#models = models
  }

  get turn(): number {
    return this.#turn
  }

  listModels(): readonly string[] {
    return this.#models
  }

  async *stream(req: ChatRequest): AsyncGenerator<StreamEvent> {
    const events = await this.#responder(req, this.#turn++)
    for (const e of events) yield e
  }
}

/** 便捷构造：一轮纯文本回答 */
export function textTurn(text: string, reasoning?: string): StreamEvent[] {
  const events: StreamEvent[] = []
  if (reasoning) events.push({ type: 'reasoning-delta', text: reasoning })
  events.push({ type: 'content-delta', text })
  events.push({ type: 'done', finishReason: 'stop' })
  return events
}

/** 便捷构造：一轮工具调用 */
export function toolTurn(
  calls: Array<{ id?: string; name: string; args: Record<string, unknown> }>,
  content = ''
): StreamEvent[] {
  const events: StreamEvent[] = []
  if (content) events.push({ type: 'content-delta', text: content })
  const toolCalls: ToolCall[] = calls.map((c, i) => ({
    id: c.id ?? `call_${i}`,
    name: c.name,
    arguments: JSON.stringify(c.args)
  }))
  for (const call of toolCalls) events.push({ type: 'tool-call', call })
  events.push({ type: 'done', finishReason: 'tool_calls' })
  return events
}
