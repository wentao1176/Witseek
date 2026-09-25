import { execFileSync } from 'node:child_process'
import {
  mkdtempSync,
  mkdirSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const electronMocks = vi.hoisted(() => {
  const handlers = new Map<string, (...args: any[]) => any>()
  const ipcMain = {
    handle: vi.fn((name: string, handler: (...args: any[]) => any) => handlers.set(name, handler))
  }
  return {
    handlers,
    ipcMain,
    dialog: { showOpenDialog: vi.fn() },
    shell: { showItemInFolder: vi.fn(), openPath: vi.fn() },
    app: { isPackaged: false }
  }
})
vi.mock('electron', () => ({ ...electronMocks, BrowserWindow: class {} }))

import { registerPreviewIpc } from '../src/main/preview-fs'

let tempRoot = ''
let workspace = ''
let dshContents: object

function register(): void {
  electronMocks.handlers.clear()
  dshContents = {}
  registerPreviewIpc(
    {} as never,
    { workspace } as never,
    dshContents as never,
    vi.fn()
  )
}

function callHandler<T>(name: string, ...args: unknown[]): T {
  const handler = electronMocks.handlers.get(name)
  if (!handler) throw new Error(`Missing IPC handler: ${name}`)
  return handler({ sender: dshContents }, ...args) as T
}

describe('workspace preview IPC', () => {
  beforeEach(() => {
    vi.unstubAllGlobals()
    electronMocks.app.isPackaged = false
    tempRoot = mkdtempSync(path.join(os.tmpdir(), 'witseek-preview-'))
    workspace = path.join(tempRoot, 'workspace')
    mkdirSync(workspace, { recursive: true })
    register()
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    rmSync(tempRoot, { recursive: true, force: true })
  })

  it('reads at most the configured text preview limit', () => {
    const file = path.join(workspace, 'large.ts')
    writeFileSync(file, Buffer.alloc(2 * 1024 * 1024 + 64, 0x61))

    const result = callHandler<{ text: string; truncated: boolean }>('preview:read', 'large.ts')

    expect(result.text).toHaveLength(2 * 1024 * 1024)
    expect(result.truncated).toBe(true)
  })

  it('does not inline images larger than the preview limit', () => {
    const file = path.join(workspace, 'large.png')
    writeFileSync(file, Buffer.alloc(8 * 1024 * 1024 + 1, 0))

    const result = callHandler<{ dataUrl?: string; note?: string }>('preview:read', 'large.png')

    expect(result.dataUrl).toBeUndefined()
    expect(result.note).toMatch(/8 MiB/)
  })

  it('allows expanding an in-workspace directory symlink but not an escaping one', () => {
    const realDir = path.join(workspace, 'real-dir')
    const outsideDir = path.join(tempRoot, 'outside')
    mkdirSync(realDir)
    mkdirSync(outsideDir)
    writeFileSync(path.join(realDir, 'child.ts'), 'export {}')
    symlinkSync(realDir, path.join(workspace, 'inside-link'), 'dir')
    symlinkSync(outsideDir, path.join(workspace, 'outside-link'), 'dir')

    const root = callHandler<{ entries: Array<{ name: string; rel: string; dir: boolean }> }>('preview:list')
    expect(root.entries.find(entry => entry.name === 'inside-link')).toMatchObject({ rel: 'inside-link', dir: true })
    expect(root.entries.find(entry => entry.name === 'outside-link')?.dir).toBe(false)

    const linked = callHandler<{ rel: string; entries: Array<{ rel: string }> }>('preview:list', 'inside-link')
    expect(linked.rel).toBe('inside-link')
    expect(linked.entries.map(entry => entry.rel)).toContain('inside-link/child.ts')
  })

  it('truncates a large tracked Git diff instead of failing at the process buffer limit', async () => {
    execFileSync('git', ['init', '--quiet'], { cwd: workspace })
    const file = path.join(workspace, 'large.ts')
    writeFileSync(file, 'a'.repeat(9 * 1024 * 1024))
    execFileSync('git', ['add', 'large.ts'], { cwd: workspace })
    execFileSync('git', ['-c', 'user.name=Witseek Test', '-c', 'user.email=test@example.invalid', 'commit', '-qm', 'baseline'], { cwd: workspace })
    writeFileSync(file, 'b'.repeat(9 * 1024 * 1024))

    const result = await callHandler<Promise<{ truncated: boolean; unstaged: string }>>(
      'preview:git-diff',
      'large.ts'
    )

    expect(result.truncated).toBe(true)
    expect(result.unstaged.length).toBeLessThanOrEqual(512 * 1024)
  })

  it('rejects a packaged workspace that overlaps the install directory', async () => {
    const installDir = path.join(tempRoot, 'install')
    const projectDir = path.join(installDir, 'project')
    mkdirSync(projectDir, { recursive: true })
    electronMocks.app.isPackaged = true
    vi.stubGlobal('process', { ...process, execPath: path.join(installDir, 'Witseek.exe') })
    register()

    expect(() => callHandler('desktop:set-workspace', projectDir)).toThrow(/安装目录重叠/)
  })
})
