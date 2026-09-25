/*
 * afterPack.cjs —— electron-builder afterPack 钩子
 *
 * 服务器是无 Wine 的 Linux，electron-builder 默认用 rcedit（依赖 Wine）改写
 * Windows exe 的图标与版本资源。win 配置里设 signAndEditExecutable:false
 * 跳过 rcedit，改为在 afterPack 阶段用纯 JS 的 resedit 直接改写 PE 资源，全链路免 Wine。
 *
 * 仅对 win32 产物生效；macOS / Linux 直接跳过。
 * 由 package.json 的 build.afterPack 引用（相对 apps/desktop）。
 */
const fs = require('node:fs')
const path = require('node:path')

/** 把 'a.b.c.d' 拆成 PE 版本资源需要的两个 32 位高低字 */
function splitVersion(version) {
  const parts = String(version).split('.').map((n) => parseInt(n, 10) || 0)
  const [maj = 0, min = 0, patch = 0, rev = 0] = parts
  return {
    ms: ((maj & 0xffff) << 16) | (min & 0xffff),
    ls: ((patch & 0xffff) << 16) | (rev & 0xffff)
  }
}

module.exports = async function afterPack(context) {
  if (context.electronPlatformName !== 'win32') return

  // resedit@3 是纯 ESM，钩子是 CJS，用动态 import 加载
  const { NtExecutable, NtExecutableResource, Data, Resource } = await import('resedit')
  const appInfo = context.packager.appInfo
  const exeName = `${appInfo.productFilename}.exe`
  const exePath = path.join(context.appOutDir, exeName)
  if (!fs.existsSync(exePath)) {
    console.warn(`[afterPack] 未找到可执行文件，跳过 PE 资源改写: ${exePath}`)
    return
  }

  const exe = NtExecutable.from(fs.readFileSync(exePath))
  const res = NtExecutableResource.from(exe)

  // 1) 替换图标组（RT_GROUP_ICON id=101 / lang=1033）
  const iconCandidates = [
    path.join(__dirname, 'resources', 'icon.ico'),
    path.join(context.appOutDir, 'resources', 'icon.ico')
  ]
  const icoPath = iconCandidates.find((p) => fs.existsSync(p))
  if (icoPath) {
    const iconFile = Data.IconFile.from(fs.readFileSync(icoPath))
    // IconFile.icons 元素是 { ...meta, data: IconItem|RawIconItem } 包装，需取 .data
    const icons = iconFile.icons.map((item) => item.data)
    Resource.IconGroupEntry.replaceIconsForResource(res.entries, 101, 1033, icons)
    console.log(`[afterPack] 已替换图标: ${icoPath}（${icons.length} 个尺寸）`)
  } else {
    console.warn('[afterPack] 未找到 resources/icon.ico，图标保持 Electron 默认')
  }

  // 2) 写入版本资源（VS_VERSIONINFO）
  const fv = splitVersion(appInfo.buildVersion || appInfo.version)
  const pv = splitVersion(appInfo.version)
  const vi = Resource.VersionInfo.create(
    1033,
    {
      fileVersionMS: fv.ms,
      fileVersionLS: fv.ls,
      productVersionMS: pv.ms,
      productVersionLS: pv.ls,
      fileFlagsMask: 0x3f,
      fileOS: 0x40004, // VOS_NT_WINDOWS32
      fileType: 1 // VFT_APP
    },
    [
      {
        lang: 1033,
        codepage: 1200, // Unicode
        values: {
          ProductName: appInfo.productName,
          FileDescription: 'Witseek · DeepSeek Harness Desktop',
          CompanyName: 'Witseek',
          LegalCopyright: 'Copyright © 2026 Witseek; powered by DeepSeek Harness (MIT)',
          OriginalFilename: exeName,
          InternalName: 'Witseek',
          ProductVersion: appInfo.version,
          FileVersion: appInfo.buildVersion || appInfo.version
        }
      }
    ]
  )
  vi.outputToResourceEntries(res.entries)

  // 3) 把资源写回 PE 并生成新二进制
  res.outputResource(exe)
  const generated = exe.generate()
  fs.writeFileSync(exePath, Buffer.from(generated))
  console.log(`[afterPack] 已写入 PE 图标与版本信息: ${exePath}`)

  // 4) 复制内置运行时（node.exe + dsh 生产树）到 resources/runtime。
  //    不能用 electron-builder 的 extraResources：它默认忽略名为 node_modules 的
  //    目录（dsh 生产树有上万个文件且核心就在 node_modules），实测只会拷出 package.json。
  //    因此在 afterPack 阶段用 fs.cpSync 原样整树复制（dereference 解引用，确保不残留链接）。
  const runtimeSrc = path.join(__dirname, '.runtime-build', 'win')
  const runtimeDst = path.join(context.appOutDir, 'resources', 'runtime')
  if (!fs.existsSync(path.join(runtimeSrc, 'node.exe'))) {
    throw new Error('[afterPack] 缺少 .runtime-build/win/node.exe，请先运行 prepare:runtime')
  }
  if (!fs.existsSync(path.join(runtimeSrc, 'dsh', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'))) {
    throw new Error('[afterPack] 缺少 .runtime-build/win/dsh 生产树，请先运行 prepare:runtime')
  }
  fs.rmSync(runtimeDst, { recursive: true, force: true })
  fs.mkdirSync(runtimeDst, { recursive: true })
  fs.copyFileSync(path.join(runtimeSrc, 'node.exe'), path.join(runtimeDst, 'node.exe'))
  fs.cpSync(path.join(runtimeSrc, 'dsh'), path.join(runtimeDst, 'dsh'), {
    recursive: true,
    force: true,
    dereference: true
  })
  const required = [
    'node.exe',
    path.join('dsh', 'node_modules', '@deepseek-ai', 'dsh', 'lib', 'bin.js'),
    path.join('dsh', 'node_modules', '@witseek', 'dsh-client-witseek-desktop', 'client.js'),
    path.join('dsh', 'node_modules', 'node-pty', 'prebuilds', 'win32-x64', 'conpty.node'),
    path.join('dsh', 'node_modules', '@img', 'sharp-win32-x64')
  ]
  for (const rel of required) {
    if (!fs.existsSync(path.join(runtimeDst, rel))) {
      throw new Error(`[afterPack] 运行时复制后缺失关键文件: ${rel}`)
    }
  }
  for (const rel of [
    path.join('agent-presets', 'witseek-coding', 'agent.cordis.yml'),
    'witseek.patch.yml'
  ]) {
    const src = path.join(runtimeSrc, rel)
    if (!fs.existsSync(src)) throw new Error(`[afterPack] 缺少 Witseek runtime resource: ${rel}`)
    const dst = path.join(runtimeDst, rel)
    fs.mkdirSync(path.dirname(dst), { recursive: true })
    fs.cpSync(src, dst, { recursive: true, force: true })
  }
  console.log('[afterPack] 内置运行时已复制到 resources/runtime（node.exe + dsh 生产树）')
}
