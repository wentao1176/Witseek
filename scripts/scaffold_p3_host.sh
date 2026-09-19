#!/usr/bin/env bash
# scaffold_p3_host.sh —— 生成 P3 的主进程与 preload
#
# 产物:
#   apps/desktop/src/main/provider.ts    提供方选择（有 Key 走 DeepSeek，无 Key 走脚本化 Mock）
#   apps/desktop/src/main/workspace.ts   工作区根解析、文件树、预览读取、内容检索
#   apps/desktop/src/main/host.ts        AgentHost —— 会话、审批桥、事件转发
#   apps/desktop/src/main/ipc.ts         把 AgentHost 接到 ipcMain / webContents
#   apps/desktop/src/main/index.ts       应用入口：窗口 + CSP + 生命周期
#   apps/desktop/src/preload/index.ts    contextBridge 白名单 API
#   scripts/make-demo-workspace.sh       生成演示用工作区
#
# 关键设计:
#   1. host.ts **不 import electron**，只接收一个 sink 回调。
#      这样 AgentHost 能在纯 Node 下单测，Electron 只负责把它接到 webContents。
#   2. 没有 API Key 时自动降级到脚本化 Mock，
#      保证界面能被完整驱动（流式、工具调用、审批），不至于因缺密钥而无法验证。
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
cd "$ROOT"

w() { mkdir -p "$(dirname "$1")"; cat > "$1"; echo "  + $1"; }

echo "== 主进程：提供方选择 =="

w apps/desktop/src/main/provider.ts <<'EOF'
import type { ChatRequest, ModelProvider, StreamEvent } from '@witseek/protocol'
import { DeepSeekClient, MockProvider } from '@witseek/provider-deepseek'

export interface ProviderChoice {
  provider: ModelProvider
  model: string
  hasApiKey: boolean
}

const DEFAULT_MODEL = 'deepseek-reasoner'

export function selectProvider(env: NodeJS.ProcessEnv = process.env): ProviderChoice {
  const key = (env.WITSEEK_API_KEY ?? env.DEEPSEEK_API_KEY ?? '').trim()
  if (key) {
    return {
      provider: new DeepSeekClient({ apiKey: key }),
      model: (env.WITSEEK_MODEL ?? '').trim() || DEFAULT_MODEL,
      hasApiKey: true
    }
  }
  // 没有 API Key 时降级到脚本化 Mock。
  // 这样界面依然能被完整驱动（流式输出、工具调用、审批卡片），
  // 而不是因为缺一个密钥就什么都看不到、什么也验证不了。
  return { provider: createScriptedProvider(), model: 'mock-scripted', hasApiKey: false }
}

// ─────────────────────────────────────────────────────────────
// 脚本化演示提供方
//
// 它不是"假装很聪明"——它按固定剧本走四轮：列目录 → 读文件 → 标注文件 → 给结论。
// 目标只有一个：在没有 API Key 的情况下，把 UI 的每条渲染路径都真实跑一遍。
// 它会主动说明自己是演示流程，不冒充真实模型。
// ─────────────────────────────────────────────────────────────

const MARK = '[Witseek 演示]'

/** 把文本切成多个 delta，逼真地走一遍"流式追加"渲染路径 */
function chunks(text: string, size = 14): StreamEvent[] {
  const out: StreamEvent[] = []
  for (let i = 0; i < text.length; i += size) {
    out.push({ type: 'content-delta', text: text.slice(i, i + size) })
  }
  return out
}

function reasoningChunks(text: string, size = 18): StreamEvent[] {
  const out: StreamEvent[] = []
  for (let i = 0; i < text.length; i += size) {
    out.push({ type: 'reasoning-delta', text: text.slice(i, i + size) })
  }
  return out
}

function toolCall(name: string, args: Record<string, unknown>, id: string): StreamEvent[] {
  return [
    { type: 'tool-call', call: { id, name, arguments: JSON.stringify(args) } },
    { type: 'done', finishReason: 'tool_calls' }
  ]
}

/** 从后往前找指定工具最近一次的输出 */
function lastToolOutput(req: ChatRequest, tool: string): string | undefined {
  for (let i = req.messages.length - 1; i >= 0; i--) {
    const m = req.messages[i]
    if (m.role === 'tool' && m.name === tool) return m.content
  }
  return undefined
}

/**
 * 候选文件打分。数值越小越优先。
 * 返回 99 表示不参与（例如 .json 无法安全地插入注释）。
 */
function score(p: string): number {
  const l = p.toLowerCase()
  if (l.endsWith('.java')) return 0
  if (l.endsWith('.kt')) return 1
  if (/\.(ts|tsx|js|mjs|cjs)$/.test(l)) return 2
  if (l.endsWith('.gradle')) return 3
  if (l.endsWith('.py')) return 4
  if (l.endsWith('.xml') || l.endsWith('.html')) return 6
  if (l.endsWith('.md') || l.endsWith('.txt')) return 8
  return 99
}

function pickTarget(req: ChatRequest): string | null {
  const out = lastToolOutput(req, 'glob')
  if (!out || out === '(无匹配)') return null
  const paths = out
    .split('\n')
    .map((s) => s.trim())
    .filter(Boolean)
    .filter((p) => score(p) < 99)
  paths.sort((a, b) => score(a) - score(b) || a.localeCompare(b))
  return paths[0] ?? null
}

/** 按扩展名给出合法的注释语法，避免往文件里塞进去会破坏语法的东西 */
function commentFor(p: string): string {
  const l = p.toLowerCase()
  const body = `${MARK} 本文件由 agent 在演示会话中标注`
  if (l.endsWith('.py')) return `# ${body}`
  if (l.endsWith('.md') || l.endsWith('.txt') || l.endsWith('.xml') || l.endsWith('.html')) {
    return `<!-- ${body} -->`
  }
  return `// ${body}`
}

/** 从 read_file 的输出里取出第一行的原文（输出格式为 `<行号>\t<内容>`） */
function firstLineOf(req: ChatRequest): string | null {
  const out = lastToolOutput(req, 'read_file')
  if (!out) return null
  const m = /^\s*\d+\t(.*)$/.exec(out.split('\n')[0] ?? '')
  return m ? m[1] : null
}

