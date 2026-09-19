import { mkdtemp, readFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { beforeEach, describe, expect, it } from 'vitest'
import type { SessionMeta } from '@witseek/protocol'
import { SessionStore, latestMeta } from '../src/session.js'

let store: SessionStore
let dir: string

beforeEach(async () => {
  dir = await mkdtemp(join(tmpdir(), 'witseek-sess-'))
  store = new SessionStore(dir)
})

const meta = (id: string, updatedAt: string): SessionMeta => ({
  id,
  title: `t-${id}`,
  workspace: '/w',
  model: 'deepseek-chat',
  createdAt: '2026-01-01T00:00:00.000Z',
  updatedAt
})

describe('SessionStore', () => {
  it('创建后可读回', async () => {
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    const records = await store.read('s1')
    expect(records).toHaveLength(1)
    expect(records[0].kind).toBe('meta')
  })

  it('追加消息', async () => {
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    await store.append('s1', { kind: 'message', message: { role: 'user', content: 'hi' } })
    await store.append('s1', { kind: 'message', message: { role: 'assistant', content: 'yo' } })
    expect(await store.read('s1')).toHaveLength(3)
  })

  it('是追加写而非覆盖', async () => {
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    await store.append('s1', { kind: 'message', message: { role: 'user', content: 'hi' } })
    const raw = await readFile(join(dir, 's1.jsonl'), 'utf8')
    expect(raw.split('\n').filter(Boolean)).toHaveLength(2)
  })

  it('损坏的半行不影响整体读取', async () => {
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    await store.append('s1', { kind: 'message', message: { role: 'user', content: 'hi' } })
    const p = join(dir, 's1.jsonl')
    const { appendFile } = await import('node:fs/promises')
    await appendFile(p, '{"kind":"mess', 'utf8') // 模拟写入中断
    expect(await store.read('s1')).toHaveLength(2)
  })

  it('list 按更新时间倒序', async () => {
    await store.create(meta('old', '2026-01-01T00:00:00.000Z'))
    await store.create(meta('new', '2026-06-01T00:00:00.000Z'))
    const list = await store.list()
    expect(list[0].id).toBe('new')
  })

  it('拒绝非法会话 id（防路径穿越）', async () => {
    await expect(store.read('../../etc/passwd')).rejects.toThrow(/非法/)
  })

  it('读不存在的会话返回空数组', async () => {
    expect(await store.read('nope')).toEqual([])
  })

  it('touch 后以最后一条 meta 为准', async () => {
    // JSONL 是追加写的，更新元信息靠再追加一条 meta。
    // 若读取时取的是第一条，界面就会一直显示建会话时的旧标题与旧时间。
    await store.create(meta('s1', '2026-01-01T00:00:00.000Z'))
    await store.touch({ ...meta('s1', '2026-09-18T12:00:00.000Z'), title: '改过的标题' })

    const records = await store.read('s1')
    expect(latestMeta(records)?.title).toBe('改过的标题')
    expect(latestMeta(records)?.updatedAt).toBe('2026-09-18T12:00:00.000Z')
  })

  it('touch 过的会话在列表里排到前面', async () => {
    await store.create(meta('old', '2026-01-01T00:00:00.000Z'))
    await store.create(meta('new', '2026-02-01T00:00:00.000Z'))
    // old 本来是旧的，touch 之后应该排到最前
    await store.touch(meta('old', '2026-12-31T00:00:00.000Z'))

    const list = await store.list()
    expect(list.map((m) => m.id)).toEqual(['old', 'new'])
  })

  it('touch 不存在的会话会抛错而不是静默新建', async () => {
    await expect(store.touch(meta('ghost', '2026-01-01T00:00:00.000Z'))).rejects.toThrow()
  })

  it('latestMeta 对空记录返回 undefined', () => {
    expect(latestMeta([])).toBeUndefined()
  })
})
