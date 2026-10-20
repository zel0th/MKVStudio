"""Exercise the shipped installer in isolated roots; never modify system tools."""
from pathlib import Path
import hashlib
import subprocess
import sys
import tempfile

project = Path(__file__).resolve().parent.parent
script = project / "Installer/scripts/install-console-tools.sh"
image = Path(sys.argv[1]).resolve()
names = ("mkvmerge", "mkvinfo", "mkvextract", "mkvpropedit")

def run(root, archive=image, succeeds=True):
    p = subprocess.run(["/bin/bash", str(script), "--test-root", str(root), str(archive)],
                       text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    assert (p.returncode == 0) == succeeds, p.stdout
    return p.stdout

with tempfile.TemporaryDirectory(prefix="MKVStudio-installer-tests-") as temporary:
    work = Path(temporary).resolve()
    clean = work / "clean"; clean.mkdir()
    run(clean)
    location = clean / "Library/Application Support/MKVStudio/ConsoleTools"
    assert not list(clean.rglob("*.app"))
    for name in names:
        exe = clean / "usr/local/bin" / name
        assert exe.is_symlink() and exe.resolve() == location / "bin" / name
        text = subprocess.check_output([str(exe), "--version"], text=True)
        assert text.startswith(name + " v102.0")
    # Prove independent linkage with empty PATH and no Homebrew search paths.
    result = subprocess.run([str(location / "bin/mkvmerge"), "-J", str(project / "Samples/Видео.mp4")],
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8"},
                            capture_output=True, text=True)
    assert result.returncode == 0 and '"tracks"' in result.stdout
    before = {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in (location / "bin").iterdir() if p.is_file()}
    assert "no downloads or changes" in run(clean, work / "does-not-exist.dmg")
    assert before == {p: hashlib.sha256(p.read_bytes()).hexdigest() for p in before}
    print("PASS clean install: 4 independent executables, linkage, identification and idempotency")

    partial = work / "partial"; folder = partial / "opt/homebrew/bin"; folder.mkdir(parents=True)
    for name in names[:3]: (folder / name).symlink_to("/usr/bin/true")
    run(partial)
    for name in names[:3]:
        assert (folder / name).readlink() == Path("/usr/bin/true")
        assert not (partial / "usr/local/bin" / name).exists()
    assert (partial / "usr/local/bin/mkvpropedit").is_symlink()
    print("PASS partial install: existing tools preserved, only missing command exposed")

    corrupt = work / "corrupt"; corrupt.mkdir()
    bad = work / "bad.dmg"; bad.write_bytes(b"corrupted-download")
    assert "SHA-256" in run(corrupt, bad, succeeds=False)
    assert not (corrupt / "Library/Application Support/MKVStudio/ConsoleTools").exists()
    assert not list(corrupt.rglob(".console-stage.*"))
    assert not list(corrupt.rglob(".console-install-lock"))
    print("PASS corrupt download rejected before execution; staging and lock cleaned")

    collision = work / "collision"; base = collision / "Library/Application Support/MKVStudio"
    untouched = work / "unrelated"; untouched.mkdir()
    base.mkdir(parents=True); (base / "ConsoleTools").symlink_to(untouched)
    assert "symbolic-link destination" in run(collision, succeeds=False)
    assert not list(untouched.iterdir())
    print("PASS symlink destination rejected without changing existing installation")

    broken = work / "broken"; commands = broken / "usr/local/bin"; commands.mkdir(parents=True)
    (commands / "mkvmerge").symlink_to("/missing/user/tool")
    run(broken)
    assert (commands / "mkvmerge").readlink() == Path("/missing/user/tool")
    assert (broken / "Library/Application Support/MKVStudio/ConsoleTools/bin/mkvmerge").is_file()
    print("PASS broken user link preserved; app can discover private fallback")
print("5 installer scenarios passed")
