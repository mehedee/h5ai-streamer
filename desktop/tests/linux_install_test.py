"""Linux installer checks. All installs and profiles use a temporary home."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import unittest


INSTALLER = Path(__file__).resolve().parents[1] / "build/linux/install.sh"
UNINSTALLER = INSTALLER.with_name("uninstall.sh")


@unittest.skipUnless(Path("/proc/self/exe").exists(), "Linux only")
class LinuxInstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / "home with spaces"
        self.data = self.home / ".local/share"
        self.target = self.data / "myra"
        self.package = self.root / "package"
        (self.package / "app").mkdir(parents=True)
        shutil.copy2(INSTALLER, self.package / "install.sh")
        (self.package / "app/Myra").write_text('#!/bin/sh\nprintf "%s\\n" "$@"\n')
        (self.package / "app/Myra").chmod(0o755)
        (self.package / "myra.png").write_bytes(b"icon fixture")
        self.profile = self.home / ".config/Myra"
        self.profile.mkdir(parents=True)
        (self.profile / "Myra.json").write_text('{"DownloadDirectory":"/existing/media"}')
        (self.profile / "EntertainmentPersonal.json").write_text('{"history":[42]}')
        self.env = dict(os.environ, HOME=str(self.home), XDG_DATA_HOME=str(self.data))

    def install(self):
        return subprocess.run(["bash", str(self.package / "install.sh")],
                              env=self.env, capture_output=True, text=True, timeout=15)

    def previous_install(self):
        self.target.mkdir(parents=True)
        (self.target / "Myra").write_bytes(b"old app")
        (self.target / "keep.txt").write_text("previous install")

    def test_first_install_launches_from_spaced_path_and_passes_arguments(self):
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        launcher = self.home / ".local/bin/myra"
        launched = subprocess.run([str(launcher), "a video file.mp4", "https://example.test/?x=1&y=2"],
                                  env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(launched.stdout.splitlines(),
                         ["a video file.mp4", "https://example.test/?x=1&y=2"])
        desktop = (self.data / "applications/myra.desktop").read_text()
        self.assertIn(f'Exec="{self.target}/Myra" %u', desktop)

    def test_update_keeps_previous_app_and_personal_profile(self):
        self.previous_install()
        original_profile = {p.name: p.read_bytes() for p in self.profile.iterdir()}
        result = self.install()
        self.assertEqual(result.returncode, 0, result.stderr)
        backups = list(self.data.glob("myra.backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual((backups[0] / "Myra").read_bytes(), b"old app")
        self.assertEqual((backups[0] / "keep.txt").read_text(), "previous install")
        self.assertFalse((self.target / "keep.txt").exists())
        self.assertEqual({p.name: p.read_bytes() for p in self.profile.iterdir()}, original_profile)
        subprocess.run(["bash", str(UNINSTALLER)], env=self.env, check=True, capture_output=True)
        self.assertFalse(self.target.exists())
        self.assertTrue(backups[0].exists())
        self.assertEqual({p.name: p.read_bytes() for p in self.profile.iterdir()}, original_profile)

    def test_incomplete_package_keeps_existing_install(self):
        self.previous_install()
        (self.package / "app/Myra").unlink()
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual((self.target / "Myra").read_bytes(), b"old app")
        self.assertFalse(list(self.data.glob("myra.backup-*")))

    def test_failed_copy_keeps_existing_install_and_removes_staging(self):
        self.previous_install()
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "cp"
        stub.write_text("#!/bin/sh\nexit 1\n")
        stub.chmod(0o755)
        self.env["PATH"] = str(bin_dir) + os.pathsep + self.env["PATH"]
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual((self.target / "Myra").read_bytes(), b"old app")
        self.assertFalse(list(self.data.glob(".myra-install.*")))

    def test_failed_replacement_restores_previous_app(self):
        self.previous_install()
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        stub = bin_dir / "mv"
        stub.write_text('#!/bin/bash\nif [[ "$3" == *"/.myra-install."* ]]; then exit 1; fi\nexec /bin/mv "$@"\n')
        stub.chmod(0o755)
        self.env["PATH"] = str(bin_dir) + os.pathsep + self.env["PATH"]
        self.assertNotEqual(self.install().returncode, 0)
        self.assertEqual((self.target / "Myra").read_bytes(), b"old app")
        self.assertEqual((self.target / "keep.txt").read_text(), "previous install")
        self.assertFalse(list(self.data.glob(".myra-install.*")))

    def test_running_app_prevents_replacement(self):
        self.previous_install()
        shutil.copy2("/bin/sleep", self.target / "Myra")
        proc = subprocess.Popen([str(self.target / "Myra"), "60"])
        self.addCleanup(proc.wait)
        self.addCleanup(proc.terminate)
        deadline = time.monotonic() + 2
        while os.readlink(f"/proc/{proc.pid}/exe") != str(self.target / "Myra"):
            if time.monotonic() > deadline:
                self.fail("fixture did not start")
            time.sleep(0.01)
        result = self.install()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Close Myra", result.stderr)
        self.assertIsNone(proc.poll())
        self.assertFalse(list(self.data.glob("myra.backup-*")))

    def test_symlink_install_is_not_replaced(self):
        old = self.root / "other-install"
        old.mkdir()
        (old / "Myra").write_bytes(b"keep")
        self.data.mkdir(parents=True)
        self.target.symlink_to(old, target_is_directory=True)
        self.assertNotEqual(self.install().returncode, 0)
        self.assertTrue(self.target.is_symlink())
        self.assertEqual((old / "Myra").read_bytes(), b"keep")
