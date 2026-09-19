#!/usr/bin/env bash
# scaffold_p2_core.sh —— 生成 harness-core、测试配置与离线演示
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
cd "$ROOT"

w() { mkdir -p "$(dirname "$1")"; cat > "$1"; echo "  + $1"; }

echo "== packages/harness-core =="
mkdir -p packages/harness-core/src

w packages/harness-core/package.json <<'EOF'
{
  "name": "@witseek/harness-core",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "main": "./src/index.ts",
  "types": "./src/index.ts",
  "exports": {
    ".": "./src/index.ts"
  },
  "dependencies": {
    "@witseek/protocol": "workspace:*"
  },
  "devDependencies": {
    "@types/node": "^26.6.1",
    "@witseek/provider-deepseek": "workspace:*",
    "@witseek/tools": "workspace:*"
  },
  "scripts": {
    "typecheck": "tsc --noEmit -p tsconfig.json"
  }
}
EOF

# 注意：这个 package.json 由本脚本独家拥有。
# 早先 scaffold_p2_tests.sh 会再改一次它来补 typecheck，结果是"后跑的覆盖先跑的"——
# 重跑 core 就把 tests 注入的脚本抹掉了，属于隐蔽的顺序依赖。现在统一在这里写全。

# typecheck 脚本（由 scaffold_p2_tests.sh 注入）依赖这份 tsconfig，
# 两者必须同时存在，否则 `pnpm typecheck` 会因找不到配置而报错。
w packages/harness-core/tsconfig.json <<'EOF'
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "noEmit": true,
    "types": ["node"]
  },
  "include": ["src/**/*.ts", "test/**/*.ts"]
}
EOF

w packages/harness-core/src/registry.ts <<'EOF'
import type { ToolDefinition, ToolSchema } from '@witseek/protocol'

export class ToolRegistry {
  readonly #tools = new Map<string, ToolDefinition>()

  constructor(tools: ToolDefinition[] = []) {
    for (const t of tools) this.register(t)
  }

  register(tool: ToolDefinition): this {
    if (this.#tools.has(tool.name)) {
      throw new Error(`工具名重复: ${tool.name}`)
    }
    this.#tools.set(tool.name, tool)
    return this
  }

  get(name: string): ToolDefinition | undefined {
    return this.#tools.get(name)
  }

  has(name: string): boolean {
    return this.#tools.has(name)
  }

  list(): ToolDefinition[] {
    return [...this.#tools.values()]
  }

  schemas(): ToolSchema[] {
    return this.list().map(({ name, description, parameters }) => ({
      name,
      description,
      parameters
    }))
  }
}
EOF

w packages/harness-core/src/permission.ts <<'EOF'
import type {
  ApprovalRequest,
  PermissionMode,
  ToolDefinition
} from '@witseek/protocol'

export type PermissionVerdict = 'allow' | 'ask' | 'deny'

/**
 * 审批策略引擎。
 *
 * 三条规则，按优先级：
 *   1. 只读工具永远放行（读操作不产生副作用）
 *   2. read-only 模式下，任何写操作直接拒绝（不是"询问"，是不给）
 *   3. auto 模式且未越界 → 放行；其余情况一律询问
 *
 * "越界"指操作落在工作区之外。这一条即使在 auto 模式下也要求确认，
 * 因为工作区隔离是这套 harness 的安全底线。
 */
export class PermissionEngine {
  #mode: PermissionMode
  readonly #alwaysAllow = new Set<string>()

  constructor(mode: PermissionMode = 'confirm') {
    this.#mode = mode
  }

  get mode(): PermissionMode {
    return this.#mode
  }

  setMode(mode: PermissionMode): void {
    this.#mode = mode
  }

  /** 用户点了"总是允许"之后记住该工具 */
  remember(toolName: string): void {
    this.#alwaysAllow.add(toolName)
  }

  forgetAll(): void {
    this.#alwaysAllow.clear()
  }

  isRemembered(toolName: string): boolean {
    return this.#alwaysAllow.has(toolName)
  }

