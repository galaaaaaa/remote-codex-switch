"""No account data or live SSH connection is used by these tests."""
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from RemoteSession import SettingsLease, document, edit


class SharedSettingsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.lease = SettingsLease(self.temp.name)
        self.lease.settings.parent.mkdir(parents=True)

    def write(self, text):
        self.lease.settings.write_bytes(text.encode('utf-8'))

    def read(self):
        return self.lease.settings.read_bytes().decode('utf-8')

    def test_exact_restore_of_comments_and_crlf(self):
        original = '\ufeff{\r\n // note\r\n "nested": {"a": [1,2,],},\r\n "http.proxy": "http://old.invalid:1234",\r\n}\r\n'
        self.write(original)
        self.lease.enable(7897, 'a'*32)
        active = self.read()
        self.assertIn('// note', active)
        self.assertIn('"nested": {"a": [1,2,],}', active)
        values = document(active)[0]
        self.assertFalse(values['http.useLocalProxyConfiguration'])
        self.assertEqual(values['http.proxy'], 'http://127.0.0.1:7897')
        self.lease.recover()
        self.assertEqual(self.read(), original)

    def test_unrelated_concurrent_edit_survives(self):
        self.write('{"editor.fontSize": 14}')
        self.lease.enable(7897, 'b'*32)
        self.write(edit(self.read(), 'editor.fontSize', True, 20))
        self.lease.recover()
        self.assertEqual(document(self.read())[0], {'editor.fontSize': 20})

    def test_user_proxy_change_is_not_overwritten(self):
        self.write('{"http.proxy": "http://old.invalid:1234"}')
        self.lease.enable(7897, 'c'*32)
        self.write(edit(self.read(), 'http.proxy', True, 'http://user.invalid:5678'))
        self.lease.recover()
        self.assertEqual(document(self.read())[0], {'http.proxy': 'http://user.invalid:5678'})

    def test_comment_after_original_trailing_comma_survives_edits(self):
        self.write('{"other": true, // keep this note\n}')
        self.lease.enable(7897, 'b'*32)
        self.write(edit(self.read(), 'other', True, False))
        self.lease.recover()
        self.assertEqual(document(self.read())[0], {'other': False})
        self.assertIn('// keep this note', self.read())

    def test_new_settings_file_removed_on_stop(self):
        self.lease.enable(7897, 'd'*32)
        self.lease.recover()
        self.assertFalse(self.lease.settings.exists())

    def test_next_launch_recovers_stale_journal(self):
        self.write('{"other": true}')
        self.lease.enable(7897, 'e'*32)
        replacement = SettingsLease(self.temp.name)
        replacement.enable(7890, 'f'*32)
        replacement.recover()
        self.assertEqual(self.read(), '{"other": true}')

    def test_invalid_settings_are_untouched(self):
        original = '{invalid-json'
        self.write(original)
        with self.assertRaises(ValueError):
            self.lease.enable(7897, 'a'*32)
        self.assertEqual(self.read(), original)


if __name__ == '__main__':
    unittest.main()
