#!/usr/bin/env bash
# scaffold_p2_kernel.sh —— 生成 P2 的 Harness 内核包
#
# 产物: packages/{protocol,provider-deepseek,tools,harness-core}
#
# 设计原则:
#   - 内核不依赖 Electron，纯 Node，可独立单测
#   - 包以 TypeScript 源码形式导出（exports 指向 src/index.ts），
#     由 vitest / Vite 负责转译，省掉一层构建，也避免 dist 与 src 不同步
#   - 零第三方运行时依赖（glob/grep 自己实现），减少环境风险
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
cd "$ROOT"

w() { mkdir -p "$(dirname "$1")"; cat > "$1"; echo "  + $1"; }

pkg() {  # pkg <dir> <name> [deps-fragment] [devdeps-fragment]
  local dir="$1" name="$2" deps="${3:-}" devdeps="${4:-}"
  mkdir -p "$dir/src"
  # deps / devdeps 片段都以逗号开头，形如:
  #   ,
  #     "dependencies": { "@witseek/protocol": "workspace:*" }
  # 直接拼在既有条目之后，保证 package.json 始终是合法 JSON。
  # @types/node 必须逐包声明：pnpm 的 node_modules 是严格隔离的，
  # 根目录装了它，子包也看不见，tsc 会报 TS2688 找不到 'node' 类型定义。
  w "$dir/package.json" <<EOF
{
  "name": "$name",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  }${deps},
  "devDependencies": {
    "@types/node": "^26.6.1"${devdeps}
  },
  "scripts": {
    "typecheck": "tsc --noEmit -p tsconfig.json"
  }
}
EOF
  # 每个包一份 tsconfig，供 `tsc --noEmit -p tsconfig.json` 做单包类型校验。
  # 缺了它，harness-core 里声明的 typecheck 脚本会直接报找不到配置文件。
  w "$dir/tsconfig.json" <<EOF
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "noEmit": true,
    "types": ["node"]
  },
  "include": ["src/**/*.ts", "test/**/*.ts"]
}
EOF
}

echo "== packages/protocol =="
pkg packages/protocol @witseek/protocol

w packages/protocol/src/index.ts <<'EOF'
// 内核的共享契约。所有跨包类型都定义在这里，是唯一事实来源。

export type ChatRole = 'system' | 'user' | 'assistant' | 'tool'

export interface ToolCall {
  id: string
  name: string
  /** 模型返回的原始 JSON 字符串。保留原文，便于在解析失败时报出可诊断的错。 */
  arguments: string
}

export interface ChatMessage {
  role: ChatRole
  content: string
  /** deepseek-reasoner 的思维链。与 content 分开存放，且不回传给 API。 */
  reasoning?: string
  toolCalls?: ToolCall[]
  /** role === 'tool' 时，指向被回应的 tool call */
  toolCallId?: string
  name?: string
}

export interface JsonSchema {
  type: string
  properties?: Record<string, JsonSchema>
  items?: JsonSchema
  required?: string[]
  description?: string
  enum?: unknown[]
  default?: unknown
}

export interface ToolSchema {
  name: string
  description: string
  parameters: JsonSchema
}

export interface ToolResult {
  ok: boolean
  output: string
  /** 结构化附加信息。不发给模型，供 UI 使用（行数、耗时、字节数等）。 */
  meta?: Record<string, unknown>
}

export interface ToolDefinition extends ToolSchema {
  /** 只读工具在任何权限模式下都无需审批 */
  readOnly: boolean
  execute(args: Record<string, unknown>, ctx: ToolContext): Promise<ToolResult>
}

export interface ToolContext {
  workspaceRoot: string
  signal?: AbortSignal
}

export type PermissionMode =
  /** 只允许读，任何写操作直接拒绝 */
  | 'read-only'
  /** 每个写操作都要用户确认 */
  | 'confirm'
  /** 工作区内自动执行，越界仍要确认 */
  | 'auto'

export interface ApprovalRequest {
  tool: string
  args: Record<string, unknown>
  /** 人类可读的变更摘要 */
  summary: string
  /** 是否触及工作区之外 */
  outsideWorkspace: boolean
}

export type ApprovalDecision = 'approve' | 'deny' | 'approve-always'

/**
 * 一次审批的完整裁决。
 *
 * - 普通批准/拒绝只需要 decision。
 * - diff 逐块审查时，UI 传 acceptedHunkIds，主进程据此把"未接受的块"还原，
 *   并把最终要执行的参数放在 rewrittenArgs 里（内核只负责照此执行，不关心 diff）。
 */
