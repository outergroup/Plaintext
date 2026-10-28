#!/usr/bin/env python3
import os
from pathlib import Path
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'Helper'))
from client_binary import run_client
with tempfile.TemporaryDirectory() as temporary:
 work=Path(temporary);file=work/'file.txt';file.write_text('on disk')
 env=dict(os.environ,XDG_STATE_HOME=str(work/'state'))
 def call(op,**values):return run_client(sys.argv[1],op,env=env,path=str(file),**values)
 original=call('read');assert original['contents']=='on disk'
 assert call('draft',contents='unsaved server draft',revision=original['revision'])['ok']
 assert call('read')['contents']=='unsaved server draft'
 disk=call('disk');assert disk['contents']=='on disk' and not disk['dirty']
 file.write_text('external change')
 assert call('read')['draftConflict']
 assert call('disk')['contents']=='external change'
 assert 'error' in call('save',contents='my changes',revision=original['revision'])
 assert file.read_text()=='external change'
 print('PASS raw disk reads bypass recovery drafts and retain conflict protection')
