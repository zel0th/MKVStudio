"""Fetch a pinned upstream image at BUILD time and embed only the CLI dependency closure.

Nothing is downloaded or installed by MKVStudio at runtime. Never write outside
the build cache and the supplied application bundle. Existing system tools are ignored.
"""
from pathlib import Path
import hashlib, json, os, shutil, subprocess, sys, tarfile, tempfile
from console_bundle import TOOLS, RELATIVE, closure

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / 'Distribution/console-tools.json'

def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''): result.update(block)
    return result.hexdigest()

def fetch(entry, cache):
    path = cache / entry['filename']
    if not path.exists():
        fd, temporary = tempfile.mkstemp(prefix='download-', dir=cache)
        os.close(fd)
        temporary = Path(temporary)
        try:
            subprocess.run(['/usr/bin/curl', '--fail', '--location', '--silent', '--show-error',
                            '--proto', '=https', '--proto-redir', '=https', '--connect-timeout', '20',
                            '--max-time', '300', '--retry', '2', entry['url'], '-o', str(temporary)], check=True)
            if digest(temporary) != entry['sha256']:
                raise RuntimeError(f'Checksum mismatch: {entry["filename"]}')
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)
    if digest(path) != entry['sha256']:
        raise RuntimeError(f'Corrupt cached download: {path}; remove it and rebuild')
    return path

def main():
    app = Path(sys.argv[1]).resolve()
    if app.suffix != '.app' or not (app / 'Contents/Info.plist').is_file():
        raise RuntimeError('Supply an existing application bundle')
    manifest = json.loads(MANIFEST.read_text())
    cache = ROOT / 'build/vendor'; cache.mkdir(parents=True, exist_ok=True)
    image = fetch(manifest['image'], cache)
    with tempfile.TemporaryDirectory(prefix='MKVStudio-console-') as temporary:
        work = Path(temporary)
        mount = work / 'image'; mount.mkdir()
        subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(image), '-quiet'], check=True)
        try:
            source = mount / 'MKVToolNix.app/Contents/MacOS'
            staged = work / 'ConsoleTools'; staged.mkdir()
            included = closure(source)
            for relative in included:
                destination = staged / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                # Dereference upstream aliases; each required install name remains at its original relative path.
                shutil.copyfile(source / relative, destination)
                destination.chmod(0o755)
            resources = app / 'Contents/Resources/ConsoleTools'
            if resources.exists(): shutil.rmtree(resources)
            resources.mkdir(parents=True)
            shutil.copyfile(mount / 'COPYING.txt', resources / 'COPYING-GPL-2.0.txt')
            shutil.copyfile(ROOT / 'Distribution/THIRD-PARTY.txt', resources / 'THIRD-PARTY.txt')
            shutil.copyfile(MANIFEST, resources / 'sources.json')
            for name in TOOLS:
                destination = resources / 'man' / (name + '.1')
                destination.parent.mkdir(exist_ok=True)
                shutil.copyfile(source / 'man/man1' / (name + '.1'), destination)
            # Retain source archives and their license notices alongside the binaries.
            for entry in manifest.get('sources', []):
                archive = fetch(entry, cache)
                (resources / 'Sources').mkdir(exist_ok=True)
                shutil.copyfile(archive, resources / 'Sources' / archive.name)
                with tarfile.open(archive) as tar:
                    for member in tar:
                        path = Path(member.name)
                        if member.isfile() and (path.parts[1:2] == ('LICENSES',) or '/doc/licenses/' in member.name):
                            destination = resources / 'Licenses' / path.name
                            destination.parent.mkdir(exist_ok=True)
                            destination.write_bytes(tar.extractfile(member).read())
            payload = app / RELATIVE
            if payload.exists(): shutil.rmtree(payload)
            payload.parent.mkdir(parents=True, exist_ok=True)
            shutil.copytree(staged, payload)
            # Sign nested code first, then the outer app in build-app.sh / Xcode.
            for relative in sorted(included, key=lambda p: p.suffix != '.dylib'):
                subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(payload / relative)], check=True)
            files = {str(p): digest(payload / p) for p in included}
            (resources / 'payload.json').write_text(json.dumps(files, indent=2, sort_keys=True) + '\n')
            print('Bundled:', ', '.join(map(str, included)))
        finally:
            subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount), '-quiet'], check=True)

if __name__ == '__main__': main()
