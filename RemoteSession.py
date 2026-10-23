"""Temporary per-user VS Code proxy settings, with a stdin heartbeat lease."""
import base64
import json
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import tempfile
import time

TOKEN = re.compile(r'\s+|//[^\r\n]*|/\*[\s\S]*?\*/|"(?:\\.|[^"\\])*"|[{}\[\]:,]|[^\s{}\[\]:,]+')
KEYS = ('http.useLocalProxyConfiguration', 'http.proxy', 'http.proxySupport')


def document(text):
    """Validate JSONC and locate root values without rewriting unrelated text."""
    tokens = [m for m in TOKEN.finditer(text) if not m[0].isspace() and m[0] != '\ufeff' and not m[0].startswith(('//', '/*'))]
    clean = ''.join(m[0] for i, m in enumerate(tokens)
                    if not (m[0] == ',' and i + 1 < len(tokens) and tokens[i + 1][0] in ('}', ']')))
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON property')
            result[key] = value
        return result
    values = json.loads(clean, object_pairs_hook=unique)
    if not isinstance(values, dict):
        raise ValueError('VS Code settings must be an object')
    entries = []
    i = 1
    previous_comma = None
    while i < len(tokens) - 1:
        key, colon = tokens[i:i + 2]
        if not key[0].startswith('"') or colon[0] != ':':
            raise ValueError('Invalid settings property')
        start = i + 2
        i = start
        depth = 0
        while i < len(tokens) - 1:
            part = tokens[i][0]
            if part == ',' and depth == 0:
                break
            if part in ('{', '['):
                depth += 1
            elif part in ('}', ']'):
                depth -= 1
            i += 1
        comma = tokens[i] if tokens[i][0] == ',' else None
        entries.append((json.loads(key[0]), key.start(), tokens[start].start(), tokens[i - 1].end(), comma, previous_comma))
        previous_comma = comma
        if comma:
            i += 1
    return values, entries, tokens[-1].start()


def edit(text, key, present, value=None):
    values, entries, closing = document(text)
    for name, key_start, value_start, value_end, comma, previous in entries:
        if name != key:
            continue
        if present:
            return text[:value_start] + json.dumps(value, ensure_ascii=False) + text[value_end:]
        if comma:
            return text[:key_start] + text[comma.end():]
        if previous:
            return text[:previous.start()] + text[value_end:]
        return text[:key_start] + text[value_end:]
    if not present:
        return text
    if entries and entries[-1][4] is None:
        end = entries[-1][3]
        text = text[:end] + ',' + text[end:]
        closing += 1
    addition = '\n  ' + json.dumps(key) + ': ' + json.dumps(value, ensure_ascii=False) + '\n'
    return text[:closing] + addition + text[closing:]


def atomic_write(path, text, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_symlink():
        raise ValueError('Refusing to replace symlinked settings')
    fd, temporary = tempfile.mkstemp(prefix='.codex-switch-', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w', encoding='utf-8', newline='') as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class SettingsLease:
    def __init__(self, home):
        self.root = Path(home) / '.cache/remote-codex-switch'
        self.settings = Path(home) / '.vscode-server/data/Machine/settings.json'
        self.journal = self.root / 'shared-settings.json'

    def recover(self):
        if not self.journal.exists():
            return
        state = json.loads(self.journal.read_text(encoding='utf-8'))
        if self.settings.is_symlink():
            raise ValueError('Refusing to restore symlinked settings')
        if not self.settings.exists():
            self.journal.unlink()
            return
        current = self.settings.read_bytes().decode('utf-8')
        if current == state['active']:
            restored = state['original']
        else:
            restored = current
            for key in KEYS:
                values, _, _ = document(restored)
                if key in values and values[key] == state['desired'][key]:
                    previous = state['previous'][key]
                    restored = edit(restored, key, previous['present'], previous.get('value'))
        if not state['existed'] and not document(restored)[0]:
            if self.settings.exists():
                self.settings.unlink()
        else:
            atomic_write(self.settings, restored, state['mode'])
        self.journal.unlink()

    def enable(self, port, session):
        self.root.mkdir(parents=True, exist_ok=True)
        os.chmod(self.root, 0o700)
        self.recover()
        if self.settings.is_symlink():
            raise ValueError('Refusing to change symlinked settings')
        existed = self.settings.exists()
        original = self.settings.read_bytes().decode('utf-8') if existed else '{}\n'
        values, _, _ = document(original)
        desired = dict(zip(KEYS, (False, 'http://127.0.0.1:' + str(port), 'on')))
        active = original
        for key, value in desired.items():
            active = edit(active, key, True, value)
        state = {'session': session, 'existed': existed, 'original': original, 'active': active,
                 'mode': self.settings.stat().st_mode & 0o777 if existed else 0o600,
                 'desired': desired, 'previous': {key: {'present': key in values, 'value': values.get(key)} for key in KEYS}}
        atomic_write(self.journal, json.dumps(state, ensure_ascii=False))
        atomic_write(self.settings, active, state['mode'])


def emit(text):
    print(text, flush=True)


def run(port, session):
    import fcntl
    home = Path.home()
    lease = SettingsLease(home)
    lease.root.mkdir(parents=True, exist_ok=True)
    os.chmod(lease.root, 0o700)
    with (lease.root / 'shared.lock').open('a') as lock:
        os.chmod(lock.name, 0o600)
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise RuntimeError('Another Remote Codex connection is active for this server user')
        def interrupted(*_):
            raise SystemExit(0)
        for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
            signal.signal(sig, interrupted)
        try:
            lease.recover()
            check = subprocess.run(['curl', '--silent', '--output', '/dev/null', '--write-out', '%{http_code}',
                                    '--connect-timeout', '5', '--max-time', '10', '--noproxy', '', '--proxy',
                                    'http://127.0.0.1:' + str(port), 'https://auth.openai.com/.well-known/openid-configuration'],
                                   capture_output=True, text=True, timeout=12)
            status = check.stdout.strip() if check.returncode == 0 else '000'
            emit('CODEX_SWITCH_AUTH_HTTP=' + status)
            if status != '200':
                raise RuntimeError('OpenAI login service proxy check failed: HTTP ' + status)
            lease.enable(port, session)
            emit('CODEX_SWITCH_HOME=' + base64.b64encode(str(home).encode()).decode())
            emit('CODEX_SWITCH_SHARED=1')
            emit('CODEX_SWITCH_READY')
            last_ping = time.monotonic()
            while time.monotonic() - last_ping < 15:
                readable, _, _ = select.select([sys.stdin], [], [], 2)
                if readable:
                    line = sys.stdin.readline()
                    if not line or line.strip() == 'STOP':
                        break
                    if line.strip() == 'PING':
                        last_ping = time.monotonic()
                emit('CODEX_SWITCH_ALIVE')
        finally:
            lease.recover()
            try:
                emit('CODEX_SWITCH_RESTORED')
            except BrokenPipeError:
                pass


if __name__ == '__main__':
    try:
        port = int(sys.argv[1])
        session = sys.argv[2]
        if not 1024 <= port <= 65535 or not re.fullmatch(r'[a-f0-9]{32}', session):
            raise ValueError('Invalid session parameters')
        run(port, session)
    except (Exception, BrokenPipeError) as error:
        # Never print settings contents or authentication data.
        print('Remote Codex connection failed: ' + type(error).__name__ + ': ' + str(error), file=sys.stderr)
        sys.exit(1)
