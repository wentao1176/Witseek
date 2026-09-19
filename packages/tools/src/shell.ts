import { spawn } from 'node:child_process'
import type { ToolDefinition, ToolResult } from '@witseek/protocol'
import { resolveInWorkspace } from './paths.js'

const MAX_OUTPUT = 64 * 1024
const DEFAULT_TIMEOUT = 60_000

function truncate(s: string): string {
  if (s.length <= MAX_OUTPUT) return s
  return `${s.slice(0, MAX_OUTPUT)}\n…[已截断，共 ${s.length} 字符]`
}

export const runCommandTool: ToolDefinition = {
  name: 'run_command',
  description:
    '在工作区内执行 shell 命令并返回输出。有超时保护，输出超长会被截断。需要用户授权。',
  readOnly: false,
  parameters: {
    type: 'object',
    properties: {
      command: { type: 'string', description: '要执行的命令' },
      cwd: { type: 'string', description: '工作目录，默认为工作区根' },
      timeoutMs: { type: 'number', description: '超时毫秒数，默认 60000' }
    },
    required: ['command']
  },
  async execute(args, ctx): Promise<ToolResult> {
    const command = typeof args.command === 'string' ? args.command : ''
    if (!command) return { ok: false, output: '缺少 command 参数' }

    const cwdArg = typeof args.cwd === 'string' && args.cwd ? args.cwd : '.'
    const { abs: cwd, outside } = resolveInWorkspace(ctx.workspaceRoot, cwdArg)
    const timeoutMs = Math.min(600_000, Math.max(1_000, Number(args.timeoutMs ?? DEFAULT_TIMEOUT)))

    const started = Date.now()

    return await new Promise<ToolResult>((resolve) => {
      const child = spawn(command, {
        cwd,
        shell: true,
        env: { ...process.env, GIT_PAGER: 'cat', PAGER: 'cat' }
      })

      let stdout = ''
      let stderr = ''
      let settled = false

      const finish = (result: ToolResult): void => {
        if (settled) return
        settled = true
        clearTimeout(timer)
        ctx.signal?.removeEventListener('abort', onAbort)
        resolve(result)
      }

      const timer = setTimeout(() => {
        child.kill('SIGKILL')
        finish({
          ok: false,
          output: `命令超时（${timeoutMs} ms）已终止\n--- stdout ---\n${truncate(stdout)}\n--- stderr ---\n${truncate(stderr)}`,
          meta: { exitCode: null, timedOut: true, outside, ms: Date.now() - started }
        })
      }, timeoutMs)

      const onAbort = (): void => {
        child.kill('SIGKILL')
        finish({ ok: false, output: '已取消', meta: { exitCode: null, aborted: true, outside } })
      }
      ctx.signal?.addEventListener('abort', onAbort, { once: true })

      child.stdout?.on('data', (d: Buffer) => {
        stdout += d.toString('utf8')
      })
      child.stderr?.on('data', (d: Buffer) => {
        stderr += d.toString('utf8')
      })
      child.on('error', (err) => {
        finish({ ok: false, output: `无法启动命令: ${err.message}`, meta: { outside } })
      })
      child.on('close', (code) => {
        const parts = [`退出码: ${code ?? 'null'}`]
        if (stdout) parts.push(`--- stdout ---\n${truncate(stdout)}`)
        if (stderr) parts.push(`--- stderr ---\n${truncate(stderr)}`)
        finish({
          ok: code === 0,
          output: parts.join('\n'),
          meta: { exitCode: code, outside, ms: Date.now() - started }
        })
      })
    })
  }
}
