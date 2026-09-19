import type {
  AgentEvent,
  AgentStopReason,
  ApprovalDecision,
  ApprovalRequest,
  ApprovalResolution,
  ChatMessage,
  ChatRequest,
  ModelProvider,
  ToolCall,
  ToolResult,
  Usage
} from '@witseek/protocol'
import { ContextManager } from './context.js'
import { describeApproval, PermissionEngine } from './permission.js'
import type { ToolRegistry } from './registry.js'

/**
 * 审批回调。
 *
 * 返回裸决策（'approve'/'deny'/'approve-always'）是最简单的形态；
 * 逐块审查时返回 ApprovalResolution，可携带 acceptedHunkIds 与 rewrittenArgs
 * （主进程据此只应用被接受的 diff hunk）。
 */
export type Approver = (
  request: ApprovalRequest
) => Promise<ApprovalDecision | ApprovalResolution>

export interface AgentRunOptions {
  provider: ModelProvider
  model: string
  registry: ToolRegistry
  workspaceRoot: string
  permission?: PermissionEngine
  /** 权限引擎判定为 'ask' 时调用；缺省视为拒绝 */
  approver?: Approver
  systemPrompt?: string
  maxSteps?: number
  maxContextTokens?: number
  temperature?: number
  onEvent?: (event: AgentEvent) => void
  signal?: AbortSignal
  /** 之前的对话，用于多轮 */
  history?: ChatMessage[]
}

export interface AgentRunResult {
  messages: ChatMessage[]
  steps: number
  stopReason: AgentStopReason
  usage: Usage
  finalText: string
  error?: string
}

export function buildSystemPrompt(workspaceRoot: string, registry: ToolRegistry): string {
  const names = registry
    .list()
    .map((t) => `${t.name}${t.readOnly ? '(只读)' : ''}`)
    .join(', ')
  return [
    '你是 Witseek，一个在用户本机工作区里执行任务的编程助手。',
    `当前工作区: ${workspaceRoot}`,
    `可用工具: ${names}`,
    '',
    '工作方式:',
    '- 先读后改。修改文件前先读取确认内容，不要凭猜测生成替换文本。',
    '- edit_file 的 oldText 必须与文件内容完全一致，且默认要求唯一匹配。',
    '- 完成任务后直接给出结论，不要复述工具输出。',
    '- 不确定时说明不确定，不要编造文件内容或命令结果。'
  ].join('\n')
}

function accumulate(total: Usage, delta: Usage): void {
  total.promptTokens += delta.promptTokens
  total.completionTokens += delta.completionTokens
  total.totalTokens += delta.totalTokens
  if (delta.reasoningTokens) {
    total.reasoningTokens = (total.reasoningTokens ?? 0) + delta.reasoningTokens
  }
}

function parseArgs(raw: string): { ok: true; value: Record<string, unknown> } | { ok: false; error: string } {
  try {
    const value = JSON.parse(raw || '{}') as unknown
    if (value === null || typeof value !== 'object' || Array.isArray(value)) {
      return { ok: false, error: '参数必须是 JSON 对象' }
    }
    return { ok: true, value: value as Record<string, unknown> }
  } catch (e) {
    return { ok: false, error: `参数不是合法 JSON: ${(e as Error).message}` }
  }
}

/** 兼容裸决策字符串与完整裁决对象 */
function normalizeResolution(r: ApprovalDecision | ApprovalResolution): ApprovalResolution {
  return typeof r === 'string' ? { decision: r } : r
}

/**
 * Agent 主循环。
 *
 * 一轮 = 一次模型调用。模型若返回工具调用，执行后把结果回灌，进入下一轮；
 * 直到模型不再请求工具、或达到步数上限、或被取消。
 *
 * 整个函数不依赖 Electron / DOM，可以在纯 Node 下跑 —— 这是内核可测性的前提。
 */
