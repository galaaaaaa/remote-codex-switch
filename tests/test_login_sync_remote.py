"""Run on Linux: python3 tests/test_login_sync_remote.py (fake credentials only)."""
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import tempfile
import unittest


class LoginSyncRemoteTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        source = Path(__file__).resolve().parents[1].joinpath("RemoteCodex.ps1").read_text(encoding="utf-8-sig")
        cls.script = re.search(r"function Get-LoginSyncCommand \{\s*\$remoteScript = @'\n(.*?)\n'@", source, re.S).group(1)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.auth_dir = Path(self.temporary.name, "auth")
        self.auth_dir.mkdir()
        self.env = dict(os.environ, CODEX_HOME=str(self.auth_dir))
        self.fixture = json.dumps({"tokens": {"access_token": "FAKE_TEST_TOKEN"}})

    def run_sync(self, value=None):
        return subprocess.run(["sh", "-c", self.script], input=self.fixture if value is None else value,
                              text=True, capture_output=True, env=self.env, timeout=10)

    def test_backup_and_atomic_replacement(self):
        auth_file = self.auth_dir / "auth.json"
        auth_file.write_text("OLD_FAKE_LOGIN")
        result = self.run_sync()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CODEX_SWITCH_LOGIN_SYNCED", result.stdout)
        self.assertNotIn("FAKE_TEST_TOKEN", result.stdout + result.stderr)
        self.assertEqual(auth_file.read_text(), self.fixture)
        self.assertEqual(stat.S_IMODE(auth_file.stat().st_mode), 0o600)
        backups = list(self.auth_dir.glob("auth.json.remote-codex-switch-backup-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_text(), "OLD_FAKE_LOGIN")
        self.assertEqual(stat.S_IMODE(backups[0].stat().st_mode), 0o600)
        self.assertFalse(list(self.auth_dir.glob(".remote-codex-login.*")))

    def test_empty_input_preserves_existing_login(self):
        auth_file = self.auth_dir / "auth.json"
        auth_file.write_text("OLD_FAKE_LOGIN")
        self.assertNotEqual(self.run_sync("").returncode, 0)
        self.assertEqual(auth_file.read_text(), "OLD_FAKE_LOGIN")
        self.assertFalse(list(self.auth_dir.glob(".remote-codex-login.*")))

    def test_symlink_is_not_followed(self):
        target = self.auth_dir / "unrelated-file"
        target.write_text("UNRELATED")
        (self.auth_dir / "auth.json").symlink_to(target)
        self.assertNotEqual(self.run_sync().returncode, 0)
        self.assertEqual(target.read_text(), "UNRELATED")

    def test_other_credential_stores_are_rejected(self):
        for store in ("keyring", "auto", "ephemeral"):
            for quote in ('"', "'"):
                (self.auth_dir / "config.toml").write_text(f"cli_auth_credentials_store = {quote}{store}{quote}\n")
                self.assertNotEqual(self.run_sync().returncode, 0)
                self.assertFalse((self.auth_dir / "auth.json").exists())


if __name__ == "__main__":
    unittest.main()
