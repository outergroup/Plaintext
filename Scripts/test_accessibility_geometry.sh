#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plaintext-geometry.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
cat > "$TEST_DIR/main.swift" <<'SWIFT'
import AppKit
MainActor.assumeIsolated {
    let storage = NSTextContentStorage()
    let manager = NSTextLayoutManager()
    let container = NSTextContainer(size: CGSize(width: 150, height: 100000))
    container.lineFragmentPadding = 0
    storage.addTextLayoutManager(manager)
    manager.textContainer = container
    let geometry = PlaintextAccessibilityTextLayout(layoutManager: manager)
    var text = "First 😀 snow 雪\nSecond line\n" + String(repeating: "wrapped text ", count: 12) + "\n"
    var generation = 0
    func load(_ value: String) {
        text = value
        generation += 1
        storage.performEditingTransaction {
            storage.textStorage?.setAttributedString(NSAttributedString(string: value, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)]))
        }
        manager.ensureLayout(for: manager.documentRange)
    }
    let viewport = CGRect(x: 20, y: 30, width: 180, height: 75)
    @MainActor func query(_ kind: OuterframeAccessibilityTextQuery, _ range: NSRange = NSRange(location: 0, length: 0), point: CGPoint = .zero, scroll: CGFloat = 0) -> OuterframeAccessibilityTextResult? {
        geometry.query(kind, range: range, point: point, text: text, generation: generation, viewport: viewport, scrollOffset: scroll, inset: CGSize(width: 10, height: 10))
    }
    load(text)
    let emoji = (text as NSString).range(of: "😀")
    guard let frame = query(.frameForRange, emoji)?.frame else { fatalError("No emoji bounds") }
    precondition(frame.width > 0 && frame.height > 0 && viewport.intersects(frame))
    let hit = query(.rangeForPosition, point: CGPoint(x: frame.minX + frame.width * 0.2, y: frame.midY))
    precondition(hit?.range == emoji, "Point must map to composed character: \(String(describing: hit?.range))")
    precondition(query(.frameForRange, NSRange(location: emoji.location + 1, length: 1)) == nil)
    let second = (text as NSString).range(of: "Second")
    guard let lineIndex = query(.lineForIndex, NSRange(location: second.location, length: 0))?.index,
          let line = query(.rangeForLine, NSRange(location: lineIndex, length: 0))?.range else { fatalError("Missing visual line") }
    precondition(NSLocationInRange(second.location, line))
    precondition(query(.rangeForLine, NSRange(location: 99999, length: 0)) == nil)
    precondition(query(.lineForIndex, NSRange(location: text.utf16.count + 1, length: 0)) == nil)
    let visible = query(.visibleRange)?.range
    let scrolled = query(.visibleRange, scroll: 100)?.range
    precondition((visible?.location ?? -1) == 0 && (scrolled?.location ?? 0) > 0)
    let shifted = query(.frameForRange, emoji, scroll: 40)?.frame
    precondition(shifted?.minY == frame.minY + 40)
    let endLine = query(.lineForIndex, NSRange(location: text.utf16.count, length: 0))?.index ?? -1
    precondition(endLine > 3, "Soft wrapping must create visual lines")
    precondition(query(.rangeForLine, NSRange(location: endLine, length: 0))?.range == NSRange(location: text.utf16.count, length: 0))
    container.size.width = 90
    manager.ensureLayout(for: manager.documentRange)
    let narrowerEndLine = query(.lineForIndex, NSRange(location: text.utf16.count, length: 0))?.index ?? -1
    precondition(narrowerEndLine > endLine, "Width change must invalidate line cache")
    container.size.width = 1100
    load("Outer Loop addresses this for two different scenarios:\n- When you already have the server saved in Outer Loop on another device\n- A true \"cold start\"\n\nFollowing paragraph.\n")
    @MainActor func checkLineEnds() {
        let string = text as NSString
        manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: [.ensuresLayout, .ensuresExtraLineFragment]) { fragment in
            let base = manager.offset(from: manager.documentRange.location, to: fragment.rangeInElement.location)
            for line in fragment.textLineFragments {
                let lower = min(base + line.characterRange.location, string.length)
                var upper = min(base + NSMaxRange(line.characterRange), string.length)
                while upper > lower, let scalar = UnicodeScalar(string.character(at: upper - 1)), CharacterSet.newlines.contains(scalar) { upper -= 1 }
                let point = CGPoint(x: container.size.width - 1, y: fragment.layoutFragmentFrame.minY + line.typographicBounds.midY)
                let actual = geometry.insertionOffset(at: point, text: text)
                precondition(actual == upper, "Click past line must stay before its newline: \(actual), expected \(upper)")
                let left = geometry.insertionOffset(at: CGPoint(x: -20, y: point.y), text: text)
                precondition(left == lower, "Click before line must select its beginning")
                let screen = CGRect(x: 0, y: 0, width: container.size.width + 20, height: 10000)
                let hit = geometry.query(.rangeForPosition, range: .init(location: 0, length: 0),
                                         point: CGPoint(x: point.x, y: screen.maxY - point.y), text: text,
                                         generation: generation, viewport: screen, scrollOffset: 0, inset: .zero)
                precondition(hit?.range.location == upper, "Accessibility must use the same line-end hit test")
            }
            return true
        }
    }
    checkLineEnds()
    load("First 😀 line\r\nSecond line\rThird line\u{2028}Fourth line\u{2029}\n")
    checkLineEnds()
    container.size.width = 150
    load(String(repeating: "wrapped words ", count: 12) + "\n\nFinal line")
    checkLineEnds()
    load("")
    precondition(query(.rangeForLine)?.range == NSRange(location: 0, length: 0))
    precondition(query(.lineForIndex)?.index == 0)
    precondition(query(.frameForRange)?.frame.height ?? 0 > 0)
    print("PASS TextKit accessibility geometry: Unicode, wrapping, scrolling, resize, line-end clicks, newlines, EOF, and empty document")
}
SWIFT
xcrun swiftc -module-cache-path "$TEST_DIR/modules" "$ROOT/Vendor/OuterframeSwiftMethods/OuterframeAccessibility.swift" \
    "$ROOT/Frontend/PlaintextAccessibilityTextLayout.swift" "$TEST_DIR/main.swift" -o "$TEST_DIR/test"
"$TEST_DIR/test"
