# Witseek Windows Storage and Installer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the approved Windows storage and install layout, then build and publish Witseek v0.4.3 with a working updater manifest.

**Architecture:** Keep dsh as the agent and approval owner. Configure Electron paths before readiness, migrate legacy profile/workspace directories by same-volume rename only, put bulky caches beside the selected installation, and keep the NSIS installer per-user. Retain the existing dsh process, file preview, Coding preset, supplied icon artwork, and GitHub Releases update flow.

**Tech Stack:** Electron 44, TypeScript, electron-updater 6, Python/NSIS, electron-builder, pnpm, GitHub Releases.

**Spec:** `docs/superpowers/specs/2026-09-25-windows-storage-install-design.md`

## Global Constraints

- Witseek dsh data stays in `%USERPROFILE%\.dsh\witseek`; Electron shell preferences stay in `%USERPROFILE%\.dsh\witseek\electron`.
- The default workspace stays in `%USERPROFILE%\.dsh\witseek\workspace`; preserve any explicit `WITSEEK_WORKSPACE` selection.
- The default per-user installation is `%USERPROFILE%\.dsh\WitseekApp`; keep the directory picker and preserve an existing custom install path.
- Derive install-side cache as `path.resolve(installDir, '..', path.basename(installDir) + '-cache')`.
- Keep NSIS `RequestExecutionLevel user`, HKCU registration, and no services, startup tasks, firewall rules, or machine-wide registry writes.
- Never merge credentials into the ordinary `%USERPROFILE%\.dsh` home or log credential contents.
- Keep the dsh-owned approval flow, Witseek Coding preset, file preview, supplied Witseek icon, GitHub update owner/repository, and full-installer updates.
- Do not add or run a test suite for this request; verify with TypeScript compilation and the requested Windows packaging outputs.
- The package remains unsigned unless a trusted signing certificate is configured; SmartScreen warnings may remain.

## Review Focus

- Old `dsh-home` contains symbolic links; only same-volume rename may migrate it, and failed/conflicting moves must leave both trees unchanged. **Task 1:** inspect migration branches, recovery actions, and post-start backup rename; ensure the code never falls back to recursive copy or recursive deletion.
- Old default workspace can contain user files; move only when the destination is absent and preserve explicit `WITSEEK_WORKSPACE`. **Task 1:** inspect both branches and the retry flow before packaging.
- A prior default install path must change to `.dsh\WitseekApp`, while a custom install path remains selected. **Task 3:** compile the generated NSIS script as part of packaging and inspect `.onInit` and registry behavior.
- electron-updater must use the install-side cache even when `userData` is under `.dsh`. **Task 2:** inspect the adapter wiring and packaged TypeScript output.
- The icon must reach the setup, installed executable, and shortcuts; manifest and installer versions must match. **Task 4:** inspect afterPack icon output, PE file type, and generated `latest.yml` fields.

---

### Task 1: Configure owned data paths and safe migration

**Files:**
- Create: `apps/desktop/src/main/storage.ts`
- Modify: `apps/desktop/src/main/paths.ts`
- Modify: `apps/desktop/src/main/index.ts`
- Modify: `apps/desktop/src/main/runtime.ts`
- Modify: `apps/desktop/src/preload/index.ts`
- Modify: `apps/desktop/resources/error.html`

**Interfaces:**
- `storage.ts` exports `DataMigrationIssue` with `source`, `destination`, and a reason (`destination-exists`, `different-volume`, or `move-failed`).
- `storage.ts` exports `DesktopStorage` with `data`, `cacheDir`, `legacyUserData`, `legacyUpdaterCacheDir`, and `migrationIssues`.
- `prepareDesktopStorage(): DesktopStorage` runs after the single-instance lock but before `app.whenReady()`. It resolves `%USERPROFILE%\.dsh\witseek`, computes the install-side cache, attempts same-volume renames for legacy `dsh-home` and default `workspace`, then calls `app.setPath('userData', ...)` and `app.setPath('sessionData', ...)` before Electron is ready.
- `finalizeLegacyUserData(storage): string | null` runs only after dsh reports ready; it renames the remaining old userData directory to a unique `legacy-desktop-backup-<timestamp>` under the Witseek dsh home and returns any preserved old path if the move fails.
- `DataLayout.dshHome` resolves to `%USERPROFILE%\.dsh\witseek`; `DataLayout.workspace` resolves to the new default or explicit `WITSEEK_WORKSPACE`.
- Migration conflicts are surfaced as startup state. Recovery actions open old/new data and workspace directories; retry relaunches the app so path selection and migration run again before readiness.

- [ ] Compute legacy paths from Electron `appData`, the user home, and the packaged executable directory without creating the destination first.
- [ ] Rename a legacy directory only when the source exists, destination is absent, and path roots match; return an issue for collisions, cross-volume paths, and rename errors.
- [ ] Keep credentials and profile data in the moved dsh home; do not merge or copy directory contents.
- [ ] Configure Electron `userData` and `sessionData` before `ready`; only create dsh/workspace directories after migration has no unresolved issue.
- [ ] Add legacy-folder open actions and relaunch-based retry to the existing recovery page, keeping error messages limited to paths and failure reasons.
- [ ] Pass the cache path as `TEMP` and `TMP` to the dsh child process. After dsh first reports ready, rename remaining old userData into a unique `.dsh\witseek\legacy-desktop-backup-*` directory without deleting its contents; remove `%APPDATA%\@witseek` only if it is empty, and remove only `%LOCALAPPDATA%\dsh-desktop-updater` as a stale download cache. If the backup move fails, preserve and report the old path.
- [ ] Run `pnpm --filter @witseek/desktop typecheck` from the repository root. Expected: exit 0 with no TypeScript diagnostics.