export function createScriptedProvider(): MockProvider {
  return new MockProvider((req, turn) => {
    if (turn === 0) {
      return [
        ...reasoningChunks('先看看工作区里有哪些文件，再决定读哪一个。'),
        ...chunks('先看一下工作区里有什么。'),
        ...toolCall('glob', { pattern: '**/*', maxResults: 60 }, 'demo-1')
      ]
    }

    if (turn === 1) {
      const target = pickTarget(req)
      if (!target) {
        return [
          ...chunks('这个工作区里没有找到可读的文本文件，演示到此结束。'),
          { type: 'done', finishReason: 'stop' }
        ]
      }
      return [
        ...reasoningChunks(`挑中了 ${target}，先把它读出来确认内容再动手。`),
        ...toolCall('read_file', { path: target }, 'demo-2')
      ]
    }

    if (turn === 2) {
      const target = pickTarget(req)
      const firstLine = firstLineOf(req)
      if (!target || firstLine === null) {
        return [
          ...chunks('没能读到文件内容，跳过修改这一步。'),
          { type: 'done', finishReason: 'stop' }
        ]
      }
      // 幂等：已经标注过就不再改，避免反复运行把文件越写越长
      if (firstLine.includes(MARK)) {
        return [
          ...reasoningChunks('文件里已经有演示标记了，不必重复写入。'),
          ...chunks('目标文件已带演示标记，跳过修改。'),
          { type: 'done', finishReason: 'stop' }
        ]
      }
      return [
        ...reasoningChunks('在第一行之前插入一行注释作为本次会话的标记，改动小且可逆。'),
        ...toolCall(
          'edit_file',
          { path: target, oldText: firstLine, newText: `${commentFor(target)}\n${firstLine}` },
          'demo-3'
        )
      ]
    }

    const target = pickTarget(req) ?? '目标文件'
    return [
      ...chunks(
        [
          `已完成本轮演示：读取并标注了 ${target}。`,
          '',
          '注意：当前没有配置 DEEPSEEK_API_KEY，走的是内置的脚本化演示流程（provider = mock）。',
          '它不会真正理解你的代码，只是把「流式输出 → 工具调用 → 审批 → 改文件」这条链路完整走了一遍。',
          '设置 API Key 后重启应用，即可换成真实模型推理，界面不需要改动。'
        ].join('\n')
      ),
      { type: 'done', finishReason: 'stop' }
    ]
  })
}
EOF

echo "== 主进程：工作区读写 =="

w apps/desktop/src/main/workspace.ts <<'EOF'
import { readFile, readdir, stat } from 'node:fs/promises'
import { join, relative, resolve } from 'node:path'
import type { FileContent, FileEntry, SearchHit } from '@witseek/protocol'
import { grepTool, resolveInWorkspace } from '@witseek/tools'

/** 这些目录永远不进文件树：要么是依赖，要么是构建产物 */
const SKIP_DIRS = new Set([
  'node_modules',
  '.git',
  'dist',
  'out',
  '.cache',
  '.tools',
  '.setup',
  '.runtime',
  '.relay-inbox'
])

const MAX_ENTRIES = 4000
// 曾经是 6 —— 那是个想当然的值。Java/Kotlin/Android 的源码路径天生很深：
//   app/src/main/java/com/xwt/schedule/HolidayUtils.java  → depth 7
// depth 6 的树会在 com/xwt 处停住，schedule/ 及其下所有 .java 根本不进树，
// 而 xwt 是目录照样画一个展开箭头 —— 界面上表现为"展开了却空的目录"。
// 真正兜底的是 MAX_ENTRIES：深度大但目录浅，条目数不会因此失控。
const MAX_DEPTH = 12
const PREVIEW_MAX_BYTES = 256 * 1024
const PREVIEW_MAX_LINES = 5000

export function resolveWorkspaceRoot(env: NodeJS.ProcessEnv = process.env): string {
  const raw = (env.WITSEEK_WORKSPACE ?? '').trim()
  return raw ? resolve(raw) : process.cwd()
}

export interface TreeResult {
  entries: FileEntry[]
  truncated: boolean
}

/**
 * 生成扁平化的文件树（带 depth）。
 * 用扁平数组而不是嵌套对象：渲染侧直接 map 一遍即可，
 * 也避免为了折叠展开去递归重建整棵树。
 */
export async function listTree(
  root: string,
  maxDepth = MAX_DEPTH,
  maxEntries = MAX_ENTRIES
): Promise<TreeResult> {
  const entries: FileEntry[] = []
  let truncated = false

  async function walk(dir: string, depth: number): Promise<void> {
    if (depth >= maxDepth) return
    let items
    try {
      items = await readdir(dir, { withFileTypes: true })
    } catch {
      return
    }
    items.sort((a, b) => {
      if (a.isDirectory() !== b.isDirectory()) return a.isDirectory() ? -1 : 1
      return a.name.localeCompare(b.name)
    })

    for (const item of items) {
      // 隐藏文件不进树：绝大多数是工具产生的噪音，混进来只会淹没源码
      if (item.name.startsWith('.')) continue
      if (item.isDirectory() && SKIP_DIRS.has(item.name)) continue
      if (entries.length >= maxEntries) {
        truncated = true
        return
      }

      const abs = join(dir, item.name)
      const rel = relative(root, abs).split('\\').join('/')
      let size = 0
      if (item.isFile()) {
        try {
          size = (await stat(abs)).size
        } catch {
          size = 0
        }
      }
      entries.push({
        name: item.name,
        path: rel,
        kind: item.isDirectory() ? 'dir' : 'file',
        size,
        depth
      })
      if (item.isDirectory()) await walk(abs, depth + 1)
    }
  }

  await walk(root, 0)
  return { entries, truncated }
}

export async function readForPreview(root: string, relPath: string): Promise<FileContent> {
  const { abs, outside } = resolveInWorkspace(root, relPath)
  if (outside) {
    return { path: relPath, text: '', lines: 0, truncated: false, binary: true }
  }

  const buf = await readFile(abs)
  // 含 NUL 字节基本可以断定是二进制；硬当文本渲染会得到一堆乱码
  if (buf.includes(0)) {
    return { path: relPath, text: '', lines: 0, truncated: false, binary: true }
  }

  const byteClipped = buf.length > PREVIEW_MAX_BYTES
  let text = buf.subarray(0, PREVIEW_MAX_BYTES).toString('utf8')

  const all = text.split('\n')
  const lineClipped = all.length > PREVIEW_MAX_LINES
  if (lineClipped) text = all.slice(0, PREVIEW_MAX_LINES).join('\n')

  return {
    path: relPath,
    text,
    lines: text === '' ? 0 : text.split('\n').length,
    truncated: byteClipped || lineClipped,
    binary: false
  }
}

