# Witseek Agent Desktop Workflow Implementation Plan
> For agentic workers: use the executing-plans skill to implement this plan in order. Keep this plan current as work proceeds.

**Goal:** Ship a Witseek Coding preset and make the desktop file preview and read-only Git view follow the dsh session workspace.

**Architecture:** Keep official dsh as the agent runtime. Add a bundled dsh preset overlay and a small supported dsh web client extension. The extension reads the active session's public `cwd` from session-scoped standard props and sends it through a narrow Electron preload bridge. The main process owns the current workspace root, file access, and Git commands; the renderer stays sandboxed and read-only.

**Tech Stack:** Electron, TypeScript/Node.js, dsh Cordis plugin/preset APIs, IPC, Git CLI, Electron Builder.

**Spec:** `docs/superpowers/specs/2026-09-25-agent-desktop-workflow-design.md`

## Global Constraints
- Make all application and build changes in `/media/hnu/hnu2021/dengxin/xuanwentao/Witseek`.
- Keep dsh's existing approval and tool permissions unchanged; do not add desktop-side agent tools.
- Preserve existing code, Markdown, image, and file preview behavior.
- Do not mutate Git state from the desktop Git panel.
- Use the public dsh session-scoped slot props and session catalogue; do not scrape DOM, routes, or browser storage.

## Review Focus
- Verify workspace paths are absolute existing directories before switching the preview root.
- Ensure every file and diff IPC operation remains scoped to the active workspace and Git arguments are passed without a shell.
- Ensure unavailable Git or non-repository workspaces render a useful empty/error state.
- Ensure the new preset retains the upstream standard composition and changes only display metadata and workflow instructions.

---

## Tasks

1. **Add Witseek Coding preset and runtime overlay.** Copy the pinned Windows runtime's standard preset, add Witseek Coding metadata and a concise coding workflow, and configure dsh's existing `agent-presets` row with `default: witseek-coding` plus a bundled system root. Preserve shipped and user roots. Package the preset and overlay in `resources/runtime` and pass the overlay using dsh's supported `--patch` flag.
2. **Add supported dsh workspace bridge.** Create a small web client extension package, register a session-scoped component in an existing dsh slot, read the current session `cwd` from public standard props, and notify the Electron preload bridge only when the active path changes. Add the package to the dsh client roster and stage it into both the Windows build runtime and packaged runtime.
3. **Make preview root follow the active session.** Add a main-view preload API limited to setting the selected workspace. Validate the IPC sender and absolute directory, update the preview filesystem service's root, clear stale explicitly-picked file grants, and notify the preview renderer so it refreshes its tree and clears stale selection.
4. **Add read-only Git status and diff.** Expose bounded status and per-file diff IPC methods using `execFile` with fixed Git arguments and path separators. Show changed files, status markers, branch information, staged/unstaged diff, and untracked text in the existing sidebar while preserving its file preview mode.
5. **Update desktop version and release notes.** Set the desktop package version to `0.4.0`, retain the existing Witseek whale icon assets, and document the shipped workflow.
6. **Review implementation and compile the Windows installer.** Perform static review, run the existing typecheck/build/package commands needed to produce the installer, verify the `.exe` and `latest.yml` agree, then push through the supplied `wentao1176` SSH identity and publish the approved GitHub release.
