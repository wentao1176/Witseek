import { existsSync, mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

const { appMock } = vi.hoisted(() => ({
  appMock: {
    isPackaged: false,
    getPath: vi.fn(),
    setPath: vi.fn()
  }
}))
vi.mock('electron', () => ({ app: appMock }))

import { prepareDesktopStorage } from '../src/main/storage'

let tempRoot = ''

function configureWindowsApp(home: string): void {
  const paths: Record<string, string> = {
    home,
    appData: path.join(home, 'AppData', 'Roaming'),
    userData: path.join(home, 'AppData', 'Roaming', '@witseek', 'desktop')
  }
  appMock.getPath.mockImplementation((name: string) => paths[name])
  appMock.setPath.mockClear()
  appMock.isPackaged = false
  vi.stubGlobal('process', {
    ...process,
    platform: 'win32',
    env: { ...process.env, WITSEEK_WORKSPACE: '' }
  })
}

describe('prepareDesktopStorage', () => {
  beforeEach(() => {
    tempRoot = mkdtempSync(path.join(os.tmpdir(), 'witseek-storage-'))
  })

  afterEach(() => {
    vi.unstubAllGlobals()
    rmSync(tempRoot, { recursive: true, force: true })
  })

  it('keeps Electron userData under .dsh while displaying a migration conflict', () => {
    configureWindowsApp(tempRoot)
    const legacyDshHome = path.join(tempRoot, 'AppData', 'Roaming', '@witseek', 'desktop', 'dsh-home')
    const newDshHome = path.join(tempRoot, '.dsh', 'witseek')
    mkdirSync(legacyDshHome, { recursive: true })
    mkdirSync(newDshHome, { recursive: true })

    const storage = prepareDesktopStorage()

    expect(storage.migrationIssues.length).toBeGreaterThan(0)
    expect(appMock.setPath).toHaveBeenCalledWith('userData', path.join(newDshHome, 'electron'))
    expect(appMock.setPath).not.toHaveBeenCalledWith('userData', expect.stringContaining('@witseek'))
  })

  it('sets userData under .dsh before a cache creation failure', () => {
    configureWindowsApp(tempRoot)
    const dshHome = path.join(tempRoot, '.dsh', 'witseek')
    const cacheFile = path.join(dshHome, 'cache')
    mkdirSync(dshHome, { recursive: true })
    writeFileSync(cacheFile, 'not a directory')

    const storage = prepareDesktopStorage()

    expect(storage.initializationError).toMatch(/无法准备/)
    expect(appMock.setPath).toHaveBeenCalledWith('userData', path.join(dshHome, 'electron'))
  })

  it('rejects a packaged workspace under the install directory before creating it', () => {
    const installDir = path.join(tempRoot, 'Install', 'WitseekApp')
    const unsafeWorkspace = path.join(installDir, 'workspace')
    mkdirSync(installDir, { recursive: true })
    configureWindowsApp(tempRoot)
    appMock.isPackaged = true
    vi.stubGlobal('process', {
      ...process,
      platform: 'win32',
      execPath: path.join(installDir, 'Witseek.exe'),
      resourcesPath: path.join(tempRoot, 'resources'),
      env: { ...process.env, WITSEEK_WORKSPACE: unsafeWorkspace }
    })

    const storage = prepareDesktopStorage()

    expect(storage.initializationError).toMatch(/工作区不能与 Witseek 安装目录或更新缓存重叠/)
    expect(storage.data.workspace).toBe(path.join(tempRoot, '.dsh', 'witseek', 'workspace'))
    expect(existsSync(unsafeWorkspace)).toBe(false)
  })

  it('rejects a packaged workspace under the updater cache before creating it', () => {
    const installDir = path.join(tempRoot, 'Install', 'WitseekApp')
    const cacheDir = path.join(tempRoot, 'Install', 'WitseekApp-cache')
    const unsafeWorkspace = path.join(cacheDir, 'workspace')
    mkdirSync(installDir, { recursive: true })
    mkdirSync(cacheDir, { recursive: true })
    configureWindowsApp(tempRoot)
    appMock.isPackaged = true
    vi.stubGlobal('process', {
      ...process,
      platform: 'win32',
      execPath: path.join(installDir, 'Witseek.exe'),
      resourcesPath: path.join(tempRoot, 'resources'),
      env: { ...process.env, WITSEEK_WORKSPACE: unsafeWorkspace }
    })

    const storage = prepareDesktopStorage()

    expect(storage.initializationError).toMatch(/工作区不能与 Witseek 安装目录或更新缓存重叠/)
    expect(storage.data.workspace).toBe(path.join(tempRoot, '.dsh', 'witseek', 'workspace'))
    expect(existsSync(unsafeWorkspace)).toBe(false)
  })
})
