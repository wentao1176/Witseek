import type {
  ApprovalRequest,
  PermissionMode,
  ToolDefinition
} from '@witseek/protocol'

export type PermissionVerdict = 'allow' | 'ask' | 'deny'

/**
 * 审批策略引擎。
 *
 * 三条规则，按优先级：
 *   1. 只读工具永远放行（读操作不产生副作用）
 *   2. read-only 模式下，任何写操作直接拒绝（不是"询问"，是不给）
 *   3. auto 模式且未越界 → 放行；其余情况一律询问
 *
 * "越界"指操作落在工作区之外。这一条即使在 auto 模式下也要求确认，
 * 因为工作区隔离是这套 harness 的安全底线。
 */
export class PermissionEngine {
  #mode: PermissionMode
  readonly #alwaysAllow = new Set<string>()

  constructor(mode: PermissionMode = 'confirm') {
    this.#mode = mode
  }

  get mode(): PermissionMode {
    return this.#mode
  }

  setMode(mode: PermissionMode): void {
    this.#mode = mode
  }

  /** 用户点了"总是允许"之后记住该工具 */
  remember(toolName: string): void {
    this.#alwaysAllow.add(toolName)
  }

  forgetAll(): void {
    this.#alwaysAllow.clear()
  }

  isRemembered(toolName: string): boolean {
    return this.#alwaysAllow.has(toolName)
  }

  verdict(tool: ToolDefinition, outsideWorkspace: boolean): PermissionVerdict {
    if (tool.readOnly) return 'allow'
    if (this.#mode === 'read-only') return 'deny'
    if (this.#alwaysAllow.has(tool.name)) return 'allow'
    if (this.#mode === 'auto' && !outsideWorkspace) return 'allow'
    return 'ask'
  }
}

/** 把工具调用转成人类可读的审批请求 */
export function describeApproval(
  tool: ToolDefinition,
  args: Record<string, unknown>,
  outsideWorkspace: boolean
): ApprovalRequest {
  const p = typeof args.path === 'string' ? args.path : undefined
  let summary: string

  switch (tool.name) {
    case 'write_file':
      summary = `写入文件 ${p ?? '(未知路径)'}`
      break
    case 'edit_file': {
      const occ = args.replaceAll === true ? '全部' : '1 处'
      summary = `修改文件 ${p ?? '(未知路径)'}（替换 ${occ}）`
      break
    }
    case 'run_command': {
      const cmd = typeof args.command === 'string' ? args.command : ''
      summary = `执行命令: ${cmd.length > 120 ? `${cmd.slice(0, 120)}…` : cmd}`
      break
    }
    default:
      summary = `${tool.name}${p ? ` ${p}` : ''}`
  }

  if (outsideWorkspace) summary += '  ⚠ 超出工作区范围'
  return { tool: tool.name, args, summary, outsideWorkspace }
}
