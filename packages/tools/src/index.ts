import type { ToolDefinition } from '@witseek/protocol'
import { editFileTool, listDirTool, readFileTool, writeFileTool } from './fs.js'
import { globTool, grepTool } from './search.js'
import { runCommandTool } from './shell.js'

export { resolveInWorkspace, displayPath, type ResolvedPath } from './paths.js'
export { globToRegExp, matchGlob } from './glob.js'
export { readFileTool, writeFileTool, editFileTool, listDirTool, applyEdit, type EditOutcome } from './fs.js'
export { globTool, grepTool } from './search.js'
export { runCommandTool } from './shell.js'

/** 默认工具集。顺序即展示顺序。 */
export function createDefaultTools(): ToolDefinition[] {
  return [
    readFileTool,
    writeFileTool,
    editFileTool,
    listDirTool,
    globTool,
    grepTool,
    runCommandTool
  ]
}