  verdict(tool: ToolDefinition, outsideWorkspace: boolean): PermissionVerdict {
    if (tool.readOnly) return 'allow'
    if (this.#mode === 'read-only') return 'deny'
    if (this.#alwaysAllow.has(tool.name)) return 'allow'
    if (this.#mode === 'auto' && !outsideWorkspace) return 'allow'
    return 'ask'
  }
}

/** 把工具调用转成人类可读的审批请求 */
export function describeApproval(
  tool: ToolDefinition,
  args: Record<string, unknown>,
  outsideWorkspace: boolean
): ApprovalRequest {
  const p = typeof args.path === 'string' ? args.path : undefined
  let summary: string

  switch (tool.name) {
    case 'write_file':
      summary = `写入文件 ${p ?? '(未知路径)'}`
      break
    case 'edit_file': {
      const occ = args.replaceAll === true ? '全部' : '1 处'
      summary = `修改文件 ${p ?? '(未知路径)'}（替换 ${occ}）`
      break
    }
    case 'run_command': {
      const cmd = typeof args.command === 'string' ? args.command : ''
      summary = `执行命令: ${cmd.length > 120 ? `${cmd.slice(0, 120)}…` : cmd}`
      break
    }
    default:
      summary = `${tool.name}${p ? ` ${p}` : ''}`
  }

  if (outsideWorkspace) summary += '  ⚠ 超出工作区范围'
  return { tool: tool.name, args, summary, outsideWorkspace }
}
EOF

w packages/harness-core/src/context.ts <<'EOF'
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
EOF

w packages/harness-core/src/session.ts <<'EOF'
import { appendFile, mkdir, readFile, readdir, stat, writeFile } from 'node:fs/promises'
import { join } from 'node:path'
import type { SessionMeta, SessionRecord } from '@witseek/protocol'

/**
 * 会话存储：JSONL 追加写。
 *
 * 选 JSONL 而不是数据库，是因为它的写入是纯追加、天然可回放 ——
 * 调试 agent 时能直接看到每一步发生了什么，这对 harness 类产品比查询能力更重要。
 */
/**
 * 取会话当前的元信息。
 *
 * 以**最后一条** meta 为准，而不是第一条 ——
 * JSONL 是纯追加的，更新标题或时间靠再追加一条 meta，
 * 不回头改写历史行。若用 `find` 取第一条，界面就会一直显示建会话时的旧信息。
 */
export function latestMeta(records: SessionRecord[]): SessionMeta | undefined {
  for (let i = records.length - 1; i >= 0; i--) {
    const r = records[i]
    if (r.kind === 'meta') return r.meta
  }
  return undefined
}

export class SessionStore {
  readonly #dir: string

  constructor(dir: string) {
    this.#dir = dir
  }

  get dir(): string {
    return this.#dir
  }

  #file(id: string): string {
    if (!/^[A-Za-z0-9_-]+$/.test(id)) throw new Error(`非法会话 id: ${id}`)
    return join(this.#dir, `${id}.jsonl`)
  }

  async init(): Promise<void> {
    await mkdir(this.#dir, { recursive: true })
  }

  async create(meta: SessionMeta): Promise<void> {
    await this.init()
    await writeFile(this.#file(meta.id), `${JSON.stringify({ kind: 'meta', meta })}\n`, 'utf8')
  }

  /** 追加一条 meta 来更新标题/时间。调用前该会话必须已 create 过。 */
  async touch(meta: SessionMeta): Promise<void> {
    await this.init()
    const file = this.#file(meta.id)
    // appendFile 在文件不存在时会**静默新建** —— 那样一个拼错的 id
    // 会凭空造出一个没有消息的空会话，混在列表里很难排查。这里显式要求它已存在。
    try {
      await stat(file)
    } catch {
      throw new Error(`会话不存在: ${meta.id}`)
    }
    await appendFile(file, `${JSON.stringify({ kind: 'meta', meta })}\n`, 'utf8')
  }

  async append(id: string, record: SessionRecord): Promise<void> {
    await this.init()
    await appendFile(this.#file(id), `${JSON.stringify(record)}\n`, 'utf8')
  }

  async read(id: string): Promise<SessionRecord[]> {
    // 必须先解析路径再进 try。把 this.#file(id) 写在 try 里面，
    // 非法 id 抛出的错误会被下面的 catch 当成"文件不存在"吞掉，
    // 路径穿越校验就形同虚设了 —— 这是被测试逮到的一个真实缺陷。
    const file = this.#file(id)
    let text: string
    try {
      text = await readFile(file, 'utf8')
    } catch {
      return []
    }
    const out: SessionRecord[] = []
    for (const line of text.split('\n')) {
      const t = line.trim()
      if (!t) continue
      try {
        out.push(JSON.parse(t) as SessionRecord)
      } catch {
        // 半行（写入中断）跳过，不让一行坏数据毁掉整个会话
      }
    }
    return out
  }

  async list(): Promise<SessionMeta[]> {
    await this.init()
    const files = await readdir(this.#dir)
    const metas: SessionMeta[] = []
    for (const f of files) {
      if (!f.endsWith('.jsonl')) continue
      const meta = latestMeta(await this.read(f.slice(0, -6)))
      if (meta) metas.push(meta)
    }
    metas.sort((a, b) => b.updatedAt.localeCompare(a.updatedAt))
    return metas
  }
}
EOF

w packages/harness-core/src/agent.ts <<'EOF'
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
EOF

w packages/harness-core/src/diff.ts <<'EOF'
import type { DiffHunk, DiffLine, DiffPreview } from '@witseek/protocol'

/**
 * 逐行 LCS 差异。
 *
 * 用 LCS 而不是"按行号硬比"：插入一行会让其后所有行号错位，
 * 硬比会把整段都标成变更，diff 就没法看了。
 *
 * 行数乘积超过阈值时退化为"整体删除 + 整体新增"：
 * LCS 的 DP 表是 O(n·m)，几万行的文件会把主进程卡住，
 * 而那种情况下用户本来也读不了逐行差异。
 */
const MAX_CELLS = 4_000_000

export function splitLines(text: string): string[] {
  if (text === '') return []
  // 末尾换行不算"多出一个空行"，否则每个正常文件都会挂一条无意义的差异
  const normalized = text.endsWith('\n') ? text.slice(0, -1) : text
  return normalized.split('\n')
}

export function diffLines(
  oldText: string,
  newText: string
): { lines: DiffLine[]; truncated: boolean } {
  const a = splitLines(oldText)
  const b = splitLines(newText)

  if ((a.length + 1) * (b.length + 1) > MAX_CELLS) {
    const lines: DiffLine[] = []
    a.forEach((text, i) => lines.push({ kind: 'del', oldNo: i + 1, text }))
    b.forEach((text, j) => lines.push({ kind: 'add', newNo: j + 1, text }))
    return { lines, truncated: true }
  }

  const n = a.length
  const m = b.length
  const w = m + 1
  // 从右下往左上填 LCS 长度表
  const t = new Uint32Array((n + 1) * w)
  for (let i = n - 1; i >= 0; i--) {
    for (let j = m - 1; j >= 0; j--) {
      t[i * w + j] =
        a[i] === b[j]
          ? t[(i + 1) * w + (j + 1)] + 1
          : Math.max(t[(i + 1) * w + j], t[i * w + (j + 1)])
    }
  }

  const lines: DiffLine[] = []
  let i = 0
  let j = 0
  while (i < n && j < m) {
    if (a[i] === b[j]) {
      lines.push({ kind: 'plain', oldNo: i + 1, newNo: j + 1, text: a[i] })
      i++
      j++
    } else if (t[(i + 1) * w + j] >= t[i * w + (j + 1)]) {
      lines.push({ kind: 'del', oldNo: i + 1, text: a[i] })
      i++
    } else {
      lines.push({ kind: 'add', newNo: j + 1, text: b[j] })
      j++
    }
  }
  while (i < n) lines.push({ kind: 'del', oldNo: i + 1, text: a[i++] })
  while (j < m) lines.push({ kind: 'add', newNo: j + 1, text: b[j++] })

  return { lines, truncated: false }
}

export interface HunkedDiff {
  /** 每行都可能带 hunkId（上下文行属于它相邻的 hunk） */
  lines: DiffLine[]
  hunks: DiffHunk[]
  /** 超大输入退化为整体替换时为 true，此时不提供 hunks */
  truncated: boolean
}

/**
 * 把扁平的差异行切成可独立接受/拒绝的 hunk。
 *
 * 连续的 add/del 归为一个变更段，段两侧各带 `context` 行未变更内容；
 * 两个段靠得太近（上下文重叠）时合并成一个 hunk —— 与 unified diff 的分块规则一致。
 *
 * truncated（超大文件退化结果）不做分组：那种情况下逐块审查没有意义，直接整体裁决。
 */
export function diffHunks(
  oldText: string,
  newText: string,
  context = 3
): HunkedDiff {
  const { lines, truncated } = diffLines(oldText, newText)
  if (truncated) return { lines, hunks: [], truncated }

  const changeIdx: number[] = []
  lines.forEach((l, idx) => {
    if (l.kind !== 'plain') changeIdx.push(idx)
  })
  if (changeIdx.length === 0) return { lines, hunks: [], truncated: false }

  // 1) 按上下文是否重叠把变更行聚成段
  const segments: Array<[number, number]> = []
  let segStart = changeIdx[0]
  let segEnd = changeIdx[0]
  for (const idx of changeIdx.slice(1)) {
    if (idx - segEnd <= 2 * context + 1) {
      segEnd = idx
    } else {
      segments.push([segStart, segEnd])
      segStart = idx
      segEnd = idx
    }
  }
  segments.push([segStart, segEnd])

  // 2) 扩上下文、切段、编号
  const annotated: DiffLine[] = lines.map((l) => ({ ...l }))
  const hunks: DiffHunk[] = []
  let hunkNo = 0

  for (const [cs, ce] of segments) {
    const start = Math.max(0, cs - context)
    const end = Math.min(lines.length - 1, ce + context)
    const id = `h${++hunkNo}`
    const hunkLines: DiffLine[] = []

    let oldStart = 0
    let newStart = 0
    let oldLines = 0
    let newLines = 0

    for (let k = start; k <= end; k++) {
      const line = { ...annotated[k], hunkId: id }
      annotated[k] = line
      hunkLines.push(line)
      if (line.oldNo !== undefined) {
        if (oldLines === 0) oldStart = line.oldNo
        oldLines++
      }
      if (line.newNo !== undefined) {
        if (newLines === 0) newStart = line.newNo
        newLines++
      }
    }

    // 纯新增（整段没有旧侧行号，例如空文件新增）：unified diff 约定旧侧起点为 0
    if (oldLines === 0) {
      oldStart = start > 0 ? lines[start - 1]?.oldNo ?? 0 : 0
    }
    if (newLines === 0) {
      newStart = start > 0 ? lines[start - 1]?.newNo ?? 0 : 0
    }

    hunks.push({ id, oldStart, oldLines, newStart, newLines, lines: hunkLines })
  }

  return { lines: annotated, hunks, truncated: false }
}

/**
 * 按 hunk 接受情况重建"新文件"文本。
 *
 * 规则：
 *   - plain 行始终保留；
 *   - add 行：所属 hunk 被接受才保留，否则丢弃；
 *   - del 行：所属 hunk 被接受则真的删除（不出现），被拒绝则把旧行留下来。
 *
 * 不变量（有测试守）：
 *   - 全部接受 → 严格等于 newText；
 *   - 全部拒绝 → 严格等于 oldText。
 */
export function rebuildText(
  lines: DiffLine[],
  acceptedHunkIds: ReadonlySet<string> | 'all',
  newTrailingNewline: boolean
): string {
  const out: string[] = []
  for (const l of lines) {
    if (l.kind === 'plain') {
      out.push(l.text)
    } else if (l.kind === 'add') {
      const keep = acceptedHunkIds === 'all' || (l.hunkId !== undefined && acceptedHunkIds.has(l.hunkId))
      if (keep) out.push(l.text)
    } else {
      // del：hunk 被接受意味着删除生效（不留）；拒绝则保留旧行
      const keepDeleted =
        acceptedHunkIds === 'all' || (l.hunkId !== undefined && acceptedHunkIds.has(l.hunkId))
      if (!keepDeleted) out.push(l.text)
    }
  }
  if (out.length === 0) return ''
  return out.join('\n') + (newTrailingNewline ? '\n' : '')
}

export function diffPreview(path: string, oldText: string, newText: string): DiffPreview {
  const hunked = diffHunks(oldText, newText)
  const { lines, hunks, truncated } = hunked
  let added = 0
  let removed = 0
  for (const l of lines) {
    if (l.kind === 'add') added++
    else if (l.kind === 'del') removed++
  }
  return { path, added, removed, lines, truncated, hunks }
}
EOF

w packages/harness-core/src/index.ts <<'EOF'
export { ToolRegistry } from './registry.js'
export {
  PermissionEngine,
  describeApproval,
  type PermissionVerdict
} from './permission.js'
export {
  ContextManager,
  estimateTokens,
  messageTokens,
  conversationTokens,
  type ContextOptions,
  type FitResult
} from './context.js'
export { SessionStore, latestMeta } from './session.js'
export {
  diffLines,
  diffPreview,
  diffHunks,
  rebuildText,
  splitLines,
  type HunkedDiff
} from './diff.js'
export {
  CheckpointService,
  DEFAULT_SKIP_DIRS,
  type CheckpointServiceOptions,
  type RollbackResult
} from './checkpoint.js'
export { SettingsStore, DEFAULT_PERMISSION_MODE } from './settings.js'
export {
  runAgent,
  buildSystemPrompt,
  type AgentRunOptions,
  type AgentRunResult,
  type Approver
} from './agent.js'
EOF

echo
echo "== 根配置：vitest =="

w vitest.config.ts <<'EOF'
import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    include: ['packages/**/test/**/*.test.ts', 'tests/**/*.test.ts'],
    environment: 'node',
    reporters: ['default']
  }
})
EOF

echo "== 离线演示脚本 =="

w scripts/demo-kernel.mts <<'EOF'
/**
 * 离线演示：不接任何 API，用 MockProvider 驱动完整 Agent 循环。
 *
 * 这条链路的价值在于：它证明了内核可以在没有 API Key、没有 UI 的情况下
 * 跑通「读文件 → 改文件 → 给出结论」的闭环。P3 接界面时，替换的只是 provider 与事件消费方。
 *
 * 运行: pnpm demo:kernel
 */
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { MockProvider, textTurn, toolTurn } from '@witseek/provider-deepseek'
import { PermissionEngine, ToolRegistry, runAgent } from '@witseek/harness-core'
import { createDefaultTools } from '@witseek/tools'
import type { AgentEvent } from '@witseek/protocol'

const C = {
  dim: '\u001b[2m',
  cyan: '\u001b[36m',
  green: '\u001b[32m',
  yellow: '\u001b[33m',
  red: '\u001b[31m',
  reset: '\u001b[0m'
}

async function main(): Promise<void> {
  const workspace = await mkdtemp(join(tmpdir(), 'witseek-demo-'))
  const target = join(workspace, 'MainActivity.java')
  await writeFile(
    target,
    [
      'public class MainActivity extends AppCompatActivity {',
      '  @Override',
      '  protected void onCreate(Bundle b) {',
      '    super.onCreate(b);',
      '    tvTitle.setText(name);',
      '  }',
      '}'
    ].join('\n'),
    'utf8'
  )

  console.log(`${C.dim}工作区: ${workspace}${C.reset}\n`)

  // 三轮脚本：读 → 改 → 结论
  const provider = new MockProvider((_req, turn) => {
    if (turn === 0) {
      return toolTurn([{ name: 'read_file', args: { path: 'MainActivity.java' } }], '先看一下这个文件。')
    }
    if (turn === 1) {
      return toolTurn([
        {
          name: 'edit_file',
          args: {
            path: 'MainActivity.java',
            oldText: '    tvTitle.setText(name);',
            newText: '    if (tvTitle != null) {\n      tvTitle.setText(name);\n    }'
          }
        }
      ])
    }
    return textTurn(
      '崩溃点是 setContentView 之前访问了未初始化的 View，已补上空值保护。',
      'tvTitle 在 onCreate 里被直接解引用，但它可能是 null…'
    )
  })

  const registry = new ToolRegistry(createDefaultTools())
  const permission = new PermissionEngine('confirm')

  // 思维链与正式回答是两股独立的流，各自用 process.stdout.write 追加。
  // 不在切换处补换行，两段文字会粘成一行，读起来像一句病句。
  let pendingBreak = false
  const brk = (): void => {
    if (pendingBreak) {
      process.stdout.write('\n')
      pendingBreak = false
    }
  }

  const render = (e: AgentEvent): void => {
    switch (e.type) {
      case 'step-start':
        brk()
        console.log(`${C.dim}── 第 ${e.step} 轮 ──${C.reset}`)
        break
      case 'reasoning':
        pendingBreak = true
        process.stdout.write(`${C.dim}${e.text}${C.reset}`)
        break
      case 'content':
        brk()
        pendingBreak = true
        process.stdout.write(e.text)
        break
      case 'tool-start':
        brk()
        console.log(`${C.cyan}▶ ${e.call.name}${C.reset} ${C.dim}${e.call.arguments}${C.reset}`)
        break
      case 'tool-end':
        brk()
        console.log(`${e.result.ok ? C.green : C.red}${e.result.ok ? '✓' : '✗'}${C.reset} ${C.dim}${e.result.output.split('\n')[0].slice(0, 100)}${C.reset}`)
        break
      case 'approval':
        brk()
        console.log(`${C.yellow}⚑ 审批${C.reset} ${e.request.summary} → ${e.decision}`)
        break
      case 'usage':
        brk()
        console.log(`${C.dim}  usage: prompt=${e.usage.promptTokens} completion=${e.usage.completionTokens}${C.reset}`)
        break
      case 'done':
        brk()
        console.log(`\n${C.dim}结束: ${e.reason}${C.reset}`)
        break
    }
  }

  const result = await runAgent(
    {
      provider,
      model: 'mock-model',
      registry,
      workspaceRoot: workspace,
      permission,
      // 演示里自动批准，模拟用户点了"批准"
      approver: async () => 'approve',
      onEvent: render
    },
    '修复 MainActivity 里的崩溃'
  )

  console.log(`\n${C.dim}────────────${C.reset}`)
  console.log(`步数: ${result.steps}  结束原因: ${result.stopReason}`)
  console.log(`\n修改后的文件:\n${await readFile(target, 'utf8')}`)

  if (result.stopReason !== 'completed') process.exitCode = 1
}

main().catch((e) => {
  console.error(e)
  process.exitCode = 1
})
EOF

echo "== 测试脚本 =="

w scripts/test.sh <<'EOF'
#!/usr/bin/env bash
# test.sh —— 运行内核单测
#
# 用法:
#   bash scripts/test.sh            # 跑一遍
#   bash scripts/test.sh --watch    # 监听模式
#   bash scripts/test.sh --demo     # 跑离线演示（不接 API）
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
export PATH="$HOME/.nvm/versions/node/v22.22.2/bin:$PATH"
export PNPM_HOME="$ROOT/.cache/pnpm"
export PATH="$PNPM_HOME:$PATH"
cd "$ROOT"

case "${1:-}" in
  --watch) exec pnpm exec vitest ;;
  --demo)  exec pnpm exec tsx scripts/demo-kernel.mts ;;
  *)       exec pnpm exec vitest run ;;
esac
EOF

echo
echo "==> P2 内核与演示已生成"
find packages -name "*.ts" -not -path "*/node_modules/*" | sort
