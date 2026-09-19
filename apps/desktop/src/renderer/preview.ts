/**
 * 文件预览栏渲染逻辑（壳自带 renderer，vite 打包；marked/highlight.js 已 bundle，离线可用）。
 * 经 window.witseekPreview（preload 白名单）访问主进程，受工作区根目录约束。
 */
import { marked } from 'marked'
import hljs from 'highlight.js/lib/core'

import javascript from 'highlight.js/lib/languages/javascript'
import typescript from 'highlight.js/lib/languages/typescript'
import python from 'highlight.js/lib/languages/python'
import rust from 'highlight.js/lib/languages/rust'
import c from 'highlight.js/lib/languages/c'
import cpp from 'highlight.js/lib/languages/cpp'
import java from 'highlight.js/lib/languages/java'
import csharp from 'highlight.js/lib/languages/csharp'
import go from 'highlight.js/lib/languages/go'
import ruby from 'highlight.js/lib/languages/ruby'
import php from 'highlight.js/lib/languages/php'
import swift from 'highlight.js/lib/languages/swift'
import kotlin from 'highlight.js/lib/languages/kotlin'
import bash from 'highlight.js/lib/languages/bash'
import powershell from 'highlight.js/lib/languages/powershell'
import css from 'highlight.js/lib/languages/css'
import scss from 'highlight.js/lib/languages/scss'
import less from 'highlight.js/lib/languages/less'
import json from 'highlight.js/lib/languages/json'
import xml from 'highlight.js/lib/languages/xml'
import yaml from 'highlight.js/lib/languages/yaml'
import ini from 'highlight.js/lib/languages/ini'
import sql from 'highlight.js/lib/languages/sql'
import markdownLang from 'highlight.js/lib/languages/markdown'
import dockerfile from 'highlight.js/lib/languages/dockerfile'
import makefile from 'highlight.js/lib/languages/makefile'
import lua from 'highlight.js/lib/languages/lua'
import dart from 'highlight.js/lib/languages/dart'
import protobuf from 'highlight.js/lib/languages/protobuf'
import groovy from 'highlight.js/lib/languages/groovy'
import dos from 'highlight.js/lib/languages/dos'

import './preview.css'

type RegisterLanguageFn = Parameters<typeof hljs.registerLanguage>[1]
const registered: Record<string, RegisterLanguageFn> = {
  javascript,
  typescript,
  python,
  rust,
  c,
  cpp,
  java,
  csharp,
  go,
  ruby,
  php,
  swift,
  kotlin,
  bash,
  powershell,
  css,
  scss,
  less,
  json,
  xml,
  yaml,
  ini,
  sql,
  markdown: markdownLang,
  dockerfile,
  makefile,
  lua,
  dart,
  protobuf,
  groovy,
  dos
}
for (const [name, mod] of Object.entries(registered)) {
  // highlight.js 语言模块导出为注册函数
  hljs.registerLanguage(name, mod)
}

marked.setOptions({ gfm: true, breaks: false })

interface DirEntry {
  name: string
  rel: string
  dir: boolean
  size: number
  mtime: number
}
interface ListResult {
  root: string
  rel: string
  entries: DirEntry[]
}
interface RootInfo {
  root: string
  rel: string
  sep: string
  platform: string
  name: string
}
type PreviewKind = 'text' | 'image' | 'markdown' | 'pdf' | 'binary'
interface PreviewResult {
  kind: PreviewKind
  name: string
  abs: string
  rel: string
  size: number
  mtime: number
  text?: string
  truncated?: boolean
  language?: string
  dataUrl?: string
  mime?: string
  note?: string
}
interface PreviewApi {
  root: () => Promise<RootInfo>
  list: (rel: string) => Promise<ListResult>
  read: (rel: string) => Promise<PreviewResult>
  pick: () => Promise<PreviewResult | null>
  openAbs: (abs: string) => Promise<unknown>
  openRoot: () => Promise<unknown>
  resize: (width: number) => Promise<number>
  onVisibility: (cb: (open: boolean) => void) => () => void
}

declare global {
  interface Window {
    witseekPreview: PreviewApi
  }
}

const api = window.witseekPreview

const treeEl = document.getElementById('tree') as HTMLDivElement
const bodyEl = document.getElementById('preview-body') as HTMLDivElement
const nameEl = document.getElementById('preview-name') as HTMLSpanElement
const metaEl = document.getElementById('preview-meta') as HTMLSpanElement
const openSystemBtn = document.getElementById('btn-open-system') as HTMLButtonElement
const wsNameEl = document.getElementById('ws-name') as HTMLSpanElement

