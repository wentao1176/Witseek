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
