/**
 * 右侧文件预览栏的后端能力：在主进程内、经 IPC 对 dsh 工作区做只读浏览/预览。
 *
 * 安全约束：
 *  - 渲染层 sandbox + contextIsolation，只能通过 preload 暴露的白名单方法调用；
 *  - 文件树/读取一律限定在工作区根目录内，rel 中的 ".." 与绝对路径会被拒绝（越权防护）；
 *  - 唯一的例外是“打开文件…”系统选择框：由用户显式选择的文件才允许读取；
 *  - 文本设大小上限，图片转 data URL，其余二进制仅返回元信息并引导系统打开。
 */
import { app, BrowserWindow, dialog, ipcMain, shell, type WebContents } from 'electron'
import { execFileSync, spawn } from 'node:child_process'
import { closeSync, openSync, readSync, readdirSync, realpathSync, statSync } from 'node:fs'
import path from 'node:path'
import type { DataLayout } from './paths'
import { pathsOverlap, resolveForPathSafety } from './path-safety'

export interface DirEntry {
  name: string
  rel: string
  dir: boolean
  size: number
  mtime: number
}

export type PreviewKind = 'text' | 'image' | 'markdown' | 'pdf' | 'binary'

export interface PreviewResult {
  kind: PreviewKind
  name: string
  abs: string
  rel: string
  size: number
  mtime: number
  /** text / markdown 的文本内容（可能被截断） */
  text?: string
  truncated?: boolean
  /** 代码高亮语言（highlight.js 名），markdown 为 'markdown' */
  language?: string
  /** 图片 data URL */
  dataUrl?: string
  mime?: string
  /** 不可内嵌预览时的说明 */
  note?: string
}

const MAX_TEXT_BYTES = 2 * 1024 * 1024
const MAX_IMAGE_BYTES = 8 * 1024 * 1024
const MAX_GIT_STATUS_BYTES = 8 * 1024 * 1024
const MAX_GIT_DIFF_CHARS = 512 * 1024
const MAX_GIT_DIFF_BYTES = MAX_GIT_DIFF_CHARS * 3 + 1
const MAX_GIT_CHANGES = 2000

const IMAGE_EXT: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.bmp': 'image/bmp',
  '.ico': 'image/x-icon',
  '.avif': 'image/avif'
}

// 扩展名 -> highlight.js 语言名
const CODE_LANG: Record<string, string> = {
  '.js': 'javascript',
  '.mjs': 'javascript',
  '.cjs': 'javascript',
  '.jsx': 'javascript',
  '.ts': 'typescript',
  '.tsx': 'typescript',
  '.json': 'json',
  '.jsonc': 'json',
  '.py': 'python',
  '.rs': 'rust',
  '.c': 'c',
  '.h': 'c',
  '.cpp': 'cpp',
  '.cc': 'cpp',
  '.cxx': 'cpp',
  '.hpp': 'cpp',
  '.hh': 'cpp',
  '.java': 'java',
  '.go': 'go',
  '.cs': 'csharp',
  '.rb': 'ruby',
  '.php': 'php',
  '.swift': 'swift',
  '.kt': 'kotlin',
  '.sh': 'bash',
  '.bash': 'bash',
  '.zsh': 'bash',
  '.bat': 'dos',
  '.cmd': 'dos',
  '.ps1': 'powershell',
  '.html': 'xml',
  '.htm': 'xml',
  '.xml': 'xml',
  '.vue': 'xml',
  '.css': 'css',
  '.scss': 'scss',
  '.less': 'less',
  '.yaml': 'yaml',
  '.yml': 'yaml',
  '.toml': 'ini',
  '.ini': 'ini',
  '.conf': 'ini',
  '.cfg': 'ini',
  '.sql': 'sql',
  '.proto': 'protobuf',
  '.gradle': 'groovy',
  '.lua': 'lua',
  '.dart': 'dart',
  '.md': 'markdown',
  '.markdown': 'markdown',
  '.txt': 'plaintext',
  '.text': 'plaintext',
  '.log': 'plaintext',
  '.csv': 'plaintext',
  '.tsv': 'plaintext',
  '.env': 'plaintext',
  '.gitignore': 'plaintext',
  '.dockerfile': 'dockerfile',
  '.makefile': 'makefile',
  '.license': 'plaintext',
  '.licence': 'plaintext',
  '.notice': 'plaintext'
}