### Task 2: Route update downloads to the install-side cache

**Files:**
- Modify: `apps/desktop/src/main/updater.ts`
- Modify: `apps/desktop/src/main/index.ts`
- Modify: `apps/desktop/src/main/storage.ts` only if the cache path interface needs adjustment.

**Interfaces:**
- Change `setupUpdater(getWin)` to `setupUpdater(getWin, cacheDir)`.
- Construct `NsisUpdater` with an `AppAdapter` whose `baseCachePath` is the resolved `DesktopStorage.cacheDir`; keep `userDataPath` at the Electron shell-data directory and retain the existing GitHub feed.

- [ ] Replace the global default-cache updater with `NsisUpdater` and a custom app adapter using the resolved cache directory.
- [ ] Keep automatic/manual update messages, checksum validation, full NSIS installer downloads, and `wentao1176/Witseek` unchanged.
- [ ] Run `pnpm --filter @witseek/desktop typecheck` from the repository root. Expected: exit 0 with no TypeScript diagnostics.

### Task 3: Move NSIS defaults and cleanup with the selected install directory

**Files:**
- Modify: `scripts/make_nsis.py`

**Interfaces:**
- The installer default becomes `$PROFILE\.dsh\WitseekApp`.
- `.onInit` reads the previous HKCU install path: redirect the exact old default `$LOCALAPPDATA\Programs\Witseek` to the new default; keep any other recorded custom path.
- The installer and application derive the same sibling cache path. Reject installation and uninstall paths, including the derived cache path, that equal, contain, or sit inside the registered dsh home or workspace. Accept only empty install directories or the registered current Witseek install. Uninstall removes only packaged files and empty directories; remove a cache only when its recorded path matches the current derived sibling, its ownership flag is set, and it does not overlap protected data.

- [ ] Remove the old unconditional `InstallDirRegKey` behavior and add deterministic `.onInit` handling for the old default versus custom path.
- [ ] Preserve `RequestExecutionLevel user`, HKCU-only registration, the editable directory page, and the Witseek icon on shortcuts.
- [ ] Record the derived cache path and ownership for uninstall; delete it only when both still match the current install and the cache does not overlap protected data. Store resolved dsh home/workspace paths; reject install/cache overlap and accept only a new empty directory or the registered Witseek install path.
- [ ] Generate exact file removals from the packaged payload; remove directories non-recursively from deepest to shallowest so extra user files survive uninstall and old-default cleanup.
- [ ] Build the NSIS output in Task 4. Expected: `makensis` exits 0 and the script contains the `.dsh\WitseekApp` default and per-user execution level.

### Task 4: Refresh the supplied icon, version, docs, and Windows package

**Files:**
- Modify: `apps/desktop/package.json`
- Modify: `apps/desktop/afterPack.cjs`
- Modify: `scripts/pack_windows.sh`
- Modify: `README.md`
- Create: `docs/release-v0.4.3.md`
- Generated by the build: `artifacts/Witseek-Setup-0.4.3.exe`, `artifacts/latest.yml`

- [ ] Set the desktop version to `0.4.3`.
- [ ] Regenerate PNG/ICO assets from `assets/source/Witseek.jpg` into `assets/icons` and `apps/desktop/resources` as part of every Windows package build; make `afterPack.cjs` fail if the icon input or Windows main icon group is missing.
- [ ] Update README data/install paths and document the unsigned-installer SmartScreen limitation.
- [ ] Write concise Chinese release notes for v0.4.3 covering storage migration, install/cache locations, icon, preview/preset retention, and automatic updates.
- [ ] Run `pnpm --filter @witseek/desktop typecheck` and `bash scripts/pack_windows.sh` from the repository root. Expected: both commands exit 0; packaging produces the version-matched x64 setup and `latest.yml`.
- [ ] Inspect `file artifacts/Witseek-Setup-0.4.3.exe`, the setup size and digest, generated icon replacement output, and `latest.yml` version, filename, size, and SHA-512 values. Expected: the NSIS bootstrap is a PE32 installer and the bundled Witseek application is PE32+ x86-64; manifest values match the generated file exactly.

### Task 5: Commit, push, and publish v0.4.3

**Files:**
- Commit source and documentation changes on `main` as `wentao1176`.
- Publish `artifacts/Witseek-Setup-0.4.3.exe` and `artifacts/latest.yml` to `wentao1176/Witseek` release tag `v0.4.3`.

- [ ] Confirm the Git author is `wentao1176` and review the complete diff and generated manifest before publishing.
- [ ] Push the verified `main` commits to `origin`.
- [ ] Publish tag `v0.4.3` from the authenticated GitHub UI because the build host has no GitHub CLI token; attach the setup and `latest.yml` built from the same commit, using `docs/release-v0.4.3.md` as the release notes.
- [ ] Confirm the remote release assets are present and report the installer link, version, size, and unsigned status.