export async function runAgent(
  opts: AgentRunOptions,
  input: string
): Promise<AgentRunResult> {
  const emit = opts.onEvent ?? ((): void => {})
  const maxSteps = opts.maxSteps ?? 12
  const permission = opts.permission ?? new PermissionEngine('confirm')
  const context = new ContextManager({ maxTokens: opts.maxContextTokens ?? 60_000 })

  const messages: ChatMessage[] = [
    { role: 'system', content: opts.systemPrompt ?? buildSystemPrompt(opts.workspaceRoot, opts.registry) }
  ]
  if (opts.history?.length) messages.push(...opts.history)
  messages.push({ role: 'user', content: input })

  const usage: Usage = { promptTokens: 0, completionTokens: 0, totalTokens: 0 }
  let stopReason: AgentStopReason = 'completed'
  let finalText = ''
  let errorMessage: string | undefined
  let step = 0

  for (step = 1; step <= maxSteps; step++) {
    if (opts.signal?.aborted) {
      stopReason = 'aborted'
      break
    }
    emit({ type: 'step-start', step })

    const fitted = context.fit(messages)
    const request: ChatRequest = {
      model: opts.model,
      messages: fitted.messages,
      tools: opts.registry.schemas(),
      temperature: opts.temperature
    }

    let content = ''
    let reasoning = ''
    const toolCalls: ToolCall[] = []

    try {
      for await (const event of opts.provider.stream(request, opts.signal)) {
        switch (event.type) {
          case 'reasoning-delta':
            reasoning += event.text
            emit({ type: 'reasoning', text: event.text })
            break
          case 'content-delta':
            content += event.text
            emit({ type: 'content', text: event.text })
            break
          case 'tool-call':
            toolCalls.push(event.call)
            break
          case 'usage':
            accumulate(usage, event.usage)
            emit({ type: 'usage', usage: event.usage })
            break
          case 'done':
            break
        }
      }
    } catch (e) {
      errorMessage = (e as Error).message
      stopReason = 'error'
      break
    }

    const assistant: ChatMessage = { role: 'assistant', content, toolCalls }
    if (reasoning) assistant.reasoning = reasoning
    if (!toolCalls.length) delete assistant.toolCalls
    messages.push(assistant)
    if (content) finalText = content

    if (!toolCalls.length) {
      stopReason = 'completed'
      break
    }

    for (const call of toolCalls) {
      const tool = opts.registry.get(call.name)
      if (!tool) {
        const result: ToolResult = { ok: false, output: `未知工具: ${call.name}` }
        messages.push({ role: 'tool', content: result.output, toolCallId: call.id, name: call.name })
        emit({ type: 'tool-end', call, result })
        continue
      }

      const parsed = parseArgs(call.arguments)
      if (!parsed.ok) {
        const result: ToolResult = { ok: false, output: parsed.error }
        messages.push({ role: 'tool', content: result.output, toolCallId: call.id, name: call.name })
        emit({ type: 'tool-end', call, result })
        continue
      }

      const args = parsed.value
      emit({ type: 'tool-start', call })

      // 路径越界由工具内部判定，这里先做一次粗判用于审批摘要
      const outside = typeof args.path === 'string' && /^([A-Za-z]:[\\/]|\/)/.test(args.path)
      const verdict = permission.verdict(tool, outside)

      let result: ToolResult
      if (verdict === 'deny') {
        result = { ok: false, output: `已被权限策略拒绝（当前模式: ${permission.mode}）` }
      } else if (verdict === 'ask') {
        const approvalRequest = describeApproval(tool, args, outside)
        const resolution = opts.approver
          ? normalizeResolution(await opts.approver(approvalRequest))
          : { decision: 'deny' as ApprovalDecision }
        emit({
          type: 'approval',
          request: approvalRequest,
          decision: resolution.decision,
          ...(resolution.acceptedHunkIds
            ? { acceptedHunkIds: resolution.acceptedHunkIds }
            : {})
        })
        if (resolution.decision === 'approve-always') permission.remember(tool.name)
        if (resolution.decision === 'deny') {
          result = { ok: false, output: '用户拒绝了该操作' }
        } else {
          // 逐块审查时，宿主把最终参数放在 rewrittenArgs（只应用被接受的 hunk）
          const finalArgs = resolution.rewrittenArgs ?? args
          result = await safeExecute(tool, finalArgs, opts)
        }
      } else {
        result = await safeExecute(tool, args, opts)
      }

      messages.push({ role: 'tool', content: result.output, toolCallId: call.id, name: call.name })
      emit({ type: 'tool-end', call, result })
    }

    if (step === maxSteps) stopReason = 'max-steps'
  }

  if (step > maxSteps) stopReason = 'max-steps'
  emit({ type: 'done', reason: stopReason })

  const result: AgentRunResult = { messages, steps: Math.min(step, maxSteps), stopReason, usage, finalText }
  if (errorMessage) result.error = errorMessage
  return result
}

async function safeExecute(
  tool: { execute: (a: Record<string, unknown>, c: { workspaceRoot: string; signal?: AbortSignal }) => Promise<ToolResult> },
  args: Record<string, unknown>,
  opts: AgentRunOptions
): Promise<ToolResult> {
  try {
    const ctx: { workspaceRoot: string; signal?: AbortSignal } = { workspaceRoot: opts.workspaceRoot }
    if (opts.signal) ctx.signal = opts.signal
    return await tool.execute(args, ctx)
  } catch (e) {
    // 工具抛错不应中断整个循环 —— 把错误当作工具结果回给模型，让它自己纠正
    return { ok: false, output: `工具执行失败: ${(e as Error).message}` }
  }
}
