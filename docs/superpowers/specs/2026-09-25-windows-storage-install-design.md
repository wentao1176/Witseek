# Witseek Windows Storage and Install Path Design

- **Date:** 2026-09-25
- **Status:** Updated per uninstall-path follow-up; implementation plan pending review
- **Target:** Next Windows release after v0.4.2
- **Repository:** `git@github.com:wentao1176/Witseek.git`

## Context

Witseek v0.4.2 is an Electron shell that starts the bundled official `dsh web` runtime. The shell's current Electron profile, dsh home, and default workspace are under `%APPDATA%\@witseek\desktop`. The updater keeps its downloaded installer under `%LOCALAPPDATA%\dsh-desktop-updater`; the current machine has a cached installer of about 164 MiB.

The user's ordinary dsh home already exists at `%USERPROFILE%\.dsh`. The old Witseek-specific `dsh-home` has a different credentials file, so merging it into the ordinary dsh home could silently change which API key Witseek uses.

The official [DeepSeek Harness Desktop](https://github.com/deepseek-ai/deepseek-harness/tree/master/apps/desktop) is an Electron shell around dsh Web. Its [desktop path resolver](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/src/paths.ts) gives Desktop an owned profile, and its [single-instance guard](https://github.com/deepseek-ai/deepseek-harness/blob/master/apps/desktop/src/single-instance.ts) runs before profile lifecycle work. Witseek will follow the data-ownership and startup-order ideas while keeping its existing bundled `dsh web` process, thin shell, and workspace preview. The upstream account, Host, plugin-manager, and mandatory-update layers are outside this change.

## Goals

1. Put Witseek's persistent dsh profile, credentials, settings, sessions, and default workspace under `%USERPROFILE%\.dsh`.
2. Put large runtime, browser-cache, and update-download files with the user-selected installation location.
3. Keep installation per-user and avoid administrator elevation, services, firewall changes, or machine-wide setup.
4. Preserve the Witseek Coding preset and the existing code, Markdown, and image preview.
5. Move the old Witseek dsh home without overwriting either its data or the user's ordinary `.dsh` home.
6. Keep the current GitHub Releases and electron-updater flow.

## Non-goals

- Replacing dsh or implementing another agent, tool, planning, or approval system.
- Porting the official Desktop Host, account service, mandatory-update policy, or plugin-management architecture.
- Moving user-selected project directories; those remain wherever the user chose them.
- Removing SmartScreen warnings without a trusted signing path.

## Design

### dsh and profile ownership

Use `%USERPROFILE%\.dsh\witseek` as Witseek's `DSH_HOME`. This keeps Witseek's existing API key and profile independent from the user's ordinary `%USERPROFILE%\.dsh` CLI home. The dsh profile remains under that Witseek-owned home, so the existing profile contents and plugin state can be migrated together.

Witseek continues to start the pinned official `dsh web` runtime and to let dsh own agent tools, planning, and permission approvals. The packaged Witseek Coding preset remains in the application resources and is exposed through the existing system-trusted preset root. The file preview continues to follow the active workspace.

### Windows directory layout

| Purpose | Path |
|---|---|
| Witseek dsh home, credentials, profiles, sessions, and default workspace | `%USERPROFILE%\.dsh\witseek` |
| Electron shell preferences and small app-owned state | `%USERPROFILE%\.dsh\witseek\electron` |
| Default workspace | `%USERPROFILE%\.dsh\witseek\workspace` |
| Default per-user installation | `%USERPROFILE%\.dsh\WitseekApp` |
| Browser session/cache, app temporary files, and updater staging | `path.resolve(installDir, '..', path.basename(installDir) + '-cache')` |

The installer keeps an editable install-directory page and defaults to `.dsh\WitseekApp`. A user may select another writable location. For an existing installation whose registry path is the previous default `%LOCALAPPDATA%\Programs\Witseek`, the installer switches the default to `.dsh\WitseekApp`; a user-chosen custom path remains selected. The cache directory follows the chosen install location and sits beside the directory NSIS replaces, so the full update installer is not stored on C: when Witseek is installed elsewhere and survives replacement of the application directory.

Set Electron's `userData` and `sessionData` paths before the app emits `ready`. Keep small shell state in `.dsh\witseek\electron`; route Chromium session data, updater downloads, and app-owned temporary files to the install-side cache directory. Pass the same temporary directory to the dsh child process. Windows may still use its own temporary and download locations for the setup file; these are outside Witseek's persistent data policy.

Configure the updater with its supported custom `AppAdapter` so its cache base is the install-side cache directory. Keep the current GitHub owner/repository, release assets, checksum validation, and full-installer update behavior.

### Per-user installation and uninstall

Keep the existing NSIS `RequestExecutionLevel user` and HKCU registration. Do not add services, startup tasks, firewall rules, or machine-wide registry writes. Validate that both the selected application directory and its install-side cache directory are writable by the current user; report a recoverable path error instead of requesting elevation.

Uninstall removes the application directory and its install-side cache directory. It preserves `%USERPROFILE%\.dsh\witseek`, including API keys, profiles, sessions, and workspace files.

### One-time data migration

Before creating or overriding Electron paths, inspect the old Electron `userData` path `%APPDATA%\@witseek\desktop`. Its `dsh-home` contains symbolic links, so recursively copying it can fail or require extra Windows privileges. If the old `dsh-home` exists, `%USERPROFILE%\.dsh\witseek` does not exist, and source and destination are on the same volume, atomically rename the old directory to the new location. This preserves links and contents without merging. Never move it into the ordinary `%USERPROFILE%\.dsh` root, merge credentials, or print credential contents to logs. If the old source is absent, use the existing new home or create it normally.

Apply the same same-volume rename rule to the old default workspace `%APPDATA%\@witseek\desktop\workspace`, moving it to `%USERPROFILE%\.dsh\witseek\workspace` only when that destination is absent. If either migration has conflicting source and destination paths, crosses volumes, or fails, do not copy, overwrite, or delete either tree. Show the affected paths in the recovery page with actions to open them and retry after the user resolves the conflict. Do not create the new dsh home or workspace before these decisions. Keep migrated data intact until the runtime reports ready; on startup failure, leave it in place and show the recovery page.

After dsh reports ready, atomically rename the remaining old Electron `userData` directory to a unique `legacy-desktop-backup-<timestamp>` directory under `%USERPROFILE%\.dsh\witseek`. This moves leftover settings and caches inside `.dsh` without deleting them. If the backup rename fails, leave the old directory untouched and report its path. Remove `%APPDATA%\@witseek` only with a non-recursive empty-directory removal; leave it if another product or file still exists there. After successful startup, also remove only the stale updater installer cache at `%LOCALAPPDATA%\dsh-desktop-updater`; the active updater cache follows the selected install location.

If the user selected a custom workspace through `WITSEEK_WORKSPACE`, continue using it and do not migrate or delete it. If the old default workspace does not exist, create `%USERPROFILE%\.dsh\witseek\workspace` on first launch.

### Icon and release package

Continue using the supplied Witseek whale artwork. The Windows setup executable, installed `Witseek.exe`, and generated shortcuts must show the Witseek icon. Verify each packaged icon after building.

Bump the desktop version for the next release after v0.4.2. Build the Windows x64 installer and matching `latest.yml` on the HNU development host; keep the GitHub Releases update target at `wentao1176/Witseek`.

The current installer is unsigned. This design keeps installation unprivileged but does not remove SmartScreen warnings. A trusted Authenticode certificate or a Microsoft Store distribution path is a separate requirement; a new or newly signed binary may still receive an initial SmartScreen warning.

## Acceptance criteria

- First launch uses `%USERPROFILE%\.dsh\witseek` for Witseek dsh data and does not change the ordinary `%USERPROFILE%\.dsh` home.
- Eligible old Witseek `dsh-home` and default workspace data move as same-volume renames; conflicts, cross-volume locations, and failures leave both copies untouched and expose a recovery path. Credential contents never appear in logs.
- After a successful start, remaining legacy Electron data moves under `.dsh\witseek\legacy-desktop-backup-*`; `%APPDATA%\@witseek` is removed only when empty. A failed backup move preserves and reports the old path.
- Electron preferences remain under `.dsh`; browser and updater caches follow the chosen installation location.
- Upgrade from the previous default install path selects the new `.dsh\WitseekApp` default; a user-selected custom install path remains selected.
- A path without current-user write access produces a clear error and never triggers UAC.
- NSIS installs per-user, and uninstall preserves Witseek dsh data while removing only program and install-side cache files.
- The dsh runtime, file preview, Coding preset, and GitHub auto-update remain available.
- Setup, installed executable, and shortcuts display the supplied Witseek icon.
- Packaging produces a Windows x64 installer and a matching `latest.yml` for the same version.
