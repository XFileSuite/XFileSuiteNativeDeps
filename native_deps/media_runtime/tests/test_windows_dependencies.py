"""Exercise uchardet installation without a Windows compiler or network access."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'mingw-w64-x86_64-uchardet'
FILENAME = PACKAGE + '-0.0.8-2-any.pkg.tar.zst'


class WindowsDependencyTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.work = self.base/'work'
        self.work.mkdir()
        self.bin = self.base/'bin'
        self.bin.mkdir()
        self.log = self.base/'commands.log'
        fixture = self.base/'package'
        fixture.write_bytes(b'official-package-fixture')
        self.env = dict(os.environ, WORK_DIR=str(self.work),
                        LOG=str(self.log), FIXTURE=str(fixture),
                        PATH=str(self.bin)+os.pathsep+os.environ['PATH'])
        self.command('pacman', '''
echo "pacman $*" >> "$LOG"
if [[ "$1" == -Q ]]; then
  if [[ "$2" == mingw-w64-x86_64-uchardet ]]; then
    [[ -n "${INSTALLED_VERSION:-}" ]] || exit 1
    echo "$2 $INSTALLED_VERSION"
  fi
fi
''')
        self.command('pacman-key', '''
echo "verify $*" >> "$LOG"
exit "${VERIFY_STATUS:-0}"
''')
        self.command('curl', '''
echo "curl $*" >> "$LOG"
while [[ $# -gt 0 ]]; do
  if [[ "$1" == -o ]]; then cp "$FIXTURE" "$2"; exit; fi
  shift
done
exit 1
''')
        script = (ROOT/'build-windows.sh').read_text()
        section = script.split('MPV_MSYS2_PACKAGES=(', 1)[1].split('# ── 3.', 1)[0]
        # Run the actual install block with a deterministic package payload.
        section = 'MPV_MSYS2_PACKAGES=(' + section
        section = section.replace(
            'f38f128c4c53ad53fa4d4e5b258dde5e244b8bd5cb986e991778c7f12c71d01a',
            hashlib.sha256(fixture.read_bytes()).hexdigest())
        self.script = 'set -euo pipefail\n' + section

    def command(self, name, body):
        path = self.bin/name
        path.write_text('#!/usr/bin/env bash\nset -e\n' + body)
        path.chmod(0o755)

    def run_install(self):
        return subprocess.run(['bash', '-c', self.script], env=self.env,
                              text=True, capture_output=True)

    def test_clean_install_verifies_before_installing_official_package(self):
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        log = self.log.read_text()
        self.assertIn('https://repo.msys2.org/mingw/mingw64/'+FILENAME, log)
        self.assertIn('verify --verify', log)
        self.assertIn('pacman -U --noconfirm', log)
        self.assertLess(log.index('verify --verify'), log.index('pacman -U'))
        self.assertNotIn('pacman -S --noconfirm '+PACKAGE, log)

    def test_bad_signature_never_installs_package(self):
        self.env['VERIFY_STATUS'] = '1'
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertNotIn('pacman -U', self.log.read_text())

    def test_bad_download_hash_never_installs_package(self):
        Path(self.env['FIXTURE']).write_bytes(b'tampered')
        self.assertNotEqual(self.run_install().returncode, 0)
        self.assertNotIn('pacman -U', self.log.read_text())

    def test_corrupt_cache_is_replaced_before_installation(self):
        (self.work/FILENAME).write_bytes(b'stale-or-incomplete-cache')
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.work/FILENAME).read_bytes(), Path(self.env['FIXTURE']).read_bytes())

    def test_matching_installed_version_needs_no_download(self):
        self.env['INSTALLED_VERSION'] = '0.0.8-2'
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn('curl ', self.log.read_text())

    def test_old_installed_version_is_replaced_with_pinned_version(self):
        self.env['INSTALLED_VERSION'] = '0.0.8-1'
        result = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('pacman -U --noconfirm', self.log.read_text())


if __name__ == '__main__':
    unittest.main()