export interface ApprovalResolution {
  decision: ApprovalDecision
  /** 逐块审查后被接受的 hunk id；缺省视为全部接受 */
  acceptedHunkIds?: string[]
  /** 宿主计算出的最终工具参数（部分应用场景），优先于模型原始 args */
  rewrittenArgs?: Record<string, unknown>
}

export interface Usage {
  promptTokens: number
  completionTokens: number
  totalTokens: number
  reasoningTokens?: number
}

export type StreamEvent =
  | { type: 'reasoning-delta'; text: string }
  | { type: 'content-delta'; text: string }
  | { type: 'tool-call'; call: ToolCall }
  | { type: 'usage'; usage: Usage }
  | { type: 'done'; finishReason: string }

export interface ChatRequest {
  model: string
  messages: ChatMessage[]
  tools?: ToolSchema[]
  temperature?: number
  maxTokens?: number
}

/** 模型提供方。DeepSeek 与测试用的 Mock 都实现它。 */
export interface ModelProvider {
  readonly id: string
  listModels(): readonly string[]
  stream(req: ChatRequest, signal?: AbortSignal): AsyncIterable<StreamEvent>
}

export interface SessionMeta {
  id: string
  title: string
  workspace: string
  model: string
  createdAt: string
  updatedAt: string
}

export type SessionRecord =
  | { kind: 'meta'; meta: SessionMeta }
  | { kind: 'message'; message: ChatMessage }
  | { kind: 'tool'; callId: string; name: string; result: ToolResult }
  | {
      kind: 'approval'
      request: ApprovalRequest
      decision: ApprovalDecision
      /** 逐块审查时实际接受的 hunk（回放/审计用） */
      acceptedHunkIds?: string[]
    }
  | { kind: 'usage'; usage: Usage }

/** Agent 循环对外广播的事件，UI 直接消费 */
export type AgentEvent =
  | { type: 'step-start'; step: number }
  | { type: 'reasoning'; text: string }
  | { type: 'content'; text: string }
  | { type: 'tool-start'; call: ToolCall }
  | { type: 'tool-end'; call: ToolCall; result: ToolResult }
  | {
      type: 'approval'
      request: ApprovalRequest
      decision: ApprovalDecision
      /** 逐块审查时实际接受的 hunk（UI 落审计卡片用） */
      acceptedHunkIds?: string[]
    }
  | { type: 'usage'; usage: Usage }
  | { type: 'checkpoint'; checkpoint: CheckpointInfo }
  | { type: 'done'; reason: AgentStopReason }

export type AgentStopReason =
  | 'completed'
  | 'max-steps'
  | 'aborted'
  | 'error'

// ─────────────────────────────────────────────────────────────
// 差异（diff）与逐块审查
// ─────────────────────────────────────────────────────────────

export type DiffLineKind = 'add' | 'del' | 'plain'

export interface DiffLine {
  kind: DiffLineKind
  /** 变更前在第几行（add 行为空） */
  oldNo?: number
  /** 变更后在第几行（del 行为空） */
  newNo?: number
  text: string
  /** 所属 hunk；不属于任何变更段的纯上下文行没有该字段 */
  hunkId?: string
}

/**
 * 一个可独立接受/拒绝的变更块（hunk）。
 * 行号语义与 unified diff 一致：oldStart 从 1 开始，oldLines/newLines 为 0 时
 * start 指向插入位置。
 */
export interface DiffHunk {
  id: string
  oldStart: number
  oldLines: number
  newStart: number
  newLines: number
  /** 该块包含的行（带前后上下文） */
  lines: DiffLine[]
}

export interface DiffPreview {
  path: string
  added: number
  removed: number
  lines: DiffLine[]
  /** 变更过大时只给统计，不返回逐行内容，也不做 hunk 分组 */
  truncated: boolean
  /** 可逐块裁决的变更段；truncated 或无变更时为空 */
  hunks: DiffHunk[]
}

// ─────────────────────────────────────────────────────────────
// 检查点（工作区快照与回滚）
// ─────────────────────────────────────────────────────────────

export type CheckpointReason = 'auto' | 'manual' | 'rollback-backup'

export interface CheckpointInfo {
  id: string
  label: string
  reason: CheckpointReason
  createdAt: string
  /** 纳入快照的文件数 */
  files: number
  /** 快照总字节数 */
  bytes: number
  /** 因超过单文件上限而跳过的文件（这些文件回滚时也不会被触碰） */
  skipped: string[]
}