const TEXT_BASENAMES: Record<string, string> = {
  dockerfile: 'dockerfile',
  makefile: 'makefile',
  license: 'plaintext',
  licence: 'plaintext',
  readme: 'markdown',
  '.gitignore': 'plaintext',
  '.npmrc': 'ini',
  '.editorconfig': 'ini'
}

function isWithin(root: string, abs: string): boolean {
  const normalizedRoot = path.resolve(root)
  const target = path.resolve(abs)
  const relative = path.relative(normalizedRoot, target)
  return relative === '' || (relative !== '..' && !relative.startsWith(`..${path.sep}`) && !path.isAbsolute(relative))
}

/** 把渲染层传来的相对路径解析到工作区内，不允许绝对路径或父目录段。 */
function resolveWorkspacePath(root: string, rel: string): string {
  const raw = String(rel || '')
  if (path.isAbsolute(raw) || /^[A-Za-z]:[\\/]/.test(raw) || /^[/\\]{2}/.test(raw)) {
    throw new Error('路径越权：只能访问工作区目录内的文件')
  }
  const parts = raw.split(/[\\/]/).filter(p => p.length > 0 && p !== '.')
  if (parts.includes('..')) throw new Error('路径越权：只能访问工作区目录内的文件')
  const abs = path.resolve(root, ...parts)
  if (!isWithin(root, abs)) {
    throw new Error('路径越权：只能访问工作区目录内的文件')
  }
  return abs
}

function resolveInside(root: string, rel: string): string {
  const abs = resolveWorkspacePath(root, rel)
  const target = realpathSync(abs)
  if (!isWithin(root, target)) throw new Error('路径越权：链接目标位于工作区之外')
  return target
}

function toRel(root: string, abs: string): string {
  return path.relative(root, abs).split(path.sep).join('/')
}

function normalizeWorkspaceRel(rel: string): string {
  return String(rel || '').split(/[\\/]+/).filter(part => part && part !== '.').join('/')
}

function readPrefix(abs: string, maxBytes: number): { buffer: Buffer; truncated: boolean } {
  const buffer = Buffer.alloc(maxBytes + 1)
  const fd = openSync(abs, 'r')
  let bytesRead = 0
  try {
    while (bytesRead < buffer.length) {
      const count = readSync(fd, buffer, bytesRead, buffer.length - bytesRead, bytesRead)
      if (count === 0) break
      bytesRead += count
    }
  } finally {
    closeSync(fd)
  }
  return {
    buffer: buffer.subarray(0, Math.min(bytesRead, maxBytes)),
    truncated: bytesRead > maxBytes
  }
}

function languageFor(fileName: string): string | undefined {
  const lower = fileName.toLowerCase()
  const ext = path.extname(lower)
  if (ext && CODE_LANG[ext]) return CODE_LANG[ext]
  const base = path.basename(lower)
  return TEXT_BASENAMES[base]
}

function classify(fileName: string): PreviewKind {
  const ext = path.extname(fileName.toLowerCase())
  if (ext === '.md' || ext === '.markdown') return 'markdown'
  if (ext === '.pdf') return 'pdf'
  if (ext in IMAGE_EXT) return 'image'
  if (languageFor(fileName)) return 'text'
  return 'binary'
}

function readAny(abs: string, rel: string, displayName = path.basename(abs)): PreviewResult {
  const st = statSync(abs)
  const name = displayName
  const base = {
    name,
    abs,
    rel,
    size: st.size,
    mtime: st.mtimeMs
  }
  const kind = classify(name)

  if (kind === 'image') {
    const ext = path.extname(name).toLowerCase()
    const mime = IMAGE_EXT[ext] || 'application/octet-stream'
    if (st.size > MAX_IMAGE_BYTES) {
      return {
        ...base,
        kind,
        mime,
        note: '图片超过 8 MiB，为避免占用过多内存，请在系统中打开。'
      }
    }
    const { buffer, truncated } = readPrefix(abs, MAX_IMAGE_BYTES)
    if (truncated) {
      return {
        ...base,
        kind,
        mime,
        note: '图片超过 8 MiB，为避免占用过多内存，请在系统中打开。'
      }
    }
    return {
      ...base,
      kind,
      mime,
      dataUrl: `data:${mime};base64,${buffer.toString('base64')}`
    }
  }

  if (kind === 'pdf') {
    return {
      ...base,
      kind,
      note: 'PDF 请在系统默认查看器中打开。'
    }
  }

  if (kind === 'binary') {
    return {
      ...base,
      kind,
      note: '二进制文件，不提供内嵌预览，可在系统中打开。'
    }
  }

  const language = languageFor(name) ?? 'plaintext'
  const { buffer, truncated } = readPrefix(abs, MAX_TEXT_BYTES)
  const text = buffer.toString('utf8')
  return {
    ...base,
    kind,
    text,
    truncated,
    language: kind === 'markdown' ? 'markdown' : language
  }
}

