from pathlib import Path
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]

def methods(path, names):
    source = (root / path).read_text()
    result = []
    for name in names:
        match = re.search(r'    private func ' + name + r'\(.*?^    }', source, re.M | re.S)
        if not match:
            raise RuntimeError('Missing method: ' + name)
        result.append(match.group().replace('private func', 'func', 1))
    return '\n'.join(result)

fixture = r'''
import AppKit
import QuartzCore
final class Editor {
    var text = ""
    var attributedText: NSAttributedString { NSAttributedString(string: text.isEmpty ? " " : text) }
    let editorCaretLayer = CALayer(), pathPromptCursorLayer = CALayer()
    let filePickerNameCaretLayer = CALayer(), findCaretLayer = CALayer()
    let caretBlinkAnimationKey = "caretBlink"
    func withoutImplicitAnimations(_ body: () -> Void) { body() }
    EDITOR_METHODS
}
final class Field {
    var text = ""
    FIELD_METHODS
}
let editor = Editor(), field = Field()
let sentence = "Shipping a command-line interface"
editor.text = sentence
field.text = sentence
var position = 0
for expected in [8, 10, 18, 23, 33] {
    position = editor.nextWordBoundary(from: position)
    precondition(position == expected)
}
for expected in [24, 19, 11, 9, 0] {
    position = editor.previousWordBoundary(from: position)
    precondition(position == expected)
}
for sample in ["", sentence, "  hello, world!  ", "can't stop", "a😀b café e\u{301}lan", "日本語 テキスト", "one\ntwo\tthree"] {
    editor.text = sample
    field.text = sample
    let native = NSAttributedString(string: sample)
    for character in 0...sample.count {
        let index = sample.index(sample.startIndex, offsetBy: character)
        let offset = index.utf16Offset(in: sample)
        for forward in [false, true] {
            let expected = native.nextWord(from: offset, forward: forward)
            let actual = forward ? editor.nextWordBoundary(from: offset) : editor.previousWordBoundary(from: offset)
            precondition(actual == expected)
            let fieldPosition = forward ? field.findNextWordBoundary(from: character) : field.findPreviousWordBoundary(from: character)
            let fieldOffset = sample.index(sample.startIndex, offsetBy: fieldPosition).utf16Offset(in: sample)
            precondition(fieldOffset == expected)
        }
    }
}
editor.startBlinkingCaret(editor.editorCaretLayer)
let initial = editor.editorCaretLayer.animation(forKey: editor.caretBlinkAnimationKey)!.beginTime
editor.startBlinkingCaret(editor.editorCaretLayer)
precondition(editor.editorCaretLayer.animation(forKey: editor.caretBlinkAnimationKey)!.beginTime == initial)
Thread.sleep(forTimeInterval: 0.02)
editor.resetCaretBlink()
let restarted = editor.editorCaretLayer.animation(forKey: editor.caretBlinkAnimationKey)!.beginTime
precondition(restarted > initial)
precondition(restarted > CACurrentMediaTime() + 0.4)
precondition(editor.editorCaretLayer.opacity == 1)
precondition(editor.findCaretLayer.animation(forKey: editor.caretBlinkAnimationKey) == nil)
print("PASS native word stops, reverse navigation, Unicode text fields, and caret idle delay")
'''
fixture = fixture.replace('EDITOR_METHODS', methods('Frontend/PlaintextContent.swift', ['clampedOffset', 'previousWordBoundary', 'nextWordBoundary', 'resetCaretBlink', 'startBlinkingCaret', 'stopBlinkingCaret']))
fixture = fixture.replace('FIELD_METHODS', methods('Frontend/SingleLineTextInputController.swift', ['clamp', 'stringIndex', 'characterIndexForUTF16', 'findPreviousWordBoundary', 'findNextWordBoundary']))
with tempfile.TemporaryDirectory(prefix='plaintext-keyboard-') as directory:
    main = Path(directory) / 'main.swift'
    binary = Path(directory) / 'test'
    main.write_text(fixture)
    subprocess.run(['swiftc', '-framework', 'AppKit', '-module-cache-path', str(Path(directory) / 'modules'), str(main), '-o', str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
