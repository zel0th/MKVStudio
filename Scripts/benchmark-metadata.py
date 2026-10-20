"""Exercise 300 metadata/thumbnail cycles with deterministic API responses, without spending API quota."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='MKVStudio-metadata-benchmark-') as temp:
    binary = Path(temp)/'benchmark'
    sources = sorted((root/'MKVStudio/Core/Models').glob('*.swift')) + sorted((root/'MKVStudio/Core/Services').glob('*.swift'))
    sources += [root/'Performance/KinopoiskBenchmark.swift']
    subprocess.run(['swiftc', '-O', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(Path(tempfile.gettempdir())/'MKVStudio-check-modules'), *map(str,sources), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(root/'MKVStudio/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png')], check=True)
