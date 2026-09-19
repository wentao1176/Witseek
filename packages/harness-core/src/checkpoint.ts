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
