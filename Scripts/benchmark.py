"""Profile the actual AppState queue and console tools using synthetic PCM, never user media."""
from pathlib import Path
import os, subprocess, tempfile, wave
root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix='MKVStudio-benchmark-') as temp:
    folder = Path(temp)
    with wave.open(str(folder/'stress.wav'), 'wb') as wav:
        wav.setnchannels(2); wav.setsampwidth(2); wav.setframerate(48000)
        block = bytes(1024*1024)
        for _ in range(1024): wav.writeframesraw(block)
    binary = folder/'queue-benchmark'
    sources = sorted((root/'MKVStudio/Core/Models').glob('*.swift')) + sorted((root/'MKVStudio/Core/Services').glob('*.swift'))
    sources += [root/'MKVStudio/App/AppState.swift', root/'MKVStudio/App/MetadataState.swift', root/'MKVStudio/App/KinopoiskState.swift', root/'Performance/QueueBenchmark.swift']
    subprocess.run(['swiftc', '-O', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(Path(tempfile.gettempdir())/'MKVStudio-check-modules'), *map(str,sources), '-o', str(binary)], check=True)
    subprocess.run([str(binary), str(folder)], check=True)
