"""Shared, strict Mach-O inspection for the standalone macOS distribution."""
from pathlib import Path
import subprocess

TOOLS = ('mkvmerge', 'mkvinfo', 'mkvextract', 'mkvpropedit')
RELATIVE = Path('Contents/Helpers/ConsoleTools')

def run(*args):
    return subprocess.check_output(list(map(str, args)), text=True).strip()

def dependencies(binary):
    ids = run('/usr/bin/otool', '-D', binary).splitlines()[1:]
    return [line.strip().split(' (compatibility')[0]
            for line in run('/usr/bin/otool', '-L', binary).splitlines()[1:]
            if line.strip().split(' (compatibility')[0] not in ids]

def resolve(dependency, binary, executable_directory):
    if dependency.startswith(('/usr/lib/', '/System/Library/')):
        return None
    for prefix, directory in (('@executable_path/', executable_directory), ('@loader_path/', binary.parent)):
        if dependency.startswith(prefix):
            return directory / dependency[len(prefix):]
    raise RuntimeError(f'Non-portable dependency in {binary.name}: {dependency}')

def closure(directory):
    pending = [directory / name for name in TOOLS]
    seen = set()
    while pending:
        binary = pending.pop()
        relative = binary.relative_to(directory)
        if relative in seen:
            continue
        if not binary.resolve().is_relative_to(directory.resolve()) or not binary.is_file():
            raise RuntimeError(f'Missing or escaping bundled binary: {binary}')
        seen.add(relative)
        for dependency in dependencies(binary):
            target = resolve(dependency, binary, directory)
            if target is not None:
                pending.append(target)
    return sorted(seen)
