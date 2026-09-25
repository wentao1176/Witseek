# Witseek Agent Desktop Workflow Design

**Date:** 2026-09-25
**Status:** Draft for user review
**Scope:** Witseek desktop workflow and its integration with the bundled official dsh runtime

## Context

Witseek is an Electron desktop shell around the official dsh runtime. dsh owns agent planning, tools, profiles, plugins, and approval behavior. Witseek already provides a workspace file tree and file previews. Today the preview file service is rooted at Witseek's configured workspace, while dsh can change the active session workspace; those views can therefore disagree.

The shipped dsh profile system already provides the coding tools and permission controls needed for this workflow. Witseek should guide those capabilities and keep its own workspace views in sync instead of recreating an agent runtime or forking dsh's bundled web application.

## Goals

1. Add a Witseek Coding preset for programming tasks. It guides the agent to read project instructions, plan multi-step work, operate in the active workspace through dsh tools, respect dsh approvals, and summarize changed files and verification results.
2. Keep the Witseek file tree and code, Markdown, and image previews bound to the active dsh session workspace.
3. Add a Git review view in the same side pane. It shows repository status and read-only diffs for the active workspace.
4. Preserve dsh as the sole agent and permission authority. Make workspace boundaries clear and handle directories without Git gracefully.

## Non-goals

- Replacing or forking the official dsh agent runtime or bundled web UI.
- Implementing a second planning, shell, file-editing, or approval system in Witseek.
- Running Git mutations from the review view (including stage, commit, checkout, reset, or push).
- Automatically widening a session's workspace to a parent directory or another repository.
- Upgrading the pinned dsh runtime as part of this feature.

## Design

### Witseek Coding preset

Provide a Witseek-owned coding profile/preset using dsh's supported profile and plugin configuration. It should instruct the agent to:

- Read the repository's applicable `AGENTS.md`, `CLAUDE.md`, and other project instructions before editing.
- Summarize the task and make a concise step plan for work that spans multiple files or actions.
- Use dsh's existing file and command tools within the active workspace, and follow dsh's configured approval prompts.
- Avoid unrelated edits, report material assumptions, and finish with a concise summary of changed files and checks actually performed.

Make the preset available to Witseek sessions without overwriting a user's existing dsh profiles or permissions. dsh remains responsible for each tool call and approval.

### Active workspace synchronization

Treat the workspace selected by the active dsh session as the source of truth. Witseek obtains workspace changes through a supported dsh API, event, or plugin bridge. It must not infer workspace state by scraping or depending on private DOM details in dsh's bundled page.

When the active session changes its workspace, Witseek updates the file tree, preview file service, and Git view together. Resolve and validate the reported directory before exposing it to filesystem operations. If the workspace is unavailable or invalid, show a recoverable empty/error state and do not silently fall back to a broader path. The existing Witseek workspace setting can serve as the initial workspace when starting a new session.

The implementation plan must identify the concrete supported dsh interface and how it is kept compatible with the pinned runtime. If no supported interface can provide the active workspace, stop and surface that integration gap for a design decision; do not add DOM scraping as a fallback.

### File tree and preview

Keep the existing side-pane file tree and code, Markdown, and image preview behavior. The selected file must resolve beneath the active workspace and preview updates must follow workspace changes. Preserve current size/type protections and show useful errors for inaccessible or unsupported files.

### Git status and diff

Add a Git review view in the same side pane, alongside the file tree/preview. Scope it to the active workspace and display changed, untracked, staged, and unstaged files where Git can report them. Selecting a change opens a read-only diff. Binary or unavailable diffs receive a clear explanation.

The review view must not execute write operations. If the workspace is not a Git repository, Git is unavailable, or a status/diff operation fails, keep the file preview usable and show a concise, recoverable Git state. Refresh the view after workspace changes and on an explicit user refresh; avoid polling that creates unnecessary process load.

## Acceptance criteria

- A Witseek Coding preset is selectable/used by Witseek and reads project guidance, plans multi-step coding work, stays in dsh's active workspace, honors dsh approvals, and reports its changes.
- Existing dsh user profiles and permission settings are preserved.
- The file tree, code/Markdown/image preview, and Git review all follow the active dsh workspace.
- Git status includes staged, unstaged, and untracked changes; a selected text change displays a read-only diff.
- A non-repository workspace or Git error does not disable file browsing or crash the desktop UI.
- The review view cannot stage or otherwise mutate repository state, and workspace changes never broaden file access silently.
- The implementation uses a supported dsh integration point and does not depend on private DOM scraping.
