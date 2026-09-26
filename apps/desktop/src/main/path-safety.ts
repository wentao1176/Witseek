import { existsSync, realpathSync } from 'node:fs'
import path from 'node:path'

/** Resolve existing symlink/junction ancestors while preserving missing path components. */
export function resolveForPathSafety(input: string): string {
  let current = path.resolve(input)
  const missing: string[] = []
  while (!existsSync(current)) {
    const parent = path.dirname(current)
    if (parent === current) return path.resolve(input)
    missing.unshift(path.basename(current))
    current = parent
  }
  return path.resolve(realpathSync(current), ...missing)
}

function isWithin(root: string, candidate: string): boolean {
  const relative = path.relative(root, candidate)
  const comparable = process.platform === 'win32' ? relative.toLocaleLowerCase() : relative
  const parentMarker = '..'
  return comparable === '' || (
    comparable !== parentMarker &&
    !comparable.startsWith(`${parentMarker}${path.sep}`) &&
    !path.isAbsolute(relative)
  )
}

/** True when either normalized path is equal to or nested under the other. */
export function pathsOverlap(left: string, right: string): boolean {
  const resolvedLeft = resolveForPathSafety(left)
  const resolvedRight = resolveForPathSafety(right)
  return isWithin(resolvedLeft, resolvedRight) || isWithin(resolvedRight, resolvedLeft)
}
