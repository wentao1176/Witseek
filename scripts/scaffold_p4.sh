#!/usr/bin/env bash
# scaffold_p4.sh —— P4 阶段新增文件
#
# 产物:
#   packages/harness-core/src/checkpoint.ts        工作区检查点（文件副本快照 + 清单回滚）
#   packages/harness-core/src/settings.ts          设置持久化（审批模式落盘）
#   apps/desktop/src/main/terminal.ts              集成终端（node-pty 主路径 + script 回退）
#   apps/desktop/src/renderer/.../TerminalPane.tsx xterm 终端面板（可折叠）
#   以及对应的内核/宿主测试
#
# 对既有文件的修改分别在 scaffold_p1/p2_kernel/p2_core/p3_host/p3_ui 中，
# 本脚本只承载 P4 新增的文件（所有权不重叠）。
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
cd "$ROOT"

w() { mkdir -p "$(dirname "$1")"; cat > "$1"; echo "  + $1"; }

echo "== P4 新增文件 =="

w packages/harness-core/src/checkpoint.ts <<'EOF'
import { createHash } from 'node:crypto'
import {
  copyFile,
  mkdir,
  readFile,
  readdir,
  rm,
  rmdir,
  stat,
  writeFile
} from 'node:fs/promises'
import { dirname, join, relative, resolve } from 'node:path'
import type { CheckpointInfo, CheckpointReason } from '@witseek/protocol'

/** 与文件树（workspace.ts）的忽略目录保持一致：依赖/产物/运行期目录不进快照 */
export const DEFAULT_SKIP_DIRS = [
  'node_modules',
  '.git',
  'dist',
  'out',
  '.cache',
  '.tools',
  '.setup',
  '.runtime',
  '.relay-inbox'
]

const DEFAULT_MAX_FILE_BYTES = 5 * 1024 * 1024
const DEFAULT_MAX_TOTAL_BYTES = 200 * 1024 * 1024
const DEFAULT_MAX_FILES = 3000
const DEFAULT_KEEP = 10

export interface CheckpointServiceOptions {
  workspaceRoot: string
  /** 快照仓库根（应放在 userData 下，不污染工作区） */
  storeDir: string
  skipDirs?: string[]
  /** 单文件上限，超过则跳过并记录，默认 5MB */
  maxFileBytes?: number
  /** 一次快照总字节上限，超过直接报错，默认 200MB */
  maxTotalBytes?: number
  /** 文件数上限，超过直接报错，默认 3000 */
  maxFiles?: number
  /** 自动保留的最近检查点数，默认 10 */
  keep?: number
}

interface ManifestEntry {
  path: string
  sha256: string
  size: number
}

interface Manifest {
  info: CheckpointInfo
  entries: ManifestEntry[]
}

export interface RollbackResult {
  /** 恢复（覆盖或找回）的文件数 */
  restored: number
  /** 删除的（检查点之后新增的）文件数 */
  removed: number
  /** 回滚前自动打的备份检查点，保证回滚本身可逆 */
  backup: CheckpointInfo
}

function sha256(buf: Buffer): string {
  return createHash('sha256').update(buf).digest('hex')
}

function toPosix(p: string): string {
  return p.split('\\').join('/')
}

/**
 * 工作区检查点：文件副本快照 + 清单驱动的回滚。
 *
 * 为什么用副本而不是 git stash：演示工作区（以及很多用户项目）不是 git 仓库，
 * 依赖 git 会让"回滚"在最需要它的新手场景下不可用。副本方案零外部依赖。
 *
 * 快照不放工作区内（避免污染用户项目、被 agent 自己看到），
 * 而放在主进程指定的 userData 目录。
 */
export class CheckpointService {
  readonly #root: string
  readonly #store: string
  readonly #skipDirs: Set<string>
  readonly #maxFileBytes: number
  readonly #maxTotalBytes: number
  readonly #maxFiles: number
  readonly #keep: number

  constructor(opts: CheckpointServiceOptions) {
    this.#root = resolve(opts.workspaceRoot)
    this.#store = resolve(opts.storeDir)
    this.#skipDirs = new Set(opts.skipDirs ?? DEFAULT_SKIP_DIRS)
    this.#maxFileBytes = opts.maxFileBytes ?? DEFAULT_MAX_FILE_BYTES
    this.#maxTotalBytes = opts.maxTotalBytes ?? DEFAULT_MAX_TOTAL_BYTES
    this.#maxFiles = opts.maxFiles ?? DEFAULT_MAX_FILES
    this.#keep = opts.keep ?? DEFAULT_KEEP
  }

  get root(): string {
    return this.#root
  }

  #filesDir(id: string): string {
    return join(this.#store, 'files', id)
  }

  #manifestFile(id: string): string {
    return join(this.#store, 'manifests', `${id}.json`)
  }

  /** 递归收集工作区内要纳入快照的文件（相对路径，posix 分隔） */
  async #walk(): Promise<{ files: string[]; dirs: string[] }> {
    const files: string[] = []
    const dirs: string[] = []