export interface CheckpointRollbackResult {
  restored: number
  removed: number
  backup: CheckpointInfo
}

// ─────────────────────────────────────────────────────────────
// 持久化设置
// ─────────────────────────────────────────────────────────────

export interface AppSettings {
  permissionMode: PermissionMode
  updatedAt: string
}

// ─────────────────────────────────────────────────────────────
// 集成终端
// ─────────────────────────────────────────────────────────────

export interface TerminalData {
  id: string
  data: string
}

export interface TerminalExit {
  id: string
  code: number | null
}

export interface TerminalCreated {
  id: string
  /** 'node-pty' 或 'script'（无原生模块时的回退） */
  backend: string
}

// ─────────────────────────────────────────────────────────────
// 主进程 ↔ 渲染进程的 IPC 契约
//
// 渲染进程是纯 Web 环境（contextIsolation，无 Node），所有文件读写、
// agent 执行都发生在主进程。这里是两侧共用的唯一事实来源。
// ─────────────────────────────────────────────────────────────

export const IPC = {
  appInfo: 'app:info',
  /** 无人值守验证用：启动时预置的一条指令，由渲染进程挂载后主动来取 */
  autoPrompt: 'app:auto-prompt',
  workspaceInfo: 'workspace:info',
  workspaceChoose: 'workspace:choose',
  fsTree: 'fs:tree',
  fsRead: 'fs:read',
  fsSearch: 'fs:search',
  sessionList: 'session:list',
  sessionCreate: 'session:create',
  sessionLoad: 'session:load',
  agentSend: 'agent:send',
  agentAbort: 'agent:abort',
  agentApprove: 'agent:approve',
  permissionGet: 'permission:get',
  permissionSet: 'permission:set',
  checkpointList: 'checkpoint:list',
  checkpointCreate: 'checkpoint:create',
  checkpointRollback: 'checkpoint:rollback',
  terminalCreate: 'terminal:create',
  terminalWrite: 'terminal:write',
  terminalResize: 'terminal:resize',
  terminalKill: 'terminal:kill',
  /** 主进程 → 渲染进程：AgentEvent 推送 */
  pushAgentEvent: 'push:agent-event',
  /** 主进程 → 渲染进程：需要用户批准的请求（注意它早于 AgentEvent 的 approval） */
  pushApproval: 'push:approval',
  /** 主进程 → 渲染进程：agent 运行状态变化 */
  pushStatus: 'push:status',
  /** 主进程 → 渲染进程：终端输出 */
  pushTerminalData: 'push:terminal-data',
  /** 主进程 → 渲染进程：终端退出 */
  pushTerminalExit: 'push:terminal-exit'
} as const

export interface AppInfo {
  name: string
  version: string
  electron: string
  chrome: string
  node: string
  platform: string
  headless: boolean
  /** 'deepseek' 或 'mock'。没有 API Key 时自动降级为 mock，保证 UI 可被完整驱动 */
  provider: string
  model: string
  hasApiKey: boolean
  /** 当前持久化的审批模式，界面启动时用它回填，而不是写死 confirm */
  permissionMode: PermissionMode
  /** 终端后端：'node-pty' 或 'script'（无原生模块时的回退） */
  terminalBackend: string
}

export interface WorkspaceInfo {
  root: string
  name: string
}

export interface FileEntry {
  name: string
  /** 相对工作区根的路径，统一用 '/' 分隔（Windows 与 POSIX 一致） */
  path: string
  kind: 'dir' | 'file'
  size: number
  /** 目录层级，0 为工作区根下的第一层。侧边栏按它做缩进。 */
  depth: number
}

export interface FileContent {
  path: string
  text: string
  lines: number
  /** 超过预览上限被截断 */
  truncated: boolean
  /** 二进制文件不做文本预览 */
  binary: boolean
}

export interface SearchHit {
  path: string
  line: number
  text: string
}

/**
 * 待用户裁决的审批请求。
 *
 * 为什么要单独定义：内核的 AgentEvent 里虽然有 `approval`，
 * 但那是**决策完成之后**才广播的。UI 要在决策前弹卡片，就得靠这条消息。
 */
export interface ApprovalPrompt extends ApprovalRequest {
  id: string
  diff?: DiffPreview
}

export interface AgentStatus {
  running: boolean
  sessionId: string | null
  /** 当前处于第几轮 */
  step: number
}

export interface SessionSummary extends SessionMeta {
  messages: number
}
EOF

