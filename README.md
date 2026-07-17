# Plaintext

Plaintext is an outerframe text editor. It serves a macOS content bundle from a
small backend and opens files via:

```text
/?file=/path/to/file.txt
```

## Deploy Over SSH

With a current Outer Shell installed on the target:

```bash
./app target "ssh -p 22 you@server"
./app deploy
```

The deploy target is stored in the gitignored `target.env`. Deployment detects
the target architecture and libc and builds only the matching dynamic backend.
glibc builds use the manylinux2014 (glibc 2.17) baseline; musl builds use
musllinux 1.2. Run `./app build-matrix` to build all four Linux release
variants, or `./app help` for the other development commands.

## Build and Run

```bash
./build_run.sh
```

The development server listens on `http://127.0.0.1:7355/` by default. For
Unix socket testing:

```bash
SOCKET_PATH="$(getconf DARWIN_USER_TEMP_DIR)org.outershell.Plaintext"
./build/macos/Release/PlaintextBackend \
  --socket-path "$SOCKET_PATH" \
  --bundles-dir ./build/run/bundles
```

Open the socket URL from Outer Shell or Outerframe with a `file` query.
Plaintext is registered as an opener for `public.text` when it is installed
through Outer Shell. Opener URLs use `?file={file}`, where outershelld replaces
`{file}` with the percent-encoded path.
