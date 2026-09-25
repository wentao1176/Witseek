# Witseek Windows Release and Auto-Update Design

**Date:** 2026-09-25
**Status:** Draft for user review
**Target release:** v0.4.0
**Repository:** `git@github.com:wentao1176/Witseek.git`

## Context

The hnu checkout is the development source of truth. Witseek already has a Windows packaging path, a GitHub Releases publisher, an `electron-updater` configuration targeting `wentao1176/Witseek`, and an existing whale artwork source at `assets/source/Witseek.jpg`. No GitHub Release currently exists, so the updater has no published installer metadata to consume yet.

## Goals

1. Synchronize the reviewed Witseek source changes from the hnu checkout to the target GitHub repository.
2. Package a Windows x64 installer as v0.4.0 using the existing build and icon pipelines.
3. Publish the installer and matching `latest.yml` together in the v0.4.0 GitHub Release so installed copies can discover updates through `electron-updater`.
4. Keep signing or publishing credentials outside source control and build artifacts.

## Non-goals

- Changing the update hosting service or introducing a separate update server.
- Publishing a prerelease, a second architecture, or unrelated platform installers.
- Replacing the existing whale artwork with newly generated art.
- Committing secrets, access tokens, or private signing keys.

## Design

### Source synchronization

Develop and package from `/media/hnu/hnu2021/dengxin/xuanwentao/Witseek` on hnu. Commit the approved source and release metadata there, then push those commits to `git@github.com:wentao1176/Witseek.git`. Keep the repository's existing main-branch workflow and avoid copying a stale local staging snapshot over the server checkout.

### Version and icon

Set the desktop application version to `0.4.0` and add release notes describing the agent workflow, workspace-aware file preview, Git review, and update packaging. Generate the Windows `.ico` and packaged PNG assets from the existing `assets/source/Witseek.jpg` using `scripts/make_icons.py`; keep the source artwork and current rounded whale treatment.

### Build artifacts

Run the existing hnu Windows packaging script, `scripts/pack_windows.sh`, from the repository checkout. The deliverable is the Windows x64 setup executable and the `latest.yml` generated for that exact installer/version. Preserve the package's existing artifact names and metadata expected by `electron-updater`; do not hand-edit the generated updater metadata.

### GitHub Release and updater

Create the `v0.4.0` GitHub Release as the latest stable release, using the repository's existing publishing path. Upload the Windows setup executable and its matching `latest.yml` to that same release. The metadata must identify the uploaded installer and its computed SHA-512 checksum. Retain the existing updater repository target and confirm the asset names and release channel match the packaged application's configuration before publication.

The release is complete only after both assets are visible on the target repository's v0.4.0 release. No credential or private key may be added to Git, release notes, or packaged resources.

## Acceptance criteria

- The intended source commits are on `main` in `git@github.com:wentao1176/Witseek.git`.
- Desktop version metadata and release notes identify v0.4.0.
- The packaged executable contains the existing Witseek whale icon derived from `assets/source/Witseek.jpg`.
- The hnu packaging path produces a Windows x64 setup executable and a `latest.yml` that references that executable and its matching SHA-512.
- The GitHub v0.4.0 release is latest/stable and contains both matching assets.
- The existing `electron-updater` configuration targets the release where these assets were published.
- No publishing credential or signing key is committed or bundled.
