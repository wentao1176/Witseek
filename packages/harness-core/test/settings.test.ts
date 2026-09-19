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
