#!/usr/bin/env python3
# make_nsis.py —— 由 electron-builder 的 win-unpacked 目录生成 NSIS 安装脚本
#
# 服务器无 Wine，electron-builder 内置 NSIS target 需要 wine 运行 32 位 makensis.exe。
# 本项目改为：electron-builder --win dir 产出 win-unpacked（afterPack 已用 resedit
# 改好 exe 图标/版本），再用 conda-forge 的【Linux 原生 makensis】编译本脚本生成的
# 零第三方插件 .nsi，得到正规 Windows 向导安装程序（per-user、免 UAC、带快捷方式与卸载器）。
#
# 内置的 dsh 运行时包含海量小文件，因此顶层文件逐个 File、顶层目录用原生
# `File /r <dir>/*` 递归打包，避免数万条 File 指令。仅用 NSIS 内置指令，不依赖
# 任何在 Linux makensis 下无法加载的 Windows 插件 DLL。
#
# 注意：本文件所有含 Windows 路径（反斜杠）的 NSIS 行一律使用【普通 Python 字符串】，
# 反斜杠写作 "\\"；不要用 r'' 原始字符串，以免单反斜杠/双反斜杠口径混乱。
#
# 用法：
#   python3 scripts/make_nsis.py --src artifacts/win-unpacked \
#       --ico apps/desktop/resources/icon.ico --nsi artifacts/witseek.nsi \
#       --setup /abs/path/Witseek-Setup-x.y.z.exe --version 0.2.0
import argparse
from pathlib import Path