echo "== packages/provider-deepseek =="
# client.ts / mock.ts 都从 @witseek/protocol 取类型，必须声明依赖，
# 否则 pnpm 不会建软链，vitest 解析 @witseek/protocol 时会失败。
pkg packages/provider-deepseek @witseek/provider-deepseek ',
  "dependencies": {
    "@witseek/protocol": "workspace:*"
  }'

w packages/provider-deepseek/src/sse.ts <<'EOF'
/**
 * SSE 行解析器。
 *
 * 不按 "\n\n" 切分整块，而是逐行消费 —— 因为一个 chunk 可能正好切在
 * "\r\n\r\n" 中间，按块切会漏事件。逐行处理对分片边界天然免疫。
 */
export async function* parseSse(
  stream: ReadableStream<Uint8Array>
): AsyncGenerator<string, void, undefined> {
  const decoder = new TextDecoder()
  const reader = stream.getReader()
  let buf = ''
  let dataLines: string[] = []

  const flush = (): string | null => {
    if (dataLines.length === 0) return null
    const payload = dataLines.join('\n')
    dataLines = []
    return payload
  }

  /** 消费一行，返回需要 yield 的 payload（无则 null）。 */
  const feed = (line: string): string | null => {
    if (line.endsWith('\r')) line = line.slice(0, -1)
    if (line === '') return flush()
    if (line.startsWith('data:')) {
      dataLines.push(line.slice(5).replace(/^ /, ''))
    }
    // 其余字段（event: / id: / retry:）当前用不到，忽略
    return null
  }

  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      buf += decoder.decode(value, { stream: true })

      let nl: number
      while ((nl = buf.indexOf('\n')) !== -1) {
        const line = buf.slice(0, nl)
        buf = buf.slice(nl + 1)
        const payload = feed(line)
        if (payload !== null) yield payload
      }
    }
    // 流结束时缓冲区里可能还压着最后一行：SSE 不要求以换行收尾，
    // 而真实服务端最后一条 data: 之后往往直接断流。漏掉它就会丢事件。
    if (buf !== '') {
      const payload = feed(buf)
      buf = ''
      if (payload !== null) yield payload
    }
    const payload = flush()
    if (payload !== null) yield payload
  } finally {
    reader.releaseLock()
  }
}
EOF

w packages/provider-deepseek/src/client.ts <<'EOF'
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
EOF

w packages/provider-deepseek/src/mock.ts <<'EOF'
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
EOF

w packages/provider-deepseek/src/index.ts <<'EOF'
export { parseSse } from './sse.js'
export {
  DeepSeekClient,
  DEEPSEEK_MODELS,
  DEFAULT_BASE_URL,
  type DeepSeekOptions
} from './client.js'
export { MockProvider, textTurn, toolTurn, type MockResponder } from './mock.js'
EOF

echo "== packages/tools =="
pkg packages/tools @witseek/tools ',
  "dependencies": {
    "@witseek/protocol": "workspace:*"
  }'

w packages/tools/src/paths.ts <<'EOF'
import { isAbsolute, relative, resolve } from 'node:path'

export interface ResolvedPath {
  abs: string
  /** 是否越出工作区。越界不是错误，但会触发审批。 */
  outside: boolean
}

/**
 * 把用户/模型给的路径解析成绝对路径，并判断是否越出工作区。
 * 所有文件类工具都必须先过这里 —— 这是工作区隔离的唯一入口。
 */
export function resolveInWorkspace(root: string, p: string): ResolvedPath {
  const abs = isAbsolute(p) ? resolve(p) : resolve(root, p)
  const rel = relative(resolve(root), abs)
  const outside = rel.startsWith('..') || isAbsolute(rel)
  return { abs, outside }
}

/** 用于展示的相对路径；越界时原样返回绝对路径 */
export function displayPath(root: string, abs: string): string {
  const rel = relative(resolve(root), abs)
  return rel.startsWith('..') || isAbsolute(rel) ? abs : rel
}
EOF

w packages/tools/src/glob.ts <<'EOF'
/**
 * 极简 glob 匹配器。
 *
 * 自己实现而不引入 fast-glob，是为了让内核保持零第三方运行时依赖 ——
 * 在这种受限环境里，每多一个依赖就多一个失败点。
 *
 * 支持: **  *  ?  {a,b}  以及转义字符
 */
const SPECIAL = /[.+^$()|[\]\\]/g

function escapeLiteral(s: string): string {
  return s.replace(SPECIAL, '\\$&')
}

