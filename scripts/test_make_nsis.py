import subprocess
import sys
import tempfile
import unittest
import re
from pathlib import Path


class MakeNsisTests(unittest.TestCase):
    def test_checks_every_packaged_path_for_reparse_points_before_install_and_removal(self):
        project_root = Path(__file__).resolve().parent.parent
        with tempfile.TemporaryDirectory(prefix="witseek-nsis-test-") as temp:
            root = Path(temp)
            source = root / "win-unpacked"
            nested = source / "resources" / "runtime" / "nested"
            nested.mkdir(parents=True)
            (source / "Witseek.exe").write_bytes(b"exe")
            (nested / "node.exe").write_bytes(b"node")
            icon = root / "icon.ico"
            icon.write_bytes(b"ico")
            nsi = root / "witseek.nsi"

            subprocess.run(
                [
                    sys.executable,
                    str(project_root / "scripts" / "make_nsis.py"),
                    "--src", str(source),
                    "--ico", str(icon),
                    "--nsi", str(nsi),
                    "--setup", str(root / "setup.exe"),
                    "--version", "0.4.5",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            generated = nsi.read_text(encoding="utf-8")

            # NSIS labels are scoped to a Function. Generated loops must not
            # reuse a terminal label, or makensis rejects the whole installer.
            current_function = None
            labels_by_function = {}
            for line in generated.splitlines():
                function_match = re.match(r"^Function(?:\s+)(\S+)", line)
                if function_match:
                    current_function = function_match.group(1)
                    labels_by_function[current_function] = set()
                    continue
                if line == "FunctionEnd":
                    current_function = None
                    continue
                label_match = re.match(r"^([A-Za-z_][A-Za-z0-9_.]*)\s*:", line)
                if current_function and label_match:
                    label = label_match.group(1)
                    self.assertNotIn(
                        label,
                        labels_by_function[current_function],
                        f"duplicate label {label!r} in {current_function}",
                    )
                    labels_by_function[current_function].add(label)

            self.assertIn("Function CheckPayloadReparse", generated)
            self.assertIn("Function un.CheckPayloadReparse", generated)
            self.assertIn('GetFullPathName $NormalizedPath "$PathToNormalize\\"', generated)
            self.assertEqual(generated.count("GetFullPathName"), 2)
            self.assertIn("Function NormalizeDirectoryPath", generated)
            self.assertIn("Function un.NormalizeDirectoryPath", generated)
            self.assertIn('StrCmp $PathNormalizeFailed "0" 0 install_path_invalid', generated)
            self.assertIn('StrCmp $PathNormalizeFailed "0" 0 uninstall_path_invalid', generated)
            self.assertLess(
                generated.index('StrCpy $INSTDIR "$NormalizedInstallDir"'),
                generated.index('  Call ComputeInstallCacheDir', generated.index("Function ValidateInstallDir")),
            )
            self.assertIn(
                'StrCpy $PathCandidate "$CleanupDir\\resources\\runtime\\nested"',
                generated,
            )
            self.assertIn(
                'StrCpy $PathCandidate "$CleanupDir\\resources\\runtime\\nested\\node.exe"',
                generated,
            )
            self.assertIn("Function CheckPathSelfReparse", generated)
            self.assertIn(
                r'$\r$\n安装目录：$NormalizedInstallDir',
                generated,
            )
            self.assertIn(
                r'$\r$\n更新缓存：$NormalizedCacheDir',
                generated,
            )
            self.assertIn(
                r'$\r$\ndsh 数据：$ProtectedDshHome',
                generated,
            )
            self.assertIn(
                r'$\r$\n工作区：$ProtectedWorkspaceDir',
                generated,
            )
            self.assertIn('可以自定义安装路径', generated)
            self.assertIn(
                'StrCpy $PathCandidate "$CleanupDir\\Uninstall Witseek.exe"',
                generated,
            )
            self.assertIn('Delete "$INSTDIR\\Uninstall Witseek.exe"', generated)
            self.assertIn('StrCpy $PathCandidate "$CleanupDir\\Witseek.exe"', generated)
            self.assertIn('StrCmp $PathHasReparse "0" uninstall_path_data_safe', generated)
            self.assertIn('IfErrors reparse_attribute_failed', generated)
            self.assertIn('StrCpy $PathHasReparse "2"', generated)
            installer_section = generated[generated.index('Section "Witseek 核心文件'):]
            self.assertLess(installer_section.index('Call ValidateInstallDir'), installer_section.index('File /r'))
            self.assertLess(
                installer_section.index('Call PreparePayloadFilesForInstall'),
                installer_section.index('File /r'),
            )
            self.assertIn(
                'Delete "$INSTDIR\\resources\\runtime\\nested\\node.exe"',
                generated,
            )
            self.assertIn('IfErrors install_payload_delete_failed', generated)
            self.assertIn(
                'IfFileExists "$INSTDIR\\resources\\app.asar" '
                'existing_install_marker check_install_recovery_marker',
                generated,
            )
            self.assertIn(
                'ReadRegStr $InstallInProgressDir HKCU "Software\\Witseek" "InstallInProgress"',
                generated,
            )
            self.assertIn('Var ExistingWitseekInstall', generated)
            self.assertIn(
                'StrCmp $ExistingWitseekInstall "1" install_prepare_existing_files',
                generated,
            )
            empty_check_start = generated.index("Function CheckInstallDirEmpty")
            empty_check_end = generated.index("FunctionEnd", empty_check_start)
            empty_check = generated[empty_check_start:empty_check_end]
            self.assertIn(
                'IfFileExists "$INSTDIR\\." install_dir_exists install_dir_empty_done',
                empty_check,
            )
            self.assertIn('IfErrors install_dir_enumeration_failed', empty_check)
            self.assertIn('StrCpy $InstallDirEmpty "2"', empty_check)
            self.assertIn('StrCmp $InstallDirEmpty "1" install_recovery_directory_empty', generated)
            self.assertIn('Goto install_dir_contains_other_files', generated)
            self.assertIn('Var PayloadRemovalFailed', generated)
            self.assertIn('StrCpy $PayloadRemovalFailed "1"', generated)
            self.assertLess(
                installer_section.rindex('File /r'),
                installer_section.index('Delete "$INSTDIR\\Uninstall Witseek.exe"'),
            )
            self.assertLess(
                installer_section.index('Delete "$INSTDIR\\Uninstall Witseek.exe"'),
                installer_section.index('WriteUninstaller'),
            )
            self.assertLess(
                installer_section.index('WriteRegStr HKCU "Software\\Witseek" "InstallInProgress"'),
                installer_section.index('Call PreparePayloadFilesForInstall'),
            )
            self.assertLess(
                installer_section.index('WriteUninstaller'),
                installer_section.index('IfErrors install_uninstaller_write_failed'),
            )
            self.assertLess(
                installer_section.index('IfErrors install_uninstaller_write_failed'),
                installer_section.index('WriteRegStr HKCU "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\Witseek"'),
            )
            uninstaller_section = generated[generated.index('Section Uninstall'):]
            self.assertIn('RMDir "$InstallCacheDir"', uninstaller_section)
            self.assertNotIn('RMDir /r "$InstallCacheDir"', uninstaller_section)
            self.assertLess(uninstaller_section.index('Call un.CheckPayloadReparse'), uninstaller_section.index('Call un.RemoveOwnedPayload'))
            self.assertLess(
                uninstaller_section.index('Call un.RemoveOwnedPayload'),
                uninstaller_section.index('StrCmp $PayloadRemovalFailed "0" uninstall_payload_removal_complete'),
            )
            self.assertLess(
                uninstaller_section.index('StrCmp $PayloadRemovalFailed "0" uninstall_payload_removal_complete'),
                uninstaller_section.index('DeleteRegKey HKCU'),
            )
            pack_script = (project_root / "scripts" / "pack_windows.sh").read_text(encoding="utf-8")
            self.assertIn("makensis -NOCD -V2", pack_script)


if __name__ == "__main__":
    unittest.main()