interface TreeNode {
  loaded: boolean
  open: boolean
  children: DirEntry[] | null
}
const nodeMap = new Map<string, TreeNode>()
let rootInfo: RootInfo | null = null
let current: PreviewResult | null = null

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
}

function formatSize(bytes: number): string {
  if (!Number.isFinite(bytes)) return ''
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`
  if (bytes < 1024 * 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`
  return `${(bytes / 1024 / 1024 / 1024).toFixed(2)} GB`
}

function codeHtml(text: string, language?: string): string {
  if (language && language !== 'plaintext' && hljs.getLanguage(language)) {
    try {
      return hljs.highlight(text, { language, ignoreIllegals: true }).value
    } catch {
      /* fall through */
    }
  }
  return escapeHtml(text)
}

function renderTree(): void {
  const root = nodeMap.get('')
  treeEl.innerHTML = ''
  if (!root || root.children === null) {
    const tip = document.createElement('div')
    tip.className = 'tree-empty'
    tip.textContent = '加载中…'
    treeEl.appendChild(tip)
    return
  }

  const frag = document.createDocumentFragment()
  const renderEntries = (entries: DirEntry[], depth: number): void => {
    for (const entry of entries) {
      const row = document.createElement('div')
      row.className = 'tree-row' + (entry.dir ? ' dir' : '')
      row.style.paddingLeft = `${8 + depth * 14}px`
      if (current && current.rel === entry.rel) row.classList.add('selected')

      const caret = document.createElement('span')
      caret.className = 'caret'
      const node = nodeMap.get(entry.rel)
      caret.textContent = entry.dir ? (node?.open ? '▾' : '▸') : ''

      const mark = document.createElement('span')
      mark.className = 'node-mark'
      mark.textContent = entry.dir ? '▤' : '·'

      const label = document.createElement('span')
      label.className = 'node-label'
      label.textContent = entry.name

      row.append(caret, mark, label)
      if (entry.dir) {
        row.addEventListener('click', () => void toggleDir(entry.rel))
        if (node?.open && node.children) renderEntries(node.children, depth + 1)
      } else {
        row.addEventListener('click', () => void openFile(entry.rel))
      }
      frag.appendChild(row)
    }
  }
  renderEntries(root.children, 0)
  treeEl.appendChild(frag)
}

async function loadDir(rel: string): Promise<DirEntry[]> {
  const result = await api.list(rel)
  return result.entries
}

async function toggleDir(rel: string): Promise<void> {
  let node = nodeMap.get(rel)
  if (!node) {
    node = { loaded: false, open: false, children: null }
    nodeMap.set(rel, node)
  }
  try {
    if (!node.loaded || node.children === null) {
      node.children = await loadDir(rel)
      node.loaded = true
    }
    node.open = !node.open
    renderTree()
  } catch (err) {
    treeEl.textContent = `读取目录失败：${err instanceof Error ? err.message : String(err)}`
  }
}

async function initTree(): Promise<void> {
  try {
    rootInfo = await api.root()
    wsNameEl.textContent = rootInfo.root
    wsNameEl.title = rootInfo.root
    nodeMap.set('', { loaded: true, open: true, children: null })
    const entries = await loadDir('')
    nodeMap.get('')!.children = entries
    renderTree()
  } catch (err) {
    treeEl.innerHTML = ''
    const tip = document.createElement('div')
    tip.className = 'tree-error'
    tip.textContent = `无法读取工作区：${err instanceof Error ? err.message : String(err)}`
    treeEl.appendChild(tip)
  }
}

async function openFile(rel: string): Promise<void> {
  try {
    const result = await api.read(rel)
    renderResult(result)
    renderTree()
  } catch (err) {
    showError(err instanceof Error ? err.message : String(err))
  }
}

function resetBody(): void {
  bodyEl.innerHTML = ''
}

function showEmpty(): void {
  resetBody()
  const empty = document.createElement('div')
  empty.className = 'empty'
  empty.innerHTML =
    '<div class="empty-doc"></div>' +
    '<p class="empty-title">尚未选择文件</p>' +
    '<p class="empty-sub">从上方文件树选择工作区文件，或点击“打开文件”选择任意文件。</p>' +
    '<p class="empty-sub">支持代码 / 文本 / Markdown / 图片预览。</p>'
  bodyEl.appendChild(empty)
}

