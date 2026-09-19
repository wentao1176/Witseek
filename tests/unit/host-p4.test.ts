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