    const walk = async (dir: string): Promise<void> => {
      let items
      try {
        items = await readdir(dir, { withFileTypes: true })
      } catch {
        return
      }
      for (const item of items) {
        // 隐藏文件/目录与忽略目录不进快照，与文件树的展示范围保持一致
        if (item.name.startsWith('.')) continue
        if (item.isDirectory() && this.#skipDirs.has(item.name)) continue
        const abs = join(dir, item.name)
        if (item.isDirectory()) {
          dirs.push(abs)
          await walk(abs)
        } else if (item.isFile()) {
          files.push(toPosix(relative(this.#root, abs)))
        }
      }
    }

    await walk(this.#root)
    files.sort()
    return { files, dirs }
  }

  async create(
    label: string,
    reason: CheckpointReason = 'manual',
    opts: { skipPrune?: boolean } = {}
  ): Promise<CheckpointInfo> {
    const { files } = await this.#walk()
    if (files.length > this.#maxFiles) {
      throw new Error(`工作区文件数 ${files.length} 超过检查点上限 ${this.#maxFiles}，已跳过快照`)
    }

    const id = `cp_${Date.now().toString(36)}_${Math.random().toString(36).slice(2, 8)}`
    const entries: ManifestEntry[] = []
    const skipped: string[] = []
    let bytes = 0

    for (const rel of files) {
      const abs = join(this.#root, rel)
      const info = await stat(abs)
      if (info.size > this.#maxFileBytes) {
        skipped.push(rel)
        continue
      }
      bytes += info.size
      if (bytes > this.#maxTotalBytes) {
        throw new Error(`检查点总体积超过 ${this.#maxTotalBytes} 字节上限，已中止快照`)
      }
      const buf = await readFile(abs)
      const dest = join(this.#filesDir(id), rel)
      await mkdir(dirname(dest), { recursive: true })
      await copyFile(abs, dest)
      entries.push({ path: rel, sha256: sha256(buf), size: info.size })
    }

    const checkpoint: CheckpointInfo = {
      id,
      label: label || '未命名检查点',
      reason,
      createdAt: new Date().toISOString(),
      files: entries.length,
      bytes,
      skipped
    }
    const manifest: Manifest = { info: checkpoint, entries }
    await mkdir(join(this.#store, 'manifests'), { recursive: true })
    await writeFile(this.#manifestFile(id), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8')

    // 回滚流程里这个新快照是"回滚前备份"，此时绝不能 prune ——
    // 否则可能把正要回滚到的目标检查点删掉。由 rollback 在结尾统一 prune。
    if (!opts.skipPrune) await this.prune(this.#keep)
    return checkpoint
  }

  async #readManifest(id: string): Promise<Manifest> {
    if (!/^[A-Za-z0-9_-]+$/.test(id)) throw new Error(`非法检查点 id: ${id}`)
    const raw = await readFile(this.#manifestFile(id), 'utf8')
    return JSON.parse(raw) as Manifest
  }

  async list(): Promise<CheckpointInfo[]> {
    const dir = join(this.#store, 'manifests')
    let names: string[] = []
    try {
      names = await readdir(dir)
    } catch {
      return []
    }
    const out: CheckpointInfo[] = []
    for (const name of names) {
      if (!name.endsWith('.json')) continue
      try {
        const manifest = await this.#readManifest(name.slice(0, -5))
        out.push(manifest.info)
      } catch {
        // 损坏的清单跳过
      }
    }
    out.sort((a, b) => b.createdAt.localeCompare(a.createdAt))
    return out
  }

  /**
   * 回滚到指定检查点。
   *
   * 三步：
   *   1. 先给当前状态打一个 rollback-backup 快照 —— 回滚本身必须可逆；
   *   2. 快照中有、现在没有或内容不同的文件 → 用副本恢复/覆盖；
   *   3. 现在有、快照中没有的文件（检查点之后新增的）→ 删除；
   *      清理因此变空的目录。
   * 超过单文件上限被跳过的文件在两个方向上都不触碰。
   */
  async rollback(id: string): Promise<RollbackResult> {
    const target = await this.#readManifest(id)
    // 备份不能触发 prune（见 create 中的说明）
    const backup = await this.create(`回滚到「${target.info.label}」之前`, 'rollback-backup', {
      skipPrune: true
    })

    const wanted = new Map<string, ManifestEntry>()
    for (const e of target.entries) wanted.set(e.path, e)
    const untouched = new Set(target.info.skipped)

    const { files: currentFiles, dirs } = await this.#walk()
    let restored = 0
    let removed = 0

    // 恢复 / 覆盖
    for (const entry of target.entries) {
      const abs = join(this.#root, entry.path)
      let needRestore = true
      try {
        const buf = await readFile(abs)
        if (buf.length === entry.size && sha256(buf) === entry.sha256) needRestore = false
      } catch {
        needRestore = true // 文件不存在
      }
      if (needRestore) {
        await mkdir(dirname(abs), { recursive: true })
        await copyFile(join(this.#filesDir(id), entry.path), abs)
        restored++
      }
    }

    // 删除新增文件
    for (const rel of currentFiles) {
      if (wanted.has(rel) || untouched.has(rel)) continue
      await rm(join(this.#root, rel), { force: true })
      removed++
    }

    // 清理空目录（从深到浅，非空的 rmdir 会失败，忽略即可）
    const sortedDirs = dirs.sort((a, b) => b.length - a.length)
    for (const d of sortedDirs) {
      try {
        await rmdir(d)
      } catch {
        // 非空，保留
      }
    }

    // 回滚完成、目标安全之后，再统一裁剪历史
    await this.prune(this.#keep)
    return { restored, removed, backup }
  }

  /** 只保留最近 keep 个检查点，删除更旧的文件副本与清单 */
  async prune(keep: number): Promise<void> {
    const all = await this.list() // 已按时间倒序
    for (const old of all.slice(keep)) {
      await rm(this.#filesDir(old.id), { recursive: true, force: true })
      await rm(this.#manifestFile(old.id), { force: true })
    }
  }
}
EOF

w packages/harness-core/src/settings.ts <<'EOF'
import { mkdir, readFile, rename, writeFile } from 'node:fs/promises'
import { dirname, join } from 'node:path'
import type { AppSettings, PermissionMode } from '@witseek/protocol'

export const DEFAULT_PERMISSION_MODE: PermissionMode = 'confirm'

const VALID_MODES: readonly PermissionMode[] = ['read-only', 'confirm', 'auto']

function isValidMode(m: unknown): m is PermissionMode {
  return typeof m === 'string' && (VALID_MODES as readonly string[]).includes(m)
}

/**
 * 应用设置的 JSON 持久化（目前只有审批模式）。
 *
 * - 放在 userData 而不是工作区：设置是"这个用户/这台机器"的偏好，
 *   不应污染用户的项目目录，也不应被 git 跟踪。
 * - 写入走临时文件 + rename 的原子替换，避免写到一半崩溃留下半份 JSON。
 * - 文件不存在或损坏时回落到默认值，绝不因为设置问题让应用起不来。
 */
export class SettingsStore {
  readonly #file: string
  #cache: AppSettings | null = null

  constructor(file: string) {
    this.#file = file
  }

  get file(): string {
    return this.#file
  }

  async load(): Promise<AppSettings> {
    if (this.#cache) return this.#cache
    let settings: AppSettings = { permissionMode: DEFAULT_PERMISSION_MODE, updatedAt: '' }
    try {
      const raw = await readFile(this.#file, 'utf8')
      const parsed = JSON.parse(raw) as Partial<AppSettings>
      if (isValidMode(parsed.permissionMode)) {
        settings = { permissionMode: parsed.permissionMode, updatedAt: parsed.updatedAt ?? '' }
      }
    } catch {
      // 首次启动（文件不存在）或文件损坏：静默回落默认
    }
    this.#cache = settings
    return settings
  }

  async save(patch: Partial<AppSettings>): Promise<AppSettings> {
    const cur = await this.load()
    const next: AppSettings = { ...cur, ...patch, updatedAt: new Date().toISOString() }
    const dir = dirname(this.#file)
    await mkdir(dir, { recursive: true })
    const tmp = join(dir, `.settings-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 7)}.tmp`)
    await writeFile(tmp, `${JSON.stringify(next, null, 2)}\n`, 'utf8')
    await rename(tmp, this.#file)
    this.#cache = next
    return next
  }
}
EOF

w apps/desktop/src/main/terminal.ts <<'EOF'
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { createRequire } from 'node:module'
import type { TerminalData, TerminalExit } from '@witseek/protocol'

// 命名为 nodeRequire 而不是 require：electron-vite 的 ESM 主进程产物本身会注入
// 一个 require 垫片，再声明 `const require` 会触发 "Identifier 'require' has
// already been declared" 并让主进程在启动阶段直接崩溃。
const nodeRequire = createRequire(import.meta.url)

export type TerminalBackend = 'node-pty' | 'script' | 'none'

interface TerminalSink {
  data(payload: TerminalData): void
  exit(payload: TerminalExit): void
}

interface Session {
  id: string
  backend: TerminalBackend
  pty?: import('node-pty').IPty
  child?: ChildProcessWithoutNullStreams
}

/** 启动前探测可用后端（node-pty 是原生模块，装不上时回退 util-linux 的 script） */
export function detectBackend(): TerminalBackend {
  try {
    nodeRequire.resolve('node-pty')
    return 'node-pty'
  } catch {
    // Linux 上 `script -c` 会给命令分配一个伪终端，零编译依赖；
    // Windows/macOS 没有等价物，没有 node-pty 就没有终端
    return process.platform === 'linux' ? 'script' : 'none'
  }
}

let seq = 0

/**
 * 集成终端。
 *
 * - 主路径 node-pty：真正的伪终端，支持颜色、作业控制、resize、vim/top 这类全屏程序。
 * - 回退路径 `script -qec bash /dev/null`：node-pty 原生模块在当前环境不可用时，
 *   Linux 上仍能提供带 PTY 的交互 shell（resize 能力降级）。
 * - 工作目录锁定在工作区，符合"终端不游离到项目之外"的设计约束。
 */
export class TerminalManager {
  readonly #root: string
  readonly #sink: TerminalSink
  readonly backend: TerminalBackend
  readonly #sessions = new Map<string, Session>()

  constructor(workspaceRoot: string, sink: TerminalSink) {
    this.#root = workspaceRoot
    this.#sink = sink
    this.backend = detectBackend()
  }

  async create(cols = 80, rows = 24): Promise<{ id: string; backend: TerminalBackend }> {
    const id = `term_${Date.now().toString(36)}_${++seq}`
    if (this.backend === 'node-pty') {
      const ptyLib = nodeRequire('node-pty') as typeof import('node-pty')
      const isWin = process.platform === 'win32'
      const shell = isWin ? process.env.ComSpec ?? 'cmd.exe' : 'bash'
      const args = isWin ? [] : ['-l']
      const term = ptyLib.spawn(shell, args, {
        name: 'xterm-256color',
        cols,
        rows,
        cwd: this.#root,
        env: process.env as Record<string, string>
      })
      const session: Session = { id, backend: 'node-pty', pty: term }
      this.#sessions.set(id, session)
      term.onData((data) => this.#sink.data({ id, data }))
      term.onExit(({ exitCode }) => {
        this.#sessions.delete(id)
        this.#sink.exit({ id, code: exitCode })
      })
      return { id, backend: 'node-pty' }
    }

    if (this.backend === 'script') {
      // 初始行列通过 stty 设置；script 通道不支持后续 resize（能力降级）
      const cmd = `stty rows ${rows} cols ${cols}; exec bash -l`
      const child = spawn('script', ['-qec', cmd, '/dev/null'], {
        cwd: this.#root,
        env: process.env,
        stdio: ['pipe', 'pipe', 'pipe']
      }) as ChildProcessWithoutNullStreams
      const session: Session = { id, backend: 'script', child }
      this.#sessions.set(id, session)
      child.stdout.on('data', (buf: Buffer) => this.#sink.data({ id, data: buf.toString('utf8') }))
      child.stderr.on('data', (buf: Buffer) => this.#sink.data({ id, data: buf.toString('utf8') }))
      child.on('exit', (code) => {
        this.#sessions.delete(id)
        this.#sink.exit({ id, code })
      })
      return { id, backend: 'script' }
    }

    throw new Error('当前环境没有可用的终端后端（node-pty 缺失且非 Linux）')
  }

  write(id: string, data: string): void {
    const s = this.#sessions.get(id)
    if (!s) return
    if (s.pty) s.pty.write(data)
    else s.child?.stdin.write(data)
  }

  resize(id: string, cols: number, rows: number): void {
    const s = this.#sessions.get(id)
    if (!s) return
    try {
      s.pty?.resize(cols, rows)
    } catch {
      // 终端已退出时 resize 会抛错，忽略
    }
    // script 后端无法在运行中改 winsize，忽略（功能降级）
  }

  kill(id: string): void {
    const s = this.#sessions.get(id)
    if (!s) return
    try {
      s.pty?.kill()
    } catch {
      // 忽略
    }
    try {
      s.child?.kill()
    } catch {
      // 忽略
    }
    this.#sessions.delete(id)
  }

  dispose(): void {
    for (const id of [...this.#sessions.keys()]) this.kill(id)
  }
}
EOF

w apps/desktop/src/renderer/src/components/TerminalPane.tsx <<'EOF'
import { useCallback, useEffect, useRef, useState, type JSX } from 'react'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import { api } from '../api'

const PANEL_HEIGHT = 240

/**
 * 集成终端面板。
 *
 * - 终端进程由主进程拉起（node-pty；没有原生模块时回退到 util-linux 的 script），
 *   工作目录在主进程侧锁定为工作区，渲染层无法逃逸；
 * - 面板可折叠，折叠时 PTY 仍然存活（会话不丢），只是不再渲染；
 * - 进程退出后可以原地重启。
 */
export default function TerminalPane(): JSX.Element {
  const hostRef = useRef<HTMLDivElement | null>(null)
  const termRef = useRef<Terminal | null>(null)
  const fitRef = useRef<FitAddon | null>(null)
  const idRef = useRef<string | null>(null)
  const resizeObsRef = useRef<ResizeObserver | null>(null)

  const [open, setOpen] = useState(false)
  const [backend, setBackend] = useState<string>('…')
  const [exited, setExited] = useState<number | null>(null)
  const [failed, setFailed] = useState<string | null>(null)

  const fit = useCallback((): void => {
    const term = termRef.current
    const fitAddon = fitRef.current
    if (!term || !fitAddon || !hostRef.current) return
    try {
      fitAddon.fit()
      const id = idRef.current
      if (id) void api().terminal.resize(id, term.cols, term.rows)
    } catch {
      // 容器不可见（display:none / 0 尺寸）时 fit 会抛错，展开后会再 fit 一次
    }
  }, [])

  const start = useCallback(async (): Promise<void> => {
    if (!termRef.current) return
    setExited(null)
    setFailed(null)
    try {
      const created = await api().terminal.create(termRef.current.cols, termRef.current.rows)
      idRef.current = created.id
      setBackend(created.backend)
      fit()
    } catch (e) {
      setFailed((e as Error).message)
    }
  }, [fit])

  // 只挂载一次：建 xterm、订阅主进程推送
  useEffect(() => {
    const term = new Terminal({
      fontFamily: "'SF Mono', 'Cascadia Mono', Consolas, monospace",
      fontSize: 12,
      cursorBlink: true,
      scrollback: 5000,
      theme: { background: '#1e1f22', foreground: '#e6e6e6' }
    })
    const fitAddon = new FitAddon()
    term.loadAddon(fitAddon)
    term.open(hostRef.current as HTMLDivElement)
    termRef.current = term
    fitRef.current = fitAddon

    const dataSub = api().onTerminalData((d) => {
      if (d.id === idRef.current) term.write(d.data)
    })
    const exitSub = api().onTerminalExit((e) => {
      if (e.id !== idRef.current) return
      setExited(e.code ?? 0)
      term.write(`\r\n\x1b[90m[进程已退出，代码 ${e.code ?? '?'}；点击"重启"开一个新终端]\x1b[0m\r\n`)
    })

    const onData = term.onData((data) => {
      const id = idRef.current
      if (id && exited === null) void api().terminal.write(id, data)
    })

    const ro = new ResizeObserver(() => {
      // 折叠/展开、窗口尺寸变化都走这里
      fit()
    })
    if (hostRef.current) ro.observe(hostRef.current)
    resizeObsRef.current = ro

    void start()

    return () => {
      ro.disconnect()
      onData.dispose()
      dataSub()
      exitSub()
      const id = idRef.current
      if (id) void api().terminal.kill(id)
      idRef.current = null
      term.dispose()
      termRef.current = null
      fitRef.current = null
    }
    // StrictMode 下会挂载-卸载-再挂载：清理里已经 kill+dispose，第二次会重新拉起 PTY
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  // 展开时重新计算行列（折叠状态下容器 0 高，fit 不出正确尺寸）
  useEffect(() => {
    if (open) {
      // 等高度过渡/布局生效后再 fit
      const t = setTimeout(() => fit(), 30)
      return () => clearTimeout(t)
    }
  }, [open, fit])

  return (
    <div className={open ? 'terminal terminal-open' : 'terminal'} style={open ? { height: PANEL_HEIGHT } : undefined}>
      <div className="terminal-bar" onClick={() => setOpen((v) => !v)}>
        <span className="terminal-caret">{open ? '▾' : '▸'}</span>
        <span className="terminal-title">终端</span>
        <span className="terminal-backend" title="终端后端">
          {backend}
        </span>
        <span className="terminal-lock">工作目录已锁定为工作区</span>
        <span className="spacer" />
        {open && (
          <button
            className="btn-ghost btn-xs terminal-restart"
            onClick={(e) => {
              e.stopPropagation()
              void start()
            }}
          >
            重启
          </button>
        )}
      </div>
      <div className="terminal-body">
        <div ref={hostRef} className="terminal-host" />
        {failed && <div className="terminal-failed">终端启动失败：{failed}</div>}
      </div>
    </div>
  )
}
EOF

w packages/harness-core/test/diff-hunks.test.ts <<'EOF'
import { describe, expect, it } from 'vitest'
import { diffHunks, diffLines, rebuildText } from '../src/diff.js'

describe('diffHunks 分块', () => {
  it('两处相隔很远的改动被切成两个 hunk', () => {
    const oldText = Array.from({ length: 40 }, (_, i) => `line${i}`).join('\n')
    const newLines = Array.from({ length: 40 }, (_, i) => `line${i}`)
    newLines[2] = 'CHANGED_TOP'
    newLines[35] = 'CHANGED_BOTTOM'
    const newText = newLines.join('\n')

    const { hunks } = diffHunks(oldText, newText)
    expect(hunks.length).toBe(2)
    expect(hunks[0].id).not.toBe(hunks[1].id)
    // 每个 hunk 的行都带自己的 hunkId
    for (const l of hunks[0].lines) {
      if (l.kind !== 'plain') expect(l.hunkId).toBe(hunks[0].id)
    }
  })

  it('相邻改动（上下文重叠）合并为一个 hunk', () => {
    const oldText = ['a', 'b', 'c', 'd', 'e'].join('\n')
    const newText = ['a', 'B', 'C', 'd', 'e'].join('\n')
    const { hunks } = diffHunks(oldText, newText)
    expect(hunks.length).toBe(1)
  })

  it('没有变更时返回空 hunk 列表', () => {
    const text = 'a\nb\nc\n'
    const { hunks, lines } = diffHunks(text, text)
    expect(hunks).toHaveLength(0)
    expect(lines.every((l) => l.kind === 'plain')).toBe(true)
  })

  it('hunk 头行号符合 unified diff 语义', () => {
    const oldText = ['a', 'b', 'c', 'd', 'e'].join('\n')
    const newText = ['a', 'b', 'c2', 'c3', 'd', 'e'].join('\n')
    const { hunks } = diffHunks(oldText, newText, 1)
    expect(hunks.length).toBe(1)
    const h = hunks[0]
    // oldStart 从 1 开始；oldLines/newLines 为该块（含上下文）覆盖的行数
    expect(h.oldStart).toBeGreaterThanOrEqual(1)
    expect(h.newStart).toBeGreaterThanOrEqual(1)
    expect(h.newLines).toBeGreaterThan(h.oldLines)
  })
})

describe('rebuildText 逐块重建', () => {
  it('全部接受严格等于新文本（含尾换行）', () => {
    const oldText = 'one\ntwo\nthree\n'
    const newText = 'one\nTWO\nthree\nfour\n'
    const { lines, hunks } = diffHunks(oldText, newText)
    const rebuilt = rebuildText(lines, new Set(hunks.map((h) => h.id)), true)
    expect(rebuilt).toBe(newText)
  })

  it('全部拒绝严格等于旧文本', () => {
    const oldText = 'one\ntwo\nthree\n'
    const newText = 'one\nTWO\nthree\nfour\n'
    const { lines } = diffHunks(oldText, newText)
    const rebuilt = rebuildText(lines, new Set(), true)
    expect(rebuilt).toBe(oldText)
  })

  it("'all' 与全选集合结果一致", () => {
    const oldText = 'a\nb\nc\n'
    const newText = 'a\nB\nc\n'
    const { lines, hunks } = diffHunks(oldText, newText)
    expect(rebuildText(lines, 'all', true)).toBe(
      rebuildText(lines, new Set(hunks.map((h) => h.id)), true)
    )
  })

  it('只接受第二个 hunk 时，第一个改动被还原', () => {
    const oldText = Array.from({ length: 40 }, (_, i) => `line${i}`).join('\n')
    const newLines = Array.from({ length: 40 }, (_, i) => `line${i}`)
    newLines[2] = 'CHANGED_TOP'
    newLines[35] = 'CHANGED_BOTTOM'
    const newText = newLines.join('\n')

    const { lines, hunks } = diffHunks(oldText, newText)
    expect(hunks.length).toBe(2)
    // 只接受底部那块
    const rebuilt = rebuildText(lines, new Set([hunks[1].id]), false)
    expect(rebuilt).toContain('line2') // 顶部改动被还原
    expect(rebuilt).not.toContain('CHANGED_TOP')
    expect(rebuilt).toContain('CHANGED_BOTTOM') // 底部改动生效
  })

  it('纯新增文件：拒绝唯一 hunk 得到空文件', () => {
    const oldText = ''
    const newText = 'brand\nnew\nfile\n'
    const { lines, hunks } = diffHunks(oldText, newText)
    expect(hunks.length).toBe(1)
    expect(rebuildText(lines, new Set(), true)).toBe('')
    expect(rebuildText(lines, 'all', true)).toBe(newText)
  })

  it('无尾换行的文件重建后仍无尾换行', () => {
    const oldText = 'a\nb'
    const newText = 'a\nB'
    const { lines } = diffHunks(oldText, newText)
    const rebuilt = rebuildText(lines, 'all', false)
    expect(rebuilt).toBe(newText)
    expect(rebuilt.endsWith('\n')).toBe(false)
  })

  it('与底层 diffLines 的行数统计一致', () => {
    const oldText = 'x\ny\nz\n'
    const newText = 'x\nY\nz\n'
    const flat = diffLines(oldText, newText)
    const hunked = diffHunks(oldText, newText)
    expect(hunked.lines.length).toBe(flat.lines.length)
  })
})
EOF

w packages/harness-core/test/checkpoint.test.ts <<'EOF'
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import { CheckpointService } from '../src/checkpoint.js'

let ws: string
let store: string

beforeEach(async () => {
  ws = await mkdtemp(join(tmpdir(), 'witseek-ws-'))
  store = await mkdtemp(join(tmpdir(), 'witseek-cp-'))
})

async function makeService(keep = 10): Promise<CheckpointService> {
  return new CheckpointService({ workspaceRoot: ws, storeDir: store, keep })
}

async function put(rel: string, content: string): Promise<void> {
  const abs = join(ws, rel)
  await mkdir(join(abs, '..'), { recursive: true })
  await writeFile(abs, content, 'utf8')
}

async function read(rel: string): Promise<string> {
  return await readFile(join(ws, rel), 'utf8')
}

describe('CheckpointService 创建与列举', () => {
  it('创建后能在 list 中读到，文件数与字节数正确', async () => {
    await put('a.txt', 'hello')
    await put('dir/b.txt', 'world!!')
    const svc = await makeService()
    const cp = await svc.create('第一个')

    expect(cp.label).toBe('第一个')
    expect(cp.files).toBe(2)
    expect(cp.bytes).toBe(Buffer.byteLength('hello') + Buffer.byteLength('world!!'))
    const list = await svc.list()
    expect(list.map((c) => c.id)).toContain(cp.id)
    // list 按时间倒序
    expect(list[0].id).toBe(cp.id)
  })

  it('node_modules 等忽略目录与隐藏文件不进快照', async () => {
    await put('src/a.ts', 'a')
    await put('node_modules/pkg/index.js', 'junk')
    await put('.secret', 'hidden')
    const svc = await makeService()
    const cp = await svc.create('快照')
    expect(cp.files).toBe(1)
    expect(cp.skipped).toHaveLength(0)
  })
})

describe('CheckpointService 回滚', () => {
  it('修改被还原、检查点之后新增的文件被删除', async () => {
    await put('keep.txt', 'unchanged')
    await put('edit.txt', 'original')
    const svc = await makeService()
    const cp = await svc.create('基线')

    await put('edit.txt', 'modified')
    await put('added.txt', 'i am new')

    const result = await svc.rollback(cp.id)

    expect(await read('edit.txt')).toBe('original')
    expect(await read('keep.txt')).toBe('unchanged')
    await expect(readFile(join(ws, 'added.txt'), 'utf8')).rejects.toThrow()
    // keep.txt 内容未变，不应计入 restored
    expect(result.restored).toBe(1)
    expect(result.removed).toBe(1)
  })

  it('回滚前自动打 rollback-backup，使回滚本身可逆', async () => {
    await put('f.txt', 'v1')
    const svc = await makeService()
    const cp = await svc.create('v1')
    await put('f.txt', 'v2')

    await svc.rollback(cp.id)
    expect(await read('f.txt')).toBe('v1')

    const list = await svc.list()
    const backup = list.find((c) => c.reason === 'rollback-backup')
    expect(backup).toBeDefined()

    // 用备份再滚回去，应恢复 v2
    await svc.rollback(backup!.id)
    expect(await read('f.txt')).toBe('v2')
  })

  it('超过单文件上限的文件被跳过，回滚时不触碰', async () => {
    await put('big.bin', 'x'.repeat(100))
    await put('small.txt', 'hi')
    const svc = new CheckpointService({
      workspaceRoot: ws,
      storeDir: store,
      maxFileBytes: 10
    })
    const cp = await svc.create('带大文件')
    expect(cp.files).toBe(1)
    expect(cp.skipped).toContain('big.bin')

    // 大文件在检查点之后被改动，回滚不得动它（它从一开始就没被纳入）
    await put('big.bin', 'changed-after')
    await svc.rollback(cp.id)
    expect(await read('big.bin')).toBe('changed-after')
  })

  it('删除的文件能被找回', async () => {
    await put('will-delete.txt', 'comeback')
    const svc = await makeService()
    const cp = await svc.create('基线')
    await rm(join(ws, 'will-delete.txt'))

    const result = await svc.rollback(cp.id)
    expect(await read('will-delete.txt')).toBe('comeback')
    expect(result.restored).toBe(1)
  })
})

describe('CheckpointService 保留策略', () => {
  it('只保留最近 keep 个检查点', async () => {
    const svc = await makeService(2)
    await put('a.txt', 'a')
    const first = await svc.create('first')
    await new Promise((r) => setTimeout(r, 5))
    await svc.create('second')
    await new Promise((r) => setTimeout(r, 5))
    await svc.create('third')

    const list = await svc.list()
    expect(list.map((c) => c.label)).toEqual(['third', 'second'])
    expect(list.find((c) => c.id === first.id)).toBeUndefined()
  })
})
EOF

w packages/harness-core/test/settings.test.ts <<'EOF'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import { DEFAULT_PERMISSION_MODE, SettingsStore } from '../src/settings.js'

let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'witseek-settings-'))
})

describe('SettingsStore 审批模式持久化', () => {
  it('文件不存在时回落默认模式 confirm', async () => {
    const store = new SettingsStore(join(dir, 'settings.json'))
    const s = await store.load()
    expect(s.permissionMode).toBe(DEFAULT_PERMISSION_MODE)
    expect(s.permissionMode).toBe('confirm')
  })

  it('保存后新实例能读回（落盘持久化）', async () => {
    const file = join(dir, 'settings.json')
    await new SettingsStore(file).save({ permissionMode: 'auto' })

    const reopened = new SettingsStore(file)
    expect((await reopened.load()).permissionMode).toBe('auto')
  })

  it('三种模式都能往返', async () => {
    const file = join(dir, 'settings.json')
    for (const mode of ['read-only', 'confirm', 'auto'] as const) {
      await new SettingsStore(file).save({ permissionMode: mode })
      expect((await new SettingsStore(file).load()).permissionMode).toBe(mode)
    }
  })

  it('文件损坏时静默回落默认，不抛错', async () => {
    const file = join(dir, 'settings.json')
    await writeFile(file, '{ this is not valid json', 'utf8')
    const s = await new SettingsStore(file).load()
    expect(s.permissionMode).toBe('confirm')
  })

  it('非法模式值被忽略，回落默认', async () => {
    const file = join(dir, 'settings.json')
    await writeFile(file, JSON.stringify({ permissionMode: 'sudo-rm-rf' }), 'utf8')
    expect((await new SettingsStore(file).load()).permissionMode).toBe('confirm')
  })

  it('落盘内容是合法 JSON 且包含模式与时间戳', async () => {
    const file = join(dir, 'settings.json')
    const saved = await new SettingsStore(file).save({ permissionMode: 'read-only' })
    expect(saved.updatedAt).not.toBe('')
    const raw = JSON.parse(await readFile(file, 'utf8')) as { permissionMode: string }
    expect(raw.permissionMode).toBe('read-only')
  })
})
EOF

w tests/unit/host-p4.test.ts <<'EOF'
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import { MockProvider, textTurn, toolTurn } from '@witseek/provider-deepseek'
import type { AgentEvent, AgentStatus, ApprovalPrompt } from '@witseek/protocol'
import { CheckpointService, SettingsStore } from '@witseek/harness-core'
import { AgentHost, type HostSink } from '../../apps/desktop/src/main/host.js'

class Recorder implements HostSink {
  events: AgentEvent[] = []
  approvals: ApprovalPrompt[] = []
  statuses: AgentStatus[] = []
  event(e: AgentEvent): void {
    this.events.push(e)
  }
  approval(p: ApprovalPrompt): void {
    this.approvals.push(p)
  }
  status(s: AgentStatus): void {
    this.statuses.push(s)
  }
}

async function waitFor(cond: () => boolean, timeoutMs = 3000): Promise<void> {
  const started = Date.now()
  while (!cond()) {
    if (Date.now() - started > timeoutMs) throw new Error('等待超时')
    await new Promise((r) => setTimeout(r, 10))
  }
}

let ws: string
let sessions: string
let cpStore: string
let settingsFile: string

beforeEach(async () => {
  ws = await mkdtemp(join(tmpdir(), 'witseek-p4-ws-'))
  sessions = await mkdtemp(join(tmpdir(), 'witseek-p4-sess-'))
  cpStore = await mkdtemp(join(tmpdir(), 'witseek-p4-cp-'))
  settingsFile = join(await mkdtemp(join(tmpdir(), 'witseek-p4-cfg-')), 'settings.json')
})

function makeHost(provider: MockProvider, autoApprove = false): AgentHost {
  return new AgentHost({
    workspaceRoot: ws,
    provider,
    model: 'mock-model',
    sessionsDir: sessions,
    sink: new Recorder(),
    autoApprove,
    settingsStore: new SettingsStore(settingsFile),
    checkpoints: new CheckpointService({ workspaceRoot: ws, storeDir: cpStore })
  })
}

/** 与上面的 makeHost 共用同一个 sink，便于断言 */
function makeHostRecorded(provider: MockProvider, sink: Recorder, autoApprove = false): AgentHost {
  return new AgentHost({
    workspaceRoot: ws,
    provider,
    model: 'mock-model',
    sessionsDir: sessions,
    sink,
    autoApprove,
    settingsStore: new SettingsStore(settingsFile),
    checkpoints: new CheckpointService({ workspaceRoot: ws, storeDir: cpStore })
  })
}

describe('P4 审批模式持久化', () => {
  it('setPermissionMode 落盘，新宿主 init() 能恢复', async () => {
    const host = makeHost(new MockProvider(() => textTurn('ok')))
    expect(host.permissionMode).toBe('confirm')

    await host.setPermissionMode('auto')

    const raw = JSON.parse(await readFile(settingsFile, 'utf8')) as { permissionMode: string }
    expect(raw.permissionMode).toBe('auto')

    const host2 = makeHost(new MockProvider(() => textTurn('ok')))
    await host2.init()
    expect(host2.permissionMode).toBe('auto')
  })
})

describe('P4 每轮检查点', () => {
  it('send 开头自动打检查点并推送 checkpoint 事件', async () => {
    const sink = new Recorder()
    const host = makeHostRecorded(new MockProvider(() => textTurn('好')), sink, true)
    await writeFile(join(ws, 'a.txt'), 'seed', 'utf8')

    await host.send('你好')

    const cpEvents = sink.events.filter((e) => e.type === 'checkpoint')
    expect(cpEvents.length).toBeGreaterThanOrEqual(1)
    if (cpEvents[0].type !== 'checkpoint') throw new Error('unreachable')
    expect(cpEvents[0].checkpoint.reason).toBe('auto')
    expect(cpEvents[0].checkpoint.files).toBe(1)

    const list = await host.listCheckpoints()
    expect(list.length).toBeGreaterThanOrEqual(1)
  })

  it('回滚到自动检查点可撤销对话之外的文件改动', async () => {
    const host = makeHost(new MockProvider(() => textTurn('好')), true)
    await writeFile(join(ws, 'a.txt'), 'v1', 'utf8')
    await host.send('打个基线')

    await writeFile(join(ws, 'a.txt'), 'v2', 'utf8')
    const cps = await host.listCheckpoints()
    const result = await host.rollbackCheckpoint(cps[0].id)

    expect(await readFile(join(ws, 'a.txt'), 'utf8')).toBe('v1')
    expect(result.backup.reason).toBe('rollback-backup')
  })
})

describe('P4 diff 逐块接受/拒绝', () => {
  it('edit_file 只接受第一个 hunk，第二处改动不写入', async () => {
    const lines = Array.from({ length: 40 }, (_, i) => `L${i}`)
    const original = lines.join('\n') + '\n'
    await writeFile(join(ws, 'big.txt'), original, 'utf8')

    const changed = [...lines]
    changed[2] = 'TOP_CHANGE'
    changed[35] = 'BOTTOM_CHANGE'
    const updated = changed.join('\n') + '\n'

    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'edit_file', args: { path: 'big.txt', oldText: original, newText: updated } }])
        : textTurn('改完')
    )
    const host = makeHostRecorded(provider, sink, false)

    const running = host.send('改两处')
    await waitFor(() => sink.approvals.length > 0)
    const prompt = sink.approvals[0]
    expect(prompt.diff?.hunks.length).toBe(2)

    // 只批准第一个 hunk
    const accepted = host.resolveApproval(prompt.id, 'approve', [prompt.diff!.hunks[0].id])
    expect(accepted).toBe(true)
    await running

    const finalText = await readFile(join(ws, 'big.txt'), 'utf8')
    expect(finalText).toContain('TOP_CHANGE')
    expect(finalText).not.toContain('BOTTOM_CHANGE')
    expect(finalText).toContain('L35')

    const approvalEvent = sink.events.find((e) => e.type === 'approval')
    if (approvalEvent?.type !== 'approval') throw new Error('缺少 approval 事件')
    expect(approvalEvent.acceptedHunkIds).toEqual([prompt.diff!.hunks[0].id])
  })

  it('一个 hunk 都不接受（approve + 空集合）等价整体拒绝，文件不变', async () => {
    await writeFile(join(ws, 'c.txt'), 'one\ntwo\nthree\n', 'utf8')
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'edit_file', args: { path: 'c.txt', oldText: 'two', newText: 'TWO' } }])
        : textTurn('好')
    )
    const host = makeHostRecorded(provider, sink, false)

    const running = host.send('改')
    await waitFor(() => sink.approvals.length > 0)
    host.resolveApproval(sink.approvals[0].id, 'approve', [])
    await running

    expect(await readFile(join(ws, 'c.txt'), 'utf8')).toBe('one\ntwo\nthree\n')
    const toolEnd = sink.events.find((e) => e.type === 'tool-end')
    if (toolEnd?.type !== 'tool-end') throw new Error('缺少 tool-end')
    expect(toolEnd.result.ok).toBe(false)
  })

  it('write_file 新建文件时逐块拒绝后文件不创建', async () => {
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'write_file', args: { path: 'new.txt', content: 'a\nb\nc\n' } }])
        : textTurn('好')
    )
    const host = makeHostRecorded(provider, sink, false)

    const running = host.send('新建')
    await waitFor(() => sink.approvals.length > 0)
    const prompt = sink.approvals[0]
    expect(prompt.diff).toBeDefined()
    host.resolveApproval(prompt.id, 'deny')
    await running

    await expect(readFile(join(ws, 'new.txt'), 'utf8')).rejects.toThrow()
  })

  it('整体批准（不传 hunk 集合）行为与 P3 一致，写入完整结果', async () => {
    await writeFile(join(ws, 'd.txt'), 'one\ntwo\n', 'utf8')
    const sink = new Recorder()
    const provider = new MockProvider((_req, turn) =>
      turn === 0
        ? toolTurn([{ name: 'edit_file', args: { path: 'd.txt', oldText: 'two', newText: 'TWO' } }])
        : textTurn('好')
    )
    const host = makeHostRecorded(provider, sink, false)

    const running = host.send('改')
    await waitFor(() => sink.approvals.length > 0)
    host.resolveApproval(sink.approvals[0].id, 'approve')
    await running

    expect(await readFile(join(ws, 'd.txt'), 'utf8')).toBe('one\nTWO\n')
  })
})
EOF
