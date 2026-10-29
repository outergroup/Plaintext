import Foundation

private final class Editor {
    var text: String
    var selection: TextEditSelection
    let history: TextUndoHistory
    var clock: Double = 0
    init(_ text: String = "", history: TextUndoHistory = TextUndoHistory()) {
        self.text = text; selection = .init(caret: text.utf16.count); self.history = history
    }
    func edit(_ range: NSRange, _ value: String, _ kind: TextUndoHistory.Kind = .typing) {
        guard let indices = Range(range, in: text) else { fatalError("Invalid test range") }
        let removed = String(text[indices]), before = selection
        text.replaceSubrange(indices, with: value)
        selection = .init(caret: range.location + value.utf16.count)
        clock += 0.1
        history.record(range: range, removed: removed, inserted: value, before: before, after: selection, kind: kind, time: clock)
    }
    func type(_ value: String) { for c in value { edit(.init(location: selection.caret, length: 0), String(c)) } }
    func undo() { guard let result = history.undo(text: text) else { fatalError("Expected undo") }; text = result.text; selection = result.selection }
    func redo() { guard let result = history.redo(text: text) else { fatalError("Expected redo") }; text = result.text; selection = result.selection }
    func backspace() { edit((text as NSString).rangeOfComposedCharacterSequence(at: selection.caret - 1), "", .backwardDelete) }
}

@main
struct TextUndoHistoryTests {
    static func main() {
        let words = Editor()
        words.type("hello world")
        words.undo(); precondition(words.text == "hello ")
        words.undo(); precondition(words.text == "" && words.selection.caret == 0)
        words.redo(); words.redo(); precondition(words.text == "hello world")
        words.undo(); words.type("there"); precondition(!words.history.canRedo)
        words.undo(); precondition(words.text == "hello ")

        let pause = Editor()
        pause.type("abc"); pause.clock += 3; pause.type("def")
        pause.undo(); precondition(pause.text == "abc")
        pause.history.breakCoalescing(); pause.type("g"); pause.undo(); precondition(pause.text == "abc")

        let actions = Editor()
        actions.type("a\nb")
        actions.undo(); precondition(actions.text == "a\n")
        actions.undo(); precondition(actions.text == "a")
        actions.edit(.init(location: 1, length: 0), "pasted\ntext", .paste)
        actions.type("x"); actions.undo(); precondition(actions.text == "apasted\ntext")
        actions.undo(); precondition(actions.text == "a")
        actions.redo(); precondition(actions.text == "apasted\ntext")

        let unicode = Editor("A👨‍👩‍👧‍👦e\u{301}🇯🇵")
        let original = unicode.text
        unicode.backspace(); unicode.backspace(); unicode.backspace()
        precondition(unicode.text == "A")
        unicode.undo(); precondition(unicode.text == original)
        unicode.redo(); precondition(unicode.text == "A")
        let forward = Editor("abc"); forward.selection = .init(caret: 0)
        forward.edit(.init(location: 0, length: 1), "", .forwardDelete)
        forward.edit(.init(location: 0, length: 1), "", .forwardDelete)
        forward.undo(); precondition(forward.text == "abc" && forward.selection.caret == 0)

        let selected = Editor("one two")
        selected.selection = .init(caret: 4, anchor: 7)
        selected.edit(.init(location: 4, length: 3), "other", .replacement)
        selected.undo(); precondition(selected.text == "one two" && selected.selection == .init(caret: 4, anchor: 7))
        selected.redo(); precondition(selected.text == "one other" && selected.selection.caret == 9)
        selected.selection = .init(caret: 0, anchor: 4)
        selected.edit(.init(location: 0, length: 4), "", .cut)
        selected.undo(); precondition(selected.text == "one other" && selected.selection == .init(caret: 0, anchor: 4))

        let overtype = Editor("selected")
        overtype.selection = .init(caret: 8, anchor: 0)
        overtype.edit(.init(location: 0, length: 8), "n", .typing)
        overtype.type("ew")
        overtype.undo(); precondition(overtype.text == "selected" && overtype.selection == .init(caret: 8, anchor: 0))
        overtype.redo(); precondition(overtype.text == "new")

        let composition = Editor("hello ")
        composition.history.beginComposition(text: composition.text, selection: composition.selection)
        composition.text = "hello n"
        composition.history.beginComposition(text: composition.text, selection: .init(caret: 7))
        composition.text = "hello 日本語"
        composition.selection = .init(caret: composition.text.utf16.count)
        composition.history.finishComposition(text: composition.text, selection: composition.selection)
        composition.undo(); precondition(composition.text == "hello ")
        composition.redo(); precondition(composition.text == "hello 日本語")
        composition.undo()
        composition.history.beginComposition(text: composition.text, selection: composition.selection)
        composition.history.finishComposition(text: composition.text, selection: composition.selection)
        precondition(composition.history.canRedo)
        composition.redo(); precondition(composition.text == "hello 日本語")

        let markedSelection = Editor("abXYZcd")
        markedSelection.selection = .init(caret: 5, anchor: 2)
        markedSelection.history.beginComposition(text: markedSelection.text, selection: markedSelection.selection)
        markedSelection.text = "abé文cd"; markedSelection.selection = .init(caret: 4)
        markedSelection.history.finishComposition(text: markedSelection.text, selection: markedSelection.selection)
        markedSelection.undo(); precondition(markedSelection.text == "abXYZcd" && markedSelection.selection == .init(caret: 5, anchor: 2))
        markedSelection.redo(); precondition(markedSelection.text == "abé文cd")

        let limited = Editor(history: TextUndoHistory(maximumGroups: 3, maximumBytes: 16))
        for _ in 0..<10 { limited.history.breakCoalescing(); limited.type("a") }
        limited.undo(); limited.undo(); limited.undo(); precondition(!limited.history.canUndo && limited.text == "aaaaaaa")
        let guarded = Editor(); guarded.type("abc")
        precondition(guarded.history.undo(text: "xyz") == nil)
        precondition(guarded.history.canUndo)
        guarded.undo(); precondition(guarded.text == "")
        let noOp = Editor("same")
        noOp.edit(.init(location: 0, length: 4), "same", .replacement)
        precondition(!noOp.history.canUndo)
        print("PASS text undo: word runs, pauses, boundaries, branching redo, paste, cut, Unicode deletion, selection direction, IME commit/cancel, limits, stale edits")
    }
}
