#!/usr/bin/env node
import { cpSync, existsSync, mkdirSync, rmSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const appRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const repoRoot = path.resolve(appRoot, '..', '..')
const stage = process.platform === 'win32'
  ? 'stage-win32'
  : process.platform === 'darwin'
    ? 'stage-darwin'
    : 'stage-linux'
const dshDir = process.env.WITSEEK_DSH_DIR || path.join(repoRoot, 'runtime', stage, 'dsh')
const extension = path.join(appRoot, 'resources', 'dsh-client-witseek-desktop')
const dshEntry = path.join(dshDir, 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js')
const target = path.join(dshDir, 'node_modules', '@witseek', 'dsh-client-witseek-desktop')

if (!existsSync(dshEntry)) {
  throw new Error(`dsh runtime not found at ${dshDir}; prepare the runtime before starting Witseek`)
}
if (!existsSync(path.join(extension, 'client.js'))) {
  throw new Error(`Witseek dsh client extension not found at ${extension}`)
}
rmSync(target, { recursive: true, force: true })
mkdirSync(path.dirname(target), { recursive: true })
cpSync(extension, target, { recursive: true, force: true })
console.log(`[Witseek] synced dsh client extension to ${target}`)
