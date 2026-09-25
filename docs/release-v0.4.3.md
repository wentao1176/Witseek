# Witseek v0.4.3

本版本调整 Windows 桌面数据与安装位置，并修复升级、卸载后的目录管理。

- Witseek 的 dsh 配置与凭据迁移到 `%USERPROFILE%\.dsh\witseek`，默认工作区迁移到其 `workspace` 子目录。
- 旧版数据只在目标位置不存在且同盘时移动；遇到冲突会保留原目录并显示恢复入口。成功启动后，旧桌面目录中的剩余文件会移入 `legacy-desktop-backup-*` 备份目录。
- 默认安装目录改为 `%USERPROFILE%\.dsh\WitseekApp`，可选空目录或当前 Witseek 安装目录。安装和卸载都会拒绝与 dsh 数据或工作区重叠的程序、缓存路径；更新缓存和临时文件放在所选安装目录旁，只有记录的缓存路径与当前安装位置吻合且由本次安装创建时才会删除。
- 卸载只删除随 Witseek 打包的程序文件和空目录；目录中的其他文件会保留。旧默认程序目录也按相同规则清理。
- 安装器、应用程序和快捷方式继续使用提供的 Witseek 鲸鱼图标。
- 保留 dsh 核心、Witseek Coding preset、代码 / Markdown / 图片预览和 GitHub 自动更新。
- 安装包未签名，Windows SmartScreen 仍可能显示保护提示；安装保持当前用户权限，不请求管理员提升。
