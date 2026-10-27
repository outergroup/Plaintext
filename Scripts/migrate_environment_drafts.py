#!/usr/bin/env python3
"""One-time recovery of legacy drafts; never modifies or deletes the original files."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import struct


def reference(buffer, field, value):
    data = value.encode('utf-8')
    struct.pack_into('<II', buffer, field, len(buffer), len(data))
    buffer.extend(data)


def draft_bytes(value):
    contents, revision = value['contents'], value['revision']
    if not isinstance(contents, str) or not isinstance(revision, str):
        raise ValueError('invalid draft fields')
    if '\0' in contents or '\0' in revision or len(contents.encode()) > 4 * 1024 * 1024 or len(revision.encode()) > 64:
        raise ValueError('invalid draft size or NUL')
    result = bytearray(32)
    struct.pack_into('<II', result, 0, 0x5244454f, 1)
    reference(result, 16, revision)
    reference(result, 24, contents)
    struct.pack_into('<I', result, 8, len(result))
    return result


def write_new(path, data):
    try:
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    except FileExistsError:
        if path.read_bytes() != data:
            raise ValueError(f'refusing to overwrite {path}')
        return
    with os.fdopen(fd, 'wb') as output:
        output.write(data)
        output.flush()
        os.fsync(output.fileno())


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('directory', type=Path)
    parser.add_argument('--target', default='host')
    parser.add_argument('--user', default='')
    parser.add_argument('--path', help='Original absolute file path, to restore a draft to its new lookup key')
    args = parser.parse_args()
    if args.path:
        fields = [args.target, args.user, args.path]
        old_key = json.dumps(fields, ensure_ascii=False, separators=(',', ':'))
        for old, new in [('<', '\\u003c'), ('>', '\\u003e'), ('&', '\\u0026'), ('\u2028', '\\u2028'), ('\u2029', '\\u2029')]:
            old_key = old_key.replace(old, new)
        source = args.directory / (hashlib.sha256(old_key.encode()).hexdigest() + '.json')
        value = json.loads(source.read_text())
        key = bytearray(24)
        for i, field in enumerate(fields):
            reference(key, i * 8, field)
        destination = args.directory / (hashlib.sha256(key).hexdigest() + '.oedraft')
        write_new(destination, draft_bytes(value))
        print(f'Restored {destination}')
    else:
        for source in sorted(args.directory.glob('*.json')):
            value = json.loads(source.read_text())
            encoded = draft_bytes(value)
            destination = args.directory / 'recovered-legacy-drafts'
            destination.mkdir(mode=0o700, exist_ok=True)
            write_new(destination / (source.stem + '.oedraft'), encoded)
            write_new(destination / (source.stem + '.txt'), value['contents'].encode())
            write_new(destination / (source.stem + '.revision'), value['revision'].encode())
            print(f'Recovered {source.name}; use --path with its original path to restore automatic lookup')


if __name__ == '__main__':
    main()
