/**
 * 右侧文件预览栏的后端能力：在主进程内、经 IPC 对 dsh 工作区做只读浏览/预览。
 *
 * 安全约束：
 *  - 渲染层 sandbox + contextIsolation，只能通过 preload 暴露的白名单方法调用；
 *  - 文件树/读取一律限定在工作区根目录内，rel 中的 ".." 与绝对路径会被拒绝（越权防护）；
 *  - 唯一的例外是“打开文件…”系统选择框：由用户显式选择的文件才允许读取；
 *  - 文本设大小上限，图片转 data URL，其余二进制仅返回元信息并引导系统打开。
 */
import { BrowserWindow, dialog, ipcMain, shell } from 'electron'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import path from 'node:path'
import type { DataLayout } from './paths'

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
  return target === normalizedRoot || target.startsWith(normalizedRoot + path.sep)
}

/** 把渲染层传来的 POSIX 风格相对路径安全地解析到工作区内的绝对路径 */
function resolveInside(root: string, rel: string): string {
  const parts = String(rel || '')
    .split(/[\\/]/)
    .filter(p => p.length > 0 && p !== '.' && p !== '..')
  const abs = path.join(root, ...parts)
  if (!isWithin(root, abs)) {
    throw new Error('路径越权：只能访问工作区目录内的文件')
  }
  return abs
}

function toRel(root: string, abs: string): string {
  return path.relative(root, abs).split(path.sep).join('/')
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

function readAny(abs: string, rel: string): PreviewResult {
  const st = statSync(abs)
  const name = path.basename(abs)
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
    const buf = readFileSync(abs)
    return {
      ...base,
      kind,
      mime,
      dataUrl: `data:${mime};base64,${buf.toString('base64')}`
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
  const buf = readFileSync(abs)
  const truncated = buf.length > MAX_TEXT_BYTES
  const text = buf.subarray(0, MAX_TEXT_BYTES).toString('utf8')
  return {
    ...base,
    kind,
    text,
    truncated,
    language: kind === 'markdown' ? 'markdown' : language
  }
}

export function registerPreviewIpc(win: BrowserWindow, data: DataLayout): void {
  const root = path.resolve(data.workspace)
  // 用户通过“打开文件…”系统选择框显式选中的工作区外文件，会话内允许系统打开/定位
  const granted = new Set<string>()

  function canTouch(abs: string): boolean {
    return isWithin(root, abs) || granted.has(path.resolve(abs))
  }

  ipcMain.handle('preview:root', () => ({
    root,
    rel: '',
    sep: '/',
    platform: process.platform,
    name: path.basename(root)
  }))

  ipcMain.handle('preview:list', (_event, rel = '') => {
    const abs = resolveInside(root, rel)
    const dirents = readdirSync(abs, { withFileTypes: true })
    const entries: DirEntry[] = []
    for (const d of dirents) {
      const childAbs = path.join(abs, d.name)
      let size = 0
      let mtime = 0
      try {
        const st = statSync(childAbs)
        size = st.size
        mtime = st.mtimeMs
      } catch {
        /* 无权限等情况忽略单项 */
      }
      entries.push({
        name: d.name,
        rel: toRel(root, childAbs),
        dir: d.isDirectory(),
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
    return { root, rel: toRel(root, abs), entries }
  })

  ipcMain.handle('preview:read', (_event, rel: string) => {
    const abs = resolveInside(root, rel)
    return readAny(abs, toRel(root, abs))
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
}
