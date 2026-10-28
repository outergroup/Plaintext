#!/usr/bin/env python3
import hashlib
from pathlib import Path
import shutil
import sys

source, destination = map(Path, sys.argv[1:])
destination.mkdir(parents=True, exist_ok=True)
digest = hashlib.sha256()
for path in sorted(source.iterdir()):
    if path.is_file():
        digest.update(path.name.encode())
        digest.update(path.read_bytes())
        shutil.copy2(path, destination / path.name)
worker = destination / 'sw.js'
worker.write_text(worker.read_text().replace('plaintext-shell-v2', 'plaintext-shell-' + digest.hexdigest()[:20]))
