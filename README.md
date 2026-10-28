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

### Container runtime adapters

Registered Docker, Apple Container and `wslc` targets use explicit runtime argv
adapters. The helper protocol remains binary and the same app-owned helper can
run in either Linux container runtime. Root macOS backends enter the owning
user's launchd session before invoking Apple Container. Helper image builds accept
`OUTER_BUILD_CONTAINER_RUNTIME=container|docker` and auto-detect an available
builder. `Scripts/test_runtime_command.c` tests the command contract, including
`wslc.exe`; Windows still needs native process transport integration and live
validation. `wslc` is not treated as a `wsl.exe` distribution.

## HTML editor draft recovery

The HTML editor updates its text immediately in the browser. Edits are saved to
IndexedDB at most 100 ms after typing begins, independently of the server; a
700 ms debounce also backs up drafts to the server. Untitled drafts are included.
The document menu's **Recover draft…** command opens previous local drafts, and
**Download a copy** exports the current text if storage is unavailable.

**Save** durably queues a snapshot before attempting the file write. Connection
failures retry with exponential backoff, capped at 30 seconds. Later edits remain
an unsaved draft; they are not silently included in an earlier Save. Queued saves
resume after reload, including other drafts when Web Locks are available. Each
tab owns a separate draft, with Web Locks preventing simultaneous ownership.

File writes check the base revision. A file changed elsewhere requires reviewing
the local and server text, saving a separate copy, or explicitly replacing the
server file. A raw disk read reconciles an acknowledged-by-server but lost HTTP
response without confusing a server draft with the saved file.

A service worker caches a complete editor shell for offline reload after the
first successful online visit. Packaging hashes the shell assets to version each
cache; a new shell activates after existing editor pages close. Browser storage
belongs to the browser profile and origin: clearing site data removes drafts,
and browser eviction or device failure can still lose them. Storage failures are
shown prominently; navigation warns when the latest edits are not persisted.
This recovery applies to the HTML editor, not the native outerframe editor.

Focused checks: `node Scripts/test_local_drafts.cjs`,
`node Scripts/test_single_document.cjs`, `node Scripts/test_web_environments.cjs`,
`python3 Scripts/test_disk_read.py <EnvironmentDriver>`, and
`python3 Scripts/test_environment_http.py <PlaintextBackend>`.

## Native outerframe draft recovery

The native editor checkpoints drafts into `plaintext.sqlite` inside the host's
`OUTERFRAME_DATA_DIR`. It requires an outerframe host with the persistent-folder
capability. If storage is unavailable, editing remains possible but the status
reports that recovery is unavailable and Save cannot durably queue a write. Use
**Copy Draft Text** or **Copy Draft as File** in the file menu to preserve the text.
The latter places a staged file on the clipboard for pasting into Finder.

Typing and rendering are immediate. A background actor writes SQLite checkpoints
within approximately 100 ms during continuous typing. Each row contains a binary
property-list document record, including any pending Save snapshot, so both are
committed together. SQLite uses WAL and FULL synchronous mode. Draft UUIDs and
OS file locks keep separate editor instances from owning the same recovery record.

Save persists its exact snapshot before sending a revision-checked request to
`/api/environments`. Failed connections retry with bounded exponential backoff;
later typing stays dirty until another Save. On reconnect or reopening the app,
queued saves resume. Raw disk reads reconcile a write whose response was lost.
Files changed elsewhere require review and explicit resolution through the file
menu. **Review Server Version** displays a read-only view; **Return to My Draft**
restores the editable draft. **Save a Copy…** and explicit replacement are also
available. **Recover Draft** includes untitled drafts and queued saves.

Closing or disconnecting requests a final checkpoint, but abrupt process death
can still lose edits made since the latest completed checkpoint. Offline content
bundle launch is a separate host capability. The native SQLite store and HTML
IndexedDB store are separate; they share the backend's file revision protocol.

Run `bash Scripts/test_native_documents.sh` for controller, SQLite ownership,
recovery, save queue, conflict, and real-backend binary protocol checks.
