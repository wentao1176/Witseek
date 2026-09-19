#!/usr/bin/env bash
# scaffold_p3_ui.sh —— 生成 P3 的渲染进程
#
# 产物: apps/desktop/src/renderer/src/**
#
# 设计原则:
#   - transcript.ts 是**纯函数**归约器：AgentEvent 流 → 可渲染的 Block 列表。
#     把它抽出来，是为了让"事件如何变成界面"这件事能被单测覆盖，
#     而不是埋在一个几百行的 useEffect 里。
#   - 界面不自己实现任何文件读写或搜索，一律走 IPC ——
#     渲染进程是 contextIsolation 的纯 Web 环境，没有 Node 能力。
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
cd "$ROOT"

w() { mkdir -p "$(dirname "$1")"; cat > "$1"; echo "  + $1"; }

echo "== 渲染进程：入口 =="

w apps/desktop/src/renderer/src/main.tsx <<'EOF'
import React from 'react'
import ReactDOM from 'react-dom/client'
import '@xterm/xterm/css/xterm.css'
import App from './App'
import { AgentProvider } from './state/AgentContext'
import './styles.css'

ReactDOM.createRoot(document.getElementById('root') as HTMLElement).render(
  <React.StrictMode>
    <AgentProvider>
      <App />
    </AgentProvider>
  </React.StrictMode>
)
EOF

echo "== 渲染进程：preload 桥接与工具函数 =="

