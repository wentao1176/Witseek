import { isAbsolute, relative, resolve } from 'node:path'

export interface ResolvedPath {
  abs: string
  /** 是否越出工作区。越界不是错误，但会触发审批。 */
  outside: boolean
}

/**
 * 把用户/模型给的路径解析成绝对路径，并判断是否越出工作区。
 * 所有文件类工具都必须先过这里 —— 这是工作区隔离的唯一入口。
 */
export function resolveInWorkspace(root: string, p: string): ResolvedPath {
  const abs = isAbsolute(p) ? resolve(p) : resolve(root, p)
  const rel = relative(resolve(root), abs)
  const outside = rel.startsWith('..') || isAbsolute(rel)
  return { abs, outside }
}

/** 用于展示的相对路径；越界时原样返回绝对路径 */
export function displayPath(root: string, abs: string): string {
  const rel = relative(resolve(root), abs)
  return rel.startsWith('..') || isAbsolute(rel) ? abs : rel
}
