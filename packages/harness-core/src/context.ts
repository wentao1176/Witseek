import type { ChatMessage } from '@witseek/protocol'

/**
 * 粗略的 token 估算。
 *
 * 没有引入 tokenizer：DeepSeek 的 tokenizer 不公开权重，各家估算差异本来就在 10% 量级，
 * 而上下文管理只需要"够准的保守估计"。中日韩字符按 1 token/字，其余按 4 字符/token，
 * 这是实践中最稳的经验值。
 */
export function estimateTokens(text: string): number {
  if (!text) return 0
  let cjk = 0
  for (const ch of text) {
    const c = ch.codePointAt(0) as number
    if (
      (c >= 0x2e80 && c <= 0x9fff) ||
      (c >= 0xf900 && c <= 0xfaff) ||
      (c >= 0xff00 && c <= 0xffef) ||
      (c >= 0x20000 && c <= 0x3ffff)
    ) {
      cjk++
    }
  }
  const rest = text.length - cjk
  return cjk + Math.ceil(rest / 4)
}

export function messageTokens(m: ChatMessage): number {
  let n = estimateTokens(m.content) + estimateTokens(m.reasoning ?? '')
  if (m.toolCalls?.length) {
    for (const c of m.toolCalls) {
      n += estimateTokens(c.name) + estimateTokens(c.arguments) + 8
    }
  }
  return n + 4 // 角色与分隔符的固定开销
}

export function conversationTokens(messages: ChatMessage[]): number {
  return messages.reduce((sum, m) => sum + messageTokens(m), 0)
}

export interface ContextOptions {
  maxTokens: number
  /** 最近多少条消息不参与裁剪 */
  keepRecent?: number
}

export interface FitResult {
  messages: ChatMessage[]
  originalTokens: number
  finalTokens: number
  trimmed: boolean
  /** 被完全丢弃的消息条数 */
  droppedMessages: number
  /** 被替换为占位符的工具结果条数 */
  stubbedToolResults: number
}

const STUB = '[已裁剪：历史工具结果过长，内容不再回传给模型]'

/**
 * 上下文裁剪。策略是"先降质，再减量"：
 *   1. 保留 system 与最近 keepRecent 条
 *   2. 把更早的工具结果替换成占位符（保留对话结构，丢掉体积最大的部分）
 *   3. 仍然超预算才真正丢弃最旧的消息
 * 工具结果通常是上下文里最占地方的部分，先动它代价最小。
 */
export class ContextManager {
  readonly #maxTokens: number
  readonly #keepRecent: number

  constructor(opts: ContextOptions) {
    this.#maxTokens = opts.maxTokens
    this.#keepRecent = opts.keepRecent ?? 8
  }

  get maxTokens(): number {
    return this.#maxTokens
  }

  fit(input: ChatMessage[]): FitResult {
    const original = conversationTokens(input)
    let messages = input.map((m) => ({ ...m }))

    if (original <= this.#maxTokens) {
      return {
        messages,
        originalTokens: original,
        finalTokens: original,
        trimmed: false,
        droppedMessages: 0,
        stubbedToolResults: 0
      }
    }

    const boundary = Math.max(1, messages.length - this.#keepRecent)
    let stubbed = 0
    for (let i = 1; i < boundary; i++) {
      const m = messages[i]
      if (m.role === 'tool' && m.content.length > 200) {
        m.content = STUB
        stubbed++
      }
      if (m.reasoning) m.reasoning = undefined // 思维链对后续推理没有复用价值
    }

    let dropped = 0
    // 循环条件只看预算。早先这里还带了 `messages.length > keepRecent + 1`，
    // 那会在"最近 keepRecent 条自身就超预算"时提前收手，裁剪完依然超标。
    // 底线改成保留 system 加最后一条消息 —— 再少就没有可回答的对象了。
    while (conversationTokens(messages) > this.#maxTokens && messages.length > 2) {
      // 保留 index 0（system），从最旧的对话消息开始丢
      messages.splice(1, 1)
      dropped++
    }

    messages = messages.map((m) => ({ ...m }))
    return {
      messages,
      originalTokens: original,
      finalTokens: conversationTokens(messages),
      trimmed: true,
      droppedMessages: dropped,
      stubbedToolResults: stubbed
    }
  }
}