function segmentToRegex(seg: string): string {
  let out = ''
  for (let i = 0; i < seg.length; i++) {
    const c = seg[i]
    if (c === '*') {
      out += '[^/]*'
    } else if (c === '?') {
      out += '[^/]'
    } else if (c === '{') {
      const end = seg.indexOf('}', i)
      if (end === -1) {
        out += '\\{'
      } else {
        const alts = seg.slice(i + 1, end).split(',').map(escapeLiteral)
        out += `(?:${alts.join('|')})`
        i = end
      }
    } else {
      out += escapeLiteral(c)
    }
  }
  return out
}

export function globToRegExp(pattern: string): RegExp {
  const segs = pattern.split('/').filter((s) => s !== '' && s !== '.')
  let re = '^'
  for (let i = 0; i < segs.length; i++) {
    const seg = segs[i]
    if (seg === '**') {
      // 匹配零个或多个完整路径段（含其后的斜杠）
      re += '(?:[^/]+/)*'
    } else {
      re += segmentToRegex(seg)
      if (i < segs.length - 1) re += '/'
    }
  }
  re += '$'
  return new RegExp(re)
}

export function matchGlob(pattern: string, path: string): boolean {
  return globToRegExp(pattern).test(path.split('\\').join('/'))
}
EOF

w packages/tools/src/fs.ts <<'EOF'
import { mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { ToolDefinition, ToolResult } from '@witseek/protocol'
import { displayPath, resolveInWorkspace } from './paths.js'

const MAX_READ_BYTES = 512 * 1024

function str(args: Record<string, unknown>, key: string): string {
  const v = args[key]
  if (typeof v !== 'string' || v.length === 0) {
    throw new Error(`参数 ${key} 必须是非空字符串`)
  }
  return v
}

export const readFileTool: ToolDefinition = {
  name: 'read_file',
  description: '读取工作区内某个文本文件的内容，可指定行范围。返回带行号的内容。',
  readOnly: true,
  parameters: {
    type: 'object',
    properties: {
      path: { type: 'string', description: '相对于工作区的文件路径' },
      offset: { type: 'number', description: '起始行（从 1 开始，可选）' },
      limit: { type: 'number', description: '读取行数（可选）' }
    },
    required: ['path']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const raw = str(args, 'path')
    const { abs, outside } = resolveInWorkspace(ctx.workspaceRoot, raw)
    const info = await stat(abs)
    if (!info.isFile()) return { ok: false, output: `${raw} 不是文件` }
    if (info.size > MAX_READ_BYTES) {
      return { ok: false, output: `文件过大（${info.size} 字节），超过 ${MAX_READ_BYTES} 上限` }
    }

    const text = await readFile(abs, 'utf8')
    const all = text.split('\n')
    const offset = Math.max(1, Number(args.offset ?? 1))
    const limit = args.limit === undefined ? all.length : Math.max(0, Number(args.limit))
    const slice = all.slice(offset - 1, offset - 1 + limit)

    const width = String(offset + slice.length - 1).length
    const body = slice
      .map((line, i) => `${String(offset + i).padStart(width, ' ')}\t${line}`)
      .join('\n')

    return {
      ok: true,
      output: body,
      meta: { path: displayPath(ctx.workspaceRoot, abs), lines: all.length, outside, bytes: info.size }
    }
  }
}

export const writeFileTool: ToolDefinition = {
  name: 'write_file',
  description: '把内容写入工作区内的文件，文件不存在则创建，存在则整体覆盖。',
  readOnly: false,
  parameters: {
    type: 'object',
    properties: {
      path: { type: 'string', description: '相对于工作区的文件路径' },
      content: { type: 'string', description: '要写入的完整内容' }
    },
    required: ['path', 'content']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const raw = str(args, 'path')
    const content = typeof args.content === 'string' ? args.content : ''
    const { abs, outside } = resolveInWorkspace(ctx.workspaceRoot, raw)

    await mkdir(dirname(abs), { recursive: true })
    await writeFile(abs, content, 'utf8')

    return {
      ok: true,
      output: `已写入 ${displayPath(ctx.workspaceRoot, abs)}（${Buffer.byteLength(content, 'utf8')} 字节）`,
      meta: { path: displayPath(ctx.workspaceRoot, abs), outside }
    }
  }
}

export type EditOutcome =
  | { ok: true; text: string; occurrences: number; applied: number }
  | { ok: false; error: string }

/**
 * 精确字符串替换的**纯函数**版本。
 *
 * 抽出来是为了让 UI 的 diff 预览和真正执行的替换走同一份逻辑。
 * 如果主进程自己再实现一遍替换规则，预览就可能与实际写入的结果不一致 ——
 * 那种"预览说改了 3 行、实际改了 1 行"的偏差比没有预览更糟。
 */
export function applyEdit(
  text: string,
  oldText: string,
  newText: string,
  replaceAll = false
): EditOutcome {
  if (oldText === '') return { ok: false, error: 'oldText 不能为空' }
  const occurrences = text.split(oldText).length - 1
  if (occurrences === 0) return { ok: false, error: '未找到待替换的原文' }
  if (occurrences > 1 && !replaceAll) {
    return {
      ok: false,
      error: `原文出现了 ${occurrences} 次，不唯一。请扩大上下文，或显式设置 replaceAll。`
    }
  }
  const applied = replaceAll ? occurrences : 1
  const next = replaceAll ? text.split(oldText).join(newText) : text.replace(oldText, newText)
  return { ok: true, text: next, occurrences, applied }
}

export const editFileTool: ToolDefinition = {
  name: 'edit_file',
  description:
    '对文件做精确字符串替换。默认要求 oldText 在文件中唯一出现，否则报错；如需替换全部请设 replaceAll。',
  readOnly: false,
  parameters: {
    type: 'object',
    properties: {
      path: { type: 'string', description: '相对于工作区的文件路径' },
      oldText: { type: 'string', description: '要被替换的原文（需与文件内容完全一致）' },
      newText: { type: 'string', description: '替换后的文本' },
      replaceAll: { type: 'boolean', description: '是否替换全部匹配（默认 false）' }
    },
    required: ['path', 'oldText', 'newText']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const raw = str(args, 'path')
    const oldText = str(args, 'oldText')
    const newText = typeof args.newText === 'string' ? args.newText : ''
    const replaceAll = args.replaceAll === true

    const { abs, outside } = resolveInWorkspace(ctx.workspaceRoot, raw)
    const text = await readFile(abs, 'utf8')

    const outcome = applyEdit(text, oldText, newText, replaceAll)
    if (!outcome.ok) {
      return { ok: false, output: `${outcome.error}（${raw}）` }
    }
    await writeFile(abs, outcome.text, 'utf8')

    const added = newText === '' ? 0 : newText.split('\n').length
    const removed = oldText === '' ? 0 : oldText.split('\n').length

    return {
      ok: true,
      output: `已修改 ${displayPath(ctx.workspaceRoot, abs)}（替换 ${outcome.applied} 处）`,
      meta: {
        path: displayPath(ctx.workspaceRoot, abs),
        outside,
        occurrences: outcome.applied,
        added,
        removed
      }
    }
  }
}

export const listDirTool: ToolDefinition = {
  name: 'list_dir',
  description: '列出工作区内某个目录的内容，可控制递归深度。',
  readOnly: true,
  parameters: {
    type: 'object',
    properties: {
      path: { type: 'string', description: '相对工作区的目录路径，默认为工作区根' },
      depth: { type: 'number', description: '递归深度，默认 2，最大 5' }
    },
    required: []
  },
  async execute(args, ctx): Promise<ToolResult> {
    const raw = typeof args.path === 'string' && args.path ? args.path : '.'
    const depth = Math.min(5, Math.max(1, Number(args.depth ?? 2)))
    const { abs, outside } = resolveInWorkspace(ctx.workspaceRoot, raw)

    const lines: string[] = []
    let count = 0

    async function walk(dir: string, level: number): Promise<void> {
      if (level > depth) return
      const entries = await readdir(dir, { withFileTypes: true })
      entries.sort((a, b) => {
        if (a.isDirectory() !== b.isDirectory()) return a.isDirectory() ? -1 : 1
        return a.name.localeCompare(b.name)
      })
      for (const e of entries) {
        if (e.name === 'node_modules' || e.name === '.git') continue
        count++
        lines.push(`${'  '.repeat(level - 1)}${e.isDirectory() ? '[D]' : '   '} ${e.name}`)
        if (e.isDirectory()) await walk(join(dir, e.name), level + 1)
      }
    }

    const info = await stat(abs)
    if (!info.isDirectory()) return { ok: false, output: `${raw} 不是目录` }
    await walk(abs, 1)

    return {
      ok: true,
      output: lines.join('\n') || '(空目录)',
      meta: { path: displayPath(ctx.workspaceRoot, abs), entries: count, outside }
    }
  }
}
EOF

w packages/tools/src/search.ts <<'EOF'
import { readdir, readFile, stat } from 'node:fs/promises'
import { join, relative } from 'node:path'
import type { ToolDefinition, ToolResult } from '@witseek/protocol'
import { globToRegExp } from './glob.js'
import { displayPath, resolveInWorkspace } from './paths.js'

const SKIP_DIRS = new Set(['node_modules', '.git', 'dist', 'out', '.cache', '.runtime', '.tools'])
const MAX_FILE_BYTES = 1024 * 1024

async function* walkFiles(root: string, maxFiles: number): AsyncGenerator<string> {
  let yielded = 0
  const stack: string[] = [root]
  while (stack.length) {
    const dir = stack.pop() as string
    let entries
    try {
      entries = await readdir(dir, { withFileTypes: true })
    } catch {
      continue
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (SKIP_DIRS.has(e.name)) continue
        stack.push(join(dir, e.name))
      } else if (e.isFile()) {
        if (yielded++ >= maxFiles) return
        yield join(dir, e.name)
      }
    }
  }
}