/**
 * 内容检索直接复用内核的 grep 工具。
 * 这样"界面上搜到的"与"模型能看到的"范围完全一致 ——
 * 如果界面自己实现一套搜索，很容易出现用户能搜到、模型却看不到的文件。
 */
export async function searchFiles(
  root: string,
  pattern: string,
  fileGlob = '**/*'
): Promise<SearchHit[]> {
  if (!pattern.trim()) return []
  const result = await grepTool.execute(
    { pattern, glob: fileGlob, maxResults: 200 },
    { workspaceRoot: root }
  )
  if (!result.ok || result.output === '(无匹配)') return []

  const hits: SearchHit[] = []
  for (const line of result.output.split('\n')) {
    const m = /^(.+?):(\d+): (.*)$/.exec(line)
    if (!m) continue
    hits.push({ path: m[1], line: Number(m[2]), text: m[3] })
  }
  return hits
}
EOF

echo "== 主进程：AgentHost =="

w apps/desktop/src/main/host.ts <<'EOF'
import { createHash } from 'node:crypto'
import { readFile } from 'node:fs/promises'
import { basename } from 'node:path'
import type {
  AgentEvent,
  AgentStatus,
  ApprovalDecision,
  ApprovalPrompt,
  ApprovalRequest,
  ApprovalResolution,
  CheckpointInfo,
  CheckpointRollbackResult,
  ChatMessage,
  DiffPreview,
  ModelProvider,
  PermissionMode,
  SessionMeta,
  SessionSummary,
  Usage
} from '@witseek/protocol'
import {
  CheckpointService,
  PermissionEngine,
  SessionStore,
  SettingsStore,
  ToolRegistry,
  diffHunks,
  diffPreview,
  rebuildText,
  latestMeta,
  runAgent,
  type Approver
} from '@witseek/harness-core'
import { applyEdit, createDefaultTools, displayPath, resolveInWorkspace } from '@witseek/tools'

/** AgentHost 与外界（Electron / 测试）之间的唯一接口 */
export interface HostSink {
  event(event: AgentEvent): void
  approval(prompt: ApprovalPrompt): void
  status(status: AgentStatus): void
}

export interface AgentHostOptions {
  workspaceRoot: string
  provider: ModelProvider
  model: string
  sessionsDir: string
  /** 事件出口。Electron 侧接 webContents，测试侧接一个数组收集器。 */
  sink: HostSink
  permissionMode?: 'read-only' | 'confirm' | 'auto'
  maxSteps?: number
  /**
   * 无人值守模式：审批不等待界面响应。
   * 仍然会把请求推给 UI（卡片能显示出来），但不阻塞 —— 否则没有界面应答时会永远挂住。
   */
  autoApprove?: boolean
  /** 每次审批前是否计算 diff 预览 */
  computeDiff?: boolean
  /** 设置持久化；提供后审批模式切换会落盘，启动时 init() 从它恢复 */
  settingsStore?: SettingsStore
  /** 工作区检查点服务；提供后每轮对话前自动打快照 */
  checkpoints?: CheckpointService
}

const APPROVAL_TIMEOUT_MS = 5 * 60 * 1000

function newId(prefix: string): string {
  return `${prefix}_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`
}

function titleFrom(text: string): string {
  const one = text.replace(/\s+/g, ' ').trim()
  return one.length > 24 ? `${one.slice(0, 24)}…` : one || '未命名会话'
}

interface PendingApproval {
  resolve(resolution: ApprovalResolution): void
  prompt: ApprovalPrompt
  /** 审批时读到的改动前全文（hunk 部分应用需要） */
  before: string
  /** 模型改动本应产生的全文 */
  after: string
  toolName: string
  args: Record<string, unknown>
}

/**
 * 会话与 Agent 循环的宿主。
 *
 * 刻意不 import electron —— 它只通过 HostSink 往外说话。
 * 这样这个类能在纯 Node 下被单测，而 Electron 只负责把 sink 接到 webContents。
 */
export class AgentHost {
  readonly #workspace: string
  readonly #provider: ModelProvider
  readonly #model: string
  readonly #sink: HostSink
  readonly #registry: ToolRegistry
  readonly #permission: PermissionEngine
  readonly #store: SessionStore
  readonly #maxSteps: number
  readonly #autoApprove: boolean
  readonly #computeDiff: boolean
  readonly #settingsStore?: SettingsStore
  readonly #checkpoints?: CheckpointService

  #history: ChatMessage[] = []
  #sessionId: string | null = null
  #meta: SessionMeta | null = null
  #running = false
  #step = 0
  #usage: Usage = { promptTokens: 0, completionTokens: 0, totalTokens: 0 }
  #abort: AbortController | null = null
  #pending = new Map<string, PendingApproval>()

  constructor(opts: AgentHostOptions) {
    this.#workspace = opts.workspaceRoot
    this.#provider = opts.provider
    this.#model = opts.model
    this.#sink = opts.sink
    this.#registry = new ToolRegistry(createDefaultTools())
    this.#permission = new PermissionEngine(opts.permissionMode ?? 'confirm')
    this.#store = new SessionStore(opts.sessionsDir)
    this.#maxSteps = opts.maxSteps ?? 12
    this.#autoApprove = opts.autoApprove ?? false
    this.#computeDiff = opts.computeDiff ?? true
    this.#settingsStore = opts.settingsStore
    this.#checkpoints = opts.checkpoints
  }

  get workspace(): string {
    return this.#workspace
  }

