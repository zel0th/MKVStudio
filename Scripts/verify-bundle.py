"""Verify a relocated app without Homebrew, installer paths or inherited dyld settings."""
from pathlib import Path
import hashlib, json, os, plistlib, re, subprocess, sys, tempfile
from console_bundle import TOOLS, RELATIVE, closure, run

app = Path(sys.argv[1]).resolve()
payload = app / RELATIVE
resources = app / 'Contents/Resources/ConsoleTools'
expected = json.loads((resources / 'payload.json').read_text())
actual = {str(p.relative_to(payload)) for p in payload.rglob('*') if p.is_file()}
resolved = {str(p) for p in closure(payload)}
assert actual == set(expected) == resolved, f'Unexpected payload: files={actual}, manifest={set(expected)}, closure={resolved}'
for relative, sha in expected.items():
    binary = payload / relative
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == sha, f'Changed bundled binary: {relative}'
    assert run('/usr/bin/lipo', '-archs', binary) == 'arm64', f'Unexpected architecture: {relative}'
    subprocess.run(['/usr/bin/codesign', '--verify', '--strict', str(binary)], check=True)
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
with tempfile.TemporaryDirectory(prefix='MKVStudio-standalone-home-') as home:
    environment = {'HOME': home, 'TMPDIR': home, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C',
                   'DYLD_PRINT_LIBRARIES': '1'}
    for name in TOOLS:
        result = subprocess.run([str(payload / name), '--version'], env=environment, capture_output=True, text=True, check=True)
        assert result.stdout.startswith(name + ' v102.0'), result.stdout
        loaded = []
        for line in result.stderr.splitlines():
            if line.startswith('dyld['):
                # dyld also emits notices about delayed loading containing just a basename.
                match = re.search(r'\s(/[\S ].*)$', line)
                if match:
                    path = match.group(1)
                    loaded.append(path)
                    assert path.startswith(('/usr/lib/', '/System/Library/', str(app) + '/')), line
        assert str(payload / 'libs/libQt6Core.6.dylib') in loaded, 'Expected bundled Qt loader trace'
        print(result.stdout.strip())
    assert not list(Path(home).glob('.config/*')), 'Version probe created user configuration'
print('PASS signatures, hashes, dependency closure, architecture and isolated tool launches')