export const globTool: ToolDefinition = {
  name: 'glob',
  description: '按 glob 模式查找文件。支持 ** * ? 与 {a,b}，例如 src/**/*.ts。',
  readOnly: true,
  parameters: {
    type: 'object',
    properties: {
      pattern: { type: 'string', description: 'glob 模式，相对工作区' },
      cwd: { type: 'string', description: '搜索起点，默认工作区根' },
      maxResults: { type: 'number', description: '最多返回条数，默认 200' }
    },
    required: ['pattern']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const pattern = typeof args.pattern === 'string' ? args.pattern : ''
    if (!pattern) return { ok: false, output: '缺少 pattern 参数' }
    const cwd = typeof args.cwd === 'string' && args.cwd ? args.cwd : '.'
    const maxResults = Math.max(1, Number(args.maxResults ?? 200))

    const { abs: root, outside } = resolveInWorkspace(ctx.workspaceRoot, cwd)
    const re = globToRegExp(pattern)
    const hits: string[] = []

    for await (const file of walkFiles(root, 20000)) {
      const rel = relative(root, file).split('\\').join('/')
      if (re.test(rel)) {
        hits.push(rel)
        if (hits.length >= maxResults) break
      }
    }
    hits.sort()

    return {
      ok: true,
      output: hits.length ? hits.join('\n') : '(无匹配)',
      meta: { count: hits.length, outside, pattern }
    }
  }
}

