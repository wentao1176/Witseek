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