interface RootInfo {
  root: string
  rel: string
  sep: string
  platform: string
  name: string
}

interface GitChange {
  path: string
  status: string
  staged: boolean
  unstaged: boolean
  untracked: boolean
  oldPath?: string
}

interface GitStatus {
  available: boolean
  root: string
  branch: string
  changes: GitChange[]
  truncated: boolean
  reason?: string
}

interface GitDiff {
  path: string
  staged: string
  unstaged: string
  untracked: boolean
  truncated: boolean
  note?: string
}

function gitOutput(cwd: string, args: string[]): string {
  return execFileSync('git', args, {
    cwd,
    encoding: 'utf8',
    maxBuffer: MAX_GIT_STATUS_BYTES,
    windowsHide: true
  })
}

function boundDiff(value: string): { text: string; truncated: boolean } {
  if (value.length <= MAX_GIT_DIFF_CHARS) return { text: value, truncated: false }
  return { text: value.slice(0, MAX_GIT_DIFF_CHARS), truncated: true }
}

function boundedGitDiff(cwd: string, args: string[]): Promise<{ text: string; truncated: boolean }> {
  return new Promise((resolve, reject) => {
    const child = spawn('git', args, { cwd, windowsHide: true })
    const chunks: Buffer[] = []
    let captured = 0
    let truncated = false
    let stderr = ''

    child.stdout?.on('data', (chunk: Buffer) => {
      const remaining = MAX_GIT_DIFF_BYTES - captured
      if (remaining <= 0) {
        truncated = true
        child.kill()
        return
      }
      const accepted = chunk.subarray(0, remaining)
      chunks.push(accepted)
      captured += accepted.length
      if (accepted.length < chunk.length) {
        truncated = true
        child.kill()
      }
    })
    child.stderr?.on('data', (chunk: Buffer) => {
      if (stderr.length < 8192) stderr += chunk.toString().slice(0, 8192 - stderr.length)
    })
    child.once('error', reject)
    child.once('close', (code, signal) => {
      const text = Buffer.concat(chunks).toString('utf8')
      if (truncated) {
        resolve({ text, truncated: true })
      } else if (code === 0) {
        resolve({ text, truncated: false })
      } else {
        reject(new Error(stderr || `git diff exited with code ${code ?? signal ?? 'unknown'}`))
      }
    })
  })
}

function repoPathToWorkspacePath(workspace: string, repoRoot: string, relative: string): string | undefined {
  const abs = path.resolve(repoRoot, ...relative.split(/[\\/]/))
  if (!isWithin(workspace, abs)) return undefined
  return toRel(workspace, abs)
}

function readGitStatus(workspace: string): GitStatus {
  try {
    const repoRoot = gitOutput(workspace, ['rev-parse', '--show-toplevel']).trim()
    const branch = gitOutput(repoRoot, ['branch', '--show-current']).trim() || 'HEAD (detached)'
    const raw = gitOutput(repoRoot, ['status', '--porcelain=v1', '-z', '--untracked-files=all'])
    const records = raw.split('\0')
    const changes: GitChange[] = []
    let truncated = false
    for (let index = 0; index < records.length; index += 1) {
      const record = records[index]
      if (!record || record.length < 4) continue
      const status = record.slice(0, 2)
      const repoPath = record.slice(3)
      const relative = repoPathToWorkspacePath(workspace, repoRoot, repoPath)
      let oldPath: string | undefined
      if (status.includes('R') || status.includes('C')) {
        const oldRepoPath = records[index + 1]
        index += 1
        if (oldRepoPath) oldPath = repoPathToWorkspacePath(workspace, repoRoot, oldRepoPath)
      }
      if (relative === undefined) continue
      if (changes.length >= MAX_GIT_CHANGES) {
        truncated = true
        break
      }
      changes.push({
        path: relative,
        status,
        staged: status[0] !== ' ' && status[0] !== '?',
        unstaged: status[1] !== ' ',
        untracked: status === '??',
        ...(oldPath === undefined ? {} : { oldPath })
      })
    }
    return { available: true, root: workspace, branch, changes, truncated }
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error)
    const reason = /ENOENT|not recognized|找不到指定/i.test(message)
      ? '未检测到 Git。安装 Git for Windows 并重启 Witseek 后可查看改动。'
      : '当前工作区不是可用的 Git 仓库。'
    return { available: false, root: workspace, branch: '', changes: [], truncated: false, reason }
  }
}

