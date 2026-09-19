#!/usr/bin/env bash
# scaffold_p1.sh —— 生成 P1 阶段的 Electron + React 工程骨架
#
# 幂等：重复执行会覆盖本脚本负责的文件，但不会碰用户原文件。
# 依赖不在此脚本内安装（由 pnpm add 单独完成），避免版本猜测。
#
# 执行: ssh -F .relay/ssh_config witseek 'bash -s' < scripts/scaffold_p1.sh
set -euo pipefail

ROOT="${WITSEEK_ROOT:-/media/hnu/hnu2021/dengxin/xuanwentao/Witseek}"
cd "$ROOT"

w() { mkdir -p "$(dirname "$1")"; cat > "$1"; echo "  + $1"; }

mkdir -p apps/desktop/src/main apps/desktop/src/preload \
         apps/desktop/src/renderer/src/components apps/desktop/src/renderer/public \
         apps/desktop/resources

cp -f assets/icons/icon-512.png apps/desktop/resources/icon.png
cp -f assets/icons/icon-256.png apps/desktop/resources/icon-256.png
# 渲染进程要用的图标必须放进 Vite 的静态目录，否则开发模式下 404
cp -f assets/icons/icon-256.png apps/desktop/src/renderer/public/icon-256.png

echo "== 根配置 =="

w pnpm-workspace.yaml <<'EOF'
packages:
  - 'apps/*'
  - 'packages/*'

# pnpm 10+ 默认不执行依赖的安装脚本。Electron 的二进制靠 postinstall 下载，
# esbuild 需要安装原生二进制，node-pty 需要在安装期针对 Node 编译原生模块，
# 三者必须放行，否则对应包装完是空的。
# 注意：pnpm 12 起的设置名是 allowBuilds（映射），不是 onlyBuiltDependencies（列表），
# 且不再读取 package.json 的 "pnpm" 字段 —— 写错名字会静默无效。
allowBuilds:
  electron: true
  esbuild: true
  node-pty: true
EOF

w package.json <<'EOF'
{
  "name": "witseek",
  "version": "0.1.0",
  "private": true,
  "description": "DeepSeek harness desktop application",
  "scripts": {
    "dev": "pnpm --filter @witseek/desktop dev",
    "build": "pnpm --filter @witseek/desktop build",
    "typecheck": "pnpm -r --if-present typecheck"
  }
}
EOF

w tsconfig.base.json <<'EOF'
{
  "compilerOptions": {
    "target": "ES2022",
    "module": "ESNext",
    "moduleResolution": "bundler",
    "lib": ["ES2022", "DOM", "DOM.Iterable"],
    "strict": true,
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "noFallthroughCasesInSwitch": true,
    "esModuleInterop": true,
    "resolveJsonModule": true,
    "isolatedModules": true,
    "skipLibCheck": true,
    "forceConsistentCasingInFileNames": true
  }
}
EOF

w .gitignore <<'EOF'
node_modules/
out/
dist/
artifacts/
.cache/
.runtime/
.tools/
.setup/
*.log
EOF

echo "== desktop 包配置 =="

