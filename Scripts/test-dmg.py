"""Check drag-and-drop installation, relocation and ZIP/DMG parity in temporary folders."""
from pathlib import Path
import hashlib, json, subprocess, sys, tempfile, zipfile
from console_bundle import RELATIVE

root = Path(__file__).resolve().parent.parent
image = Path(sys.argv[1]).resolve()
zip_path = image.with_suffix('.zip')

def manifest(directory):
    return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in directory.rglob('*') if path.is_file()}

def verify(app, succeeds=True):
    result = subprocess.run([sys.executable, str(root / 'Scripts/verify-bundle.py'), str(app)],
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    assert (result.returncode == 0) == succeeds, result.stdout
    if succeeds: print(result.stdout, end='')

subprocess.run(['/usr/bin/hdiutil', 'verify', str(image)], check=True, stdout=subprocess.DEVNULL)
with tempfile.TemporaryDirectory(prefix='MKVStudio-dmg-check-') as temporary:
    work = Path(temporary).resolve(); mount = work / 'mounted'; mount.mkdir()
    subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', str(mount), str(image), '-quiet'], check=True)
    try:
        assert {p.name for p in mount.iterdir() if not p.name.startswith('.')} == {'MKVStudio.app', 'Программы', 'Установка.txt'}
        assert (mount / 'Программы').is_symlink() and (mount / 'Программы').readlink() == Path('/Applications')
        assert not list(mount.rglob('*.pkg')), 'Unexpected installer'
        original = manifest(mount / 'MKVStudio.app')
        assert original == manifest(root / 'build/MKVStudio.app'), 'DMG differs from release app'
        installed = work / 'Программы с пробелами/MKVStudio.app'
        installed.parent.mkdir()
        subprocess.run(['/usr/bin/ditto', '--norsrc', '--noextattr', str(mount / 'MKVStudio.app'), str(installed)], check=True)
    finally:
        subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount), '-quiet'], check=True)
    assert original == manifest(installed), 'Copy changed app contents'
    verify(installed)  # The original disk image is no longer mounted.
    with zipfile.ZipFile(zip_path) as archive:
        assert archive.testzip() is None
        zipped = {item.filename.removeprefix('MKVStudio.app/'): hashlib.sha256(archive.read(item)).hexdigest()
                  for item in archive.infolist() if not item.is_dir()}
        assert original == zipped, 'ZIP and DMG differ'
    tool = installed / RELATIVE / 'mkvinfo'
    saved = tool.read_bytes(); tool.write_bytes(saved + b'corrupt')
    verify(installed, succeeds=False)
    tool.write_bytes(saved)
    verify(installed)
    resources = installed / 'Contents/Resources/ConsoleTools'
    for entry in json.loads((resources / 'sources.json').read_text())['sources']:
        assert hashlib.sha256((resources / 'Sources' / entry['filename']).read_bytes()).hexdigest() == entry['sha256']
print('PASS DMG layout, no PKG, Applications link, relocation after eject, ZIP equality, source hashes and tamper detection')