async function readGitDiff(workspace: string, rel: string): Promise<GitDiff> {
  const abs = resolveWorkspacePath(workspace, rel)
  const repoRoot = gitOutput(workspace, ['rev-parse', '--show-toplevel']).trim()
  if (!isWithin(repoRoot, abs)) throw new Error('文件不属于当前 Git 仓库')
  const repoRel = toRel(repoRoot, abs)
  const [stagedOutput, unstagedOutput] = await Promise.all([
    boundedGitDiff(repoRoot, ['diff', '--cached', '--no-ext-diff', '--unified=3', '--', repoRel]),
    boundedGitDiff(repoRoot, ['diff', '--no-ext-diff', '--unified=3', '--', repoRel])
  ])
  const stagedRaw = stagedOutput.text
  const unstagedRaw = unstagedOutput.text
  const statusRaw = gitOutput(repoRoot, ['status', '--porcelain=v1', '-z', '--untracked-files=all', '--', repoRel])
  const untracked = statusRaw.split('\0').some(record => record.startsWith('?? ') && record.slice(3) === repoRel)
  let staged = stagedRaw
  let unstaged = unstagedRaw
  let truncated = stagedOutput.truncated || unstagedOutput.truncated
  let note: string | undefined
  if (untracked) {
    try {
      const preview = readAny(resolveInside(workspace, rel), rel)
      if (preview.kind === 'text' || preview.kind === 'markdown') {
        const lines = (preview.text ?? '').replace(/\r\n/g, '\n').split('\n')
        const header = `diff --git a/${repoRel} b/${repoRel}\nnew file mode 100644\n--- /dev/null\n+++ b/${repoRel}\n@@ -0,0 +1,${lines.length} @@\n`
        unstaged = `${header}${lines.map(line => `+${line}`).join('\n')}`
        truncated = Boolean(preview.truncated)
      } else {
        note = '未跟踪文件为二进制格式，无法生成文本 diff。'
      }
    } catch (error) {
      note = error instanceof Error ? error.message : String(error)
    }
  }
  const boundedStaged = boundDiff(staged)
  const boundedUnstaged = boundDiff(unstaged)
  staged = boundedStaged.text
  unstaged = boundedUnstaged.text
  truncated ||= boundedStaged.truncated || boundedUnstaged.truncated
  return { path: rel, staged, unstaged, untracked, truncated, ...(note === undefined ? {} : { note }) }
}