function showError(message: string): void {
  resetBody()
  const div = document.createElement('div')
  div.className = 'unsupported'
  div.textContent = `预览失败：${message}`
  bodyEl.appendChild(div)
}

function renderResult(r: PreviewResult): void {
  current = r
  nameEl.textContent = r.name
  metaEl.textContent = formatSize(r.size)
  openSystemBtn.hidden = false
  resetBody()

  if (r.truncated) {
    const banner = document.createElement('div')
    banner.className = 'trunc-banner'
    banner.textContent = '文件较大，仅显示前 2 MB 内容，完整文件请在系统中打开。'
    bodyEl.appendChild(banner)
  }

  if (r.kind === 'image' && r.dataUrl) {
    const wrap = document.createElement('div')
    wrap.className = 'img-wrap'
    const img = document.createElement('img')
    img.src = r.dataUrl
    img.alt = r.name
    wrap.appendChild(img)
    bodyEl.appendChild(wrap)
    return
  }

  if (r.kind === 'markdown') {
    const md = document.createElement('div')
    md.className = 'md-body'
    md.innerHTML = marked.parse(r.text ?? '', { async: false }) as string
    md.querySelectorAll('pre code').forEach(el => {
      try {
        hljs.highlightElement(el as HTMLElement)
      } catch {
        /* ignore */
      }
    })
    bodyEl.appendChild(md)
    bodyEl.scrollTop = 0
    return
  }

  if (r.kind === 'text') {
    const pre = document.createElement('pre')
    pre.className = 'code'
    const code = document.createElement('code')
    code.className = `hljs language-${r.language ?? 'plaintext'}`
    code.innerHTML = codeHtml(r.text ?? '', r.language)
    pre.appendChild(code)
    bodyEl.appendChild(pre)
    bodyEl.scrollTop = 0
    return
  }

  // pdf / binary：不做内嵌，给出信息与系统打开入口
  const box = document.createElement('div')
  box.className = 'unsupported'
  const doc = document.createElement('div')
  doc.className = 'empty-doc'
  const title = document.createElement('div')
  title.className = 'u-name'
  title.textContent = r.name
  const meta = document.createElement('div')
  meta.className = 'u-meta'
  meta.textContent = `${formatSize(r.size)}${r.note ? ` · ${r.note}` : ''}`
  const btn = document.createElement('button')
  btn.className = 'btn'
  btn.textContent = '在系统中打开'
  btn.addEventListener('click', () => void api.openAbs(r.abs))
  box.append(doc, title, meta, btn)
  bodyEl.appendChild(box)
}

function initToolbar(): void {
  document.getElementById('btn-pick')!.addEventListener('click', async () => {
    const result = await api.pick()
    if (result) {
      renderResult(result)
      renderTree()
    }
  })
  document.getElementById('btn-refresh')!.addEventListener('click', () => {
    nodeMap.clear()
    current = null
    nameEl.textContent = '未选择文件'
    metaEl.textContent = ''
    openSystemBtn.hidden = true
    showEmpty()
    void initTree()
  })
  document.getElementById('btn-root')!.addEventListener('click', () => void api.openRoot())
  openSystemBtn.addEventListener('click', () => {
    if (current) void api.openAbs(current.abs)
  })

  const collapseBtn = document.getElementById('btn-tree-collapse') as HTMLButtonElement
  collapseBtn.addEventListener('click', () => {
    const collapsed = document.body.classList.toggle('tree-collapsed')
    collapseBtn.textContent = collapsed ? '展开' : '收起'
  })
}

function initResizer(): void {
  const resizer = document.getElementById('resizer') as HTMLDivElement
  let dragging = false
  let startX = 0
  let startWidth = 0
  let raf = 0
  let pending = 0

  resizer.addEventListener('mousedown', e => {
    dragging = true
    startX = e.screenX
    startWidth = window.innerWidth
    resizer.classList.add('dragging')
    e.preventDefault()
  })
  window.addEventListener('mousemove', e => {
    if (!dragging) return
    pending = startWidth + (startX - e.screenX)
    if (raf) return
    raf = requestAnimationFrame(() => {
      raf = 0
      void api.resize(Math.round(pending))
    })
  })
  window.addEventListener('mouseup', () => {
    dragging = false
    resizer.classList.remove('dragging')
  })
}

if (!api) {
  nameEl.textContent = '桥接不可用'
  showError('未能加载预览桥接脚本，请重启应用。')
} else {
  initToolbar()
  initResizer()
  void initTree()
  api.onVisibility(open => {
    if (open && !rootInfo) void initTree()
  })
}
