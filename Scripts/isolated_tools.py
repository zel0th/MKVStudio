"""Test-only sandbox: prove no console binary/library can come from host installations."""
import os

PROFILE = '''(version 1)
(allow default)
(deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local")
    (subpath "/Library/Application Support/MKVStudio/ConsoleTools"))
'''

def isolated_command(command):
    if os.environ.get('MKVSTUDIO_ISOLATE_TOOLS') == '1':
        if not os.environ.get('MKVSTUDIO_TOOLS_DIRECTORY'):
            raise RuntimeError('Specify the bundled tool directory for isolated checks')
        return ['/usr/bin/sandbox-exec', '-p', PROFILE, *command]
    return command