  get workspaceName(): string {
    return basename(this.#workspace)
  }

  get model(): string {
    return this.#model
  }

  get providerId(): string {
    return this.#provider.id
  }

  get sessionId(): string | null {
    return this.#sessionId
  }

  get running(): boolean {
    return this.#running
  }

  get usage(): Usage {
    return this.#usage
  }

  get permissionMode(): PermissionMode {
    return this.#permission.mode
  }

  /** 从设置文件恢复审批模式。窗口创建后、首次使用前调用一次。 */
  async init(): Promise<void> {
    if (this.#settingsStore) {
      const settings = await this.#settingsStore.load()
      this.#permission.setMode(settings.permissionMode)
    }
  }

  /** 切换审批模式并持久化 */
  async setPermissionMode(mode: PermissionMode): Promise<PermissionMode> {
    this.#permission.setMode(mode)
    if (this.#settingsStore) await this.#settingsStore.save({ permissionMode: mode })
    return mode
  }

  /** 供界面回填历史 */
  get history(): ChatMessage[] {
    return this.#history
  }

  async startSession(title = '新会话'): Promise<string> {
    const id = newId('s')
    const now = new Date().toISOString()
    this.#meta = {
      id,
      title: titleFrom(title),
      workspace: this.#workspace,
      model: this.#model,
      createdAt: now,
      updatedAt: now
    }
    await this.#store.create(this.#meta)
    this.#sessionId = id
    this.#history = []
    this.#usage = { promptTokens: 0, completionTokens: 0, totalTokens: 0 }
    this.#emitStatus()
    return id
  }

  async listSessions(): Promise<SessionSummary[]> {
    const metas = await this.#store.list()
    const out: SessionSummary[] = []
    for (const meta of metas) {
      const records = await this.#store.read(meta.id)
      out.push({ ...meta, messages: records.filter((r) => r.kind === 'message').length })
    }
    return out
  }

  async loadSession(id: string): Promise<ChatMessage[]> {
    const records = await this.#store.read(id)
    const meta = latestMeta(records)
    if (!meta) return []
    this.#sessionId = meta.id
    this.#meta = meta
    this.#history = records
      .filter((r): r is { kind: 'message'; message: ChatMessage } => r.kind === 'message')
      .map((r) => r.message)
    this.#emitStatus()
    return this.#history
  }

  abort(): void {
    this.#abort?.abort()
  }

  /**
   * 界面裁决审批。
   *
   * 逐块审查（acceptedHunkIds 只覆盖部分 hunk）时，在这里把"未接受的块"还原：
   * 基于审批时缓存的 before/after 重建文本，并改写工具参数 ——
   * - edit_file → oldText=审批时全文、newText=重建后全文（全文唯一匹配，语义等价）
   * - write_file → content=重建后文本
   * 内核不感知 diff，只负责执行 rewrittenArgs。
   * 找不到对应 id（已超时/已自动处理）返回 false。
   */
  resolveApproval(
    id: string,
    decision: ApprovalDecision,
    acceptedHunkIds?: string[]
  ): boolean {
    const pending = this.#pending.get(id)
    if (!pending) return false
    this.#pending.delete(id)

    let resolution: ApprovalResolution = { decision }
    const hunks = pending.prompt.diff?.hunks ?? []

    if (decision !== 'deny' && acceptedHunkIds && hunks.length > 0) {
      const accepted = new Set(acceptedHunkIds)
      if (accepted.size < hunks.length) {
        const hunked = diffHunks(pending.before, pending.after)
        const rebuilt = rebuildText(hunked.lines, accepted, pending.after.endsWith('\n'))
        if (rebuilt === pending.before) {
          // 所有变更块都被拒绝 → 等价于整体拒绝
          resolution = { decision: 'deny' }
        } else if (pending.toolName === 'edit_file') {
          resolution = {
            decision: 'approve',
            acceptedHunkIds: [...accepted],
            rewrittenArgs: { path: pending.args.path, oldText: pending.before, newText: rebuilt }
          }
        } else {
          // write_file
          resolution = {
            decision: 'approve',
            acceptedHunkIds: [...accepted],
            rewrittenArgs: { path: pending.args.path, content: rebuilt }
          }
        }
      } else {
        resolution = { decision, acceptedHunkIds: [...accepted] }
      }
    }

    pending.resolve(resolution)
    return true
  }

  /** 窗口关闭时调用，避免残留的审批 Promise 永远挂着 */
  dispose(): void {
    for (const p of this.#pending.values()) p.resolve({ decision: 'deny' })
    this.#pending.clear()
    this.#abort?.abort()
  }

  // ── 检查点 ──────────────────────────────────────────────

  async listCheckpoints(): Promise<CheckpointInfo[]> {
    if (!this.#checkpoints) return []
    return await this.#checkpoints.list()
  }

  async createCheckpoint(label: string): Promise<CheckpointInfo> {
    if (!this.#checkpoints) throw new Error('检查点服务未启用')
    return await this.#checkpoints.create(label, 'manual')
  }

  async rollbackCheckpoint(id: string): Promise<CheckpointRollbackResult> {
    if (!this.#checkpoints) throw new Error('检查点服务未启用')
    return await this.#checkpoints.rollback(id)
  }

  async send(text: string): Promise<void> {
    if (this.#running) throw new Error('上一轮还在执行中')
    const input = text.trim()
    if (!input) return

    // 先把 running 置位，再开会话。
    this.#running = true
    this.#step = 0
    this.#abort = new AbortController()

    // 用对象持有而不是裸变量：闭包里赋值会让 TS 的控制流收窄失效
    const tail: { done: AgentEvent | null } = { done: null }

    try {
      if (!this.#sessionId) await this.startSession(input)
      const sessionId = this.#sessionId as string
      this.#emitStatus()

      // 每轮对话前自动打检查点：接下来的写操作一旦失控，用户可以一键回到这里。
      // 失败不阻断对话，但要明确告知。
      if (this.#checkpoints) {
        try {
          const cp = await this.#checkpoints.create(titleFrom(input), 'auto')
          this.#sink.event({ type: 'checkpoint', checkpoint: cp })
        } catch (e) {
          this.#sink.event({
            type: 'content',
            text: `\n（检查点未创建：${(e as Error).message}）\n`
          })
        }
      }

      await this.#store.append(sessionId, {
        kind: 'message',
        message: { role: 'user', content: input }
      })

      // runAgent 内部会拼 [system, ...history, user, ...本轮新增]。
      const historyLen = this.#history.length

      const result = await runAgent(
        {
          provider: this.#provider,
          model: this.#model,
          registry: this.#registry,
          workspaceRoot: this.#workspace,
          permission: this.#permission,
          approver: this.#approver,
          maxSteps: this.#maxSteps,
          signal: this.#abort.signal,
          history: this.#history,
          onEvent: (e) => {
            if (e.type === 'step-start') {
              this.#step = e.step
              this.#emitStatus()
            }
            if (e.type === 'usage') {
              this.#usage = {
                promptTokens: this.#usage.promptTokens + e.usage.promptTokens,
                completionTokens: this.#usage.completionTokens + e.usage.completionTokens,
                totalTokens: this.#usage.totalTokens + e.usage.totalTokens,
                reasoningTokens:
                  (this.#usage.reasoningTokens ?? 0) + (e.usage.reasoningTokens ?? 0)
              }
            }
            // done 押后到落盘之后再发：界面收到 done 时，会话文件一定已经写完了
            if (e.type === 'done') {
              tail.done = e
              return
            }
            this.#sink.event(e)
          }
        },
        input
      )

      const produced = result.messages.slice(1 + historyLen)
      // runAgent 每轮都会重新拼 system 消息，历史里要去掉它，否则下一轮会出现两条 system
      this.#history = result.messages.slice(1)

      // produced[0] 是刚写过的 user 消息，从第二条开始落盘
      for (const m of produced.slice(1)) {
        await this.#store.append(sessionId, { kind: 'message', message: m })
      }
      await this.#store.append(sessionId, { kind: 'usage', usage: this.#usage })

      // 刷新 updatedAt，否则侧边栏的会话列表会永远按创建时间排序
      if (this.#meta) {
        this.#meta = { ...this.#meta, updatedAt: new Date().toISOString() }
        await this.#store.touch(this.#meta)
      }

      if (result.error) {
        this.#sink.event({ type: 'content', text: `\n[错误] ${result.error}\n` })
      }
    } catch (e) {
      this.#sink.event({
        type: 'content',
        text: `\n[运行失败] ${(e as Error).message}\n`
      })
      tail.done = { type: 'done', reason: 'error' }
    } finally {
      this.#running = false
      this.#abort = null
      this.#emitStatus()
    }

    if (tail.done) this.#sink.event(tail.done)
  }

  #emitStatus(): void {
    this.#sink.status({
      running: this.#running,
      sessionId: this.#sessionId,
      step: this.#step
    })
  }

  #approver: Approver = async (request: ApprovalRequest): Promise<ApprovalResolution> => {
    const id = newId('ap')
    const preview = this.#computeDiff ? await this.#previewDiff(request) : undefined
    const diff = preview?.diff
    const prompt: ApprovalPrompt = diff ? { ...request, id, diff } : { ...request, id }

    // 无论是否自动批准，都先推给界面 —— 这样审批卡片总是可见的
    this.#sink.approval(prompt)

    if (this.#autoApprove) {
      // 无人值守时不能等界面。给一点时间让卡片渲染出来，然后放行。
      await new Promise((r) => setTimeout(r, 400))
      return { decision: 'approve' }
    }

    return await new Promise<ApprovalResolution>((resolve) => {
      const timer = setTimeout(() => {
        this.#pending.delete(id)
        resolve({ decision: 'deny' })
      }, APPROVAL_TIMEOUT_MS)

      this.#pending.set(id, {
        resolve: (r) => {
          clearTimeout(timer)
          resolve(r)
        },
        prompt,
        before: preview?.before ?? '',
        after: preview?.after ?? '',
        toolName: request.tool,
        args: request.args
      })
    })
  }

  /**
   * 计算写工具落盘前的差异预览（edit_file 与 write_file 都覆盖）。
   * 用内核的 applyEdit 而不是自己再实现一遍替换 ——
   * 预览必须与实际写入结果一致，否则比没有预览更糟。
   * 同时返回 before/after 全文，供逐块审查时重建文本。
   */
  async #previewDiff(
    request: ApprovalRequest
  ): Promise<{ diff?: DiffPreview; before: string; after: string } | undefined> {
    if (request.tool !== 'edit_file' && request.tool !== 'write_file') return undefined
    const p = request.args.path
    if (typeof p !== 'string') return undefined

    try {
      const { abs, outside } = resolveInWorkspace(this.#workspace, p)
      if (outside) return undefined

      let before = ''
      try {
        before = await readFile(abs, 'utf8')
      } catch {
        before = '' // 文件不存在（新建）
      }

      if (request.tool === 'edit_file') {
        const oldText = request.args.oldText
        if (typeof oldText !== 'string') return { before, after: before }
        const newText = typeof request.args.newText === 'string' ? request.args.newText : ''
        const outcome = applyEdit(before, oldText, newText, request.args.replaceAll === true)
        if (!outcome.ok) return { before, after: before }
        return {
          diff: diffPreview(displayPath(this.#workspace, abs), before, outcome.text),
          before,
          after: outcome.text
        }
      }

      // write_file：整文件写入，新建文件时 before 为空串
      const after = typeof request.args.content === 'string' ? request.args.content : ''
      return {
        diff: diffPreview(displayPath(this.#workspace, abs), before, after),
        before,
        after
      }
    } catch {
      return undefined
    }
  }
}

/** 由工作区路径派生稳定的检查点存储目录名（userData/checkpoints/<slug>） */
export function checkpointSlug(workspaceRoot: string): string {
  return createHash('sha256').update(resolveInWorkspace(workspaceRoot, '.').abs).digest('hex').slice(0, 12)
}
EOF

echo "== 主进程：环境开关 =="

w apps/desktop/src/main/env.ts <<'EOF'
/**
 * 集中读环境变量。
 *
 * 单独放一个文件，是为了让"无头 / 自动批准 / 工作区"这几个开关只有一处定义。
 * 散落在各模块里各读各的，很容易出现"界面以为是交互模式、主进程却自动放行"这种错位。
 */
export const HEADLESS = process.env.WITSEEK_HEADLESS === '1'

/**
 * 无头运行时没有人在界面上点「批准」。
 * 不自动放行的话，第一次写操作就会一直挂到超时 —— 表现为"agent 卡住了"，
 * 实际原因却和 agent 毫无关系。
 * 需要显式关闭可设 WITSEEK_AUTO_APPROVE=0。
 */
export const AUTO_APPROVE =
  process.env.WITSEEK_AUTO_APPROVE === '1' ||
  (HEADLESS && process.env.WITSEEK_AUTO_APPROVE !== '0')

export const WORKSPACE_ROOT = process.env.WITSEEK_WORKSPACE ?? process.cwd()
EOF

echo "== 主进程：IPC 接线 =="

w apps/desktop/src/main/ipc.ts <<'EOF'
import { app, dialog, ipcMain, type BrowserWindow } from 'electron'
import { createHash } from 'node:crypto'
import { join } from 'node:path'
import { IPC } from '@witseek/protocol'
import type {
  AgentEvent,
  AgentStatus,
  AppInfo,
  ApprovalDecision,
  ApprovalPrompt,
  CheckpointRollbackResult,
  PermissionMode,
  TerminalData,
  TerminalExit
} from '@witseek/protocol'
import { CheckpointService, SettingsStore } from '@witseek/harness-core'
import { AgentHost, type HostSink } from './host.js'
import { listTree, readForPreview, searchFiles, type TreeResult } from './workspace.js'
import { selectProvider } from './provider.js'
import { TerminalManager } from './terminal.js'
import { AUTO_APPROVE, HEADLESS, WORKSPACE_ROOT } from './env.js'

export interface HostBundle {
  host: AgentHost
  terminals: TerminalManager
  info: AppInfo
}

/**
 * 会话记录放在应用数据目录，**不放在工作区里**。
 * 工作区是用户的项目，往里面塞 .witseek-sessions 属于污染 ——
 * 用户会看到莫名其妙的目录，还可能被 git 跟踪。
 * 设置、检查点同理，都放 userData。
 */
export function sessionsDir(): string {
  return process.env.WITSEEK_SESSIONS_DIR ?? join(app.getPath('userData'), 'sessions')
}

export function settingsFile(): string {
  return process.env.WITSEEK_SETTINGS_FILE ?? join(app.getPath('userData'), 'settings.json')
}

/** 检查点仓库按工作区路径哈希分目录，切换工作区不会串档 */
export function checkpointsDir(root: string): string {
  if (process.env.WITSEEK_CHECKPOINTS_DIR) return process.env.WITSEEK_CHECKPOINTS_DIR
  const slug = createHash('sha256').update(root).digest('hex').slice(0, 12)
  return join(app.getPath('userData'), 'checkpoints', slug)
}

export function createHost(getWindow: () => BrowserWindow | null): HostBundle {
  const choice = selectProvider()

  const send = (channel: string, payload: unknown): void => {
    const win = getWindow()
    if (win && !win.isDestroyed()) win.webContents.send(channel, payload)
  }

  // AgentHost 只认 sink、不认 electron —— 这里就是两者的接缝。
  const sink: HostSink = {
    event: (e: AgentEvent) => send(IPC.pushAgentEvent, e),
    approval: (p: ApprovalPrompt) => send(IPC.pushApproval, p),
    status: (s: AgentStatus) => send(IPC.pushStatus, s)
  }

  const settingsStore = new SettingsStore(settingsFile())
  const checkpoints = new CheckpointService({
    workspaceRoot: WORKSPACE_ROOT,
    storeDir: checkpointsDir(WORKSPACE_ROOT)
  })

  const host = new AgentHost({
    workspaceRoot: WORKSPACE_ROOT,
    provider: choice.provider,
    model: choice.model,
    sessionsDir: sessionsDir(),
    permissionMode: (process.env.WITSEEK_PERMISSION as PermissionMode | undefined) ?? 'confirm',
    autoApprove: AUTO_APPROVE,
    settingsStore,
    checkpoints,
    sink
  })

  const terminals = new TerminalManager(WORKSPACE_ROOT, {
    data: (p: TerminalData) => send(IPC.pushTerminalData, p),
    exit: (p: TerminalExit) => send(IPC.pushTerminalExit, p)
  })

  const info: AppInfo = {
    name: app.getName(),
    version: app.getVersion(),
    electron: process.versions.electron,
    chrome: process.versions.chrome,
    node: process.versions.node,
    platform: process.platform,
    headless: HEADLESS,
    provider: choice.provider.id,
    model: choice.model,
    hasApiKey: choice.hasApiKey,
    // 启动瞬间先用兜底值，host.init() 从设置文件恢复后会以 permission:get 为准
    permissionMode: host.permissionMode,
    terminalBackend: terminals.backend
  }

  return { host, terminals, info }
}

export function registerHandlers(
  bundle: HostBundle,
  getWindow: () => BrowserWindow | null
): void {
  const { host, terminals, info } = bundle

  // 从设置文件恢复审批模式，并回填 info（界面启动时读到的就是持久化后的值）
  void host.init().then(() => {
    info.permissionMode = host.permissionMode
  })

  // 启动预置指令只发一次。渲染进程挂载完成后主动来取，
  // 这样不会和"建立事件订阅"抢时序 —— 主进程主动推的话很可能推在订阅之前。
  let autoPrompt: string | null = (process.env.WITSEEK_DEMO_SEND ?? '').trim() || null

  ipcMain.handle(IPC.appInfo, () => info)
  ipcMain.handle(IPC.autoPrompt, () => {
    const p = autoPrompt
    autoPrompt = null
    return p
  })
  ipcMain.handle(IPC.workspaceInfo, () => ({ root: host.workspace, name: host.workspaceName }))
  ipcMain.handle(IPC.fsTree, async (): Promise<TreeResult> => listTree(host.workspace))
  ipcMain.handle(IPC.fsRead, (_e, path: string) => readForPreview(host.workspace, path))
  ipcMain.handle(IPC.fsSearch, (_e, q: { pattern: string; glob?: string }) =>
    searchFiles(host.workspace, q.pattern, q.glob ?? '**/*')
  )
  ipcMain.handle(IPC.sessionList, () => host.listSessions())
  ipcMain.handle(IPC.sessionCreate, () => host.startSession())
  ipcMain.handle(IPC.sessionLoad, (_e, id: string) => host.loadSession(id))
  ipcMain.handle(IPC.agentSend, (_e, text: string) => host.send(text))
  ipcMain.handle(IPC.agentAbort, () => host.abort())
  ipcMain.handle(
    IPC.agentApprove,
    (_e, id: string, decision: ApprovalDecision, acceptedHunkIds?: string[]) =>
      host.resolveApproval(id, decision, acceptedHunkIds)
  )
  ipcMain.handle(IPC.permissionGet, () => host.permissionMode)
  ipcMain.handle(IPC.permissionSet, async (_e, mode: PermissionMode) => {
    const applied = await host.setPermissionMode(mode)
    info.permissionMode = applied
    return applied
  })

  // 检查点
  ipcMain.handle(IPC.checkpointList, () => host.listCheckpoints())
  ipcMain.handle(IPC.checkpointCreate, (_e, label: string) =>
    host.createCheckpoint(typeof label === 'string' && label ? label : '手动检查点')
  )
  ipcMain.handle(
    IPC.checkpointRollback,
    async (_e, id: string): Promise<CheckpointRollbackResult> => {
      const result = await host.rollbackCheckpoint(id)
      return result
    }
  )

  // 集成终端
  ipcMain.handle(IPC.terminalCreate, (_e, cols?: number, rows?: number) =>
    terminals.create(cols, rows)
  )
  ipcMain.handle(IPC.terminalWrite, (_e, id: string, data: string) => {
    terminals.write(id, data)
  })
  ipcMain.handle(IPC.terminalResize, (_e, id: string, cols: number, rows: number) => {
    terminals.resize(id, cols, rows)
  })
  ipcMain.handle(IPC.terminalKill, (_e, id: string) => {
    terminals.kill(id)
  })

  ipcMain.handle(IPC.workspaceChoose, async () => {
    const win = getWindow()
    const r = win
      ? await dialog.showOpenDialog(win, { properties: ['openDirectory'] })
      : await dialog.showOpenDialog({ properties: ['openDirectory'] })
    return r.canceled ? null : (r.filePaths[0] ?? null)
  })
}
EOF

echo "== 主进程：应用入口 =="

w apps/desktop/src/main/index.ts <<'EOF'
import { existsSync } from 'node:fs'
import { join } from 'node:path'
import { app, BrowserWindow, session, shell } from 'electron'
import { HEADLESS } from './env.js'
import { createHost, registerHandlers, type HostBundle } from './ipc.js'

// 无头（Xvfb）环境下 Chromium 拿不到真实 GPU，必须关硬件加速，
// 否则渲染进程可能起不来或整屏空白。
if (HEADLESS) {
  app.disableHardwareAcceleration()
  app.commandLine.appendSwitch('disable-dev-shm-usage')
  app.commandLine.appendSwitch('no-sandbox')
  app.commandLine.appendSwitch('disable-gpu-compositor')
}

// CSP 只在生产环境通过响应头注入。
// 不写在 index.html 的 meta 里，因为 Vite 开发模式会注入内联脚本，
// 被 script-src 'self' 拦掉会导致白屏，且报错位置很不直观。
const CSP = [
  "default-src 'self'",
  "script-src 'self'",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data:",
  "font-src 'self' data:",
  "connect-src 'self' https://api.deepseek.com"
].join('; ')

function applyCsp(): void {
  if (process.env.ELECTRON_RENDERER_URL) return
  session.defaultSession.webRequest.onHeadersReceived((details, cb) => {
    cb({
      responseHeaders: {
        ...details.responseHeaders,
        'Content-Security-Policy': [CSP]
      }
    })
  })
}

function resolveIcon(): string | undefined {
  const candidates = [
    join(import.meta.dirname, '../../resources/icon.png'),
    join(process.resourcesPath ?? '', 'icon.png')
  ]
  return candidates.find((p) => p && existsSync(p))
}

let mainWindow: BrowserWindow | null = null
let bundle: HostBundle | null = null

function createWindow(): void {
  mainWindow = new BrowserWindow({
    width: 1440,
    height: 900,
    minWidth: 1000,
    minHeight: 640,
    show: false,
    title: 'Witseek',
    backgroundColor: '#ffffff',
    icon: resolveIcon(),
    autoHideMenuBar: true,
    webPreferences: {
      preload: join(import.meta.dirname, '../preload/index.mjs'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false
    }
  })

  mainWindow.on('ready-to-show', () => {
    mainWindow?.show()
    mainWindow?.focus()
  })

  // 窗口关掉后不能再让审批 Promise 悬着、终端子进程成孤儿
  mainWindow.on('closed', () => {
    bundle?.host.dispose()
    bundle?.terminals.dispose()
    mainWindow = null
  })

  // 外部链接交给系统浏览器，不在应用内开新窗口
  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    void shell.openExternal(url)
    return { action: 'deny' }
  })

  const devUrl = process.env.ELECTRON_RENDERER_URL
  if (devUrl) {
    void mainWindow.loadURL(devUrl)
  } else {
    void mainWindow.loadFile(join(import.meta.dirname, '../renderer/index.html'))
  }
}

app.whenReady().then(() => {
  applyCsp()
  createWindow()
  // 必须在窗口存在之后再建 host：sink 需要 webContents 才能把事件推出去
  bundle = createHost(() => mainWindow)
  registerHandlers(bundle, () => mainWindow)

  app.on('activate', () => {
    if (BrowserWindow.getAllWindows().length === 0) createWindow()
  })
})

app.on('window-all-closed', () => {
  bundle?.host.dispose()
  bundle?.terminals.dispose()
  if (process.platform !== 'darwin') app.quit()
})
EOF

echo "== preload =="

w apps/desktop/src/preload/index.ts <<'EOF'
import { contextBridge, ipcRenderer, type IpcRendererEvent } from 'electron'
import { IPC } from '@witseek/protocol'
import type {
  AgentEvent,
  AgentStatus,
  AppInfo,
  ApprovalDecision,
  ApprovalPrompt,
  ChatMessage,
  CheckpointInfo,
  CheckpointRollbackResult,
  FileContent,
  FileEntry,
  PermissionMode,
  SearchHit,
  SessionSummary,
  TerminalCreated,
  TerminalData,
  TerminalExit,
  WorkspaceInfo
} from '@witseek/protocol'

/** 订阅推送，返回取消订阅的函数（React 的 useEffect 清理函数直接用它） */
function subscribe<T>(channel: string, cb: (payload: T) => void): () => void {
  const listener = (_e: IpcRendererEvent, payload: T): void => cb(payload)
  ipcRenderer.on(channel, listener)
  return () => {
    ipcRenderer.removeListener(channel, listener)
  }
}

const api = {
  platform: process.platform,

  getAppInfo: (): Promise<AppInfo> => ipcRenderer.invoke(IPC.appInfo),

  getAutoPrompt: (): Promise<string | null> => ipcRenderer.invoke(IPC.autoPrompt),

  workspace: {
    info: (): Promise<WorkspaceInfo> => ipcRenderer.invoke(IPC.workspaceInfo),
    choose: (): Promise<string | null> => ipcRenderer.invoke(IPC.workspaceChoose),
    tree: (): Promise<{ entries: FileEntry[]; truncated: boolean }> => ipcRenderer.invoke(IPC.fsTree),
    read: (path: string): Promise<FileContent> => ipcRenderer.invoke(IPC.fsRead, path),
    search: (pattern: string, glob?: string): Promise<SearchHit[]> =>
      ipcRenderer.invoke(IPC.fsSearch, { pattern, glob })
  },

  session: {
    list: (): Promise<SessionSummary[]> => ipcRenderer.invoke(IPC.sessionList),
    create: (): Promise<string> => ipcRenderer.invoke(IPC.sessionCreate),
    load: (id: string): Promise<ChatMessage[]> => ipcRenderer.invoke(IPC.sessionLoad, id)
  },

  agent: {
    send: (text: string): Promise<void> => ipcRenderer.invoke(IPC.agentSend, text),
    abort: (): Promise<void> => ipcRenderer.invoke(IPC.agentAbort),
    approve: (
      id: string,
      decision: ApprovalDecision,
      acceptedHunkIds?: string[]
    ): Promise<boolean> =>
      ipcRenderer.invoke(IPC.agentApprove, id, decision, acceptedHunkIds),
    getPermissionMode: (): Promise<PermissionMode> => ipcRenderer.invoke(IPC.permissionGet),
    setPermissionMode: (mode: PermissionMode): Promise<PermissionMode> =>
      ipcRenderer.invoke(IPC.permissionSet, mode)
  },

  checkpoint: {
    list: (): Promise<CheckpointInfo[]> => ipcRenderer.invoke(IPC.checkpointList),
    create: (label: string): Promise<CheckpointInfo> =>
      ipcRenderer.invoke(IPC.checkpointCreate, label),
    rollback: (id: string): Promise<CheckpointRollbackResult> =>
      ipcRenderer.invoke(IPC.checkpointRollback, id)
  },

  terminal: {
    create: (cols?: number, rows?: number): Promise<TerminalCreated> =>
      ipcRenderer.invoke(IPC.terminalCreate, cols, rows),
    write: (id: string, data: string): Promise<void> =>
      ipcRenderer.invoke(IPC.terminalWrite, id, data),
    resize: (id: string, cols: number, rows: number): Promise<void> =>
      ipcRenderer.invoke(IPC.terminalResize, id, cols, rows),
    kill: (id: string): Promise<void> => ipcRenderer.invoke(IPC.terminalKill, id)
  },

  onAgentEvent: (cb: (e: AgentEvent) => void): (() => void) =>
    subscribe<AgentEvent>(IPC.pushAgentEvent, cb),
  onApproval: (cb: (p: ApprovalPrompt) => void): (() => void) =>
    subscribe<ApprovalPrompt>(IPC.pushApproval, cb),
  onStatus: (cb: (s: AgentStatus) => void): (() => void) =>
    subscribe<AgentStatus>(IPC.pushStatus, cb),
  onTerminalData: (cb: (d: TerminalData) => void): (() => void) =>
    subscribe<TerminalData>(IPC.pushTerminalData, cb),
  onTerminalExit: (cb: (e: TerminalExit) => void): (() => void) =>
    subscribe<TerminalExit>(IPC.pushTerminalExit, cb)
}

contextBridge.exposeInMainWorld('witseek', api)

export type WitseekApi = typeof api
EOF

echo "== 演示工作区 =="

w scripts/make-demo-workspace.sh <<'EOF'
#!/usr/bin/env bash
# 生成一个用于演示与截图验证的小工作区。
#
# 存在的意义：在没有 API Key 时也能把界面完整驱动起来（文件树、预览、diff、
# 审批卡片都需要真实文件），同时避免让 agent 去改真正的工程源码。
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
WS="$ROOT/.runtime/demo-workspace"

rm -rf "$WS"
mkdir -p "$WS/app/src/main/java/com/xwt/schedule"
mkdir -p "$WS/app/src/main/res/layout"
mkdir -p "$WS/gradle/wrapper"

cat > "$WS/README.md" <<'MD'
# 大学课表（演示工作区）

这是一个用于演示 Witseek 的小工程，不是真实项目。

## 模块

- `app/` 应用模块
- `gradle/` 构建脚本
MD

cat > "$WS/build.gradle" <<'GRADLE'
plugins {
    id 'com.android.application'
}

android {
    compileSdk 35
    defaultConfig {
        applicationId "com.xwt.schedule"
        minSdk 26
        targetSdk 35
    }
}
GRADLE

cat > "$WS/settings.gradle" <<'GRADLE'
rootProject.name = "class_table"
include ':app'
GRADLE

cat > "$WS/app/src/main/java/com/xwt/schedule/MainActivity.java" <<'JAVA'
package com.xwt.schedule;

import android.os.Bundle;
import android.widget.TextView;
import androidx.appcompat.app.AppCompatActivity;

public class MainActivity extends AppCompatActivity {
    private TextView tvTitle;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);

        tvTitle = findViewById(R.id.tv_title);
        tvTitle.setText(weekLabel(0));
    }

    private String weekLabel(int offset) {
        return "第 " + (currentWeek() + offset) + " 周";
    }

    private int currentWeek() {
        return 3;
    }
}
JAVA

cat > "$WS/app/src/main/java/com/xwt/schedule/HolidayUtils.java" <<'JAVA'
package com.xwt.schedule;

import java.time.LocalDate;
import java.util.Map;

/** 法定节假日与调休判定。 */
public final class HolidayUtils {
    private static final Map<String, String> HOLIDAYS = Map.of(
        "2026-01-01", "元旦",
        "2026-10-01", "国庆节"
    );

    private HolidayUtils() {}

    public static boolean isHoliday(LocalDate date) {
        return HOLIDAYS.containsKey(date.toString());
    }

    public static String holidayName(LocalDate date) {
        return HOLIDAYS.get(date.toString());
    }
}
JAVA

cat > "$WS/app/src/main/res/layout/activity_main.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<LinearLayout xmlns:android="http://schemas.android.com/apk/res/android"
    android:layout_width="match_parent"
    android:layout_height="match_parent"
    android:orientation="vertical">

    <TextView
        android:id="@+id/tv_title"
        android:layout_width="wrap_content"
        android:layout_height="wrap_content" />
</LinearLayout>
XML

echo "演示工作区已生成: $WS"
find "$WS" -type f | sort
EOF
chmod +x scripts/make-demo-workspace.sh

echo
echo "==> P3 主进程与 preload 已生成"
find apps/desktop/src/main apps/desktop/src/preload -type f | sort
