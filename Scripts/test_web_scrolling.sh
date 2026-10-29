#!/bin/bash
set -euo pipefail
DEVICE="${1:?Usage: test_web_scrolling.sh BOOTED_SIMULATOR_UDID}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTERLOOP_ROOT="${OUTERLOOP_ROOT:-$(dirname "$ROOT")/outerloop}"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/plaintext-scrolling.XXXXXX")"
APP="$TEST_ROOT/Scrolling.app"
BUNDLE_ID=dev.outerloop.plaintext-scrolling-tests
trap 'xcrun simctl uninstall "$DEVICE" "$BUNDLE_ID" >/dev/null 2>&1 || true; rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$APP"
python3 - "$ROOT" "$OUTERLOOP_ROOT" "$TEST_ROOT" <<'PY'
from pathlib import Path
import html, plistlib, sys
root, outerloop, output = map(Path, sys.argv[1:])
web = root / 'Resources/PlaintextWeb'
source = (web / 'index.html').read_text()
markup = source[source.index('<main>'):source.index('</main>') + 7]
contents = ''.join(f'{i:03d} A long line for keyboard, scrolling, and wrapping checks.\n' for i in range(100))
markup = markup.replace('aria-label="Text editor"></textarea>', 'aria-label="Text editor">' + html.escape(contents) + '</textarea>')
markup = markup.replace('Open a file or create a new document', '')
fixture = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>' + (web / 'app.css').read_text() + '</style>' + markup
script = (web / 'app.js').read_text()
start = script.index('function configureEditorFocusScrolling()')
end = script.index('const wrapLinesKey=', start)
fixture += '<script>const $=selector=>document.querySelector(selector);' + script[start:end] + '</script>'
(output / 'Scrolling.app/fixture.html').write_text(fixture)
source = (outerloop / 'OuterLoop/MobileBrowser/MobileBrowserView.swift').read_text()
a = source.index('private struct MobilePageDragValue')
b = source.index('private struct MobileServerForwardSwipeArea', a)
c = source.index('private struct MobileWebView:')
d = source.index('\n@MainActor\nfinal class MobileSudoPasswordPrompt', c)
workspace = (outerloop / 'OuterLoop/MobileBrowser/MobileBrowserWorkspace.swift').read_text()
keyboard = workspace[workspace.index('private struct MobileBrowserKeyboardShortcut'):]
keyboard = keyboard.replace('private struct MobileBrowserKeyboard', 'struct MobileBrowserKeyboard').replace('private final class MobileBrowserKeyboard', 'final class MobileBrowserKeyboard')
(output / 'WebView.swift').write_text('import SwiftUI\nimport WebKit\n' + source[a:b].replace('private struct', 'struct') + source[c:d].replace('private struct MobileWebView', 'struct MobileWebView') + '\n' + keyboard)
(output / 'Scrolling.app/Info.plist').write_bytes(plistlib.dumps(dict(
    CFBundleIdentifier='dev.outerloop.plaintext-scrolling-tests', CFBundleExecutable='Scrolling',
    CFBundlePackageType='APPL', CFBundleName='Scrolling Tests', UILaunchScreen={}, LSRequiresIPhoneOS=True)))
PY
xcrun --sdk iphonesimulator swiftc -target "$(uname -m)-apple-ios26.0-simulator" \
    -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -module-cache-path "$TEST_ROOT/modules" \
    "$ROOT/Tests/WebScrollingTests.swift" "$TEST_ROOT/WebView.swift" \
    "$OUTERLOOP_ROOT/OuterLoop/MobileBrowser/MobilePortraitChromeLayout.swift" \
    "$OUTERLOOP_ROOT/OuterLoop/MobileBrowser/MobilePortraitChromeSurface.swift" -o "$APP/Scrolling"
xcrun simctl install "$DEVICE" "$APP"
xcrun simctl launch --console "$DEVICE" "$BUNDLE_ID" | tee "$TEST_ROOT/result.log"
grep -q 'PASS all web document scrolling checks' "$TEST_ROOT/result.log"