def nsis_quote(s: str) -> str:
    return '"' + str(s).replace('"', '$\\"') + '"'


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="win-unpacked 目录")
    ap.add_argument("--ico", required=True, help="安装程序/卸载程序图标 ico")
    ap.add_argument("--nsi", required=True, help="输出 .nsi 路径")
    ap.add_argument("--setup", required=True, help="输出 setup exe 的绝对路径(Linux)")
    ap.add_argument("--version", default="0.2.0")
    ap.add_argument("--app", default="Witseek")
    args = ap.parse_args()

    src = Path(args.src).resolve()
    ico = Path(args.ico).resolve()
    nsi = Path(args.nsi).resolve()
    setup = args.setup
    app = args.app

    ver_parts = args.version.split(".")
    while len(ver_parts) < 4:
        ver_parts.append("0")
    ver4 = ".".join(ver_parts[:4])

    top_files = sorted(p for p in src.iterdir() if p.is_file())
    top_dirs = sorted(p for p in src.iterdir() if p.is_dir())
    if not top_files and not top_dirs:
        raise SystemExit(f"win-unpacked 内没有文件: {src}")

    uninst_key = r"Software\Microsoft\Windows\CurrentVersion\Uninstall\Witseek"
    inst_dir = r"$PROFILE\.dsh\WitseekApp"
    exe_path = r"$INSTDIR\Witseek.exe"
    uninst_path = r"$INSTDIR\Uninstall Witseek.exe"
    sm_dir = r"$SMPROGRAMS\Witseek"
    sm_lnk = r"$SMPROGRAMS\Witseek\Witseek.lnk"
    sm_uninst_lnk = r"$SMPROGRAMS\Witseek\卸载 Witseek.lnk"
    desktop_lnk = r"$DESKTOP\Witseek.lnk"

    lines = []
    a = lines.append

    a("; ============================================================")
    a("; witseek.nsi —— 由 make_nsis.py 自动生成，请勿手改")
    a("; Linux 原生 makensis 编译，零第三方插件，per-user(免 UAC) 安装")
    a("; ============================================================")
    a("Unicode true")
    a("SetCompressor /SOLID lzma")
    a("ManifestDPIAware true")
    a("")
    a('!include "MUI2.nsh"')
    a('!include "FileFunc.nsh"')
    a("")
    a("Var InstallCacheDir")
    a("Var CacheParent")
    a("Var CacheName")
    a("Var ExpectedCacheDir")
    a("Var ProbeDir")
    a("Var ProbePath")
    a("Var ProbeSuffix")
    a("Var ProbeHandle")
    a("Var ProbeWritable")
    a("")
    a(f'Name "{app}"')
    a(f"OutFile {nsis_quote(setup)}")
    a(f'InstallDir "{inst_dir}"')
    a("RequestExecutionLevel user")
    a("ShowInstDetails hide")
    a("ShowUninstDetails hide")
    a("")
    a(f"!define MUI_ICON {nsis_quote(str(ico))}")
    a(f"!define MUI_UNICON {nsis_quote(str(ico))}")
    a("!define MUI_ABORTWARNING")
    a("")
    a(f'VIProductVersion "{ver4}"')
    a(f'VIFileVersion "{ver4}"')
    for lang in (2052, 1033):
        a(f'VIAddVersionKey /LANG={lang} "ProductName" "{app}"')
        a(f'VIAddVersionKey /LANG={lang} "FileDescription" "{app} Setup"')
        a(f'VIAddVersionKey /LANG={lang} "CompanyName" "{app}"')
        a(f'VIAddVersionKey /LANG={lang} "LegalCopyright" "Copyright (C) 2026 {app}"')
        a(f'VIAddVersionKey /LANG={lang} "ProductVersion" "{args.version}"')
        a(f'VIAddVersionKey /LANG={lang} "FileVersion" "{args.version}"')
    a("")
    a("!insertmacro MUI_PAGE_WELCOME")
    a("!define MUI_PAGE_CUSTOMFUNCTION_LEAVE ValidateInstallDir")
    a("!insertmacro MUI_PAGE_DIRECTORY")
    a("!insertmacro MUI_PAGE_COMPONENTS")
    a("!insertmacro MUI_PAGE_INSTFILES")
    a(f'!define MUI_FINISHPAGE_RUN "{exe_path}"')
    a("!insertmacro MUI_PAGE_FINISH")
    a("!insertmacro MUI_UNPAGE_CONFIRM")
    a("!insertmacro MUI_UNPAGE_INSTFILES")
    a('!insertmacro MUI_LANGUAGE "SimpChinese"')
    a('!insertmacro MUI_LANGUAGE "English"')
    a("")

    a("Function .onInit")
    a(f'  StrCpy $INSTDIR "{inst_dir}"')
    a(r'  ReadRegStr $0 HKCU "Software\Witseek" ""')
    a(r'  StrCmp $0 "" init_done')
    a(r'  StrCmp $0 "$LOCALAPPDATA\Programs\Witseek" init_done')
    a(r"  StrCpy $INSTDIR $0")
    a("init_done:")
    a("FunctionEnd")
    a("")

    a("Function ComputeInstallCacheDir")
    a(r'  ${GetParent} "$INSTDIR" $CacheParent')
    a(r'  ${GetFileName} "$INSTDIR" $CacheName')
    a(r'  StrCpy $InstallCacheDir "$CacheParent\$CacheName-cache"')
    a("FunctionEnd")
    a("")

    a("Function TestProbeDirWritable")
    a(r'  IfFileExists "$ProbeDir\." probe_dir_exists')
    a("  ClearErrors")
    a(r'  CreateDirectory "$ProbeDir"')
    a("  IfErrors probe_not_writable")
    a("probe_dir_exists:")
    a(r'  StrCpy $ProbePath "$ProbeDir\.witseek-write-check-$HWNDPARENT"')
    a("  StrCpy $ProbeSuffix 0")
    a("probe_choose_name:")
    a(r'  IfFileExists "$ProbePath" probe_next_name probe_open')
    a("probe_next_name:")
    a("  IntOp $ProbeSuffix $ProbeSuffix + 1")
    a(r'  StrCpy $ProbePath "$ProbeDir\.witseek-write-check-$HWNDPARENT-$ProbeSuffix"')
    a("  Goto probe_choose_name")
    a("probe_open:")
    a("  ClearErrors")
    a(r'  FileOpen $ProbeHandle "$ProbePath" w')
    a("  IfErrors probe_not_writable")
    a("  FileClose $ProbeHandle")
    a(r'  Delete "$ProbePath"')
    a(r'  IfFileExists "$ProbePath" probe_not_writable')
    a(r'  StrCpy $ProbeWritable "1"')
    a("  Return")
    a("probe_not_writable:")
    a(r'  StrCpy $ProbeWritable "0"')
    a("FunctionEnd")
    a("")

    a("Function ValidateInstallDir")
    a("  Call ComputeInstallCacheDir")
    a(r'  StrCpy $ProbeDir "$INSTDIR"')
    a("  Call TestProbeDirWritable")
    a(r'  StrCmp $ProbeWritable "1" install_dir_writable')
    a("  Goto install_dir_not_writable")
    a("install_dir_writable:")
    a(r'  StrCpy $ProbeDir "$InstallCacheDir"')
    a("  Call TestProbeDirWritable")
    a(r'  StrCmp $ProbeWritable "1" cache_dir_writable')
    a("  Goto cache_dir_not_writable")
    a("cache_dir_writable:")
    a("  Return")
    a("install_dir_not_writable:")
    a('  MessageBox MB_ICONSTOP|MB_OK "无法写入所选安装目录。请选择当前用户可写的位置；Witseek 不会请求管理员权限。"')
    a("  Abort")
    a("cache_dir_not_writable:")
    a('  MessageBox MB_ICONSTOP|MB_OK "无法写入安装目录旁的缓存目录。请选择当前用户可写的位置；Witseek 不会请求管理员权限。"')
    a("  Abort")
    a("FunctionEnd")
    a("")

    # ---- 安装：核心文件 ----
    a('Section "Witseek 核心文件（必需，含 DeepSeek Harness 运行时）" SecCore')
    a("SectionIn RO")
    a("  Call ComputeInstallCacheDir")
    a(r'  SetOutPath "$INSTDIR"')
    for f in top_files:
        a(f"  File {nsis_quote(str(f))}")
    for d in top_dirs:
        a(f'  SetOutPath "$INSTDIR\\{d.name}"')
        a(f"  File /r {nsis_quote(str(d) + '/*')}")
    a("")
    a(r'  SetOutPath "$INSTDIR"')
    a(f'  WriteUninstaller "{uninst_path}"')
    a(r'  WriteRegStr HKCU "Software\Witseek" "CacheDir" "$InstallCacheDir"')
    a(r'  WriteRegStr HKCU "Software\Witseek" "" "$INSTDIR"')
    a(f'  WriteRegStr HKCU "{uninst_key}" "DisplayName" "{app}"')
    a(f'  WriteRegStr HKCU "{uninst_key}" "DisplayVersion" "{args.version}"')
    a(f'  WriteRegStr HKCU "{uninst_key}" "Publisher" "{app}"')
    a(f'  WriteRegStr HKCU "{uninst_key}" "InstallLocation" "$INSTDIR"')
    a(f'  WriteRegStr HKCU "{uninst_key}" "DisplayIcon" "{exe_path}"')
    # NSIS 字符串可用单引号定界，便于内含空格、双引号
    a(f"  WriteRegStr HKCU \"{uninst_key}\" \"UninstallString\" '{uninst_path}'")
    a(f"  WriteRegStr HKCU \"{uninst_key}\" \"QuietUninstallString\" '{uninst_path} /S'")
    a(f'  WriteRegDWORD HKCU "{uninst_key}" "NoModify" 1')
    a(f'  WriteRegDWORD HKCU "{uninst_key}" "NoRepair" 1')
    a("")
    a(f'  CreateDirectory "{sm_dir}"')
    a(f'  CreateShortcut "{sm_lnk}" "{exe_path}" "" "{exe_path}" 0')
    a(f'  CreateShortcut "{sm_uninst_lnk}" "{uninst_path}"')
    a("SectionEnd")
    a("")

    # ---- 安装：可选桌面快捷方式 ----
    a('Section "桌面快捷方式" SecDesktop')
    a(f'  CreateShortcut "{desktop_lnk}" "{exe_path}" "" "{exe_path}" 0')
    a("SectionEnd")
    a("")
    a("!insertmacro MUI_FUNCTION_DESCRIPTION_BEGIN")
    a('  !insertmacro MUI_DESCRIPTION_TEXT ${SecCore} "安装 Witseek 与内置 DeepSeek Harness 运行时的全部程序与资源文件（必需）。"')
    a('  !insertmacro MUI_DESCRIPTION_TEXT ${SecDesktop} "在 Windows 桌面创建 Witseek 快捷方式。"')
    a("!insertmacro MUI_FUNCTION_DESCRIPTION_END")
    a("")

    # ---- 卸载 ----
    a("Section Uninstall")
    a(r'  ReadRegStr $InstallCacheDir HKCU "Software\Witseek" "CacheDir"')
    a(r'  ${GetParent} "$INSTDIR" $CacheParent')
    a(r'  ${GetFileName} "$INSTDIR" $CacheName')
    a(r'  StrCpy $ExpectedCacheDir "$CacheParent\$CacheName-cache"')
    a(r'  StrCmp $InstallCacheDir $ExpectedCacheDir cache_path_ready')
    a(r'  StrCpy $InstallCacheDir $ExpectedCacheDir')
    a("cache_path_ready:")
    a(r'  RMDir /r "$InstallCacheDir"')
    a(f'  Delete "{desktop_lnk}"')
    a(f'  Delete "{sm_lnk}"')
    a(f'  Delete "{sm_uninst_lnk}"')
    a(f'  RMDir "{sm_dir}"')
    a(r'  RMDir /r "$INSTDIR"')
    a(f'  DeleteRegKey HKCU "{uninst_key}"')
    a(r'  DeleteRegKey HKCU "Software\Witseek"')
    a("SectionEnd")
    a("")

    nsi.parent.mkdir(parents=True, exist_ok=True)
    nsi.write_text("\n".join(lines), encoding="utf-8")
    print(f"[make_nsis] 写入 {nsi}")
    print(f"[make_nsis] 顶层文件 {len(top_files)} 个，递归目录 {len(top_dirs)} 个："
          + ", ".join(d.name for d in top_dirs))
    print(f"[make_nsis] 目标安装程序: {setup}")


if __name__ == "__main__":
    main()