export const grepTool: ToolDefinition = {
  name: 'grep',
  description: '在文件内容中按正则搜索，返回文件、行号与匹配行。',
  readOnly: true,
  parameters: {
    type: 'object',
    properties: {
      pattern: { type: 'string', description: 'JavaScript 正则表达式' },
      glob: { type: 'string', description: '限定文件范围，默认 **/*' },
      cwd: { type: 'string', description: '搜索起点，默认工作区根' },
      ignoreCase: { type: 'boolean', description: '是否忽略大小写' },
      maxResults: { type: 'number', description: '最多返回条数，默认 100' }
    },
    required: ['pattern']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const pattern = typeof args.pattern === 'string' ? args.pattern : ''
    if (!pattern) return { ok: false, output: '缺少 pattern 参数' }

    let re: RegExp
    try {
      re = new RegExp(pattern, args.ignoreCase === true ? 'i' : '')
    } catch (e) {
      return { ok: false, output: `正则无效: ${(e as Error).message}` }
    }

    const fileGlob = typeof args.glob === 'string' && args.glob ? args.glob : '**/*'
    const cwd = typeof args.cwd === 'string' && args.cwd ? args.cwd : '.'
    const maxResults = Math.max(1, Number(args.maxResults ?? 100))

    const { abs: root, outside } = resolveInWorkspace(ctx.workspaceRoot, cwd)
    const fileRe = globToRegExp(fileGlob)
    const hits: string[] = []

    outer: for await (const file of walkFiles(root, 20000)) {
      const rel = relative(root, file).split('\\').join('/')
      if (!fileRe.test(rel)) continue

      let info
      try {
        info = await stat(file)
      } catch {
        continue
      }
      if (info.size > MAX_FILE_BYTES) continue

      let text: string
      try {
        text = await readFile(file, 'utf8')
      } catch {
        continue
      }
      if (text.includes('\u0000')) continue // 二进制

      const lines = text.split('\n')
      for (let i = 0; i < lines.length; i++) {
        if (re.test(lines[i])) {
          hits.push(`${rel}:${i + 1}: ${lines[i].trim().slice(0, 300)}`)
          if (hits.length >= maxResults) break outer
        }
      }
    }

    return {
      ok: true,
      output: hits.length ? hits.join('\n') : '(无匹配)',
      meta: { count: hits.length, outside, pattern }
    }
  }
}