w apps/desktop/package.json <<'EOF'
{
  "name": "@witseek/desktop",
  "version": "0.1.0",
  "private": true,
  "description": "Witseek desktop shell (Electron main + preload + renderer)",
  "main": "./out/main/index.mjs",
  "scripts": {
    "dev": "electron-vite dev",
    "build": "electron-vite build",
    "preview": "electron-vite preview",
    "rebuild-native": "electron-rebuild -f -w node-pty",
    "postinstall": "electron-rebuild -f -w node-pty || echo skip native rebuild",
    "typecheck": "tsc --noEmit -p tsconfig.json",
    "dist:win": "electron-builder --win dir"
  },
  "dependencies": {
    "@witseek/harness-core": "workspace:*",
    "@witseek/protocol": "workspace:*",
    "@witseek/provider-deepseek": "workspace:*",
    "@witseek/tools": "workspace:*",
    "@xterm/addon-fit": "^0.11.0",
    "@xterm/xterm": "^6.0.0",
    "node-pty": "^1.1.0",
    "react": "^19.3.0",
    "react-dom": "^19.3.0"
  },
  "devDependencies": {
    "@electron/rebuild": "^4.2.0",
    "@types/node": "^26.6.1",
    "@types/react": "^19.3.0",
    "@types/react-dom": "^19.3.0",
    "@vitejs/plugin-react": "^6.1.1",
    "electron": "^44.4.1",
    "electron-builder": "^26.15.3",
    "electron-vite": "^5.0.0",
    "resedit": "^3.1.0",
    "typescript": "^7.0.2",
    "vite": "^8.3.0"
  },
  "build": {
    "appId": "com.witseek.desktop",
    "productName": "Witseek",
    "copyright": "Copyright © 2026 Witseek",
    "directories": {
      "output": "../../artifacts",
      "buildResources": "resources"
    },
    "files": [
      "out/**/*",
      "resources/**/*",
      "package.json",
      "!**/node_modules/**/*.{pdb,map}",
      "!**/node_modules/node-pty/{build,bin,deps,doc,tools}/**",
      "!**/node_modules/node-pty/prebuilds/{darwin-arm64,darwin-x64,win32-arm64}/**"
    ],
    "asarUnpack": [
      "**/node_modules/node-pty/**",
      "**/*.node",
      "**/*.exe",
      "**/*.dll"
    ],
    "afterPack": "./afterPack.cjs",
    "win": {
      "target": [
        {
          "target": "dir",
          "arch": [
            "x64"
          ]
        }
      ],
      "icon": "resources/icon.ico",
      "executableName": "Witseek",
      "signAndEditExecutable": false
    }
  }
}
EOF

w apps/desktop/electron.vite.config.ts <<'EOF'
import { resolve } from 'node:path'
import { defineConfig, externalizeDepsPlugin } from 'electron-vite'
import react from '@vitejs/plugin-react'

// externalizeDepsPlugin 默认只外置 dependencies，而 electron 位于 devDependencies，
// 若不显式声明 external，electron 的 npm 包会被整个打进主进程产物，
// 运行时它会去读 node_modules/electron/path.txt 并报
// "Electron failed to install correctly"。主进程与 preload 都必须显式外置 electron。
//
// node-pty 是原生模块（.node 二进制 + 安装期编译），无法被 rollup 打包，
// 必须在运行时从 node_modules 直接 require，同样加入 external。
const EXTERNAL = ['electron', 'node-pty']

export default defineConfig({
  main: {
    plugins: [externalizeDepsPlugin()],
    build: {
      outDir: 'out/main',
      rollupOptions: {
        input: resolve(__dirname, 'src/main/index.ts'),
        external: EXTERNAL
      }
    }
  },
  preload: {
    plugins: [externalizeDepsPlugin()],
    build: {
      outDir: 'out/preload',
      rollupOptions: {
        input: resolve(__dirname, 'src/preload/index.ts'),
        external: EXTERNAL
      }
    }
  },
  renderer: {
    root: resolve(__dirname, 'src/renderer'),
    plugins: [react()],
    build: {
      outDir: 'out/renderer',
      emptyOutDir: true,
      rollupOptions: { input: resolve(__dirname, 'src/renderer/index.html') }
    }
  }
})
EOF

w apps/desktop/tsconfig.json <<'EOF'
{
  "extends": "../../tsconfig.base.json",
  "compilerOptions": {
    "jsx": "react-jsx",
    "types": ["node", "electron-vite/node", "vite/client"],
    "noEmit": true
  },
  "include": ["src/**/*.ts", "src/**/*.tsx", "electron.vite.config.ts"]
}
EOF

w apps/desktop/src/renderer/index.html <<'EOF'
<!doctype html>
<html lang="zh-CN">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1.0" />
    <title>Witseek</title>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
EOF

echo
echo "==> P1 工程配置已生成"
echo "    注意：主进程 / preload / 渲染进程的代码不在这里生成。"
echo "    它们由 scaffold_p3_host.sh 与 scaffold_p3_ui.sh 负责。"
echo "    完整重建请用 scripts/scaffold_all.sh。"
find apps/desktop -type f -not -path "*/node_modules/*" | sort