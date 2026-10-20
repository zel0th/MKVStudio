from pathlib import Path
import struct
import sys
# Package the existing PNG artwork without modifying the images.
source, destination = map(Path, sys.argv[1:])
chunks = []
for name, code in [('icon_16x16.png', b'icp4'), ('icon_32x32.png', b'icp5'), ('icon_32x32@2x.png', b'icp6'), ('icon_128x128.png', b'ic07'), ('icon_256x256.png', b'ic08'), ('icon_512x512.png', b'ic09'), ('AppIcon-1024.png', b'ic10')]:
    data = (source / name).read_bytes()
    chunks.append(code + struct.pack('>I', len(data) + 8) + data)
body = b''.join(chunks)
destination.write_bytes(b'icns' + struct.pack('>I', len(body) + 8) + body)
