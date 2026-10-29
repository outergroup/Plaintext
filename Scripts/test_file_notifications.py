#!/usr/bin/env python3
import http.client
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import time

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root / 'Helper'))
from client_binary import encode_client, decode_client

class Connection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__('localhost', timeout=5)
        self.path = str(path)
    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(5)
        self.sock.connect(self.path)

with tempfile.TemporaryDirectory(prefix='plaintext-watch-', dir='/tmp') as directory:
    work = Path(directory)
    endpoint = work / 'backend.sock'
    file = work / 'document.txt'
    file.write_text('initial')
    process = subprocess.Popen([sys.argv[1], '--socket-path', str(endpoint)],
        env=dict(os.environ, XDG_STATE_HOME=str(work / 'state')), stdout=subprocess.DEVNULL)
    subscriptions = []
    def watch(path, guard=True):
        conn = Connection(endpoint)
        conn.request('POST', '/api/watch', encode_client('disk', path=str(path)),
                     {'X-Environment-Request':'1'} if guard else {})
        response = conn.getresponse()
        if not guard:
            assert response.status == 403
            response.read(); conn.close(); return
        assert response.status == 200
        subscriptions.append((conn, response))
        assert response.readline() == b'{"changed":true}\n'
        return response
    def changed(response):
        while True:
            line = response.readline()
            assert line, 'notification stream closed'
            if line.strip():
                assert line == b'{"changed":true}\n'
                return
    def request(operation, **values):
        conn = Connection(endpoint)
        conn.request('POST', '/api/environments', encode_client(operation, **values), {'X-Environment-Request':'1'})
        response = conn.getresponse()
        assert response.status == 200
        result = decode_client(response.read()); conn.close()
        return result
    try:
        for _ in range(200):
            if endpoint.exists(): break
            assert process.poll() is None
            time.sleep(.01)
        watch(file, False)
        first, second = watch(file), watch(file)
        original = request('state', path=str(file))
        assert original['draftRevision'] == 'missing' and not original['dirty'], original
        published = request('publish', path=str(file), contents='shared draft', revision=original['revision'], draftRevision=original['draftRevision'])
        assert 'error' not in published, published
        changed(first); changed(second)
        shared = request('state', path=str(file))
        assert shared['contents'] == 'shared draft' and shared['dirty'], shared
        assert file.read_text() == 'initial'
        stale = request('publish', path=str(file), contents='stale edit', revision=original['revision'], draftRevision=original['draftRevision'])
        assert 'error' in stale, stale
        stale_save = request('commit', path=str(file), contents='stale save', revision=original['revision'], draftRevision=original['draftRevision'])
        assert 'error' in stale_save and file.read_text() == 'initial', stale_save
        saved = request('commit', path=str(file), contents='shared draft', revision=shared['revision'], draftRevision=shared['draftRevision'])
        assert 'error' not in saved, saved
        changed(first); changed(second)
        clean = request('state', path=str(file))
        assert clean['contents'] == 'shared draft' and not clean['dirty'] and clean['draftRevision'] == 'missing', clean
        assert request('disk', path=str(file))['contents'] == 'shared draft'
        stale = request('publish', path=str(file), contents='old base', revision=original['revision'], draftRevision='missing')
        assert 'error' in stale, stale
        with file.open('w') as output: output.write('external editor')
        changed(first); changed(second)
        replacement = work / 'replacement'
        replacement.write_text('atomic replacement'); os.replace(replacement, file)
        changed(first); changed(second)
        assert request('disk', path=str(file))['contents'] == 'atomic replacement'
        file.unlink(); changed(first); changed(second)
        file.write_text('recreated'); changed(first); changed(second)
        assert request('disk', path=str(file))['contents'] == 'recreated'
        # A fresh, quiescent subscription must not produce periodic file checks/events.
        quiet = watch(file)
        raw = quiet.fp.raw._sock
        assert not select.select([raw], [], [], 1)[0], 'unexpected idle notification'
        (work / 'unrelated').write_text('another file')
        assert not select.select([raw], [], [], .3)[0], 'unrelated file notified this subscription'
        for conn, response in subscriptions: response.close(); conn.close()
        subscriptions.clear()
        file.write_text('while disconnected')
        watch(file)
        assert request('disk', path=str(file))['contents'] == 'while disconnected'
        # The helper uses the same event source when it runs inside a container.
        helper = subprocess.Popen([sys.argv[2], 'watch', str(file)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
        assert helper.stdout.read(1) == b'R'
        file.write_text('helper notification')
        assert select.select([helper.stdout], [], [], 3)[0]
        assert helper.stdout.read(1) == b'C'
        helper.stdin.close(); helper.wait(timeout=3)
        helper.stdout.close()
        print('PASS shared draft notifications, revision-checked publish/save, dirty/clean transitions, two clients, external write, atomic replacement, deletion/recreation, idle silence, reconnect, helper cleanup')
    finally:
        for conn, response in subscriptions: response.close(); conn.close()
        process.terminate(); process.wait(timeout=5)
