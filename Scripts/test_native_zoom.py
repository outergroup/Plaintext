#!/usr/bin/env python3
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).resolve().parents[1] / 'Frontend/PlaintextContent.swift').read_text()
a = source.index('    private var pendingTextScale:')
b = source.index('    private func savePreferences()', a)
methods = source[a:b].replace('private ', '')
program = '''import Foundation
import CoreGraphics
class Harness {
    struct Preferences { var textScale: CGFloat = 1 }
    var preferences = Preferences()
    var pendingFilePicker: Bool?
    var layouts = 0
    var saves = 0
    func savePreferences() { saves += 1 }
    func updateTextContent(force: Bool, keepingCursorVisible: Bool) {
        assert(force && keepingCursorVisible)
        layouts += 1
    }
''' + methods + '''
}
func drain(_ seconds: Double = 0.06) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
let h = Harness()
for _ in 0..<500 { h.scheduleTextMagnification(0.001) }
assert(h.layouts == 0)
drain()
assert(h.layouts == 1)
assert(abs(h.preferences.textScale - pow(1.001, 500)) < 0.000001)
assert(h.saves == 0)
for _ in 0..<5 {
    h.scheduleTextMagnification(0.01)
    drain()
    assert(h.saves == 0, "Saved in the middle of a gesture")
}
drain(0.3)
assert(h.saves == 1)
let count = h.layouts
drain()
assert(h.layouts == count, "Zoom has a render backlog")
h.scheduleTextMagnification(100)
drain()
assert(h.preferences.textScale == 3)
let clampedCount = h.layouts
h.scheduleTextMagnification(100)
drain()
assert(h.layouts == clampedCount)
h.scheduleTextMagnification(-0.5)
h.setTextScale(1)
drain()
assert(h.preferences.textScale == 1)
let saved = h.saves
drain(0.3)
assert(h.saves == saved, "Obsolete preference write survived explicit zoom")
h.scheduleTextMagnification(0.5)
h.pendingFilePicker = true
drain()
assert(h.preferences.textScale == 1)
h.setTextScale(.nan)
assert(h.preferences.textScale == 1)
print("PASS: 500-event coalescing, accumulated scale, one layout per frame, debounced persistence, bounds, explicit zoom, picker and nonfinite input")
'''
a = source.index('    private func setTextScale(')
b = source.index('    private func savePreferences()', a)
assert 'layout()' not in source[a:b] and 'updateViewport()' not in source[a:b]
a = source.index('private final class TextFragmentLayer')
b = source.index('private final class SymbolImageLayer', a)
assert 'override func action(forKey event: String) -> CAAction? { nil }' in source[a:b]
with tempfile.TemporaryDirectory() as directory:
    path = Path(directory) / 'main.swift'
    path.write_text(program)
    subprocess.run(['swift', str(path)], check=True)
