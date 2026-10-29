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

## HTML document scrolling

The HTML editor uses the page's vertical scrollbar. The textarea grows with its
contents using CSS `field-sizing: content`; the title/Save bar is fixed to the viewport, outside the scrolling content.
There is no viewport-height tracking, translated editor surface, or nested
vertical editor scrollbar. Current Safari (26.2+) and other browsers supporting
`field-sizing` are required. This lets the iOS status-bar tap return the document
to its start. Outer Loop must use native keyboard resizing and automatic WebKit
inset adjustment so the keyboard is not counted twice. Pointer focus uses
`preventScroll` to avoid WebKit's animated focus scroll, which can move the native
scroll layer ahead of fixed-element painting. When the keyboard shrinks the
visible area, a temporary text-layout mirror locates the caret and the document
scrolls immediately only as far as needed to reveal it.

Run `Scripts/test_web_scrolling.sh <booted-iOS-simulator-UDID>` for the native
keyboard/scrolling regression, including native scroll-layer presentation checks. It uses the sibling `outerloop` checkout; set
`OUTERLOOP_ROOT` to test a different checkout. Also check a real status-bar tap,
scrolling with the keyboard dismissed, and tapping to reopen it.

## HTML editor draft recovery

The HTML editor updates its text immediately in the browser. Edits are saved to
IndexedDB at most 100 ms after typing begins, independently of the server; a
700 ms debounce also publishes drafts to the server. Untitled drafts are included.
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

The visible document subscribes to `/api/watch`, an HTTP notification stream backed
by kqueue on macOS and inotify on Linux. Saved-file and shared-draft changes update other editors while preserving selection
and scroll position. A synchronized draft remains marked **Edited** until saved;
it can receive newer drafts as long as it has no outstanding local edits. Local
edits, pending saves, and composition are protected from replacement. Reconnecting or returning to the
page checks the current revision to catch missed events. There is no periodic file
polling; blank stream heartbeats only keep the connection alive. Container watches
use the helper’s `watch PATH` command and require an updated helper in the container.

The HTML client uses `state`, `publish`, and `commit` operations. Each shared draft
has a content revision separate from the saved file revision. Publish and commit
compare both revisions under a per-document filesystem lock; commit only removes
the draft it checked. Shared state reads use the same lock. Draft acknowledgments
and the last synchronized local version are persisted with the local recovery
record, so reloading does not turn an already synchronized draft into a new edit.
Conflicting edits stay local for review against the shared draft and saved file;
they can be saved as a copy or explicitly replace the reviewed server state. This
is device switching with conflict protection, not simultaneous text merging. The
native editor continues to use its existing draft API.

Where supported, a service worker opportunistically caches the editor shell for
offline reload after the first successful online visit. Unsupported browsers and
cache-registration failures do not produce user-facing capability warnings.
Actual file-loading, draft-storage, and save failures are still reported. Packaging hashes the shell assets to version each
cache. Updated shells activate after a foreground editor pauses and checkpoints
its drafts locally. Each editor then checkpoints before its own automatic reload,
restoring its document, selection, scroll position, and Open panel. Background tabs
may be suspended by the browser; they update when they can run again rather than
blocking the foreground editor. Typing, composition, modal dialogs, and failed
checkpoints defer that editor's reload. Update checks run on opening, focus,
visibility, and reconnect; server synchronization is not required for the local
checkpoint. Older pages without auto-update support may need a close and reopen
to receive their first update. Browser storage
belongs to the browser profile and origin: clearing site data removes drafts,
and browser eviction or device failure can still lose them. Storage failures are
shown prominently; navigation warns when the latest edits are not persisted.
This recovery applies to the HTML editor, not the native outerframe editor.

Focused checks: `node Scripts/test_shared_drafts.cjs <PlaintextBackend>`,
`node Scripts/test_live_refresh.cjs`, `node Scripts/test_shell_updates.cjs`,
`python3 Scripts/test_file_notifications.py <PlaintextBackend> <PlaintextHelper>`,
`node Scripts/test_local_drafts.cjs`,
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

## Native undo and redo

The outerframe editor handles Command-Z and Shift-Command-Z through the host's
native Edit menu and offers named actions in its context menu. Each open document
owns a Foundation-only `TextUndoHistory` from `Vendor/TextEditing`: contiguous typing forms word-sized
runs, adjacent deletions in the same direction coalesce, and a two-second pause,
caret movement, focus change, or Save ends the current group. Paste, cut, line
breaks, replacements, and committed marked-text compositions are distinct edits.
Undo and redo restore the caret and selection direction. Character deletion and
movement respect composed Unicode characters.

Undo uses the same local draft checkpoint and revision-checked save pipeline as
ordinary editing. Returning to the saved contents clears the modified indicator;
undoing a saved change marks the draft modified again. A new edit discards redo.
History is kept in memory per document, with up to 200 groups and a 16 MiB text
payload budget (the newest operation is always retained). Draft recovery restores
text and queued saves, but does not restore undo history after restarting.

The outerframe protocol advertises Undo/Redo availability with edit-command mask
bits 7 and 8 and forwards the existing `textCommand` messages `undo` and `redo`.
Find and file-picker text fields have independent undo histories using the same
vendored engine; their focused field receives Undo/Redo instead of the document.
`Scripts/test_native_documents.sh` includes grouping, Unicode, composition,
selection, save-race, and backend draft-cleanliness tests.

## iPhone landscape layout

The HTML editor opts into `viewport-fit=cover`. When the browser exposes the full
landscape width and the opposite-to-camera safe-area margin is at least 52 CSS
pixels wide, the top toolbar becomes an icon stack in that margin: file information, Save
(only when edited), and the document menu. Save is a contextual text button in both orientations. With the keyboard open,
all controls and file information move into the document menu, leaving one
44-pixel ellipsis control in the margin. Safe-area size changes are observed so
arriving on the page already in landscape activates the layout after WebKit
finishes initializing the viewport.
The document retains both safe-area margins; the controls consume no document
width. Screen orientation changes move the menu to the opposite side. A smaller
or already-inset viewport keeps the regular toolbar.

Outer Loop lets WebKit manage viewport fitting and safe-area insets, including
ordinary pages that do not opt into cover. The scrolling simulator test checks
both landscape orientations, keyboard visibility, menu access, the default and
cover viewport behaviors, and portrait keyboard animation stability.
