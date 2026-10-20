"""Build an explicitly separate native UI test app using the production views and fixture transport."""
import plistlib, subprocess, tempfile, shutil
from pathlib import Path
root = Path(__file__).resolve().parent.parent
app = root/'build/MKVStudio-QA.app'
(app/'Contents/MacOS').mkdir(parents=True, exist_ok=True)
(app/'Contents/Resources').mkdir(parents=True, exist_ok=True)
shutil.copyfile(root/'MKVStudio/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png', app/'Contents/Resources/poster.png')
Path('/tmp/MKVStudio-ui-050').mkdir(exist_ok=True)
fixture = Path('/tmp/MKVStudio-ui-050/source.mkv')
if not fixture.exists():
    subprocess.run(['mkvmerge', '-q', '-o', str(fixture), '--title', 'Проверка поиска', str(root/'Samples/Видео.mp4')], check=True)
(app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleExecutable':'MKVStudio-QA','CFBundleIdentifier':'com.zshfan.MKVStudio.QA','CFBundleName':'MKVStudio QA','CFBundlePackageType':'APPL','LSMinimumSystemVersion':'14.0','NSHighResolutionCapable':True}))
files = [p for p in (root/'MKVStudio').rglob('*.swift') if p.name != 'MKVStudioApp.swift'] + [root/'UITests/KinopoiskHarness.swift']
subprocess.run(['swiftc','-O','-swift-version','6','-parse-as-library','-module-cache-path', str(Path(tempfile.gettempdir())/'MKVStudio-check-modules'),*map(str, files),'-o',str(app/'Contents/MacOS/MKVStudio-QA')],check=True)
subprocess.run(['xattr','-cr',str(app)],check=True)
subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print(app)
