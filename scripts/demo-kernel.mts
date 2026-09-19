/**
 * 离线演示：不接任何 API，用 MockProvider 驱动完整 Agent 循环。
 *
 * 这条链路的价值在于：它证明了内核可以在没有 API Key、没有 UI 的情况下
 * 跑通「读文件 → 改文件 → 给出结论」的闭环。P3 接界面时，替换的只是 provider 与事件消费方。
 *
 * 运行: pnpm demo:kernel
 */
import { mkdtemp, readFile, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { MockProvider, textTurn, toolTurn } from '@witseek/provider-deepseek'
import { PermissionEngine, ToolRegistry, runAgent } from '@witseek/harness-core'
import { createDefaultTools } from '@witseek/tools'
import type { AgentEvent } from '@witseek/protocol'

const C = {
  dim: '\u001b[2m',
  cyan: '\u001b[36m',
  green: '\u001b[32m',
  yellow: '\u001b[33m',
  red: '\u001b[31m',
  reset: '\u001b[0m'
}

async function main(): Promise<void> {
  const workspace = await mkdtemp(join(tmpdir(), 'witseek-demo-'))
  const target = join(workspace, 'MainActivity.java')
  await writeFile(
    target,
    [
      'public class MainActivity extends AppCompatActivity {',
      '  @Override',
      '  protected void onCreate(Bundle b) {',
      '    super.onCreate(b);',
      '    tvTitle.setText(name);',
      '  }',
      '}'
    ].join('\n'),
    'utf8'
  )

  console.log(`${C.dim}工作区: ${workspace}${C.reset}\n`)

  // 三轮脚本：读 → 改 → 结论
  const provider = new MockProvider((_req, turn) => {
    if (turn === 0) {
      return toolTurn([{ name: 'read_file', args: { path: 'MainActivity.java' } }], '先看一下这个文件。')
    }
    if (turn === 1) {
      return toolTurn([
        {
          name: 'edit_file',
          args: {
            path: 'MainActivity.java',
            oldText: '    tvTitle.setText(name);',
            newText: '    if (tvTitle != null) {\n      tvTitle.setText(name);\n    }'
          }
        }
      ])
    }
    return textTurn(
      '崩溃点是 setContentView 之前访问了未初始化的 View，已补上空值保护。',
      'tvTitle 在 onCreate 里被直接解引用，但它可能是 null…'
    )
  })

  const registry = new ToolRegistry(createDefaultTools())
  const permission = new PermissionEngine('confirm')

  // 思维链与正式回答是两股独立的流，各自用 process.stdout.write 追加。
  // 不在切换处补换行，两段文字会粘成一行，读起来像一句病句。
  let pendingBreak = false
  const brk = (): void => {
    if (pendingBreak) {
      process.stdout.write('\n')
      pendingBreak = false
    }
  }

  const render = (e: AgentEvent): void => {
    switch (e.type) {
      case 'step-start':
        brk()
        console.log(`${C.dim}── 第 ${e.step} 轮 ──${C.reset}`)
        break
      case 'reasoning':
        pendingBreak = true
        process.stdout.write(`${C.dim}${e.text}${C.reset}`)
        break
      case 'content':
        brk()
        pendingBreak = true
        process.stdout.write(e.text)
        break
      case 'tool-start':
        brk()
        console.log(`${C.cyan}▶ ${e.call.name}${C.reset} ${C.dim}${e.call.arguments}${C.reset}`)
        break
      case 'tool-end':
        brk()
        console.log(`${e.result.ok ? C.green : C.red}${e.result.ok ? '✓' : '✗'}${C.reset} ${C.dim}${e.result.output.split('\n')[0].slice(0, 100)}${C.reset}`)
        break
      case 'approval':
        brk()
        console.log(`${C.yellow}⚑ 审批${C.reset} ${e.request.summary} → ${e.decision}`)
        break
      case 'usage':
        brk()
        console.log(`${C.dim}  usage: prompt=${e.usage.promptTokens} completion=${e.usage.completionTokens}${C.reset}`)
        break
      case 'done':
        brk()
        console.log(`\n${C.dim}结束: ${e.reason}${C.reset}`)
        break
    }
  }

  const result = await runAgent(
    {
      provider,
      model: 'mock-model',
      registry,
      workspaceRoot: workspace,
      permission,
      // 演示里自动批准，模拟用户点了"批准"
      approver: async () => 'approve',
      onEvent: render
    },
    '修复 MainActivity 里的崩溃'
  )

  console.log(`\n${C.dim}────────────${C.reset}`)
  console.log(`步数: ${result.steps}  结束原因: ${result.stopReason}`)
  console.log(`\n修改后的文件:\n${await readFile(target, 'utf8')}`)

  if (result.stopReason !== 'completed') process.exitCode = 1
}

main().catch((e) => {
  console.error(e)
  process.exitCode = 1
})
