import type {
  ChatMessage,
  ChatRequest,
  ModelProvider,
  StreamEvent,
  ToolCall,
  ToolSchema,
  Usage
} from '@witseek/protocol'
import { parseSse } from './sse.js'

export const DEEPSEEK_MODELS = ['deepseek-chat', 'deepseek-reasoner'] as const
export const DEFAULT_BASE_URL = 'https://api.deepseek.com'

export interface DeepSeekOptions {
  apiKey: string
  baseUrl?: string
  /** 便于测试注入 */
  fetchImpl?: typeof fetch
}

interface ApiToolCallDelta {
  index?: number
  id?: string
  function?: { name?: string; arguments?: string }
}

interface ApiChunk {
  choices?: Array<{
    delta?: { content?: string; reasoning_content?: string; tool_calls?: ApiToolCallDelta[] }
    finish_reason?: string | null
  }>
  usage?: {
    prompt_tokens?: number
    completion_tokens?: number
    total_tokens?: number
    completion_tokens_details?: { reasoning_tokens?: number }
  }
}

/**
 * 把内部消息转成 API 期望的形状。
 * 关键：reasoning 不回传 —— deepseek-reasoner 不接受上一轮的 reasoning_content。
 */
function toApiMessages(messages: ChatMessage[]): unknown[] {
  return messages.map((m) => {
    if (m.role === 'tool') {
      return { role: 'tool', content: m.content, tool_call_id: m.toolCallId }
    }
    if (m.role === 'assistant') {
      const out: Record<string, unknown> = { role: 'assistant', content: m.content ?? '' }
      if (m.toolCalls?.length) {
        out.tool_calls = m.toolCalls.map((c) => ({
          id: c.id,
          type: 'function',
          function: { name: c.name, arguments: c.arguments }
        }))
      }
      return out
    }
    return { role: m.role, content: m.content }
  })
}

function toApiTools(tools: ToolSchema[]): unknown[] {
  return tools.map((t) => ({
    type: 'function',
    function: { name: t.name, description: t.description, parameters: t.parameters }
  }))
}

function mapUsage(u: NonNullable<ApiChunk['usage']>): Usage {
  const prompt = u.prompt_tokens ?? 0
  const completion = u.completion_tokens ?? 0
  return {
    promptTokens: prompt,
    completionTokens: completion,
    totalTokens: u.total_tokens ?? prompt + completion,
    reasoningTokens: u.completion_tokens_details?.reasoning_tokens
  }
}

export class DeepSeekClient implements ModelProvider {
  readonly id = 'deepseek'
  readonly #apiKey: string
  readonly #baseUrl: string
  readonly #fetch: typeof fetch

  constructor(opts: DeepSeekOptions) {
    if (!opts.apiKey) throw new Error('DeepSeekClient 需要 apiKey')
    this.#apiKey = opts.apiKey
    this.#baseUrl = (opts.baseUrl ?? DEFAULT_BASE_URL).replace(/\/+$/, '')
    this.#fetch = opts.fetchImpl ?? globalThis.fetch
  }

  listModels(): readonly string[] {
    return DEEPSEEK_MODELS
  }

  async *stream(req: ChatRequest, signal?: AbortSignal): AsyncGenerator<StreamEvent> {
    const body: Record<string, unknown> = {
      model: req.model,
      messages: toApiMessages(req.messages),
      stream: true,
      stream_options: { include_usage: true }
    }
    if (req.tools?.length) {
      body.tools = toApiTools(req.tools)
      body.tool_choice = 'auto'
    }
    if (req.temperature !== undefined) body.temperature = req.temperature
    if (req.maxTokens !== undefined) body.max_tokens = req.maxTokens

    const res = await this.#fetch(`${this.#baseUrl}/chat/completions`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        authorization: `Bearer ${this.#apiKey}`
      },
      body: JSON.stringify(body),
      signal
    })

    if (!res.ok) {
      const detail = await res.text().catch(() => '')
      throw new Error(`DeepSeek API ${res.status} ${res.statusText}: ${detail.slice(0, 500)}`)
    }
    if (!res.body) throw new Error('DeepSeek API 返回了空 body')

    // tool_calls 是分片下发的：id/name 只在首片出现，arguments 需要按 index 累加
    const pending = new Map<number, { id: string; name: string; args: string }>()
    let finishReason = ''

    for await (const data of parseSse(res.body)) {
      if (data === '[DONE]') break

      let chunk: ApiChunk
      try {
        chunk = JSON.parse(data) as ApiChunk
      } catch {
        continue // 非 JSON 的心跳/注释行
      }

      if (chunk.usage) yield { type: 'usage', usage: mapUsage(chunk.usage) }

      const choice = chunk.choices?.[0]
      if (!choice) continue

      const delta = choice.delta ?? {}
      if (delta.reasoning_content) {
        yield { type: 'reasoning-delta', text: delta.reasoning_content }
      }
      if (delta.content) {
        yield { type: 'content-delta', text: delta.content }
      }
      for (const tc of delta.tool_calls ?? []) {
        const idx = tc.index ?? 0
        const cur = pending.get(idx) ?? { id: '', name: '', args: '' }
        if (tc.id) cur.id = tc.id
        if (tc.function?.name) cur.name = tc.function.name
        if (tc.function?.arguments) cur.args += tc.function.arguments
        pending.set(idx, cur)
      }
      if (choice.finish_reason) finishReason = choice.finish_reason
    }

    const calls: ToolCall[] = [...pending.entries()]
      .sort((a, b) => a[0] - b[0])
      .map(([idx, c]) => ({
        id: c.id || `call_${idx}`,
        name: c.name,
        arguments: c.args || '{}'
      }))
    for (const call of calls) yield { type: 'tool-call', call }

    yield { type: 'done', finishReason: finishReason || 'stop' }
  }
}