w apps/desktop/src/renderer/src/api.ts <<'EOF'
import type {
  AgentEvent,
  AgentStatus,
  AppInfo,
  ApprovalDecision,
  ApprovalPrompt,
  ChatMessage,
  CheckpointInfo,
  CheckpointRollbackResult,
  DiffPreview,
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

/**
 * preload 通过 contextBridge 暴露的接口。
 * 渲染进程没有 Node 能力，所有文件与 agent 操作都必须走这里。
 */
export interface WitseekApi {
  platform: string
  getAppInfo(): Promise<AppInfo>
  /** 无人值守验证：启动时预置的一条指令，取走即清空 */
  getAutoPrompt(): Promise<string | null>
  workspace: {
    info(): Promise<WorkspaceInfo>
    choose(): Promise<string | null>
    tree(): Promise<{ entries: FileEntry[]; truncated: boolean }>
    read(path: string): Promise<FileContent>
    search(pattern: string, glob?: string): Promise<SearchHit[]>
  }
  session: {
    list(): Promise<SessionSummary[]>
    create(): Promise<string>
    load(id: string): Promise<ChatMessage[]>
  }
  agent: {
    send(text: string): Promise<void>
    abort(): Promise<void>
    /** 逐块审查时第三参传被接受的 hunk id；缺省视为整体批准 */
    approve(
      id: string,
      decision: ApprovalDecision,
      acceptedHunkIds?: string[]
    ): Promise<boolean>
    getPermissionMode(): Promise<PermissionMode>
    setPermissionMode(mode: PermissionMode): Promise<PermissionMode>
  }
  checkpoint: {
    list(): Promise<CheckpointInfo[]>
    create(label: string): Promise<CheckpointInfo>
    rollback(id: string): Promise<CheckpointRollbackResult>
  }
  terminal: {
    create(cols?: number, rows?: number): Promise<TerminalCreated>
    write(id: string, data: string): Promise<void>
    resize(id: string, cols: number, rows: number): Promise<void>
    kill(id: string): Promise<void>
  }
  onAgentEvent(cb: (e: AgentEvent) => void): () => void
  onApproval(cb: (p: ApprovalPrompt) => void): () => void
  onStatus(cb: (s: AgentStatus) => void): () => void
  onTerminalData(cb: (d: TerminalData) => void): () => void
  onTerminalExit(cb: (e: TerminalExit) => void): () => void
}

export function api(): WitseekApi {
  const w = (window as unknown as { witseek?: WitseekApi }).witseek
  if (!w) throw new Error('preload 未注入 witseek API —— 检查 BrowserWindow 的 preload 配置')
  return w
}

/** 预览区要展示的东西：文件内容，或某个改动的 diff */
export interface PreviewState {
  path: string
  content: FileContent | null
  diff?: DiffPreview
  loading: boolean
  error?: string
}
EOF

w apps/desktop/src/renderer/src/util.ts <<'EOF'
import type { FileEntry } from '@witseek/protocol'

export function basename(p: string): string {
  const parts = p.split('/')
  return parts[parts.length - 1] || p
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)} KB`
  return `${(n / 1024 / 1024).toFixed(1)} MB`
}

export function relativeTime(iso: string, now = Date.now()): string {
  const t = Date.parse(iso)
  if (Number.isNaN(t)) return ''
  const diff = Math.max(0, now - t)
  const min = Math.floor(diff / 60000)
  if (min < 1) return '刚刚'
  if (min < 60) return `${min} 分钟前`
  const hour = Math.floor(min / 60)
  if (hour < 24) return `${hour} 小时前`
  return `${Math.floor(hour / 24)} 天前`
}

/**
 * 按折叠状态过滤文件树。
 *
 * 树是扁平的（带 depth），所以"折叠某个目录"= 跳过它后面所有更深的条目，
 * 直到遇到一个深度不更深的为止。用扁平结构 + 这个函数，
 * 比递归组件少一层状态传递，展开/收起也不会重建整棵树。
 */
export function visibleTree(entries: FileEntry[], collapsed: Set<string>): FileEntry[] {
  const out: FileEntry[] = []
  let hideDeeperThan: number | null = null

  for (const e of entries) {
    if (hideDeeperThan !== null) {
      if (e.depth > hideDeeperThan) continue
      hideDeeperThan = null
    }
    out.push(e)
    if (e.kind === 'dir' && collapsed.has(e.path)) hideDeeperThan = e.depth
  }
  return out
}

/** 条目数超过这个量级才值得默认折叠；小工程全展开最省事 */
export const AUTO_FOLD_MIN_ENTRIES = 120
/** 默认折叠的起始深度：前两层（如 app/src）保持展开 */
export const AUTO_FOLD_DEPTH = 2

/**
 * 计算树的初始折叠集合。
 *
 * 为什么要有阈值：Java/Android 的源码路径天生很深，工程一大，
 * 全展开就只剩一串目录名，真正要找的文件全被挤出可视区。
 * 但小工程全展开反而更好用 —— 所以按条目数决定，而不是一刀切。
 *
 * 只在树首次加载时调用一次。刷新树时若重新播种，
 * 用户手动展开/收起的选择会被无声抹掉。
 */
export function defaultCollapsed(entries: FileEntry[]): Set<string> {
  if (entries.length < AUTO_FOLD_MIN_ENTRIES) return new Set()
  const out = new Set<string>()
  for (const e of entries) {
    if (e.kind === 'dir' && e.depth >= AUTO_FOLD_DEPTH) out.add(e.path)
  }
  return out
}
EOF

echo "== 渲染进程：事件归约器 =="

w apps/desktop/src/renderer/src/transcript.ts <<'EOF'
import type {
  AgentEvent,
  ApprovalDecision,
  ApprovalPrompt,
  CheckpointInfo,
  DiffPreview,
  Usage
} from '@witseek/protocol'

/**
 * 对话流里的一个可视块。
 *
 * 界面渲染的是它，而不是原始的 AgentEvent 流 ——
 * 事件是"增量"的（每个 delta 一条），块是"累积"的（一段推理就是一块）。
 * 这个转换只做一次，放在这里，组件里就只剩渲染逻辑。
 */
export type Block =
  | { id: string; kind: 'user'; text: string }
  | { id: string; kind: 'reasoning'; text: string; open: boolean }
  | { id: string; kind: 'text'; text: string }
  | {
      id: string
      kind: 'tool'
      callId: string
      name: string
      args: string
      state: 'running' | 'ok' | 'fail'
      output: string
      startedAt: number
      ms?: number
      /** 写操作审批时算出的 diff，结果卡上也保留一份 */
      diff?: DiffPreview
      /** 逐块审查时最终应用的 hunk */
      acceptedHunkIds?: string[]
    }
  | {
      id: string
      kind: 'approval'
      tool: string
      summary: string
      outside: boolean
      decision?: ApprovalDecision
      diff?: DiffPreview
      /** 逐块审查时用户接受的 hunk；整体批准时不设置 */
      acceptedHunkIds?: string[]
    }
  | { id: string; kind: 'checkpoint'; checkpoint: CheckpointInfo }
  | { id: string; kind: 'error'; text: string }

export interface Transcript {
  blocks: Block[]
  seq: number
  step: number
  running: boolean
  usage: Usage | null
  stopReason: string | null
  /** 等待用户裁决的请求。裁决结果会作为 approval 块落到 blocks 里。 */
  pending: ApprovalPrompt | null
  /** 已发出裁决、还在等内核确认，用于禁用按钮防止重复点击 */
  deciding: boolean
}

export const emptyTranscript: Transcript = {
  blocks: [],
  seq: 0,
  step: 0,
  running: false,
  usage: null,
  stopReason: null,
  pending: null,
  deciding: false
}

function push(t: Transcript, make: (id: string) => Block): Transcript {
  const id = `b${t.seq + 1}`
  return { ...t, seq: t.seq + 1, blocks: [...t.blocks, make(id)] }
}

/** 追加到末尾同类型的块；类型不同就新开一块 */
function appendText(t: Transcript, kind: 'reasoning' | 'text', text: string): Transcript {
  const last = t.blocks[t.blocks.length - 1]
  if (last && last.kind === 'reasoning' && kind === 'reasoning') {
    return { ...t, blocks: [...t.blocks.slice(0, -1), { ...last, text: last.text + text }] }
  }
  if (last && last.kind === 'text' && kind === 'text') {
    return { ...t, blocks: [...t.blocks.slice(0, -1), { ...last, text: last.text + text }] }
  }
  return push(t, (id) =>
    kind === 'reasoning' ? { id, kind: 'reasoning', text, open: true } : { id, kind: 'text', text }
  )
}

export function addUser(t: Transcript, text: string): Transcript {
  return push({ ...t, running: true, stopReason: null }, (id) => ({ id, kind: 'user', text }))
}

export function addError(t: Transcript, text: string): Transcript {
  return push(t, (id) => ({ id, kind: 'error', text }))
}

/** 收到 push:approval —— 此时还没裁决，只是把它挂出来等用户点 */
export function setPending(t: Transcript, p: ApprovalPrompt): Transcript {
  return { ...t, pending: p, deciding: false }
}

export function markDeciding(t: Transcript): Transcript {
  return { ...t, deciding: true }
}

export function toggleReasoning(t: Transcript, id: string): Transcript {
  return {
    ...t,
    blocks: t.blocks.map((b) =>
      b.kind === 'reasoning' && b.id === id ? { ...b, open: !b.open } : b
    )
  }
}

export function resetTranscript(): Transcript {
  return emptyTranscript
}

/**
 * AgentEvent → 界面状态。
 *
 * 注意 approval 事件是**决策之后**才来的，所以它在这里的职责是
 * "把挂着的待办落成一条已裁决记录"，而不是弹出询问。
 * 询问走 setPending（对应 push:approval）。
 */
export function applyEvent(t: Transcript, e: AgentEvent, now = Date.now()): Transcript {
  switch (e.type) {
    case 'step-start':
      return { ...t, step: e.step, running: true }

    case 'reasoning':
      return appendText(t, 'reasoning', e.text)

    case 'content':
      return appendText(t, 'text', e.text)

    case 'tool-start':
      return push(t, (id) => ({
        id,
        kind: 'tool',
        callId: e.call.id,
        name: e.call.name,
        args: e.call.arguments,
        state: 'running',
        output: '',
        startedAt: now
      }))

    case 'tool-end':
      return {
        ...t,
        blocks: t.blocks.map((b) =>
          b.kind === 'tool' && b.callId === e.call.id
            ? {
                ...b,
                state: e.result.ok ? ('ok' as const) : ('fail' as const),
                output: e.result.output,
                ms: now - b.startedAt
              }
            : b
        )
      }

    case 'approval': {
      const diff = t.pending?.diff
      const accepted = e.acceptedHunkIds
      // 审批发生在工具执行之前：把 diff 与逐块选择同步给仍在 running 的同名工具卡，
      // 这样工具结果出来后卡片上仍能看到"改了什么、应用了哪几块"。
      const blocks = t.blocks.map((b) => {
        if (b.kind !== 'tool' || b.state !== 'running' || b.name !== e.request.tool) return b
        const next: Block = {
          ...b,
          ...(diff ? { diff } : {}),
          ...(accepted ? { acceptedHunkIds: accepted } : {})
        }
        return next
      })
      const next: Transcript = {
        ...t,
        blocks: push({ ...t, blocks }, (id) => {
          const block: Extract<Block, { kind: 'approval' }> = {
            id,
            kind: 'approval',
            tool: e.request.tool,
            summary: e.request.summary,
            outside: e.request.outsideWorkspace,
            decision: e.decision
          }
          if (diff) block.diff = diff
          if (accepted) block.acceptedHunkIds = accepted
          return block
        }).blocks
      }
      return { ...next, pending: null, deciding: false }
    }

    case 'checkpoint':
      return push(t, (id) => ({ id, kind: 'checkpoint', checkpoint: e.checkpoint }))

    case 'usage':
      return { ...t, usage: e.usage }

    case 'done':
      return { ...t, running: false, stopReason: e.reason, pending: null, deciding: false }

    default:
      return t
  }
}

/** 本会话被写过的文件，用于在文件树上打改动标记 */
export function changedPaths(t: Transcript): string[] {
  const out = new Set<string>()
  for (const b of t.blocks) {
    if (b.kind !== 'tool' || b.state !== 'ok') continue
    if (b.name !== 'write_file' && b.name !== 'edit_file') continue
    try {
      const args = JSON.parse(b.args) as { path?: unknown }
      if (typeof args.path === 'string') out.add(args.path)
    } catch {
      // 参数不是合法 JSON 就跳过，不影响其他块的统计
    }
  }
  return [...out]
}

/** 最近一次带 diff 的审批，供预览区展示改动 */
export function lastDiff(t: Transcript): { path: string; diff: DiffPreview } | null {
  for (let i = t.blocks.length - 1; i >= 0; i--) {
    const b = t.blocks[i]
    if (b.kind === 'approval' && b.diff) return { path: b.diff.path, diff: b.diff }
  }
  return null
}
EOF

echo "== 渲染进程：状态容器 =="

w apps/desktop/src/renderer/src/state/AgentContext.tsx <<'EOF'
import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useMemo,
  useRef,
  useState,
  type JSX,
  type ReactNode
} from 'react'
import type {
  AppInfo,
  CheckpointInfo,
  FileEntry,
  PermissionMode,
  SearchHit,
  SessionSummary,
  WorkspaceInfo
} from '@witseek/protocol'
import { api, type PreviewState } from '../api'
import {
  addError,
  addUser,
  applyEvent,
  changedPaths,
  emptyTranscript,
  lastDiff,
  markDeciding,
  setPending,
  toggleReasoning,
  type Transcript
} from '../transcript'
import { defaultCollapsed } from '../util'

export interface AgentApp {
  info: AppInfo | null
  workspace: WorkspaceInfo | null
  tree: FileEntry[]
  treeTruncated: boolean
  sessions: SessionSummary[]
  transcript: Transcript
  preview: PreviewState | null
  mode: PermissionMode
  searchHits: SearchHit[]
  changed: string[]
  collapsed: Set<string>
  checkpoints: CheckpointInfo[]
  /** 回滚/建检查点这类操作进行中，用于禁用按钮 */
  checkpointBusy: boolean

  send(text: string): Promise<void>
  abort(): Promise<void>
  /** 逐块审查时传入被接受的 hunk id 列表；整体批准省略第二参 */
  decide(decision: 'approve' | 'deny', acceptedHunkIds?: string[]): Promise<void>
  setMode(mode: PermissionMode): Promise<void>
  openFile(path: string): Promise<void>
  closePreview(): void
  refreshTree(): Promise<void>
  chooseWorkspace(): Promise<void>
  refreshSessions(): Promise<void>
  loadSession(id: string): Promise<void>
  newSession(): Promise<void>
  search(pattern: string): Promise<void>
  toggleDir(path: string): void
  toggleReasoningBlock(id: string): void
  refreshCheckpoints(): Promise<void>
  createCheckpoint(label?: string): Promise<void>
  rollbackCheckpoint(id: string): Promise<void>
}

const Ctx = createContext<AgentApp | null>(null)

export function useAgent(): AgentApp {
  const v = useContext(Ctx)
  if (!v) throw new Error('useAgent 必须在 AgentProvider 内使用')
  return v
}

export function AgentProvider({ children }: { children: ReactNode }): JSX.Element {
  const [info, setInfo] = useState<AppInfo | null>(null)
  const [workspace, setWorkspace] = useState<WorkspaceInfo | null>(null)
  const [tree, setTree] = useState<FileEntry[]>([])
  const [treeTruncated, setTreeTruncated] = useState(false)
  const [sessions, setSessions] = useState<SessionSummary[]>([])
  const [transcript, setTranscript] = useState<Transcript>(emptyTranscript)
  const [preview, setPreview] = useState<PreviewState | null>(null)
  const [mode, setModeState] = useState<PermissionMode>('confirm')
  const [searchHits, setSearchHits] = useState<SearchHit[]>([])
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set())
  const [checkpoints, setCheckpoints] = useState<CheckpointInfo[]>([])
  const [checkpointBusy, setCheckpointBusy] = useState(false)

  // 事件回调里需要读最新状态，但又不想每次状态变化都重新订阅
  const pendingRef = useRef<Transcript['pending']>(null)
  pendingRef.current = transcript.pending
  const previewRef = useRef<PreviewState | null>(null)
  previewRef.current = preview

  // 默认折叠只在树第一次落地时播种一次。
  // 若每次刷新都重新播种，用户手动展开/收起的选择会被静默抹掉 ——
  // 而刷新恰恰是 agent 改完文件后最常发生的动作。
  const foldSeeded = useRef(false)

  const refreshTree = useCallback(async (): Promise<void> => {
    const r = await api().workspace.tree()
    setTree(r.entries)
    setTreeTruncated(r.truncated)
    if (!foldSeeded.current) {
      foldSeeded.current = true
      setCollapsed(defaultCollapsed(r.entries))
    }
  }, [])

  const refreshSessions = useCallback(async (): Promise<void> => {
    setSessions(await api().session.list())
  }, [])

  const refreshCheckpoints = useCallback(async (): Promise<void> => {
    try {
      setCheckpoints(await api().checkpoint.list())
    } catch {
      // 检查点服务不可用时侧边栏保持空列表，不影响主流程
    }
  }, [])

  useEffect(() => {
    const w = api()
    void w.getAppInfo().then((i) => {
      setInfo(i)
      // 用持久化的审批模式回填下拉框，而不是写死 confirm
      setModeState(i.permissionMode)
    }).catch(() => setInfo(null))
    // 再向主进程确认一次（appInfo 在 init() 落盘恢复前就可能被取走）
    void w.agent.getPermissionMode().then(setModeState).catch(() => {})
    void w.workspace.info().then(setWorkspace)
    void refreshTree()
    void refreshSessions()
    void refreshCheckpoints()

    const offEvent = w.onAgentEvent((e) => {
      setTranscript((t) => applyEvent(t, e))
      // 写文件之后刷新预览，让用户看到真实结果而不是缓存
      if (e.type === 'tool-end' && e.result.ok) {
        const name = e.call.name
        if (name === 'write_file' || name === 'edit_file') {
          const args = JSON.parse(e.call.arguments || '{}') as { path?: string }
          if (args.path) {
            void w.workspace.read(args.path).then((content) => {
              setPreview((p) => (p && p.path === args.path ? { ...p, content, loading: false } : p))
            })
          }
        }
      }
      // 每轮开头的自动检查点、手动检查点都会推事件 —— 顺手刷新侧边栏
      if (e.type === 'checkpoint') void refreshCheckpoints()
      if (e.type === 'done') void refreshSessions()
    })

    const offApproval = w.onApproval((p) => {
      setTranscript((t) => setPending(t, p))
      // 有待审批的改动时，顺手把 diff 显示到预览区
      if (p.diff) {
        setPreview({ path: p.diff.path, content: null, diff: p.diff, loading: false })
      }
    })

    // 订阅建立之后再去拉预置指令。反过来的话，agent 的第一批事件
    // 会在订阅就绪之前就发出去，界面直接漏掉开头一段。
    void w.getAutoPrompt().then(async (prompt) => {
      if (!prompt) return
      setTranscript((prev) => addUser(prev, prompt))
      await w.agent.send(prompt)
    })

    return () => {
      offEvent()
      offApproval()
    }
  }, [refreshTree, refreshSessions, refreshCheckpoints])

  const send = useCallback(async (text: string): Promise<void> => {
    const t = text.trim()
    if (!t) return
    setTranscript((prev) => addUser(prev, t))
    try {
      await api().agent.send(t)
    } catch (e) {
      setTranscript((prev) => addError(prev, (e as Error).message))
    }
  }, [])

  const abort = useCallback(async (): Promise<void> => {
    await api().agent.abort()
  }, [])

  const decide = useCallback(
    async (decision: 'approve' | 'deny', acceptedHunkIds?: string[]): Promise<void> => {
      const p = pendingRef.current
      if (!p) return
      setTranscript(markDeciding)
      await api().agent.approve(p.id, decision, acceptedHunkIds)
    },
    []
  )

  const setMode = useCallback(async (m: PermissionMode): Promise<void> => {
    setModeState(await api().agent.setPermissionMode(m))
  }, [])

  const openFile = useCallback(async (path: string): Promise<void> => {
    setPreview({ path, content: null, loading: true })
    try {
      const content = await api().workspace.read(path)
      setPreview({ path, content, loading: false })
    } catch (e) {
      setPreview({ path, content: null, loading: false, error: (e as Error).message })
    }
  }, [])

  const closePreview = useCallback((): void => setPreview(null), [])

  const chooseWorkspace = useCallback(async (): Promise<void> => {
    const picked = await api().workspace.choose()
    // 换工作区要重启应用：主进程的工作区根在建 host 时就固定了，
    // 这里只提示用户，不做半吊子的热切换（那会让会话、审批、树三者不一致）。
    if (picked) {
      setTranscript((prev) =>
        addError(
          prev,
          `已选择新的工作区：${picked}\n请重启应用使其生效（工作区在启动时锁定）。`
        )
      )
    }
  }, [])

  const loadSession = useCallback(async (id: string): Promise<void> => {
    await api().session.load(id)
    // 重新拉一遍历史，把会话内容还原到对话区
    const messages = await api().session.load(id)
    let next = emptyTranscript
    for (const m of messages) {
      if (m.role === 'user') next = addUser(next, m.content)
      else if (m.role === 'assistant' && m.content) {
        next = applyEvent(next, { type: 'content', text: m.content })
      } else if (m.role === 'tool') {
        next = applyEvent(next, {
          type: 'tool-end',
          call: { id: m.toolCallId ?? '', name: m.name ?? 'tool', arguments: '{}' },
          result: { ok: true, output: m.content }
        })
      }
    }
    setTranscript({ ...next, running: false })
  }, [])

  const newSession = useCallback(async (): Promise<void> => {
    await api().session.create()
    setTranscript(emptyTranscript)
    setPreview(null)
    await refreshSessions()
  }, [refreshSessions])

  const search = useCallback(async (pattern: string): Promise<void> => {
    if (!pattern.trim()) {
      setSearchHits([])
      return
    }
    setSearchHits(await api().workspace.search(pattern))
  }, [])

  const toggleDir = useCallback((path: string): void => {
    setCollapsed((prev) => {
      const next = new Set(prev)
      if (next.has(path)) next.delete(path)
      else next.add(path)
      return next
    })
  }, [])

  const toggleReasoningBlock = useCallback((id: string): void => {
    setTranscript((t) => toggleReasoning(t, id))
  }, [])

  const createCheckpoint = useCallback(
    async (label?: string): Promise<void> => {
      setCheckpointBusy(true)
      try {
        const cp = await api().checkpoint.create(label?.trim() || '手动检查点')
        setTranscript((t) => applyEvent(t, { type: 'checkpoint', checkpoint: cp }))
        await refreshCheckpoints()
      } catch (e) {
        setTranscript((prev) => addError(prev, `检查点创建失败：${(e as Error).message}`))
      } finally {
        setCheckpointBusy(false)
      }
    },
    [refreshCheckpoints]
  )

  const rollbackCheckpoint = useCallback(
    async (id: string): Promise<void> => {
      setCheckpointBusy(true)
      try {
        const result = await api().checkpoint.rollback(id)
        await refreshTree()
        await refreshCheckpoints()
        // 回滚后当前预览可能已经是旧内容，重新读一次
        const current = previewRef.current
        if (current && !current.diff) void openFile(current.path)
        setTranscript((prev) =>
          addError(
            prev,
            `已回滚：恢复 ${result.restored} 个文件、移除 ${result.removed} 个新增文件（回滚前已自动备份，可在检查点列表中找到）。`
          )
        )
      } catch (e) {
        setTranscript((prev) => addError(prev, `回滚失败：${(e as Error).message}`))
      } finally {
        setCheckpointBusy(false)
      }
    },
    [refreshTree, refreshCheckpoints, openFile]
  )

  const changed = useMemo(() => changedPaths(transcript), [transcript])

  // 审批块里的 diff 若比预览区当前的更新，就切过去
  useEffect(() => {
    const d = lastDiff(transcript)
    if (!d) return
    setPreview((p) => {
      if (p && p.diff && p.path === d.path) return p
      if (p && p.path === d.path && p.content) return p
      return { path: d.path, content: null, diff: d.diff, loading: false }
    })
  }, [transcript])

  const value: AgentApp = {
    info,
    workspace,
    tree,
    treeTruncated,
    sessions,
    transcript,
    preview,
    mode,
    searchHits,
    changed,
    collapsed,
    checkpoints,
    checkpointBusy,
    send,
    abort,
    decide,
    setMode,
    openFile,
    closePreview,
    refreshTree,
    chooseWorkspace,
    refreshSessions,
    loadSession,
    newSession,
    search,
    toggleDir,
    toggleReasoningBlock,
    refreshCheckpoints,
    createCheckpoint,
    rollbackCheckpoint
  }

  return <Ctx.Provider value={value}>{children}</Ctx.Provider>
}
EOF

echo "== 渲染进程：组件 =="

w apps/desktop/src/renderer/src/App.tsx <<'EOF'
import type { JSX } from 'react'
import ChatPane from './components/ChatPane'
import Composer from './components/Composer'
import PreviewPane from './components/PreviewPane'
import Sidebar from './components/Sidebar'
import TerminalPane from './components/TerminalPane'
import TitleBar from './components/TitleBar'

export default function App(): JSX.Element {
  return (
    <div className="app">
      <TitleBar />
      <main className="body">
        <Sidebar />
        <div className="center">
          <ChatPane />
          <TerminalPane />
          <Composer />
        </div>
        <PreviewPane />
      </main>
    </div>
  )
}
EOF

w apps/desktop/src/renderer/src/components/TitleBar.tsx <<'EOF'
import type { JSX } from 'react'
import { useAgent } from '../state/AgentContext'

/** 上下文预算的参考上限，与内核默认值保持一致 */
const CONTEXT_BUDGET = 60_000

export default function TitleBar(): JSX.Element {
  const { info, workspace, transcript } = useAgent()

  const used = transcript.usage?.totalTokens ?? 0
  const percent = Math.min(100, Math.round((used / CONTEXT_BUDGET) * 100))

  return (
    <header className="titlebar">
      <div className="brand">
        <img src="/icon-256.png" alt="" className="brand-logo" />
        <span className="brand-name">Witseek</span>
      </div>

      <span className="chip" title={workspace?.root}>
        工作区：{workspace?.name ?? '…'}
      </span>

      {info && (
        <span className={info.hasApiKey ? 'chip' : 'chip chip-muted'}>
          {info.hasApiKey ? info.model : `${info.model}（演示）`}
        </span>
      )}

      {transcript.running && <span className="chip chip-running">运行中 · 第 {transcript.step} 轮</span>}
      {info?.headless && <span className="chip chip-muted">无头渲染</span>}

      <div className="context-meter" title={`已用约 ${used.toLocaleString()} tokens`}>
        <span className="meter-label">上下文</span>
        <div className="meter-track">
          <div className="meter-fill" style={{ width: `${percent}%` }} />
        </div>
        <span className="meter-value">{percent}%</span>
      </div>

      {info && <span className="version">v{info.version}</span>}
    </header>
  )
}
EOF

w apps/desktop/src/renderer/src/components/Sidebar.tsx <<'EOF'
import { useState, type JSX } from 'react'
import type { CheckpointInfo, FileEntry } from '@witseek/protocol'
import { useAgent } from '../state/AgentContext'
import { formatBytes, relativeTime, visibleTree } from '../util'

type Tab = 'files' | 'sessions' | 'search' | 'checkpoints'

const REASON_LABEL: Record<CheckpointInfo['reason'], string> = {
  auto: '自动',
  manual: '手动',
  'rollback-backup': '回滚前备份'
}

export default function Sidebar(): JSX.Element {
  const [tab, setTab] = useState<Tab>('files')

  return (
    <aside className="sidebar">
      <nav className="tabs">
        {(
          [
            ['files', '文件'],
            ['sessions', '会话'],
            ['checkpoints', '检查点'],
            ['search', '搜索']
          ] as const
        ).map(([key, label]) => (
          <button
            key={key}
            className={tab === key ? 'tab tab-active' : 'tab'}
            onClick={() => setTab(key)}
          >
            {label}
          </button>
        ))}
      </nav>

      {tab === 'files' && <FilesTab />}
      {tab === 'sessions' && <SessionsTab />}
      {tab === 'checkpoints' && <CheckpointsTab />}
      {tab === 'search' && <SearchTab />}
    </aside>
  )
}

function FilesTab(): JSX.Element {
  const { tree, treeTruncated, collapsed, toggleDir, openFile, preview, changed, refreshTree, chooseWorkspace } =
    useAgent()
  const rows = visibleTree(tree, collapsed)

  return (
    <>
      <div className="sidebar-actions">
        <button className="btn-ghost" onClick={() => void chooseWorkspace()}>
          打开文件夹
        </button>
        <button className="btn-ghost" onClick={() => void refreshTree()}>
          刷新
        </button>
      </div>

      <div className="tree">
        {rows.length === 0 && <p className="hint">工作区为空，或还在加载…</p>}
        {rows.map((node) => (
          <TreeRow
            key={node.path}
            node={node}
            collapsed={collapsed.has(node.path)}
            active={preview?.path === node.path}
            modified={changed.includes(node.path)}
            onToggle={toggleDir}
            onOpen={openFile}
          />
        ))}
        {treeTruncated && <p className="hint">条目过多，仅显示前一部分。</p>}
      </div>

      <footer className="sidebar-foot">
        {tree.length} 个条目{changed.length > 0 ? ` · ${changed.length} 个已改动` : ''}
      </footer>
    </>
  )
}

function TreeRow({
  node,
  collapsed,
  active,
  modified,
  onToggle,
  onOpen
}: {
  node: FileEntry
  collapsed: boolean
  active: boolean
  modified: boolean
  onToggle: (path: string) => void
  onOpen: (path: string) => void
}): JSX.Element {
  const isDir = node.kind === 'dir'
  const className = ['tree-row', active ? 'tree-row-active' : ''].filter(Boolean).join(' ')

  return (
    <div
      className={className}
      style={{ paddingLeft: 8 + node.depth * 10 }}
      title={node.path}
      onClick={() => (isDir ? onToggle(node.path) : void onOpen(node.path))}
    >
      <span className={isDir ? 'caret caret-dir' : 'caret caret-file'}>
        {isDir ? (collapsed ? '▸' : '▾') : ''}
      </span>
      <span className="tree-name">{node.name}</span>
      {modified && <span className="status status-M">M</span>}
      {!isDir && !modified && node.size > 0 && (
        <span className="tree-size">{formatBytes(node.size)}</span>
      )}
    </div>
  )
}

function SessionsTab(): JSX.Element {
  const { sessions, newSession, loadSession } = useAgent()

  return (
    <>
      <div className="sidebar-actions">
        <button className="btn-ghost" onClick={() => void newSession()}>
          新建会话
        </button>
        <span className="spacer" />
      </div>
      <div className="session-list">
        {sessions.length === 0 && <p className="hint">还没有会话。发一条指令就会自动创建。</p>}
        {sessions.map((s) => (
          <div key={s.id} className="session-item" onClick={() => void loadSession(s.id)}>
            <div className="session-title">{s.title}</div>
            <div className="session-meta">
              {relativeTime(s.updatedAt)} · {s.messages} 条
            </div>
          </div>
        ))}
      </div>
    </>
  )
}

function CheckpointsTab(): JSX.Element {
  const { checkpoints, checkpointBusy, createCheckpoint, rollbackCheckpoint } = useAgent()
  const [label, setLabel] = useState('')

  const onCreate = async (): Promise<void> => {
    const name = label.trim()
    await createCheckpoint(name || undefined)
    setLabel('')
  }

  const onRollback = async (cp: CheckpointInfo): Promise<void> => {
    const ok = window.confirm(
      `确定回滚到检查点「${cp.label}」吗？\n\n` +
        '当前工作区状态会先自动备份，回滚后可用该备份撤销本次操作。'
    )
    if (!ok) return
    await rollbackCheckpoint(cp.id)
  }

  return (
    <>
      <div className="cp-create">
        <input
          className="search-input"
          placeholder="检查点名称（可留空）"
          value={label}
          onChange={(e) => setLabel(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') void onCreate()
          }}
        />
        <button className="btn-primary btn-xs" disabled={checkpointBusy} onClick={() => void onCreate()}>
          创建检查点
        </button>
      </div>
      <p className="hint cp-tip">每轮对话开始前会自动打一个检查点。回滚会先备份当前状态。</p>
      <div className="session-list">
        {checkpoints.length === 0 && <p className="hint">还没有检查点。</p>}
        {checkpoints.map((cp) => (
          <div key={cp.id} className="cp-item">
            <div className="cp-head">
              <span className={`cp-tag cp-tag-${cp.reason}`}>{REASON_LABEL[cp.reason]}</span>
              <span className="cp-title" title={cp.label}>
                {cp.label}
              </span>
            </div>
            <div className="session-meta">
              {relativeTime(cp.createdAt)} · {cp.files} 个文件 · {formatBytes(cp.bytes)}
              {cp.skipped.length > 0 ? ` · 跳过 ${cp.skipped.length}` : ''}
            </div>
            <div className="cp-actions">
              <button className="btn-ghost btn-xs" disabled={checkpointBusy} onClick={() => void onRollback(cp)}>
                回滚到此
              </button>
            </div>
          </div>
        ))}
      </div>
    </>
  )
}

function SearchTab(): JSX.Element {
  const { search, searchHits, openFile } = useAgent()
  const [value, setValue] = useState('')

  return (
    <>
      <div className="search-pane">
        <input
          className="search-input"
          placeholder="搜索文件内容…"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') void search(value)
          }}
        />
        <p className="hint">
          检索走内核的 grep 工具，范围与大模型看到的完全一致。回车执行。
        </p>
      </div>
      <div className="search-results">
        {searchHits.map((h, i) => (
          <div key={`${h.path}-${h.line}-${i}`} className="search-hit" onClick={() => void openFile(h.path)}>
            <div className="search-path">
              {h.path}
              <span className="search-line">:{h.line}</span>
            </div>
            <div className="search-text">{h.text}</div>
          </div>
        ))}
      </div>
    </>
  )
}
EOF

w apps/desktop/src/renderer/src/components/ChatPane.tsx <<'EOF'
import { useEffect, useRef, useState, type JSX } from 'react'
import type { ApprovalPrompt, DiffHunk, DiffLine, DiffPreview } from '@witseek/protocol'
import { useAgent } from '../state/AgentContext'
import { relativeTime } from '../util'
import type { Block } from '../transcript'

export default function ChatPane(): JSX.Element {
  const { transcript, decide, toggleReasoningBlock } = useAgent()
  const endRef = useRef<HTMLDivElement | null>(null)

  // 新内容到达时贴到底部。只在块数量变化时滚，避免流式追加时每帧都滚。
  const count = transcript.blocks.length + (transcript.pending ? 1 : 0)
  useEffect(() => {
    endRef.current?.scrollIntoView({ block: 'end' })
  }, [count])

  const empty = transcript.blocks.length === 0 && !transcript.pending

  return (
    <section className="chat">
      <div className="chat-scroll">
        {empty && <EmptyState />}
        {transcript.blocks.map((b) => (
          <BlockView key={b.id} block={b} onToggle={toggleReasoningBlock} />
        ))}
        {transcript.pending && (
          <ApprovalCard
            prompt={transcript.pending}
            deciding={transcript.deciding}
            onDecide={decide}
          />
        )}
        {transcript.stopReason && transcript.stopReason !== 'completed' && (
          <p className="chat-note">
            本轮结束原因：{transcript.stopReason === 'max-steps' ? '达到步数上限' : transcript.stopReason === 'aborted' ? '已中止' : '出错'}
          </p>
        )}
        <div ref={endRef} />
      </div>
    </section>
  )
}

function EmptyState(): JSX.Element {
  const { info, workspace } = useAgent()
  return (
    <div className="empty">
      <h2>在 {workspace?.name ?? '工作区'} 里开始</h2>
      <p>
        agent 会在当前工作区内读写文件、执行命令。写操作会先弹审批卡片，批准后才落盘。
      </p>
      {info && !info.hasApiKey && (
        <p className="empty-warn">
          未检测到 DEEPSEEK_API_KEY，当前走内置的脚本化演示流程（provider = mock）。
          它会把「流式输出 → 工具调用 → 审批 → 改文件」整条链路真实跑一遍，但不会真正理解你的代码。
        </p>
      )}
      <p className="empty-hint">试试输入：看看工作区里有什么</p>
    </div>
  )
}

function BlockView({
  block,
  onToggle
}: {
  block: Block
  onToggle: (id: string) => void
}): JSX.Element {
  if (block.kind === 'user') {
    return (
      <div className="user-bubble">
        <span className="user-label">你</span>
        <span className="user-text">{block.text}</span>
      </div>
    )
  }

  if (block.kind === 'reasoning') {
    return (
      <div className="card card-reasoning">
        <div className="card-head clickable" onClick={() => onToggle(block.id)}>
          <span className="caret">{block.open ? '▾' : '▸'}</span>
          <span className="card-title">推理过程{block.open ? '' : ' · 已折叠'}</span>
        </div>
        {block.open && <p className="card-detail pre-wrap">{block.text}</p>}
      </div>
    )
  }

  if (block.kind === 'tool') {
    const stateClass =
      block.state === 'ok' ? 'dot-ok' : block.state === 'fail' ? 'dot-fail' : 'dot-running'
    return (
      <div className="card">
        <div className="card-head">
          <span className={`dot ${stateClass}`} />
          <span className="card-title mono">{block.name}</span>
          <span className="card-args mono">{compactArgs(block.args)}</span>
          {block.ms !== undefined && <span className="card-ms">{block.ms} ms</span>}
        </div>
        {block.diff && (
          <DiffStat
            diff={block.diff}
            accepted={block.acceptedHunkIds}
          />
        )}
        {block.output && <pre className="card-output">{firstLines(block.output, 8)}</pre>}
      </div>
    )
  }

  if (block.kind === 'approval') {
    return <ApprovalRecord block={block} />
  }

  if (block.kind === 'checkpoint') {
    const cp = block.checkpoint
    const reasonLabel =
      cp.reason === 'auto'
        ? '自动检查点'
        : cp.reason === 'rollback-backup'
          ? '回滚前备份'
          : '检查点'
    return (
      <div className="card card-checkpoint">
        <div className="card-head">
          <span className="checkpoint-icon">⏺</span>
          <span className="card-title">{reasonLabel}</span>
          <span className="card-args" title={cp.label}>
            {cp.label}
          </span>
          <span className="card-ms">{relativeTime(cp.createdAt)}</span>
        </div>
        <p className="card-detail">
          {cp.files} 个文件 · 检查点侧栏可一键回滚
          {cp.skipped.length > 0 ? ` · ${cp.skipped.length} 个大文件已跳过` : ''}
        </p>
      </div>
    )
  }

  if (block.kind === 'error') {
    return <div className="card card-error">{block.text}</div>
  }

  return <p className="answer">{block.text}</p>
}

/**
 * 待决审批卡。有 hunk 时每个变更块给一个复选框 —— 这就是"逐块接受/拒绝"：
 * 勾选 = 接受该块，取消 = 把该块改动还原。批准时把勾选集合交给主进程。
 */
function ApprovalCard({
  prompt,
  deciding,
  onDecide
}: {
  prompt: ApprovalPrompt
  deciding: boolean
  onDecide: (d: 'approve' | 'deny', acceptedHunkIds?: string[]) => void
}): JSX.Element {
  const hunks = prompt.diff?.hunks ?? []
  const canSplit = hunks.length > 0 && !prompt.diff?.truncated
  const [accepted, setAccepted] = useState<Set<string>>(
    () => new Set(hunks.map((h) => h.id))
  )

  const allAccepted = canSplit && accepted.size === hunks.length
  const noneAccepted = canSplit && accepted.size === 0

  const toggle = (id: string): void => {
    setAccepted((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  const approve = (): void => {
    if (!canSplit || allAccepted) {
      void onDecide('approve')
      return
    }
    if (noneAccepted) {
      // 一块都不留 = 整体拒绝
      void onDecide('deny')
      return
    }
    void onDecide('approve', [...accepted])
  }

  return (
    <div className="card card-approval">
      <div className="card-head">
        <span className="dot dot-pending" />
        <span className="card-title mono">{prompt.tool}</span>
        <span className="badge badge-pending">待批准</span>
      </div>
      <p className="card-detail">{prompt.summary}</p>
      {prompt.diff && <DiffStat diff={prompt.diff} />}
      {canSplit && (
        <div className="hunk-list">
          <div className="hunk-toolbar">
            <button
              type="button"
              className="btn-link btn-xs"
              onClick={() => setAccepted(new Set(hunks.map((h) => h.id)))}
            >
              全选
            </button>
            <button type="button" className="btn-link btn-xs" onClick={() => setAccepted(new Set())}>
              全不选
            </button>
            <span className="hint">
              已选 {accepted.size}/{hunks.length} 块 —— 未勾选的块不会写入
            </span>
          </div>
          {hunks.map((h) => (
            <HunkPicker key={h.id} hunk={h} checked={accepted.has(h.id)} onToggle={toggle} />
          ))}
        </div>
      )}
      {prompt.diff?.truncated && (
        <p className="card-warn">变更过大，仅提供整体统计，不支持逐块选择。</p>
      )}
      {prompt.outsideWorkspace && (
        <p className="card-warn">该操作超出工作区范围，请确认路径后再批准。</p>
      )}
      <div className="actions">
        <button className="btn-primary" disabled={deciding} onClick={approve}>
          {canSplit && !allAccepted && !noneAccepted ? `批准选中的 ${accepted.size} 块` : '批准'}
        </button>
        <button className="btn-ghost" disabled={deciding} onClick={() => onDecide('deny')}>
          拒绝
        </button>
        {deciding && <span className="hint">已提交，等待内核确认…</span>}
      </div>
    </div>
  )
}

function HunkPicker({
  hunk,
  checked,
  onToggle
}: {
  hunk: DiffHunk
  checked: boolean
  onToggle: (id: string) => void
}): JSX.Element {
  return (
    <label className={`hunk ${checked ? 'hunk-on' : 'hunk-off'}`}>
      <input type="checkbox" checked={checked} onChange={() => onToggle(hunk.id)} />
      <div className="hunk-body">
        <div className="hunk-head mono">
          @@ -{hunk.oldStart},{hunk.oldLines} +{hunk.newStart},{hunk.newLines} @@
        </div>
        <pre className="hunk-diff">
          {hunk.lines.map((l, i) => (
            <HunkLine key={i} line={l} dimmed={!checked} />
          ))}
        </pre>
      </div>
    </label>
  )
}

function HunkLine({ line, dimmed }: { line: DiffLine; dimmed: boolean }): JSX.Element {
  const cls =
    line.kind === 'add'
      ? dimmed
        ? 'hunk-line hunk-line-add-off'
        : 'hunk-line hunk-line-add'
      : line.kind === 'del'
        ? dimmed
          ? 'hunk-line hunk-line-del-off'
          : 'hunk-line hunk-line-del'
        : 'hunk-line hunk-line-plain'
  const prefix = line.kind === 'add' ? '+ ' : line.kind === 'del' ? '− ' : '  '
  return (
    <div className={cls}>
      {prefix}
      {line.text}
    </div>
  )
}

function ApprovalRecord({ block }: { block: Extract<Block, { kind: 'approval' }> }): JSX.Element {
  const approved = block.decision === 'approve' || block.decision === 'approve-always'
  const total = block.diff?.hunks.length ?? 0
  const picked = block.acceptedHunkIds?.length
  const partial = approved && picked !== undefined && total > 0 && picked < total
  return (
    <div className={approved ? 'card' : 'card card-denied'}>
      <div className="card-head">
        <span className={approved ? 'dot dot-ok' : 'dot dot-fail'} />
        <span className="card-title mono">{block.tool}</span>
        <span className={approved ? 'badge badge-ok' : 'badge badge-denied'}>
          {block.decision === 'approve-always'
            ? '已批准（总是）'
            : partial
              ? `已部分批准（${picked}/${total} 块）`
              : approved
                ? '已批准'
                : '已拒绝'}
        </span>
      </div>
      <p className="card-detail">{block.summary}</p>
      {block.diff && <DiffStat diff={block.diff} accepted={block.acceptedHunkIds} />}
    </div>
  )
}

function DiffStat({
  diff,
  accepted
}: {
  diff: DiffPreview
  accepted?: string[]
}): JSX.Element {
  const total = diff.hunks.length
  const picked = accepted?.length
  return (
    <div className="diffstat">
      <span className="add">+{diff.added}</span>
      <span className="del">−{diff.removed}</span>
      <span className="muted">{diff.path}</span>
      {picked !== undefined && total > 0 && picked < total && (
        <span className="muted">（应用 {picked}/{total} 块）</span>
      )}
      {diff.truncated && <span className="muted">（过大，仅统计）</span>}
    </div>
  )
}

function compactArgs(raw: string): string {
  if (!raw || raw === '{}') return ''
  try {
    const args = JSON.parse(raw) as Record<string, unknown>
    const path = typeof args.path === 'string' ? args.path : ''
    const cmd = typeof args.command === 'string' ? args.command : ''
    const shown = path || cmd
    if (!shown) return raw.length > 90 ? `${raw.slice(0, 90)}…` : raw
    return shown.length > 90 ? `${shown.slice(0, 90)}…` : shown
  } catch {
    return raw.length > 90 ? `${raw.slice(0, 90)}…` : raw
  }
}

function firstLines(text: string, n: number): string {
  const lines = text.split('\n')
  if (lines.length <= n) return text
  return `${lines.slice(0, n).join('\n')}\n…（共 ${lines.length} 行）`
}
EOF

w apps/desktop/src/renderer/src/components/PreviewPane.tsx <<'EOF'
import type { JSX } from 'react'
import type { DiffLine } from '@witseek/protocol'
import { useAgent } from '../state/AgentContext'
import { basename } from '../util'

export default function PreviewPane(): JSX.Element {
  const { preview, closePreview, openFile } = useAgent()

  if (!preview) {
    return (
      <aside className="preview preview-empty">
        <div className="preview-head">
          <span className="muted">预览</span>
        </div>
        <p className="hint preview-hint">
          点击左侧文件查看内容。agent 改动文件时会自动切到 diff 视图。
        </p>
      </aside>
    )
  }

  return (
    <aside className="preview">
      <div className="preview-head">
        <span title={preview.path}>{basename(preview.path)}</span>
        <span className="preview-head-actions">
          <button className="btn-ghost btn-xs" onClick={() => void openFile(preview.path)}>
            刷新
          </button>
          <button className="btn-ghost btn-xs" onClick={closePreview}>
            关闭
          </button>
        </span>
      </div>

      {preview.loading && <p className="hint preview-hint">读取中…</p>}
      {preview.error && <p className="hint preview-hint">读取失败：{preview.error}</p>}

      {preview.diff && <DiffView diff={preview.diff} />}

      {!preview.diff && preview.content?.binary && (
        <p className="hint preview-hint">这是二进制文件，不做文本预览。</p>
      )}

      {!preview.diff && preview.content && !preview.content.binary && (
        <>
          <div className="preview-code">
            {preview.content.text.split('\n').map((line, i) => (
              <div key={i} className="code-row">
                <span className="gutter">{i + 1}</span>
                <span className="code-text">{line}</span>
              </div>
            ))}
          </div>
          <div className="preview-foot">
            <span className="hint">
              {preview.content.lines} 行
              {preview.content.truncated ? '（已截断）' : ''}
            </span>
          </div>
        </>
      )}
    </aside>
  )
}

function DiffView({
  diff
}: {
  diff: { lines: DiffLine[]; hunks: Array<{ id: string; oldStart: number; oldLines: number; newStart: number; newLines: number }>; truncated: boolean }
}): JSX.Element {
  // 有 hunk 分组时按块渲染（块间留缝、带 @@ 头），与审批卡的逐块视图保持一致
  if (diff.hunks.length > 0) {
    return (
      <div className="preview-code">
        {diff.hunks.map((h) => {
          const lines = diff.lines.filter((l) => l.hunkId === h.id)
          return (
            <div key={h.id} className="diff-hunk">
              <div className="diff-hunk-head mono">
                @@ -{h.oldStart},{h.oldLines} +{h.newStart},{h.newLines} @@
              </div>
              {lines.map((l, i) => (
                <DiffRow key={i} l={l} />
              ))}
            </div>
          )
        })}
      </div>
    )
  }

  return (
    <div className="preview-code">
      {diff.lines.map((l, i) => (
        <DiffRow key={i} l={l} />
      ))}
    </div>
  )
}

function DiffRow({ l }: { l: DiffLine }): JSX.Element {
  return (
    <div className={`code-row code-${l.kind}`}>
      <span className="gutter">{l.kind === 'add' ? l.newNo : l.oldNo}</span>
      <span className="code-text">
        {l.kind === 'add' ? '+ ' : l.kind === 'del' ? '− ' : '  '}
        {l.text}
      </span>
    </div>
  )
}
EOF

w apps/desktop/src/renderer/src/components/Composer.tsx <<'EOF'
import { useState, type JSX } from 'react'
import type { PermissionMode } from '@witseek/protocol'
import { useAgent } from '../state/AgentContext'

const MODES: Array<{ value: PermissionMode; label: string; hint: string }> = [
  { value: 'confirm', label: '逐次确认', hint: '每个写操作都要你点批准' },
  { value: 'auto', label: '工作区内自动', hint: '工作区内的写操作直接执行，越界仍要确认' },
  { value: 'read-only', label: '只读', hint: '拒绝一切写操作' }
]

export default function Composer(): JSX.Element {
  const { send, abort, mode, setMode, transcript } = useAgent()
  const [value, setValue] = useState('')
  const running = transcript.running

  const submit = async (): Promise<void> => {
    const text = value.trim()
    if (!text || running) return
    setValue('')
    await send(text)
  }

  return (
    <div className="composer">
      <div className="composer-box">
        <textarea
          className="composer-input"
          rows={1}
          placeholder="输入指令，Enter 发送，Shift+Enter 换行…"
          value={value}
          onChange={(e) => setValue(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' && !e.shiftKey) {
              e.preventDefault()
              void submit()
            }
          }}
        />
        {running ? (
          <button className="btn-ghost" onClick={() => void abort()}>
            中止
          </button>
        ) : (
          <button className="send" aria-label="发送" onClick={() => void submit()} />
        )}
      </div>
      <div className="composer-foot">
        <select
          className="mode-select"
          value={mode}
          onChange={(e) => void setMode(e.target.value as PermissionMode)}
        >
          {MODES.map((m) => (
            <option key={m.value} value={m.value}>
              {m.label}
            </option>
          ))}
        </select>
        <span className="composer-hint">{MODES.find((m) => m.value === mode)?.hint}</span>
        <span className="spacer" />
        <span className="composer-hint">工作目录锁定在工作区</span>
      </div>
    </div>
  )
}
EOF

echo "== 渲染进程：样式 =="

w apps/desktop/src/renderer/src/styles.css <<'EOF'
:root {
  --bg: #ffffff;
  --bg-secondary: #f7f8fa;
  --bg-tertiary: #eef0f4;
  --border: rgba(0, 0, 0, 0.1);
  --border-strong: rgba(0, 0, 0, 0.18);
  --text: #1a1d21;
  --text-secondary: #5c6370;
  --text-tertiary: #8b93a1;
  --brand: #185fa5;
  --brand-deep: #0c447c;
  --brand-soft: #e6f1fb;
  --brand-border: #b5d4f4;
  --ok: #3b6d11;
  --ok-soft: #eaf3de;
  --warn: #ba7517;
  --warn-soft: #faeeda;
  --del: #a32d2d;
  --del-soft: #fcebeb;
  --radius: 8px;
  --radius-lg: 12px;
  --font: -apple-system, 'Segoe UI', 'Microsoft YaHei', system-ui, sans-serif;
  --mono: 'SF Mono', 'Cascadia Mono', Consolas, 'Liberation Mono', monospace;
}

* {
  box-sizing: border-box;
}

html,
body,
#root {
  height: 100%;
  margin: 0;
}

body {
  font-family: var(--font);
  font-size: 13px;
  line-height: 1.6;
  color: var(--text);
  background: var(--bg);
  -webkit-font-smoothing: antialiased;
  overflow: hidden;
}

button {
  font-family: inherit;
  font-size: 12px;
  cursor: pointer;
  border-radius: 6px;
  border: 0.5px solid var(--border-strong);
  background: transparent;
  color: var(--text-secondary);
  padding: 4px 10px;
}

button:hover:not(:disabled) {
  border-color: var(--brand);
  color: var(--brand);
}

button:disabled {
  opacity: 0.5;
  cursor: default;
}

.spacer {
  margin-left: auto;
}

.app {
  display: flex;
  flex-direction: column;
  height: 100%;
}

/* ---------- 标题栏 ---------- */
.titlebar {
  display: flex;
  align-items: center;
  gap: 10px;
  height: 44px;
  padding: 0 14px;
  background: var(--bg-secondary);
  border-bottom: 0.5px solid var(--border);
  flex: none;
}

.brand {
  display: flex;
  align-items: center;
  gap: 7px;
}

.brand-logo {
  width: 20px;
  height: 20px;
  border-radius: 5px;
  object-fit: cover;
}

.brand-name {
  font-size: 14px;
  font-weight: 500;
}

.chip {
  font-size: 12px;
  color: var(--text-secondary);
  border: 0.5px solid var(--border);
  border-radius: 6px;
  padding: 2px 9px;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
  max-width: 260px;
}

.chip-muted {
  color: var(--warn);
  border-color: #ef9f27;
  background: var(--warn-soft);
}

.chip-running {
  color: var(--brand-deep);
  border-color: var(--brand-border);
  background: var(--brand-soft);
}

.context-meter {
  margin-left: auto;
  display: flex;
  align-items: center;
  gap: 7px;
}

.meter-label,
.meter-value {
  font-size: 11px;
  color: var(--text-tertiary);
}

.meter-track {
  width: 60px;
  height: 5px;
  border-radius: 3px;
  background: var(--bg-tertiary);
  overflow: hidden;
}

.meter-fill {
  height: 100%;
  background: #378add;
}

.version {
  font-size: 11px;
  color: var(--text-tertiary);
}

/* ---------- 主体三栏 ---------- */
.body {
  flex: 1;
  display: flex;
  min-height: 0;
}

.sidebar {
  /* 288 而不是更窄：Java/Android 的源码路径能到 7~8 层，
     缩进（每层 10px）吃掉的宽度必须留够，否则最先被省略号吃掉的
     恰恰是文件名本身 —— 那是这棵树里唯一真正有用的信息。 */
  width: 288px;
  flex: none;
  border-right: 0.5px solid var(--border);
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.center {
  flex: 1;
  display: flex;
  flex-direction: column;
  min-width: 0;
}

.preview {
  width: 300px;
  flex: none;
  border-left: 0.5px solid var(--border);
  display: flex;
  flex-direction: column;
  min-height: 0;
}

.preview-empty {
  opacity: 0.85;
}

/* ---------- 侧边栏 ---------- */
.tabs {
  display: flex;
  gap: 3px;
  padding: 9px 9px 7px;
}

.tab {
  border: none;
  padding: 3px 10px;
  color: var(--text-secondary);
  background: transparent;
}

.tab-active {
  color: var(--brand-deep);
  background: var(--brand-soft);
  font-weight: 500;
}

.sidebar-actions {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 0 10px 8px;
}

.tree {
  flex: 1;
  overflow-y: auto;
  padding: 2px 6px;
}

.tree-row {
  display: flex;
  align-items: center;
  gap: 5px;
  height: 25px;
  border-radius: 5px;
  padding-right: 8px;
  font-size: 12px;
  cursor: pointer;
}

.tree-row:hover {
  background: var(--bg-secondary);
}

.tree-row-active {
  background: var(--brand-soft);
  color: var(--brand-deep);
}

.caret {
  font-size: 9px;
  color: var(--text-tertiary);
  width: 9px;
  flex: none;
}

.caret-dir {
  color: var(--warn);
}

.tree-name {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.tree-size {
  margin-left: auto;
  font-size: 10px;
  color: var(--text-tertiary);
  flex: none;
}

.status {
  margin-left: auto;
  font-size: 10px;
  font-weight: 600;
  flex: none;
}

.status-M {
  color: var(--ok);
}

.sidebar-foot {
  border-top: 0.5px solid var(--border);
  padding: 8px 10px;
  font-size: 11px;
  color: var(--text-tertiary);
}

.session-list {
  flex: 1;
  overflow-y: auto;
  padding: 4px 8px;
}

.session-item {
  padding: 7px 9px;
  border-radius: 6px;
  font-size: 12px;
  color: var(--text-secondary);
  cursor: pointer;
}

.session-item:hover {
  background: var(--bg-secondary);
  color: var(--text);
}

.session-title {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.session-meta {
  font-size: 10px;
  color: var(--text-tertiary);
  margin-top: 1px;
}

.search-pane {
  padding: 4px 10px;
}

.search-input {
  width: 100%;
  font-family: inherit;
  font-size: 12px;
  padding: 6px 9px;
  border: 0.5px solid var(--border-strong);
  border-radius: 6px;
  background: var(--bg);
  color: var(--text);
  outline: none;
}

.search-input:focus {
  border-color: var(--brand);
}

.search-results {
  flex: 1;
  overflow-y: auto;
  padding: 0 8px 8px;
}

.search-hit {
  padding: 6px 8px;
  border-radius: 6px;
  cursor: pointer;
}

.search-hit:hover {
  background: var(--bg-secondary);
}

.search-path {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--brand-deep);
}

.search-line {
  color: var(--text-tertiary);
}

.search-text {
  font-family: var(--mono);
  font-size: 11px;
  color: var(--text-secondary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.hint {
  font-size: 11px;
  color: var(--text-tertiary);
  line-height: 1.7;
}

/* ---------- 对话区 ---------- */
.chat {
  flex: 1;
  overflow-y: auto;
  padding: 14px 16px;
  min-height: 0;
}

.chat-scroll {
  display: flex;
  flex-direction: column;
  gap: 10px;
}

.chat-note {
  font-size: 11px;
  color: var(--text-tertiary);
  text-align: center;
  margin: 4px 0;
}

.empty {
  padding: 28px 8px;
  max-width: 560px;
}

.empty h2 {
  font-size: 15px;
  font-weight: 500;
  margin: 0 0 8px;
}

.empty p {
  font-size: 12px;
  color: var(--text-secondary);
  margin: 0 0 10px;
}

.empty-warn {
  color: var(--warn) !important;
  background: var(--warn-soft);
  border: 0.5px solid #ef9f27;
  border-radius: var(--radius);
  padding: 8px 10px;
}

.empty-hint {
  font-family: var(--mono);
  color: var(--text-tertiary) !important;
}

.user-bubble {
  align-self: flex-end;
  max-width: 82%;
  background: var(--brand-soft);
  border: 0.5px solid var(--brand-border);
  border-radius: var(--radius-lg);
  padding: 7px 12px;
  display: flex;
  gap: 8px;
  align-items: baseline;
}

.user-label {
  font-size: 10px;
  color: var(--brand);
  flex: none;
}

.user-text {
  font-size: 13px;
  color: var(--brand-deep);
  white-space: pre-wrap;
  word-break: break-word;
}

.card {
  border: 0.5px solid var(--border);
  border-radius: var(--radius);
  padding: 9px 12px;
}

.card-reasoning {
  background: var(--brand-soft);
  border-color: var(--brand-border);
}

.card-reasoning .card-title {
  color: var(--brand-deep);
}

.card-reasoning .card-detail {
  color: var(--brand);
}

.card-approval {
  border-color: #ef9f27;
  background: var(--warn-soft);
}

.card-denied {
  opacity: 0.75;
}

.card-error {
  border-color: #f09595;
  background: var(--del-soft);
  color: var(--del);
  white-space: pre-wrap;
  font-size: 12px;
}

.card-warn {
  margin: 5px 0 0;
  font-size: 11px;
  color: var(--del);
}

.card-head {
  display: flex;
  align-items: center;
  gap: 7px;
  min-width: 0;
}

.clickable {
  cursor: pointer;
}

.card-title {
  font-size: 12px;
  font-weight: 500;
  flex: none;
}

.card-args {
  font-size: 11px;
  color: var(--text-tertiary);
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.card-ms {
  margin-left: auto;
  font-size: 10px;
  color: var(--text-tertiary);
  flex: none;
}

.card-output {
  margin: 6px 0 0;
  font-family: var(--mono);
  font-size: 11px;
  line-height: 1.6;
  color: var(--text-secondary);
  background: var(--bg-secondary);
  border-radius: 6px;
  padding: 7px 9px;
  overflow-x: auto;
  white-space: pre;
  max-height: 180px;
}

.mono {
  font-family: var(--mono);
}

.card-detail {
  margin: 4px 0 0;
  font-size: 11px;
  color: var(--text-tertiary);
}

.pre-wrap {
  white-space: pre-wrap;
  word-break: break-word;
}

.dot {
  width: 6px;
  height: 6px;
  border-radius: 50%;
  flex: none;
}

.dot-ok {
  background: #639922;
}

.dot-fail {
  background: var(--del);
}

.dot-pending {
  background: var(--warn);
}

.dot-running {
  background: #378add;
  animation: pulse 1s ease-in-out infinite;
}

@keyframes pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.3;
  }
}

.badge {
  font-size: 11px;
  border-radius: 4px;
  padding: 1px 7px;
  flex: none;
}

.badge-pending {
  color: #854f0b;
  background: #fbe4c4;
}

.badge-ok {
  color: var(--ok);
  background: var(--ok-soft);
}

.badge-denied {
  color: var(--del);
  background: var(--del-soft);
}

.diffstat {
  display: flex;
  gap: 8px;
  align-items: center;
  font-family: var(--mono);
  font-size: 11px;
  margin-top: 5px;
}

.add {
  color: var(--ok);
}

.del {
  color: var(--del);
}

.muted {
  color: var(--text-secondary);
  font-family: var(--font);
}

.actions {
  display: flex;
  gap: 6px;
  align-items: center;
  margin-top: 8px;
}

.btn-primary {
  color: var(--brand-deep);
  background: var(--brand-soft);
  border-color: var(--brand-border);
}

.btn-primary:hover:not(:disabled) {
  background: var(--brand-border);
  color: var(--brand-deep);
}

.btn-ghost {
  background: transparent;
}

.btn-xs {
  padding: 2px 7px;
  font-size: 11px;
}

.answer {
  margin: 2px 0;
  font-size: 13px;
  line-height: 1.75;
  white-space: pre-wrap;
  word-break: break-word;
}

/* ---------- 输入区 ---------- */
.composer {
  flex: none;
  border-top: 0.5px solid var(--border);
  padding: 10px 16px 12px;
}

.composer-box {
  display: flex;
  align-items: flex-end;
  gap: 8px;
  border: 0.5px solid var(--border-strong);
  border-radius: var(--radius);
  padding: 7px 10px;
}

.composer-box:focus-within {
  border-color: var(--brand);
}

.composer-input {
  flex: 1;
  border: none;
  outline: none;
  background: transparent;
  font-family: inherit;
  font-size: 13px;
  line-height: 1.6;
  color: var(--text);
  resize: none;
  max-height: 140px;
}

.composer-input::placeholder {
  color: var(--text-tertiary);
}

.composer-hint {
  font-size: 11px;
  color: var(--text-tertiary);
  white-space: nowrap;
}

.composer-foot {
  display: flex;
  align-items: center;
  gap: 8px;
  margin-top: 7px;
}

.mode-select {
  font-family: inherit;
  font-size: 11px;
  color: var(--text-secondary);
  border: 0.5px solid var(--border-strong);
  border-radius: 6px;
  background: var(--bg);
  padding: 2px 6px;
  outline: none;
}

.send {
  width: 22px;
  height: 22px;
  padding: 0;
  border: none;
  border-radius: 5px;
  background: var(--brand);
  flex: none;
}

.send:hover {
  background: var(--brand-deep);
}

/* ---------- 预览区 ---------- */
.preview-head {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 8px;
  padding: 9px 12px;
  font-size: 12px;
  font-weight: 500;
  border-bottom: 0.5px solid var(--border);
  overflow: hidden;
}

.preview-head > span:first-child {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}

.preview-head-actions {
  display: flex;
  gap: 4px;
  flex: none;
}

.preview-hint {
  padding: 12px;
}

.preview-code {
  flex: 1;
  overflow: auto;
  padding: 6px 0;
  font-family: var(--mono);
  font-size: 11px;
  line-height: 1.75;
}

.code-row {
  display: flex;
  white-space: pre;
}

.gutter {
  width: 34px;
  flex: none;
  text-align: right;
  padding-right: 9px;
  color: var(--text-tertiary);
  user-select: none;
}

.code-text {
  flex: 1;
}

.code-add {
  background: var(--ok-soft);
  color: var(--ok);
}

.code-add .gutter {
  color: var(--ok);
}

.code-del {
  background: var(--del-soft);
  color: var(--del);
}

.code-del .gutter {
  color: var(--del);
}

.preview-foot {
  border-top: 0.5px solid var(--border);
  padding: 8px 12px;
}

/* ---------- 滚动条 ---------- */
::-webkit-scrollbar {
  width: 9px;
  height: 9px;
}

::-webkit-scrollbar-thumb {
  background: rgba(0, 0, 0, 0.16);
  border-radius: 5px;
}

::-webkit-scrollbar-thumb:hover {
  background: rgba(0, 0, 0, 0.28);
}

::-webkit-scrollbar-track {
  background: transparent;
}

/* ================= P4：逐块审批 ================= */
.hunk-list {
  margin-top: 8px;
  display: flex;
  flex-direction: column;
  gap: 6px;
}

.hunk-toolbar {
  display: flex;
  align-items: center;
  gap: 8px;
}

.btn-link {
  border: none;
  padding: 0 4px;
  color: var(--brand);
  background: transparent;
}

.btn-link:hover:not(:disabled) {
  text-decoration: underline;
  color: var(--brand-deep);
}

.hunk {
  display: flex;
  align-items: flex-start;
  gap: 7px;
  border: 0.5px solid var(--border);
  border-radius: 6px;
  padding: 6px 8px;
  cursor: pointer;
}

.hunk input {
  margin-top: 3px;
  flex: none;
}

.hunk-on {
  background: var(--bg);
  border-color: var(--brand-border);
}

.hunk-off {
  background: var(--bg-secondary);
  opacity: 0.62;
}

.hunk-body {
  flex: 1;
  min-width: 0;
}

.hunk-head {
  font-size: 10px;
  color: var(--text-tertiary);
  margin-bottom: 3px;
  user-select: none;
}

.hunk-diff {
  margin: 0;
  font-family: var(--mono);
  font-size: 11px;
  line-height: 1.6;
  white-space: pre-wrap;
  word-break: break-all;
  max-height: 150px;
  overflow-y: auto;
}

.hunk-line {
  padding: 0 4px;
  border-radius: 3px;
}

.hunk-line-add {
  background: var(--ok-soft);
  color: var(--ok);
}

.hunk-line-del {
  background: var(--del-soft);
  color: var(--del);
}

.hunk-line-add-off {
  background: #e9eaee;
  color: var(--text-tertiary);
  text-decoration: line-through;
}

.hunk-line-del-off {
  background: #e9eaee;
  color: var(--text-tertiary);
}

.hunk-line-plain {
  color: var(--text-secondary);
}

/* ================= P4：检查点 ================= */
.card-checkpoint {
  background: var(--bg-secondary);
  border-style: dashed;
  padding: 7px 12px;
}

.checkpoint-icon {
  color: var(--brand);
  font-size: 11px;
  flex: none;
}

.cp-create {
  display: flex;
  gap: 6px;
  padding: 4px 10px 6px;
}

.cp-create .search-input {
  flex: 1;
}

.cp-tip {
  padding: 0 10px 6px;
}

.cp-item {
  padding: 7px 9px;
  border-radius: 6px;
  font-size: 12px;
}

.cp-item:hover {
  background: var(--bg-secondary);
}

.cp-head {
  display: flex;
  align-items: center;
  gap: 6px;
}

.cp-title {
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
  color: var(--text);
}

.cp-tag {
  font-size: 10px;
  border-radius: 4px;
  padding: 0 6px;
  flex: none;
}

.cp-tag-auto {
  color: var(--brand-deep);
  background: var(--brand-soft);
}

.cp-tag-manual {
  color: var(--ok);
  background: var(--ok-soft);
}

.cp-tag-rollback-backup {
  color: var(--warn);
  background: var(--warn-soft);
}

.cp-actions {
  margin-top: 4px;
  display: flex;
  justify-content: flex-end;
}

/* ================= P4：diff hunk 分组（预览区） ================= */
.diff-hunk {
  margin-bottom: 8px;
}

.diff-hunk-head {
  position: sticky;
  top: 0;
  background: var(--bg-tertiary);
  color: var(--text-secondary);
  font-size: 10px;
  padding: 1px 9px;
}

/* ================= P4：集成终端 ================= */
.terminal {
  flex: none;
  height: 31px;
  border-top: 0.5px solid var(--border);
  background: #1e1f22;
  display: flex;
  flex-direction: column;
  min-height: 0;
  /* 折叠时把终端主体裁掉（否则 xterm 画布会从 31px 的栏下方溢出可见） */
  overflow: hidden;
  transition: height 0.12s ease;
}

.terminal-open {
  height: 240px;
}

.terminal-bar {
  height: 30px;
  flex: none;
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 0 10px;
  background: #2b2d31;
  color: #c7cbd4;
  cursor: pointer;
  user-select: none;
  font-size: 12px;
}

.terminal-caret {
  font-size: 9px;
}

.terminal-title {
  font-weight: 500;
}

.terminal-backend {
  font-size: 10px;
  color: #8b93a1;
  border: 0.5px solid #3a3d44;
  border-radius: 4px;
  padding: 0 6px;
}

.terminal-lock {
  font-size: 10px;
  color: #6b7280;
}

.terminal-restart {
  color: #c7cbd4;
  border-color: #3a3d44;
}

.terminal-body {
  flex: 1;
  min-height: 0;
  position: relative;
  padding: 4px 8px;
}

.terminal-host {
  height: 100%;
  width: 100%;
}

.terminal-failed {
  position: absolute;
  inset: 8px;
  color: #f0a0a0;
  font-size: 11px;
}
EOF

echo
echo "==> P3 渲染进程已生成"
find apps/desktop/src/renderer -type f | sort
