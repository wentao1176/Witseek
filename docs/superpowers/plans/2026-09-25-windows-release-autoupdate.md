# Witseek Windows Release and Auto-Update Plan
> For agentic workers: use the executing-plans skill to implement this plan in order. Keep this plan current as work proceeds.

**Goal:** Produce and publish Witseek Desktop v0.4.0 as a Windows installer with the existing whale icon and GitHub electron-updater metadata.

**Architecture:** Keep the existing Linux-hosted, Windows-x64 packaging pipeline. The package includes the Electron shell, pinned official dsh runtime, Witseek preset/client extension resources, the Windows Node runtime, and the NSIS installer. Publish the installer and `latest.yml` to the stable GitHub Release configured in electron-updater.

**Tech Stack:** pnpm, electron-vite, electron-builder, NSIS, Python release scripts, GitHub Releases, SSH.

**Spec:** `docs/superpowers/specs/2026-09-25-windows-release-auto-update-design.md`

## Global Constraints
- Build and publish from the canonical hnu checkout.
- Keep Git author and transport identity as `wentao1176`; use `/home/dengxin/.ssh/id_ed25519_XWT` with `IdentitiesOnly=yes` for SSH Git operations.
- Preserve the existing whale icon source and generation pipeline.
- Keep the stable updater owner/repository aligned with `wentao1176/Witseek`.

## Review Focus
- Confirm packaged runtime contains the preset, patch, dsh web extension, and expected Windows-native dependencies.
- Confirm the release installer filename and `latest.yml` version/hash/size match.
- Confirm uploaded release assets include both the installer and `latest.yml` and release notes describe v0.4.0.

---

## Tasks

1. Bump `apps/desktop/package.json` to `0.4.0` and add release notes.
2. Build the Windows runtime and NSIS installer using `scripts/pack_windows.sh`.
3. Inspect the installer and update manifest and verify the existing icon is embedded.
4. Push the source changes to `wentao1176/Witseek` using the provided SSH key.
5. Create stable GitHub Release `v0.4.0` and upload the installer plus `latest.yml`.