export function registerPreviewIpc(
  win: BrowserWindow,
  data: DataLayout,
  dshContents: WebContents,
  onWorkspaceChange: (info: RootInfo) => void,
  protectedPaths: string[] = []
): void {
  const fallbackRoot = realpathSync(data.workspace)
  const protectedRoots = [
    ...(app.isPackaged ? [resolveForPathSafety(path.dirname(process.execPath))] : []),
    ...protectedPaths.map(resolveForPathSafety)
  ]
  function assertWorkspaceIsSafe(candidate: string): void {
    if (protectedRoots.some(protectedRoot => pathsOverlap(protectedRoot, candidate))) {
      throw new Error('工作区不能与 Witseek 安装目录或更新缓存重叠')
    }
  }
  assertWorkspaceIsSafe(fallbackRoot)
  let root = fallbackRoot
  // 用户通过“打开文件…”系统选择框显式选中的工作区外文件，会话内允许系统打开/定位
  const granted = new Set<string>()

  function rootInfo(): RootInfo {
    return { root, rel: '', sep: '/', platform: process.platform, name: path.basename(root) }
  }

  function setWorkspace(candidate: unknown): RootInfo {
    if (candidate !== null && (typeof candidate !== 'string' || !path.isAbsolute(candidate))) {
      throw new Error('工作区路径必须是绝对路径')
    }
    const target = candidate === null ? fallbackRoot : realpathSync(path.resolve(candidate))
    if (!statSync(target).isDirectory()) throw new Error('工作区路径不是文件夹')
    assertWorkspaceIsSafe(target)
    const samePath = process.platform === 'win32'
      ? target.toLocaleLowerCase() === root.toLocaleLowerCase()
      : target === root
    if (!samePath) {
      root = target
      granted.clear()
      onWorkspaceChange(rootInfo())
    }
    return rootInfo()
  }

  function canTouch(abs: string): boolean {
    const target = path.resolve(abs)
    if (granted.has(target)) return true
    try {
      return isWithin(root, realpathSync(target))
    } catch {
      return false
    }
  }

  ipcMain.handle('desktop:set-workspace', (event, candidate: unknown) => {
    if (event.sender !== dshContents) throw new Error('工作区只能由 dsh 主视图更新')
    return setWorkspace(candidate)
  })

  ipcMain.handle('desktop:validate-workspace', (event, candidate: unknown) => {
    if (event.sender !== dshContents) throw new Error('工作区只能由 dsh 主视图验证')
    if (typeof candidate !== 'string' || !path.isAbsolute(candidate)) {
      throw new Error('工作区路径必须是绝对路径')
    }
    const target = realpathSync(path.resolve(candidate))
    if (!statSync(target).isDirectory()) throw new Error('工作区路径不是文件夹')
    assertWorkspaceIsSafe(target)
    return true
  })

  ipcMain.handle('preview:root', () => rootInfo())

  ipcMain.handle('preview:list', (_event, rel = '') => {
    const abs = resolveInside(root, rel)
    const logicalRel = normalizeWorkspaceRel(rel)
    const dirents = readdirSync(abs, { withFileTypes: true })
    const entries: DirEntry[] = []
    for (const d of dirents) {
      const childAbs = path.join(abs, d.name)
      let size = 0
      let mtime = 0
      let dir = false
      try {
        const st = statSync(childAbs)
        size = st.size
        mtime = st.mtimeMs
        if (st.isDirectory()) {
          dir = isWithin(root, realpathSync(childAbs))
        }
      } catch {
        /* 无权限等情况忽略单项 */
      }
      entries.push({
        name: d.name,
        rel: path.posix.join(logicalRel, d.name),
        dir,
        size,
        mtime
      })
    }
    entries.sort((a, b) => {
      if (a.dir !== b.dir) return a.dir ? -1 : 1
      const hidden = (n: string): number => (n.startsWith('.') ? 1 : 0)
      if (hidden(a.name) !== hidden(b.name)) return hidden(a.name) - hidden(b.name)
      return a.name.localeCompare(b.name)
    })
    return { root, rel: logicalRel, entries }
  })

  ipcMain.handle('preview:read', (_event, rel: string) => {
    const abs = resolveInside(root, rel)
    const logicalRel = normalizeWorkspaceRel(rel)
    return readAny(abs, logicalRel, path.basename(logicalRel))
  })

  ipcMain.handle('preview:pick', async () => {
    const result = await dialog.showOpenDialog(win, {
      title: '选择要预览的文件',
      properties: ['openFile']
    })
    if (result.canceled || result.filePaths.length === 0) return null
    const abs = result.filePaths[0]
    granted.add(path.resolve(abs))
    return readAny(abs, isWithin(root, abs) ? toRel(root, abs) : path.basename(abs))
  })

  ipcMain.handle('preview:reveal', (_event, rel: string) => {
    const abs = resolveInside(root, rel)
    shell.showItemInFolder(abs)
    return true
  })

  ipcMain.handle('preview:open', (_event, rel: string) => {
    const abs = resolveInside(root, rel)
    return shell.openPath(abs)
  })

  ipcMain.handle('preview:open-abs', (_event, abs: string) => {
    const target = path.resolve(abs)
    if (!canTouch(target)) throw new Error('无权打开该路径')
    return shell.openPath(target)
  })

  ipcMain.handle('preview:reveal-abs', (_event, abs: string) => {
    const target = path.resolve(abs)
    if (!canTouch(target)) throw new Error('无权定位该路径')
    shell.showItemInFolder(target)
    return true
  })

  ipcMain.handle('preview:open-root', () => shell.openPath(root))

  ipcMain.handle('preview:git-status', () => readGitStatus(root))

  ipcMain.handle('preview:git-diff', (_event, rel: string) => readGitDiff(root, rel))
}