export { displayPath }
EOF

w packages/tools/src/shell.ts <<'EOF'
import { spawn } from 'node:child_process'
import type { ToolDefinition, ToolResult } from '@witseek/protocol'
import { resolveInWorkspace } from './paths.js'

const MAX_OUTPUT = 64 * 1024
const DEFAULT_TIMEOUT = 60_000

function truncate(s: string): string {
  if (s.length <= MAX_OUTPUT) return s
  return `${s.slice(0, MAX_OUTPUT)}\n…[已截断，共 ${s.length} 字符]`
}

export const runCommandTool: ToolDefinition = {
  name: 'run_command',
  description:
    '在工作区内执行 shell 命令并返回输出。有超时保护，输出超长会被截断。需要用户授权。',
  readOnly: false,
  parameters: {
    type: 'object',
    properties: {
      command: { type: 'string', description: '要执行的命令' },
      cwd: { type: 'string', description: '工作目录，默认为工作区根' },
      timeoutMs: { type: 'number', description: '超时毫秒数，默认 60000' }
    },
    required: ['command']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const command = typeof args.command === 'string' ? args.command : ''
    if (!command) return { ok: false, output: '缺少 command 参数' }

    const cwdArg = typeof args.cwd === 'string' && args.cwd ? args.cwd : '.'
    const { abs: cwd, outside } = resolveInWorkspace(ctx.workspaceRoot, cwdArg)
    const timeoutMs = Math.min(600_000, Math.max(1_000, Number(args.timeoutMs ?? DEFAULT_TIMEOUT)))

    const started = Date.now()

    return await new Promise<ToolResult>((resolve) => {
      const child = spawn(command, {
        cwd,
        shell: true,
        env: { ...process.env, GIT_PAGER: 'cat', PAGER: 'cat' }
      })

      let stdout = ''
      let stderr = ''
      let settled = false

      const finish = (result: ToolResult): void => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        ctx.signal?.removeEventListener('abort', onAbort)
        resolve(result)
      }

      const timer = setTimeout(() => {
        child.kill('SIGKILL')
        finish({
          ok: false,
          output: `命令超时（${timeoutMs} ms）已终止\n--- stdout ---\n${truncate(stdout)}\n--- stderr ---\n${truncate(stderr)}`,
          meta: { exitCode: null, timedOut: true, outside, ms: Date.now() - started }
        })
      }, timeoutMs)

      const onAbort = (): void => {
        child.kill('SIGKILL')
        finish({ ok: false, output: '已取消', meta: { exitCode: null, aborted: true, outside } })
      }
      ctx.signal?.addEventListener('abort', onAbort, { once: true })

      child.stdout?.on('data', (d: Buffer) => {
        stdout += d.toString('utf8')
      })
      child.stderr?.on('data', (d: Buffer) => {
        stderr += d.toString('utf8')
      })
      child.on('error', (err) => {
        finish({ ok: false, output: `无法启动命令: ${err.message}`, meta: { outside } })
      })
      child.on('close', (code) => {
        const parts = [`退出码: ${code ?? 'null'}`]
        if (stdout) parts.push(`--- stdout ---\n${truncate(stdout)}`)
        if (stderr) parts.push(`--- stderr ---\n${truncate(stderr)}`)
        finish({
          ok: code === 0,
          output: parts.join('\n'),
          meta: { exitCode: code, outside, ms: Date.now() - started }
        })
      })
    })
  }
}
EOF

w packages/tools/src/index.ts <<'EOF'
import type { ToolDefinition } from '@witseek/protocol'
import { editFileTool, listDirTool, readFileTool, writeFileTool } from './fs.js'
import { globTool, grepTool } from './search.js'
import { runCommandTool } from './shell.js'

export { resolveInWorkspace, displayPath, type ResolvedPath } from './paths.js'
export { globToRegExp, matchGlob } from './glob.js'
export { readFileTool, writeFileTool, editFileTool, listDirTool, applyEdit, type EditOutcome } from './fs.js'
export { globTool, grepTool } from './search.js'
export { runCommandTool } from './shell.js'

/** 默认工具集。顺序即展示顺序。 */
export function createDefaultTools(): ToolDefinition[] {
  return [
    readFileTool,
    writeFileTool,
    editFileTool,
    listDirTool,
    globTool,
    grepTool,
    runCommandTool
  ]
}
EOF

echo
echo "==> P2 内核包（第一批）已生成"
find packages -name "*.ts" -not -path "*/node_modules/*" | sort
