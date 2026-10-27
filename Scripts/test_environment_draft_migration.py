#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'Helper'))
from client_binary import run_client
helper = sys.argv[1]
with tempfile.TemporaryDirectory() as temp:
    work = Path(temp).resolve()
    directory = work / 'state/outershell/plaintext-environments'
    directory.mkdir(parents=True)
    file = work / 'quoted " <& café\u2028.txt'
    file.write_text('original')
    revision = hashlib.sha256(b'original').hexdigest()
    fields = ['host', '', str(file)]
    key = json.dumps(fields, ensure_ascii=False, separators=(',', ':'))
    for a,b in [('<','\\u003c'),('>','\\u003e'),('&','\\u0026'),('\u2028','\\u2028'),('\u2029','\\u2029')]:
        key = key.replace(a,b)
    source = directory / (hashlib.sha256(key.encode()).hexdigest() + '.json')
    source.write_text(json.dumps(dict(contents='unsaved ☃',revision=revision)))
    original = source.read_bytes()
    script = str(root / 'Scripts/migrate_environment_drafts.py')
    subprocess.run([sys.executable,script,str(directory)],check=True,stdout=subprocess.DEVNULL)
    assert next((directory / 'recovered-legacy-drafts').glob('*.txt')).read_text() == 'unsaved ☃'
    for _ in range(2):
        subprocess.run([sys.executable,script,str(directory),'--path',str(file)],check=True,stdout=subprocess.DEVNULL)
    env=dict(os.environ,XDG_STATE_HOME=str(work/'state'))
    result=run_client(helper,'read',env=env,path=str(file))
    assert result['contents']=='unsaved ☃' and result['dirty'] and not result['draftConflict'],result
    assert source.read_bytes()==original
    destination=next(directory.glob('*.oedraft'))
    destination.write_bytes(b'newer draft')
    result=subprocess.run([sys.executable,script,str(directory),'--path',str(file)],capture_output=True)
    assert result.returncode and destination.read_bytes()==b'newer draft'
print('PASS: legacy draft recovery, exact key migration, idempotence, no overwrite or source deletion')
