import type { ToolDefinition, ToolSchema } from '@witseek/protocol'

export class ToolRegistry {
  readonly #tools = new Map<string, ToolDefinition>()

  constructor(tools: ToolDefinition[] = []) {
    for (const t of tools) this.register(t)
  }

  register(tool: ToolDefinition): this {
    if (this.#tools.has(tool.name)) {
      throw new Error(`工具名重复: ${tool.name}`)
    }
    this.#tools.set(tool.name, tool)
    return this
  }

  get(name: string): ToolDefinition | undefined {
    return this.#tools.get(name)
  }

  has(name: string): boolean {
    return this.#tools.has(name)
  }

  list(): ToolDefinition[] {
    return [...this.#tools.values()]
  }

  schemas(): ToolSchema[] {
    return this.list().map(({ name, description, parameters }) => ({
      name,
      description,
      parameters
    }))
  }
}
