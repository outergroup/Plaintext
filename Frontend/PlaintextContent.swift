import AppKit
import CoreText
import Foundation
import QuartzCore

@MainActor
@objc public final class PlaintextContent: NSObject, OuterframeContentLibrary {
    @objc public static func start(socketFD: Int32, appConnection: OuterframeAppConnection) -> Int32 {
        let host = OuterframeHost(socketFD: socketFD)
        let handler = PlaintextHandler(outerframeHost: host, appConnection: appConnection)
        host.delegate = handler
        return 0
    }
}

private struct PlaintextConfiguration {
    let fileAPIPath: String
    let filesAPIPath: String

    init?(data: Data) {
        guard PlaintextBinary.version(in: data) == 2,
              let fileAPIPath = PlaintextBinary.stringRef64(in: data, at: 4),
              let filesAPIPath = PlaintextBinary.stringRef64(in: data, at: 20) else {
            return nil
        }
        self.fileAPIPath = fileAPIPath
        self.filesAPIPath = filesAPIPath
    }
}

private enum PlaintextBinary {
    static func version(in data: Data) -> UInt32? {
        uint32(in: data, at: 0)
    }

    static func uint8(in data: Data, at offset: Int) -> UInt8? {
        guard offset >= 0, offset < data.count else { return nil }
        return data[offset]
    }

    static func uint32(in data: Data, at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    static func uint64(in data: Data, at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= data.count else { return nil }
        return UInt64(data[offset])
            | (UInt64(data[offset + 1]) << 8)
            | (UInt64(data[offset + 2]) << 16)
            | (UInt64(data[offset + 3]) << 24)
            | (UInt64(data[offset + 4]) << 32)
            | (UInt64(data[offset + 5]) << 40)
            | (UInt64(data[offset + 6]) << 48)
            | (UInt64(data[offset + 7]) << 56)
    }

    static func double(in data: Data, at offset: Int) -> Double? {
        guard let bits = uint64(in: data, at: offset) else { return nil }
        return Double(bitPattern: bits)
    }

    static func stringRef64(in data: Data, at offset: Int) -> String? {
        guard let range = ref64Range(in: data, at: offset) else { return nil }
        return String(data: data.subdata(in: range), encoding: .utf8)
    }

    private static func ref64Range(in data: Data, at offset: Int) -> Range<Int>? {
        guard let refOffsetValue = uint64(in: data, at: offset),
              let refLengthValue = uint64(in: data, at: offset + 8),
              refOffsetValue <= UInt64(Int.max),
              refLengthValue <= UInt64(Int.max) else {
            return nil
        }
        let refOffset = Int(refOffsetValue)
        let refLength = Int(refLengthValue)
        guard refOffset >= 0,
              refOffset <= data.count,
              refLength <= data.count - refOffset else {
            return nil
        }
        return refOffset..<(refOffset + refLength)
    }
}

private enum BinaryPayloadError: Error {
    case outOfBounds
    case invalidString
}

private struct BinaryPayloadReader {
    let data: Data

    func uint32(at offset: Int) throws -> UInt32 {
        guard let value = PlaintextBinary.uint32(in: data, at: offset) else { throw BinaryPayloadError.outOfBounds }
        return value
    }

    func uint64(at offset: Int) throws -> UInt64 {
        guard let value = PlaintextBinary.uint64(in: data, at: offset) else { throw BinaryPayloadError.outOfBounds }
        return value
    }

    func double(at offset: Int) throws -> Double {
        Double(bitPattern: try uint64(at: offset))
    }

    func dataRef(at offset: Int) throws -> Data {
        let start = Int(try uint32(at: offset))
        let length = Int(try uint32(at: offset + 4))
        guard start >= 0, length >= 0, start <= data.count, length <= data.count - start else {
            throw BinaryPayloadError.outOfBounds
        }
        return Data(data[start..<(start + length)])
    }

    func stringRef(at offset: Int) throws -> String {
        let bytes = try dataRef(at: offset)
        guard !bytes.isEmpty else { return "" }
        guard let string = String(data: bytes, encoding: .utf8) else {
            throw BinaryPayloadError.invalidString
        }
        return string
    }

    func child(at offset: Int) throws -> BinaryPayloadReader {
        BinaryPayloadReader(data: try dataRef(at: offset))
    }
}

private struct FilePickerResponse {
    let path: String
    let parent: String
    let entries: [FilePickerEntryRecord]

    static func decodeBinary(_ data: Data) throws -> FilePickerResponse {
        let reader = BinaryPayloadReader(data: data)
        let count = Int(try reader.uint32(at: 16))
        var entries: [FilePickerEntryRecord] = []
        entries.reserveCapacity(count)
        for index in 0..<count {
            entries.append(try FilePickerEntryRecord.decodeBinary(try reader.child(at: 20 + index * 8)))
        }
        return FilePickerResponse(path: try reader.stringRef(at: 0),
                                  parent: try reader.stringRef(at: 8),
                                  entries: entries)
    }
}

private struct FilePickerEntryRecord {
    let name: String
    let path: String
    let isDirectory: Bool
    let size: UInt64
    let modified: Double

    static func decodeBinary(_ reader: BinaryPayloadReader) throws -> FilePickerEntryRecord {
        FilePickerEntryRecord(name: try reader.stringRef(at: 0),
                              path: try reader.stringRef(at: 8),
                              isDirectory: (try reader.uint32(at: 16) & 0x01) != 0,
                              size: try reader.uint64(at: 20),
                              modified: try reader.double(at: 28))
    }
}

private struct NativeRecentFile: Codable {
    var path: String
    var target: String
}
private struct NativePreferences: Codable {
    var textScale: CGFloat = 1
    var wrapLines = true
    var recent: [NativeRecentFile] = []
}

private struct PendingFilePicker {
    var directory: String
    var entries: [FilePickerEntryRecord]
    var isLoading: Bool
    var error: String
}

private struct EditorVisualLine {
    let range: NSRange
}

private struct EditorVisualLineMetrics {
    let textWidth: CGFloat
    let charWidth: CGFloat
    let lineHeight: CGFloat
    let charactersPerLine: Int
    let lines: [EditorVisualLine]
}

private final class TextFragmentLayer: CALayer {
    var textLayoutFragment: NSTextLayoutFragment? {
        didSet {
            if textLayoutFragment !== oldValue {
                setNeedsDisplay()
            }
        }
    }
    var renderingSurfaceOffset: CGPoint = .zero {
        didSet {
            if renderingSurfaceOffset != oldValue {
                setNeedsDisplay()
            }
        }
    }

    override init() {
        super.init()
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
    }

    override init(layer: Any) {
        super.init(layer: layer)
        if let layer = layer as? TextFragmentLayer {
            textLayoutFragment = layer.textLayoutFragment
            renderingSurfaceOffset = layer.renderingSurfaceOffset
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func action(forKey event: String) -> CAAction? { nil }

    override func draw(in context: CGContext) {
        guard let textLayoutFragment else { return }
        context.saveGState()
        context.translateBy(x: 0, y: bounds.height)
        context.scaleBy(x: 1, y: -1)
        textLayoutFragment.draw(at: CGPoint(x: -renderingSurfaceOffset.x,
                                            y: -renderingSurfaceOffset.y),
                                in: context)
        context.restoreGState()
    }
}

private final class SymbolImageLayer: CALayer {
    var symbolName: String {
        didSet { setNeedsDisplay() }
    }
    var accessibilityTitle: String {
        didSet { setNeedsDisplay() }
    }
    var tintColor: NSColor = .labelColor {
        didSet { setNeedsDisplay() }
    }
    var symbolPointSize: CGFloat = 9 {
        didSet { setNeedsDisplay() }
    }
    var symbolWeight: NSFont.Weight = .medium {
        didSet { setNeedsDisplay() }
    }
    var maxSymbolSize = CGSize(width: 10, height: 7) {
        didSet { setNeedsDisplay() }
    }

    init(symbolName: String, accessibilityTitle: String) {
        self.symbolName = symbolName
        self.accessibilityTitle = accessibilityTitle
        super.init()
        contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        needsDisplayOnBoundsChange = true
    }

    override init(layer: Any) {
        if let layer = layer as? SymbolImageLayer {
            symbolName = layer.symbolName
            accessibilityTitle = layer.accessibilityTitle
            tintColor = layer.tintColor
            symbolPointSize = layer.symbolPointSize
            symbolWeight = layer.symbolWeight
            maxSymbolSize = layer.maxSymbolSize
        } else {
            symbolName = "circle"
            accessibilityTitle = ""
        }
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(in context: CGContext) {
        guard let image = NSImage(systemSymbolName: symbolName,
                                  accessibilityDescription: accessibilityTitle) else {
            return
        }
        image.isTemplate = true
        let configuredImage = image.withSymbolConfiguration(.init(pointSize: symbolPointSize, weight: symbolWeight)) ?? image
        let imageSize = configuredImage.size
        let maxSize = CGSize(width: min(bounds.width, maxSymbolSize.width),
                             height: min(bounds.height, maxSymbolSize.height))
        let scale = min(maxSize.width / max(imageSize.width, 1),
                        maxSize.height / max(imageSize.height, 1))
        let iconSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let iconRect = CGRect(x: bounds.midX - iconSize.width / 2,
                              y: bounds.midY - iconSize.height / 2,
                              width: iconSize.width,
                              height: iconSize.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        configuredImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        context.setBlendMode(.sourceIn)
        context.setFillColor(tintColor.cgColor)
        context.fill(iconRect)
        context.endTransparencyLayer()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private enum PathPromptMode {
    case open
    case moveRename
    case saveAs
    case saveCopy

    var label: String {
        switch self {
        case .open:
            return "Open"
        case .moveRename:
            return "Move/Rename"
        case .saveAs: return "Save As"
        case .saveCopy: return "Save a Copy"
        }
    }
}

@MainActor
private final class PlaintextHandler: NSObject, OuterframeHostDelegate, ScrollbarControllerDelegate, SingleLineTextInputControllerDelegate {
    private let outerframeHost: OuterframeHost
    private let appConnection: OuterframeAppConnection
    private var retainedSelf: PlaintextHandler?

    private var appearance: NSAppearance = .currentDrawing()
    private var currentSize = CGSize(width: 900, height: 640)
    private var resizeLayoutUpdateScheduled = false
    private var windowIsActive = true
    private var viewIsFocused = true
    private var didRegisterLayer = false
    private var currentURLString = ""

    private var urlSession: URLSession?
    private var filesEndpoint: URL?
    private var filePath = ""
    private var statusText = "Loading..."
    private var isLoading = false
    private var isSaving = false
    private var environmentEndpoint: URL?
    private var draftStore: PlaintextDraftStore?
    private var document: PlaintextDocument?
    private var documents: [String: PlaintextDocument] = [:]
    private var reviewedDisk: PlaintextReply?
    private var showingServerVersion = false
    private var didRestoreQueue = false
    private var preferences = NativePreferences()
    private var preferencesWriteTask: Task<Void, Never>?
    private var watchTask: Task<Void, Never>?
    private var watchedKey = ""
    private var pickerMode = "open"
    private var pickerRequest = UUID()
    private var recentFrames: [(CGRect, CGRect, NativeRecentFile)] = []
    private var recentTabFrame = CGRect.zero
    private var openTabFrame = CGRect.zero
    private var newFileFrame = CGRect.zero
    private var openControlFrame = CGRect.zero
    private var saveControlFrame = CGRect.zero
    private var menuControlFrame = CGRect.zero
    private var containerControlFrame = CGRect.zero
    private let containerButtonLayer = CALayer()
    private let containerTitleLayer = CATextLayer()
    private let openButtonLayer = CALayer()
    private let openIconLayer = SymbolImageLayer(symbolName: "folder", accessibilityTitle: "Open files")
    private let saveButtonLayer = CATextLayer()
    private let menuButtonLayer = CATextLayer()
    private var horizontalOffset: CGFloat = 0
    private var naturalTextWidth: CGFloat = 0
    private var shouldPushHistory = false
    private var showStartupPopover = false
    private var reviewedShared: PlaintextReply?
    private var pickerTarget = "host"
    private var targets: [(id: String, name: String, running: Bool)] = []
    private var targetControlFrame = CGRect.zero
    private var targetMenuIDs: Set<UUID> = []
    private var conflictFrames: [(CGRect, String)] = []


    private let rootLayer = CALayer()
    private let backgroundLayer = CALayer()
    private let headerLayer = CALayer()
    private let toolbarDividerLayer = CALayer()
    private let statusLayer = CATextLayer()
    private let pathLayer = CATextLayer()
    private let pathChevronLayer = SymbolImageLayer(symbolName: "chevron.down", accessibilityTitle: "File actions")
    private let pathPromptCursorLayer = CALayer()
    private let editorClipLayer = CALayer()
    private let textContentLayer = CALayer()
    private let textSelectionLayer = CALayer()
    private let editorCaretLayer = CALayer()
    private let filePickerOverlayLayer = CALayer()
    private let filePickerListLayer = CALayer()
    private let filePickerRowsContentLayer = CALayer()
    private let filePickerStatusLayer = CALayer()
    private let filePickerBreadcrumbLayer = CALayer()
    private let filePickerNameFieldLayer = CALayer()
    private let filePickerNameTextLayer = CATextLayer()
    private let filePickerNamePlaceholderLayer = CATextLayer()
    private let filePickerNameSelectionLayer = CALayer()
    private let filePickerNameMarkedUnderlineLayer = CALayer()
    private let filePickerNameCaretLayer = CALayer()
    private let findBarLayer = CALayer()
    private let findFieldLayer = CALayer()
    private let findTextLayer = CATextLayer()
    private let findPlaceholderLayer = CATextLayer()
    private let findSelectionLayer = CALayer()
    private let findMarkedUnderlineLayer = CALayer()
    private let findCaretLayer = CALayer()
    private let findPreviousButtonLayer = CALayer()
    private let findPreviousIconLayer = SymbolImageLayer(symbolName: "chevron.left", accessibilityTitle: "Find Previous")
    private let findNextButtonLayer = CALayer()
    private let findNextIconLayer = SymbolImageLayer(symbolName: "chevron.right", accessibilityTitle: "Find Next")
    private let findStatusLayer = CATextLayer()
    private let findDoneButtonLayer = CALayer()
    private let findDoneTextLayer = CATextLayer()

    private let contentStorage = NSTextContentStorage()
    private let textLayoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: CGSize(width: 320, height: 1_000_000))
    private var textFragmentLayers: [ObjectIdentifier: TextFragmentLayer] = [:]
    private var fragmentCoverage: (generation: Int, textWidth: CGFloat, contentHeight: CGFloat, rect: CGRect)?

    private var text = ""
    private var attributedText = NSAttributedString(string: "")
    private var generation = 0
    private var contentHeightCache: (generation: Int, textWidth: CGFloat, height: CGFloat)?
    private var visualLineCache: (generation: Int, textWidth: CGFloat, metrics: EditorVisualLineMetrics)?
    private var textLayoutWidth: CGFloat = 0

    private var cursorOffset = 0
    private var selectionAnchor: Int?
    private var dragAnchorOffset: Int?
    private var selectionLayers: [CALayer] = []
    private var scrollOffset: CGFloat = 0
    private var scrollbarController: ScrollbarController<PlaintextHandler>?
    private lazy var filePickerScrollbarDelegate = FilePickerScrollbarDelegate(owner: self)
    private var filePickerScrollbarController: ScrollbarController<FilePickerScrollbarDelegate>?
    private var pathControlFrame = CGRect.zero
    private var pendingPathMenuIDs: Set<UUID> = []
    private var pendingFindMenuIDs: Set<UUID> = []
    private var pendingFilePickerNameMenuIDs: Set<UUID> = []
    private var pathPromptMode: PathPromptMode?
    private var pathPromptText = ""
    private var pathPromptCursorOffset = 0
    private var pathPromptSelectionRange: NSRange?
    private let pathPromptSelectionLayer = CALayer()
    private var pendingFilePicker: PendingFilePicker?
    private var filePickerPanelFrame = CGRect.zero
    private var filePickerListFrame = CGRect.zero
    private var filePickerBreadcrumbFrame = CGRect.zero
    private var filePickerNameFieldFrame = CGRect.zero
    private var filePickerCancelFrame = CGRect.zero
    private var filePickerOpenFrame = CGRect.zero
    private var filePickerBreadcrumbSegmentFrames: [(frame: CGRect, path: String)] = []
    private var filePickerEntryFrames: [(frame: CGRect, entry: FilePickerEntryRecord, index: Int)] = []
    private var filePickerVisibleRowLayers: [Int: CALayer] = [:]
    private var filePickerReusableRowLayers: [CALayer] = []
    private var filePickerSelectedIndex: Int?
    private var filePickerScroll: CGFloat = 0
    private var filePickerContentHeight: CGFloat = 0
    private var filePickerTypeaheadBuffer = ""
    private var filePickerTypeaheadDeadline: Date?
    private var filePickerFadeToken = UUID()
    private var isFilePickerFadingOut = false
    private lazy var findInputController: SingleLineTextInputController<PlaintextHandler> = {
        let controller = SingleLineTextInputController<PlaintextHandler>(
            identifier: findInputID,
            acceptedPasteboardTypeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue]
        )
        controller.delegate = self
        controller.onSubmit = { [weak self] in
            self?.findNext()
        }
        return controller
    }()
    private lazy var filePickerNameInputController: SingleLineTextInputController<PlaintextHandler> = {
        let controller = SingleLineTextInputController<PlaintextHandler>(
            identifier: filePickerNameInputID,
            acceptedPasteboardTypeIdentifiers: [NSPasteboard.PasteboardType.string.rawValue]
        )
        controller.delegate = self
        controller.onSubmit = { [weak self] in
            self?.openFilePickerTypedPath()
        }
        return controller
    }()
    private var isFindVisible = false
    private var findMatches: [NSRange] = []
    private var activeFindMatchIndex: Int?
    private var markedTextRange: NSRange?
    private var pendingMarkedTextReplacementRange: NSRange?
    private var findBarFrame = CGRect.zero
    private var findFieldFrame = CGRect.zero
    private var findPreviousButtonFrame = CGRect.zero
    private var findNextButtonFrame = CGRect.zero
    private var findDoneButtonFrame = CGRect.zero
    private var accessibilityNotificationScheduled = false

    private let editorInputID = UUID()
    private let findInputID = UUID()
    private let filePickerNameInputID = UUID()
    private let headerHeight: CGFloat = 58
    private let textInsetX: CGFloat = 14
    private let textInsetY: CGFloat = 12
    private let textMeasurementHeight: CGFloat = 10_000_000
    private let scrollLineHeight: CGFloat = 18
    private let filePickerRowHeight: CGFloat = 28
    private let cursorWidth: CGFloat = 1.5
    private let caretBlinkAnimationKey = "caretBlink"

    init(outerframeHost: OuterframeHost, appConnection: OuterframeAppConnection) {
        self.outerframeHost = outerframeHost
        self.appConnection = appConnection
        super.init()
        retainedSelf = self

        textContainer.lineFragmentPadding = 0
        textLayoutManager.textContainer = textContainer
        textLayoutManager.usesFontLeading = true
        contentStorage.addTextLayoutManager(textLayoutManager)
        contentStorage.attributedString = attributedText
    }

    func outerframeHost(_ host: OuterframeHost, didReceiveMessage message: BrowserToContentMessage) {
        switch message {
        case .initializeContent(let arguments):
            configure(with: arguments)
        case .resizeContent(let size):
            currentSize = size
            scheduleResizeLayoutUpdate()
        case .systemAppearanceUpdate(let nextAppearance):
            appearance = nextAppearance
            updateColors()
            layout()
            updateTextContent(force: true)
        case .windowActiveUpdate(let isActive):
            if !isActive {
                endUndoGroup()
                findInputController.breakUndoCoalescing()
                filePickerNameInputController.breakUndoCoalescing()
            }
            windowIsActive = isActive
            updateSelectionLayers(force: true)
            updateCursor()
        case .viewFocusChanged(let isFocused):
            if !isFocused {
                endUndoGroup()
                findInputController.breakUndoCoalescing()
                filePickerNameInputController.breakUndoCoalescing()
            }
            viewIsFocused = isFocused
            updateCursor()
        case .mouseDown(let point, let modifierFlags, let clickCount):
            endUndoGroup()
            if modifierFlags.contains(.control) {
                if pendingFilePicker != nil {
                    _ = handleFilePickerMouseDown(point: point, clickCount: clickCount)
                    return
                }
                handleRightMouseDown(point: point, clickCount: clickCount)
                return
            }
            if pendingFilePicker != nil {
                _ = handleFilePickerMouseDown(point: point, clickCount: clickCount)
                _ = modifierFlags
                return
            }
            handleMouseDown(point: point, modifierFlags: modifierFlags, clickCount: clickCount)
        case .mouseDragged(let point, _):
            if pendingFilePicker != nil {
                _ = filePickerScrollbarController?.handleMouseDragged(to: filePickerListLayer.convert(rootLayer.convert(point, to: rootLayer), from: rootLayer))
                return
            }
            handleMouseDragged(point: point)
        case .mouseUp(let point, _):
            if pendingFilePicker != nil {
                _ = filePickerScrollbarController?.handleMouseUp(at: filePickerListLayer.convert(rootLayer.convert(point, to: rootLayer), from: rootLayer))
                return
            }
            _ = scrollbarController?.handleMouseUp(at: rootLayer.convert(point, to: editorClipLayer))
            dragAnchorOffset = nil
        case .mouseMoved(let point, _):
            updateCursorShape(at: point)
        case .rightMouseDown(let point, _, let clickCount):
            if pendingFilePicker != nil {
                let rootPoint = rootLayer.convert(point, to: rootLayer)
                if filePickerNameFieldFrame.contains(rootPoint) {
                    focusFilePickerNameField(atRootPoint: rootPoint, clickCount: clickCount, modifySelection: false)
                    showFilePickerNameContextMenu(at: point)
                    return
                }
                _ = handleFilePickerMouseDown(point: point, clickCount: clickCount)
                return
            }
            handleRightMouseDown(point: point, clickCount: clickCount)
        case .keyDown(_, let characters, let charactersIgnoringModifiers, let modifierFlags, _):
            if pendingFilePicker != nil,
               handleFilePickerKeyDown(characters: characters,
                                       charactersIgnoringModifiers: charactersIgnoringModifiers,
                                       modifierFlags: modifierFlags) {
                return
            }
            handleKeyDown(characters: characters,
                          charactersIgnoringModifiers: charactersIgnoringModifiers,
                          modifierFlags: modifierFlags)
        case .magnification(_, let amount, let point, _):
            if pendingFilePicker == nil && editorClipLayer.frame.contains(point) { scheduleTextMagnification(amount) }
        case .scrollWheelEvent(let point, let delta, _, _, _, let precise):
            let rootPoint = rootLayer.convert(point, to: rootLayer)
            if pendingFilePicker != nil, pickerMode == "conflict", filePickerPanelFrame.contains(rootPoint) {
                filePickerScroll = max(0, filePickerScroll - delta.y * (precise ? 1 : 28)); renderFilePicker()
            } else if pendingFilePicker != nil, pickerMode == "recent", filePickerPanelFrame.contains(rootPoint) {
                filePickerScroll = min(max(0, filePickerScroll - delta.y * (precise ? 1 : 28)), max(0, CGFloat(preferences.recent.count) * 58 - filePickerPanelFrame.height + 70)); renderFilePicker()
            } else if pendingFilePicker != nil, filePickerListFrame.contains(rootPoint) {
                setFilePickerScroll(filePickerScroll - delta.y * (precise ? 1 : filePickerRowHeight))
            } else if editorClipLayer.frame.contains(rootPoint) {
                if !preferences.wrapLines { horizontalOffset = min(max(0, horizontalOffset - delta.x * (precise ? 1 : 18)), max(0, editorTextWidth() - editorClipLayer.bounds.width + textInsetX * 2)) }
                scrollOffset = clampedScrollOffset(scrollOffset - delta.y * (precise ? 1 : scrollLineHeight))
                updateViewport()
                updateCursor()
            }
        case .textInput(let input, let hasReplacementRange, let replacementLocation, let replacementLength):
            if pendingFilePicker != nil {
                if filePickerNameInputController.isFocused {
                    if hasReplacementRange {
                        let lower = min(max(Int(replacementLocation), 0), filePickerNameInputController.text.count)
                        let upper = min(max(lower + Int(replacementLength), lower), filePickerNameInputController.text.count)
                        filePickerNameInputController.replaceText(range: lower..<upper, with: input)
                    } else {
                        filePickerNameInputController.insertText(input)
                    }
                }
            } else if findInputController.isFocused {
                if hasReplacementRange {
                    let lower = min(max(Int(replacementLocation), 0), findInputController.text.count)
                    let upper = min(max(lower + Int(replacementLength), lower), findInputController.text.count)
                    findInputController.replaceText(range: lower..<upper, with: input)
                } else {
                    findInputController.insertText(input)
                }
            } else if pathPromptMode != nil {
                if hasReplacementRange {
                    replacePathPromptText(range: NSRange(location: Int(replacementLocation),
                                                         length: Int(replacementLength)),
                                          with: input)
                } else {
                    insertPathPromptText(input)
                }
            } else if hasReplacementRange {
                replace(range: NSRange(location: Int(replacementLocation), length: Int(replacementLength)), with: input)
            } else {
                insertText(input)
            }
        case .setMarkedText(let input, let selectedLocation, let selectedLength, let hasReplacementRange, let replacementLocation, let replacementLength):
            if pendingFilePicker != nil {
                if filePickerNameInputController.isFocused {
                    let replacementRange: Range<Int>? = hasReplacementRange
                        ? Int(replacementLocation)..<(Int(replacementLocation) + Int(replacementLength))
                        : nil
                    filePickerNameInputController.setMarkedText(input,
                                                               selectedLocation: Int(selectedLocation),
                                                               selectedLength: Int(selectedLength),
                                                               replacementRange: replacementRange)
                }
            } else if findInputController.isFocused {
                let replacementRange: Range<Int>? = hasReplacementRange
                    ? Int(replacementLocation)..<(Int(replacementLocation) + Int(replacementLength))
                    : nil
                findInputController.setMarkedText(input,
                                                  selectedLocation: Int(selectedLocation),
                                                  selectedLength: Int(selectedLength),
                                                  replacementRange: replacementRange)
            } else if pathPromptMode != nil {
                if hasReplacementRange {
                    replacePathPromptText(range: NSRange(location: Int(replacementLocation),
                                                         length: Int(replacementLength)),
                                          with: input)
                } else {
                    insertPathPromptText(input)
                }
            } else {
                setMarkedText(input,
                              selectedLocation: Int(selectedLocation),
                              selectedLength: Int(selectedLength),
                              hasReplacementRange: hasReplacementRange,
                              replacementLocation: Int(replacementLocation),
                              replacementLength: Int(replacementLength))
            }
        case .unmarkText:
            if filePickerNameInputController.isFocused {
                filePickerNameInputController.unmarkText()
            } else if findInputController.isFocused {
                findInputController.unmarkText()
            } else if pathPromptMode != nil {
                _ = pathPromptMode
            } else {
                unmarkText()
            }
        case .textCommand(let command):
            if pendingFilePicker != nil {
                performFilePickerTextCommand(command)
            } else if findInputController.isFocused {
                performFindTextCommand(command)
            } else if pathPromptMode != nil {
                performPathPromptTextCommand(command)
            } else {
                performTextCommand(command)
            }
        case .setCursorPosition(let fieldID, let position, let modifySelection):
            if fieldID == filePickerNameInputID {
                filePickerNameInputController.setCursorPosition(Int(position), modifySelection: modifySelection)
            } else if fieldID == findInputID {
                findInputController.setCursorPosition(Int(position), modifySelection: modifySelection)
            } else if fieldID != editorInputID {
                return
            } else if pathPromptMode != nil {
                let textLength = (pathPromptText as NSString).length
                let destination = min(max(Int(position), 0), textLength)
                guard OuterframeAccessibilityTextRange.isValid(NSRange(location: destination, length: 0), in: pathPromptText) else { return }
                let anchor = pathPromptSelectionRange?.location ?? pathPromptCursorOffset
                pathPromptSelectionRange = modifySelection && destination != anchor
                    ? NSRange(location: min(anchor, destination), length: abs(destination - anchor)) : nil
                pathPromptCursorOffset = destination
                layout()
            } else {
                setCursorOffset(Int(position), modifySelection: modifySelection)
            }
        case .selectionToPasteboardCopyRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID, items: pasteboardItemsForCopy())
        case .selectionToPasteboardCutRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID, items: pasteboardItemsForCut())
        case .editCommandValidationRequest(let requestID, let commands):
            outerframeHost.sendEditCommandValidationResponse(
                requestID: requestID,
                enabledCommands: enabledEditCommands(in: commands)
            )
        case .pasteboardContentPasted(let items):
            if pendingFilePicker != nil {
                pasteFilePickerName(items)
            } else if pathPromptMode != nil {
                pastePathPrompt(items)
            } else {
                paste(items)
            }
        case .pasteboardDropHitTestRequest(let requestID, let point, let pasteboardTypes, let operationMask, _):
            let accepts = pendingFilePicker == nil && isPointInEditor(point) && pasteboardTypes.contains(NSPasteboard.PasteboardType.string.rawValue)
            outerframeHost.sendPasteboardDropHitTestResponse(requestID: requestID,
                                                             operationMask: accepts ? NSDragOperation.copy : [])
            _ = operationMask
        case .pasteboardContentDropped(let point, let items):
            guard pendingFilePicker == nil else { return }
            let offset = textOffset(atRootPoint: point)
            setCursorOffset(offset, modifySelection: false)
            paste(items)
        case .contextMenuItemSelected(let menuID, let itemID):
            handleContextMenuItem(menuID: menuID, itemID: itemID)
        case .accessibilityActionAndSnapshot(let requestID, let identifier, let action, let value):
            performAccessibilityAction(identifier, action: action, value: value)
            outerframeHost.sendAccessibilitySnapshotResponse(requestID: requestID, snapshot: buildAccessibilitySnapshot())
        case .accessibilityAction(let identifier, let action, let value):
            performAccessibilityAction(identifier, action: action, value: value)
        case .accessibilityTextQuery(let requestID, let identifier, let query, let range, let point):
            _ = buildAccessibilitySnapshot()
            outerframeHost.sendAccessibilityTextResponse(requestID: requestID,
                result: accessibilityTextQuery(identifier: identifier, query: query, range: range, point: point))
        case .accessibilitySnapshotRequest(let requestID):
            outerframeHost.sendAccessibilitySnapshotResponse(requestID: requestID,
                                                             snapshot: buildAccessibilitySnapshot())
        case .historyTraversal(_, let url):
            currentURLString = url
            showStartupPopover = filePath(from: url) == nil && queryValue("draft") == nil
            openDocument(path: filePath(from: url) ?? "", draftID: queryValue("draft"), target: queryValue("target"))
        case .shutdown:
            watchTask?.cancel(); watchTask = nil
            flushDrafts()
            retainedSelf = nil
        default:
            break
        }
    }

    func outerframeHostDidDisconnect(_ host: OuterframeHost) {
        watchTask?.cancel(); watchTask = nil
        flushDrafts()
        retainedSelf = nil
    }

    func scrollbarDidChangeScrollOffset(_ offset: CGFloat) {
        scrollOffset = clampedScrollOffset(offset)
        updateViewport()
        updateCursor()
    }

    private func configure(with arguments: InitializeContentArguments) {
        outerframeHost.configure(url: arguments.url ?? "",
                                 bundleUrl: arguments.bundleUrl ?? "",
                                 proxyHost: arguments.proxy?.host,
                                 proxyPort: arguments.proxy?.port ?? 0,
                                 proxyUsername: arguments.proxy?.username,
                                 proxyPassword: arguments.proxy?.password)
        outerframeHost.setTitle("Plaintext")
        outerframeHost.setIcon(.bundleResource(path: "Contents/Resources/app-icon.png"))
        currentURLString = arguments.url ?? ""
        appearance = arguments.appearance ?? .currentDrawing()
        windowIsActive = arguments.windowIsActive ?? true
        currentSize = arguments.contentSize ?? currentSize

        if let data = arguments.data,
           let configuration = PlaintextConfiguration(data: data),
           let base = outerframeHost.pluginBaseURL() {
            filesEndpoint = URL(string: configuration.filesAPIPath, relativeTo: base)?.absoluteURL
        } else if let base = outerframeHost.pluginBaseURL() {
            filesEndpoint = URL(string: "/api/files", relativeTo: base)?.absoluteURL
        }
        if let base = outerframeHost.pluginBaseURL() {
            environmentEndpoint = URL(string: "/api/environments", relativeTo: base)?.absoluteURL
        }
        draftStore = PlaintextDraftStore(directory: outerframeHost.dataDirectoryURL)
        filePath = filePath(from: arguments.url) ?? ""
        showStartupPopover = filePath.isEmpty && queryValue("draft") == nil

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 120
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        outerframeHost.applyProxy(to: configuration)
        urlSession = URLSession(configuration: configuration)

        setupLayers()
        outerframeHost.setInputMode([.textInput, .rawKeys])
        outerframeHost.setAcceptedPasteboardPasteTypes([
            NSPasteboard.PasteboardType.string.rawValue,
            NSPasteboard.PasteboardType.rtf.rawValue
        ])
        updateEditingCapabilities()
        Task {
            do {
                if let data = try await draftStore?.setting("preferences") { preferences = try PropertyListDecoder().decode(NativePreferences.self, from: data) }
                preferences.textScale = min(3, max(0.25, preferences.textScale))
            } catch { statusText = "Could not load preferences: " + error.localizedDescription }
            loadFile(); discoverTargets()
        }
    }

    private func filePath(from urlString: String?) -> String? {
        guard let urlString,
              let components = URLComponents(string: urlString) else {
            return nil
        }
        return components.queryItems?.first(where: { $0.name == "file" })?.value
    }

    private func setupLayers() {
        rootLayer.frame = CGRect(origin: .zero, size: currentSize)
        if !didRegisterLayer, let registerLayer = appConnection.registerLayer {
            didRegisterLayer = true
            registerLayer(rootLayer)
        }
        rootLayer.addSublayer(backgroundLayer)
        rootLayer.addSublayer(headerLayer)
        rootLayer.addSublayer(editorClipLayer)
        rootLayer.addSublayer(filePickerOverlayLayer)
        headerLayer.addSublayer(toolbarDividerLayer)
        headerLayer.addSublayer(pathChevronLayer)
        headerLayer.addSublayer(containerButtonLayer)
        containerButtonLayer.cornerRadius = 7
        containerButtonLayer.addSublayer(containerTitleLayer)
        headerLayer.addSublayer(openButtonLayer)
        openButtonLayer.cornerRadius = 7
        headerLayer.addSublayer(openIconLayer)
        headerLayer.addSublayer(saveButtonLayer)
        headerLayer.addSublayer(menuButtonLayer)
        openIconLayer.symbolPointSize = 23
        openIconLayer.maxSymbolSize = CGSize(width: 26, height: 24)
        headerLayer.addSublayer(pathPromptSelectionLayer)
        headerLayer.addSublayer(pathPromptCursorLayer)
        headerLayer.addSublayer(findBarLayer)
        pathPromptCursorLayer.zPosition = 10
        findBarLayer.zPosition = 20
        findBarLayer.isHidden = true
        findBarLayer.addSublayer(findFieldLayer)
        findBarLayer.addSublayer(findPreviousButtonLayer)
        findBarLayer.addSublayer(findNextButtonLayer)
        findBarLayer.addSublayer(findStatusLayer)
        findBarLayer.addSublayer(findDoneButtonLayer)
        findFieldLayer.addSublayer(findSelectionLayer)
        findFieldLayer.addSublayer(findPlaceholderLayer)
        findFieldLayer.addSublayer(findTextLayer)
        findFieldLayer.addSublayer(findMarkedUnderlineLayer)
        findFieldLayer.addSublayer(findCaretLayer)
        findPreviousButtonLayer.addSublayer(findPreviousIconLayer)
        findNextButtonLayer.addSublayer(findNextIconLayer)
        findDoneButtonLayer.addSublayer(findDoneTextLayer)
        findPreviousButtonLayer.cornerRadius = 5
        findNextButtonLayer.cornerRadius = 5
        findDoneButtonLayer.cornerRadius = 5
        findPreviousButtonLayer.borderWidth = 1
        findNextButtonLayer.borderWidth = 1
        findDoneButtonLayer.borderWidth = 1
        findPreviousButtonLayer.masksToBounds = true
        findNextButtonLayer.masksToBounds = true
        findDoneButtonLayer.masksToBounds = true
        findPreviousIconLayer.symbolPointSize = 13
        findNextIconLayer.symbolPointSize = 13
        findPreviousIconLayer.symbolWeight = .semibold
        findNextIconLayer.symbolWeight = .semibold
        findPreviousIconLayer.maxSymbolSize = CGSize(width: 12, height: 14)
        findNextIconLayer.maxSymbolSize = CGSize(width: 12, height: 14)
        findSelectionLayer.isHidden = true
        findSelectionLayer.cornerRadius = 2
        findMarkedUnderlineLayer.isHidden = true
        findCaretLayer.isHidden = true
        findCaretLayer.zPosition = 10
        editorClipLayer.addSublayer(textContentLayer)
        textContentLayer.addSublayer(textSelectionLayer)
        textContentLayer.addSublayer(editorCaretLayer)
        editorCaretLayer.zPosition = 20
        editorCaretLayer.isHidden = true

        editorClipLayer.masksToBounds = true
        filePickerOverlayLayer.isHidden = false
        filePickerOverlayLayer.opacity = 0
        filePickerOverlayLayer.zPosition = 100
        filePickerListLayer.masksToBounds = true
        filePickerBreadcrumbLayer.masksToBounds = true
        filePickerNameFieldLayer.masksToBounds = true
        filePickerNameFieldLayer.cornerRadius = 6
        filePickerNameSelectionLayer.isHidden = true
        filePickerNameSelectionLayer.cornerRadius = 2
        filePickerNameMarkedUnderlineLayer.isHidden = true
        filePickerNameCaretLayer.isHidden = true
        filePickerNameCaretLayer.zPosition = 10
        filePickerNameFieldLayer.addSublayer(filePickerNameSelectionLayer)
        filePickerNameFieldLayer.addSublayer(filePickerNamePlaceholderLayer)
        filePickerNameFieldLayer.addSublayer(filePickerNameTextLayer)
        filePickerNameFieldLayer.addSublayer(filePickerNameMarkedUnderlineLayer)
        filePickerNameFieldLayer.addSublayer(filePickerNameCaretLayer)
        for textLayer in [pathLayer, statusLayer, findTextLayer, findPlaceholderLayer, findStatusLayer, filePickerNameTextLayer, filePickerNamePlaceholderLayer] {
            textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            textLayer.truncationMode = .middle
            textLayer.alignmentMode = .left
        }
        headerLayer.addSublayer(pathLayer)
        headerLayer.addSublayer(statusLayer)
        findTextLayer.truncationMode = .end
        findPlaceholderLayer.truncationMode = .end
        findDoneTextLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        findDoneTextLayer.alignmentMode = .center
        findDoneTextLayer.truncationMode = .end
        findDoneTextLayer.string = "Done"

        scrollbarController = ScrollbarController(appConnection: outerframeHost,
                                                  viewportLayer: editorClipLayer,
                                                  appearance: appearance,
                                                  scrollOffsetOrigin: .bottom)
        scrollbarController?.delegate = self
        filePickerScrollbarController = ScrollbarController(appConnection: outerframeHost,
                                                            viewportLayer: filePickerListLayer,
                                                            appearance: appearance,
                                                            width: 8,
                                                            inset: 4,
                                                            scrollOffsetOrigin: .bottom)
        filePickerScrollbarController?.delegate = filePickerScrollbarDelegate
        updateColors()
        layout()
    }

    private func updateColors() {
        backgroundLayer.backgroundColor = resolvedCGColor(.textBackgroundColor)
        headerLayer.backgroundColor = resolvedCGColor(chromeBackgroundColor)
        toolbarDividerLayer.backgroundColor = resolvedCGColor(.separatorColor)
        editorClipLayer.backgroundColor = resolvedCGColor(.textBackgroundColor)
        pathLayer.foregroundColor = resolvedCGColor(.labelColor)
        statusLayer.foregroundColor = resolvedCGColor(isSaving || isLoading ? .secondaryLabelColor : statusColor())
        openIconLayer.tintColor = resolvedNSColor(.secondaryLabelColor)
        pathChevronLayer.tintColor = resolvedNSColor(.secondaryLabelColor)
        pathPromptCursorLayer.backgroundColor = resolvedCGColor(.keyboardFocusIndicatorColor)
        editorCaretLayer.backgroundColor = resolvedCGColor(.textColor)
        findBarLayer.backgroundColor = resolvedCGColor(chromeBackgroundColor)
        findFieldLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
        findFieldLayer.borderColor = resolvedCGColor(findInputController.isFocused ? .separatorColor : .separatorColor)
        findTextLayer.foregroundColor = resolvedCGColor(.labelColor)
        findPlaceholderLayer.foregroundColor = resolvedCGColor(.placeholderTextColor)
        findStatusLayer.foregroundColor = resolvedCGColor(.secondaryLabelColor)
        findDoneTextLayer.foregroundColor = resolvedCGColor(.labelColor)
        findSelectionLayer.backgroundColor = resolvedCGColor(.selectedTextBackgroundColor)
        findMarkedUnderlineLayer.backgroundColor = resolvedCGColor(.keyboardFocusIndicatorColor)
        findCaretLayer.backgroundColor = resolvedCGColor(.textColor)
        filePickerNameFieldLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
        filePickerNameFieldLayer.borderColor = resolvedCGColor(filePickerNameInputController.isFocused ? .separatorColor : .separatorColor)
        filePickerNameTextLayer.foregroundColor = resolvedCGColor(.labelColor)
        filePickerNamePlaceholderLayer.foregroundColor = resolvedCGColor(.placeholderTextColor)
        filePickerNameSelectionLayer.backgroundColor = resolvedCGColor(.selectedTextBackgroundColor)
        filePickerNameMarkedUnderlineLayer.backgroundColor = resolvedCGColor(.keyboardFocusIndicatorColor)
        filePickerNameCaretLayer.backgroundColor = resolvedCGColor(.textColor)
        let buttonTint = resolvedNSColor(findInputController.text.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor)
        findPreviousIconLayer.tintColor = buttonTint
        findNextIconLayer.tintColor = buttonTint
        findPreviousButtonLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
        findNextButtonLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
        findDoneButtonLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
        findPreviousButtonLayer.borderColor = resolvedCGColor(.separatorColor)
        findNextButtonLayer.borderColor = resolvedCGColor(.separatorColor)
        findDoneButtonLayer.borderColor = resolvedCGColor(.separatorColor)
        scrollbarController?.updateAppearance(appearance)
        filePickerScrollbarController?.updateAppearance(appearance)
        updateSelectionLayers(force: true)
        updateFindDisplay()
        renderFilePicker()
    }

    private var chromeBackgroundColor: NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .underPageBackgroundColor : .windowBackgroundColor
    }

    private func withEffectiveAppearance(_ body: () -> Void) {
        appearance.performAsCurrentDrawingAppearance(body)
    }

    private func resolvedCGColor(_ color: NSColor) -> CGColor {
        var resolved = CGColor(gray: 0, alpha: 1)
        withEffectiveAppearance {
            resolved = color.cgColor
        }
        return resolved
    }

    private func resolvedNSColor(_ color: NSColor) -> NSColor {
        var resolved = color
        withEffectiveAppearance {
            resolved = color.usingColorSpace(.deviceRGB) ?? color
        }
        return resolved
    }

    private func statusColor() -> NSColor {
        document?.localError != nil || statusText.lowercased().contains("error") || statusText.lowercased().contains("failed")
            ? .systemRed
            : .secondaryLabelColor
    }

    private func layout() {
        withoutImplicitAnimations {
            rootLayer.frame = CGRect(origin: .zero, size: currentSize)
            backgroundLayer.frame = rootLayer.bounds
            headerLayer.frame = CGRect(x: 0,
                                       y: currentSize.height - headerHeight,
                                       width: currentSize.width,
                                       height: headerHeight)
            toolbarDividerLayer.frame = CGRect(x: 0, y: 0, width: currentSize.width, height: 1)
            editorClipLayer.frame = CGRect(x: 0,
                                           y: 0,
                                           width: currentSize.width,
                                           height: max(currentSize.height - headerHeight, 0))
            let isPrompting = pathPromptMode != nil
            let pathFont = NSFont.systemFont(ofSize: 13, weight: isPrompting ? .regular : .semibold)
            pathLayer.font = pathFont
            pathLayer.fontSize = 13
            statusLayer.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            statusLayer.fontSize = 12
            pathLayer.truncationMode = isPrompting ? .end : .middle
            renderHeader()
            openControlFrame = CGRect(x: 10, y: 7, width: 38, height: 44)
            openButtonLayer.frame = openControlFrame.insetBy(dx: 0, dy: 4)
            openIconLayer.frame = openControlFrame.insetBy(dx: 6, dy: 9)
            openIconLayer.tintColor = resolvedNSColor(.secondaryLabelColor)
            menuControlFrame = CGRect(x: max(0, currentSize.width - 52), y: 7, width: 42, height: 44)
            saveControlFrame = CGRect(x: menuControlFrame.minX - 68, y: 7, width: 64, height: 44)
            let dirty = document?.draft.dirty == true || document?.draft.pending != nil
            saveButtonLayer.isHidden = !dirty
            for layer in [saveButtonLayer, menuButtonLayer] { layer.font = NSFont.systemFont(ofSize: 15); layer.fontSize = 15; layer.alignmentMode = .center; layer.contentsScale = rootLayer.contentsScale }
            saveButtonLayer.string = isSaving ? "Saving…" : "Save"
            saveButtonLayer.foregroundColor = resolvedCGColor(.controlAccentColor)
            menuButtonLayer.string = "•••"; menuButtonLayer.foregroundColor = resolvedCGColor(.secondaryLabelColor)
            saveButtonLayer.frame = saveControlFrame.insetBy(dx: 0, dy: 12)
            menuButtonLayer.frame = menuControlFrame.insetBy(dx: 0, dy: 12)
            let target = document?.draft.target ?? "host"
            let containerName = targets.first { $0.id == target }?.name ?? "Container"
            let containerWidth = target == "host" ? 0 : min(230, max(60, currentSize.width * 0.3), (containerName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .semibold)]).width + 36)
            containerControlFrame = CGRect(x: 62, y: 13, width: containerWidth, height: 32)
            containerButtonLayer.frame = containerControlFrame; containerButtonLayer.isHidden = target == "host"
            containerButtonLayer.backgroundColor = resolvedCGColor(NSColor.labelColor.withAlphaComponent(0.06))
            containerTitleLayer.string = containerName + "  ▾"; containerTitleLayer.font = NSFont.systemFont(ofSize: 13, weight: .semibold); containerTitleLayer.fontSize = 13
            containerTitleLayer.foregroundColor = resolvedCGColor(.labelColor); containerTitleLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2; containerTitleLayer.truncationMode = .middle
            containerTitleLayer.frame = CGRect(x: 9, y: 8, width: max(1, containerWidth - 18), height: 18)
            let pathX: CGFloat = target == "host" ? 62 : containerControlFrame.maxX + 12
            let pathWidth = max(40, (dirty ? saveControlFrame.minX : menuControlFrame.minX) - pathX - 12)
            let textY: CGFloat = statusText.isEmpty ? 19 : 27
            pathLayer.frame = CGRect(x: pathX, y: textY, width: pathWidth, height: 20)
            pathControlFrame = pathLayer.frame.insetBy(dx: -4, dy: -7)
            pathChevronLayer.isHidden = true
            statusLayer.frame = CGRect(x: pathX, y: 5, width: pathWidth, height: 16)
            layoutFindBar()
            pathPromptSelectionLayer.isHidden = !isPrompting || pathPromptSelectionRange == nil
            if isPrompting, let selection = pathPromptSelectionRange {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: pathPromptText, attributes: [.font: pathFont]))
                let start = CTLineGetOffsetForStringIndex(line, selection.location, nil)
                let end = CTLineGetOffsetForStringIndex(line, NSMaxRange(selection), nil)
                pathPromptSelectionLayer.frame = CGRect(x: pathLayer.frame.minX + min(start, end), y: textY,
                    width: max(abs(end - start), 1), height: 18).intersection(pathLayer.frame)
                pathPromptSelectionLayer.backgroundColor = resolvedCGColor(.selectedTextBackgroundColor)
            }
            if isPrompting {
                let cursorX = pathLayer.frame.minX + pathPromptCursorX(font: pathFont, maxWidth: pathLayer.frame.width)
                pathPromptCursorLayer.frame = CGRect(x: cursorX, y: textY, width: cursorWidth, height: 17)
                pathPromptCursorLayer.isHidden = pathPromptSelectionRange != nil
                startBlinkingCaret(pathPromptCursorLayer)
            } else {
                pathPromptCursorLayer.isHidden = true
                stopBlinkingCaret(pathPromptCursorLayer)
            }
            layoutText()
            renderFilePicker()
        }
        notifyAccessibilityLayoutChanged()
    }

    private func layoutFindBar() {
        let desiredWidth = min(max(currentSize.width * 0.48, 330), 470)
        let width = min(desiredWidth, max(currentSize.width - 20, 1))
        findBarFrame = CGRect(x: max(currentSize.width - width - 10, 10),
                              y: 7,
                              width: width,
                              height: 28)
        findBarLayer.frame = findBarFrame
        findBarLayer.isHidden = !isFindVisible

        let statusWidth: CGFloat = 54
        let doneWidth: CGFloat = 54
        let buttonSize: CGFloat = 26
        let buttonGap: CGFloat = 4
        let buttonsWidth = buttonSize * 2 + buttonGap
        findFieldFrame = CGRect(x: 0,
                                y: 0,
                                width: max(findBarFrame.width - statusWidth - buttonsWidth - doneWidth - 24, 80),
                                height: 28)
        findFieldLayer.frame = findFieldFrame
        findFieldLayer.cornerRadius = 6
        findFieldLayer.borderWidth = findInputController.isFocused ? 1.5 : 1
        findPreviousButtonFrame = CGRect(x: findFieldFrame.maxX + 6, y: 1, width: buttonSize, height: buttonSize)
        findNextButtonFrame = CGRect(x: findPreviousButtonFrame.maxX + buttonGap, y: 1, width: buttonSize, height: buttonSize)
        findPreviousButtonLayer.frame = findPreviousButtonFrame
        findNextButtonLayer.frame = findNextButtonFrame
        findPreviousIconLayer.frame = findPreviousButtonLayer.bounds
        findNextIconLayer.frame = findNextButtonLayer.bounds
        findStatusLayer.frame = CGRect(x: findNextButtonFrame.maxX + 7, y: 6, width: statusWidth, height: 16)
        findDoneButtonFrame = CGRect(x: findStatusLayer.frame.maxX + 7, y: 1, width: doneWidth, height: buttonSize)
        findDoneButtonLayer.frame = findDoneButtonFrame
        findDoneTextLayer.frame = CGRect(x: 6, y: 6, width: max(doneWidth - 12, 1), height: 16)
        updateFindDisplay()
    }

    private func makeTextLayer(size: CGFloat,
                               weight: NSFont.Weight,
                               color: NSColor,
                               alignment: CATextLayerAlignmentMode = .left) -> CATextLayer {
        let layer = CATextLayer()
        layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.font = NSFont.systemFont(ofSize: size, weight: weight)
        layer.fontSize = size
        layer.foregroundColor = resolvedCGColor(color)
        layer.truncationMode = .middle
        layer.alignmentMode = alignment
        return layer
    }

    private func makeButtonLayer(title: String, emphasized: Bool) -> CALayer {
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 70, height: 32)
        layer.cornerRadius = 6
        layer.masksToBounds = true
        layer.backgroundColor = resolvedCGColor(emphasized ? .controlAccentColor : .controlBackgroundColor)
        layer.borderWidth = emphasized ? 0 : 1
        layer.borderColor = resolvedCGColor(.separatorColor)
        let text = makeTextLayer(size: 12,
                                 weight: .semibold,
                                 color: emphasized ? .white : .labelColor,
                                 alignment: .center)
        text.string = title
        let font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        let lineHeight = ceil(font.ascender - font.descender)
        let textTop = (layer.bounds.height + font.capHeight) / 2 - font.ascender
        let textY = floor((layer.bounds.height - textTop - lineHeight) * text.contentsScale) / text.contentsScale
        text.frame = CGRect(x: 6, y: textY, width: 58, height: lineHeight)
        text.autoresizingMask = [.layerWidthSizable, .layerMinYMargin, .layerMaxYMargin]
        layer.addSublayer(text)
        return layer
    }

    private func renderFilePicker() {
        openButtonLayer.backgroundColor = pendingFilePicker != nil && ["recent", "open"].contains(pickerMode) ? resolvedCGColor(NSColor.labelColor.withAlphaComponent(0.07)) : nil
        defer { notifyAccessibilityLayoutChanged() }
        guard let picker = pendingFilePicker else {
            guard !isFilePickerFadingOut else { return }
            setFilePickerOverlayOpacity(0)
            filePickerOverlayLayer.isHidden = false
            filePickerOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            filePickerEntryFrames.removeAll()
            filePickerNameFieldFrame = .zero
            return
        }

        withoutImplicitAnimations {
            renderFilePickerContents(picker)
        }
    }

    private func popoverOutlinePath(size: CGSize, arrowX: CGFloat) -> CGPath {
        let rect = CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = 12
        let arrowHalfWidth: CGFloat = 8
        let arrowHeight: CGFloat = 8
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addLine(to: CGPoint(x: arrowX - arrowHalfWidth, y: rect.maxY))
        path.addLine(to: CGPoint(x: arrowX, y: rect.maxY + arrowHeight))
        path.addLine(to: CGPoint(x: arrowX + arrowHalfWidth, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: radius)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius)
        path.closeSubpath()
        return path
    }

    private func renderFilePickerContents(_ picker: PendingFilePicker) {
        filePickerOverlayLayer.isHidden = false
        filePickerOverlayLayer.frame = rootLayer.bounds
        filePickerOverlayLayer.backgroundColor = nil
        filePickerOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let width = rootLayer.bounds.width
        let height = rootLayer.bounds.height
        let panelWidth = min(max(width - 24, 100), 560)
        let panelHeight = pickerMode == "recent" ? min(max(170, CGFloat(preferences.recent.count) * 58 + 70), max(100, height - headerHeight - 34)) : max(120, height - headerHeight - 34)
        let anchorX = pickerMode == "move" ? pathControlFrame.midX : openControlFrame.midX
        let panelFrame = CGRect(x: max(12, min(pickerMode == "move" ? pathControlFrame.minX : 12, width - panelWidth - 12)),
                                y: height - headerHeight - 12 - panelHeight,
                                width: panelWidth,
                                height: panelHeight)
        filePickerPanelFrame = panelFrame

        let panel = CALayer()
        panel.frame = panelFrame
        let outlinePath = popoverOutlinePath(size: panelFrame.size, arrowX: max(24, min(panelWidth - 24, anchorX - panelFrame.minX)))
        panel.shadowColor = NSColor.black.cgColor; panel.shadowOpacity = 0.18; panel.shadowRadius = 14; panel.shadowOffset = CGSize(width: 0, height: -5)
        panel.shadowPath = outlinePath
        filePickerOverlayLayer.addSublayer(panel)
        let outline = CAShapeLayer()
        outline.frame = panel.bounds
        outline.path = outlinePath
        outline.fillColor = resolvedCGColor(chromeBackgroundColor)
        outline.strokeColor = resolvedCGColor(.separatorColor)
        outline.lineWidth = 1
        panel.addSublayer(outline)
        recentTabFrame = CGRect(x: 16, y: panelHeight - 48, width: 72, height: 32).offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        openTabFrame = CGRect(x: 90, y: panelHeight - 48, width: 66, height: 32).offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        newFileFrame = CGRect(x: panelWidth - 136, y: panelHeight - 48, width: 120, height: 32).offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        if ["recent", "open"].contains(pickerMode) {
            for (label, frame, active) in [("Recent", recentTabFrame, pickerMode == "recent"), ("Open", openTabFrame, pickerMode == "open"), ("New text file", newFileFrame, false)] {
                let button = makeButtonLayer(title: label, emphasized: active); button.frame = frame.offsetBy(dx: -panelFrame.minX, dy: -panelFrame.minY); panel.addSublayer(button)
            }
        }
        recentFrames.removeAll(); conflictFrames.removeAll()
        if pickerMode == "conflict", let doc = document, let disk = reviewedDisk {
            filePickerNameFieldFrame = .zero; filePickerEntryFrames.removeAll(); filePickerListFrame = .zero; filePickerBreadcrumbSegmentFrames.removeAll()
            let heading = makeTextLayer(size: 15, weight: .semibold, color: .labelColor); heading.string = "Changes were made on another device"; heading.frame = CGRect(x: 18, y: panelHeight - 40, width: panelWidth - 36, height: 22); panel.addSublayer(heading)
            let columns = [("Your draft", doc.draft.contents), ("Saved file", disk.contents)] + (reviewedShared?.dirty == true ? [("Shared draft", reviewedShared?.contents ?? "")] : [])
            let columnWidth = (panelWidth - 36) / CGFloat(columns.count)
            for (index, column) in columns.enumerated() {
                let x = 18 + CGFloat(index) * columnWidth
                let title = makeTextLayer(size: 12, weight: .semibold, color: .labelColor); title.string = column.0; title.frame = CGRect(x: x, y: panelHeight - 70, width: columnWidth - 10, height: 20); panel.addSublayer(title)
                let clip = CALayer(); clip.frame = CGRect(x: x, y: 112, width: columnWidth - 10, height: max(20, panelHeight - 188)); clip.masksToBounds = true; panel.addSublayer(clip)
                let preview = makeTextLayer(size: 12, weight: .regular, color: .labelColor); preview.isWrapped = true; preview.truncationMode = .none
                let content = NSAttributedString(string: column.1, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: resolvedNSColor(.labelColor)])
                let contentHeight = max(clip.bounds.height, content.boundingRect(with: CGSize(width: clip.bounds.width, height: 1000000), options: [.usesLineFragmentOrigin, .usesFontLeading]).height + 20)
                preview.string = content; preview.frame = CGRect(x: 0, y: clip.bounds.height - contentHeight + filePickerScroll, width: clip.bounds.width, height: contentHeight); clip.addSublayer(preview)
            }
            let actions = [("Keep my draft", "keep"), ("Save a copy…", "copy"), ("Discard drafts; use saved file", "discard"), ("Replace server with my draft", "replace")]
            for (index, action) in actions.enumerated() {
                let frame = CGRect(x: 18 + CGFloat(index % 2) * (panelWidth - 36) / 2, y: 64 - CGFloat(index / 2) * 40, width: (panelWidth - 44) / 2, height: 32)
                let button = makeButtonLayer(title: action.0, emphasized: false); button.frame = frame; panel.addSublayer(button); conflictFrames.append((frame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY), action.1))
            }
            return
        }
        if pickerMode == "recent" {
            filePickerNameFieldFrame = .zero; filePickerListFrame = .zero; filePickerOpenFrame = .zero; filePickerCancelFrame = .zero
            filePickerEntryFrames.removeAll(); filePickerBreadcrumbSegmentFrames.removeAll()
            if preferences.recent.isEmpty { let empty = makeTextLayer(size: 13, weight: .regular, color: .secondaryLabelColor); empty.string = "Files you open appear here."; empty.frame = CGRect(x: 18, y: panelHeight - 94, width: panelWidth - 36, height: 20); panel.addSublayer(empty) }
            for (index, recent) in preferences.recent.enumerated() {
                let row = CGRect(x: 16, y: panelHeight - 112 - CGFloat(index) * 58 + filePickerScroll, width: panelWidth - 32, height: 52)
                guard row.minY >= 12, row.maxY <= panelHeight - 58 else { continue }
                let name = makeTextLayer(size: 14, weight: .semibold, color: .labelColor); name.string = (recent.path as NSString).lastPathComponent; name.frame = CGRect(x: row.minX, y: row.minY + 25, width: row.width - 40, height: 20); panel.addSublayer(name)
                let detail = makeTextLayer(size: 12, weight: .regular, color: .secondaryLabelColor); detail.string = (recent.target == "host" ? "" : recent.target + " · ") + recent.path; detail.frame = CGRect(x: row.minX, y: row.minY + 6, width: row.width - 40, height: 17); panel.addSublayer(detail)
                let remove = makeTextLayer(size: 20, weight: .regular, color: .secondaryLabelColor); remove.string = "×"; remove.frame = CGRect(x: row.maxX - 28, y: row.minY + 12, width: 28, height: 28); panel.addSublayer(remove)
                recentFrames.append((row.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY), remove.frame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY), recent))
            }
            return
        }

        let title = makeTextLayer(size: 15, weight: .semibold, color: .labelColor)
        title.string = pickerMode == "move" ? "Move or rename file" : pickerMode == "copy" ? "Save a copy" : "Save text file"
        title.frame = CGRect(x: 18, y: panelHeight - 38, width: panelWidth - 36, height: 20)
        if pickerMode != "open" { panel.addSublayer(title) }

        targetControlFrame = .zero
        if ["open", "save", "copy"].contains(pickerMode) {
            let frame = CGRect(x: 18, y: panelHeight - 86, width: panelWidth - 36, height: 30)
            let label = targets.first { $0.id == pickerTarget }?.name ?? pickerTarget
            let target = makeButtonLayer(title: (pickerTarget == "host" ? "Host — " : "") + label + " ▾", emphasized: false)
            target.frame = frame; panel.addSublayer(target); targetControlFrame = frame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        }
        let breadcrumbFrame = CGRect(x: 18,
                                     y: panelHeight - (["open", "save", "copy"].contains(pickerMode) ? 120 : 78),
                                     width: panelWidth - 36,
                                     height: FilePickerBreadcrumbBar.height)
        filePickerBreadcrumbFrame = breadcrumbFrame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        filePickerBreadcrumbLayer.frame = breadcrumbFrame
        FilePickerBreadcrumbBar.render(path: picker.directory,
                                       in: filePickerBreadcrumbLayer,
                                       segmentFrames: &filePickerBreadcrumbSegmentFrames,
                                       appearance: appearance)
        panel.addSublayer(filePickerBreadcrumbLayer)

        let bottomControlsHeight: CGFloat = pickerMode == "open" ? 62 : 108
        let listFrame = CGRect(x: 18,
                               y: bottomControlsHeight,
                               width: panelWidth - 36,
                               height: max(breadcrumbFrame.minY - bottomControlsHeight - 12, 1))
        filePickerListFrame = listFrame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        filePickerListLayer.frame = listFrame
        filePickerListLayer.cornerRadius = 6
        filePickerListLayer.borderWidth = 1
        filePickerListLayer.borderColor = resolvedCGColor(.separatorColor)
        filePickerListLayer.backgroundColor = resolvedCGColor(.textBackgroundColor)
        panel.addSublayer(filePickerListLayer)

        if filePickerRowsContentLayer.superlayer !== filePickerListLayer {
            filePickerListLayer.addSublayer(filePickerRowsContentLayer)
        }
        if filePickerStatusLayer.superlayer !== filePickerListLayer {
            filePickerListLayer.addSublayer(filePickerStatusLayer)
        }
        filePickerStatusLayer.frame = filePickerListLayer.bounds
        filePickerStatusLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        filePickerContentHeight = CGFloat(picker.entries.count) * filePickerRowHeight
        filePickerScroll = min(max(filePickerScroll, 0), max(filePickerContentHeight - listFrame.height, 0))
        if picker.isLoading {
            resetFilePickerRowLayers()
            let loading = makeTextLayer(size: 12, weight: .regular, color: .secondaryLabelColor, alignment: .center)
            loading.string = "Loading..."
            loading.frame = CGRect(x: 0, y: max((listFrame.height - 18) / 2, 0), width: listFrame.width, height: 18)
            filePickerStatusLayer.addSublayer(loading)
        } else if !picker.error.isEmpty {
            resetFilePickerRowLayers()
            let message = makeTextLayer(size: 12, weight: .regular, color: .systemRed, alignment: .center)
            message.string = picker.error
            message.frame = CGRect(x: 10, y: max((listFrame.height - 18) / 2, 0), width: listFrame.width - 20, height: 18)
            filePickerStatusLayer.addSublayer(message)
        } else {
            updateFilePickerVisibleRows(rebuild: true)
        }
        updateFilePickerScrollbarLayout()

        let nameLabel = makeTextLayer(size: 12, weight: .regular, color: .secondaryLabelColor)
        nameLabel.string = "File name:"
        nameLabel.frame = CGRect(x: 18, y: 70, width: 76, height: 18)
        if pickerMode != "open" { panel.addSublayer(nameLabel) }

        let nameFieldLocal = CGRect(x: 96, y: 64, width: max(panelWidth - 114, 80), height: 30)
        filePickerNameFieldFrame = pickerMode == "open" ? .zero : nameFieldLocal.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        filePickerNameFieldLayer.frame = nameFieldLocal
        filePickerNameFieldLayer.borderWidth = filePickerNameInputController.isFocused ? 1.5 : 1
        if pickerMode != "open" { panel.addSublayer(filePickerNameFieldLayer) }
        updateFilePickerNameDisplay()

        let openLocal = CGRect(x: panelWidth - 104, y: 18, width: 86, height: 32)
        let cancelLocal = CGRect.zero
        filePickerOpenFrame = openLocal.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        filePickerCancelFrame = cancelLocal.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        let cancel = makeButtonLayer(title: "Cancel", emphasized: false)
        cancel.frame = cancelLocal
        _ = cancel
        let open = makeButtonLayer(title: pickerMode == "move" ? "Move" : pickerMode == "open" ? "Open file" : "Save", emphasized: true)
        open.frame = openLocal
        open.opacity = picker.isLoading || !picker.error.isEmpty ? 0.4 : 1
        panel.addSublayer(open)
    }

    private func setFilePickerOverlayOpacity(_ opacity: Float) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        filePickerOverlayLayer.opacity = opacity
        CATransaction.commit()
    }

    private func animateFilePickerOverlayOpacity(to targetOpacity: Float, from startOpacity: Float? = nil) {
        let startOpacity = startOpacity ?? filePickerOverlayLayer.presentation()?.opacity ?? filePickerOverlayLayer.opacity
        setFilePickerOverlayOpacity(targetOpacity)

        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = startOpacity
        animation.toValue = targetOpacity
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        filePickerOverlayLayer.add(animation, forKey: "filePickerOpacity")
    }

    private func prepareFilePickerOverlayForPresentation(animated: Bool) {
        filePickerFadeToken = UUID()
        isFilePickerFadingOut = false
        filePickerOverlayLayer.removeAnimation(forKey: "filePickerOpacity")
        if animated {
            setFilePickerOverlayOpacity(0)
        } else {
            setFilePickerOverlayOpacity(1)
        }
    }

    private func fadeInFilePickerOverlayIfNeeded(_ animated: Bool) {
        guard animated else { return }
        animateFilePickerOverlayOpacity(to: 1, from: 0)
    }

    private func fadeOutAndHideFilePickerOverlay() {
        let token = UUID()
        filePickerFadeToken = token
        isFilePickerFadingOut = true
        filePickerOverlayLayer.removeAnimation(forKey: "filePickerOpacity")
        animateFilePickerOverlayOpacity(to: 0)

        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard let self,
                  self.filePickerFadeToken == token,
                  self.pendingFilePicker == nil else { return }
            withoutImplicitAnimations {
                self.isFilePickerFadingOut = false
                self.filePickerOverlayLayer.isHidden = false
                self.filePickerOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
                self.filePickerOverlayLayer.opacity = 0
                self.filePickerEntryFrames.removeAll()
            }
        }
    }

    private func makeFilePickerRowLayer() -> CALayer {
        let row = CALayer()
        row.addSublayer(SymbolImageLayer(symbolName: "doc", accessibilityTitle: "File"))
        row.addSublayer(makeTextLayer(size: 12, weight: .regular, color: .labelColor))
        return row
    }

    private func configureFilePickerRowLayer(_ row: CALayer,
                                             entry: FilePickerEntryRecord,
                                             index: Int,
                                             frame: CGRect) {
        row.frame = frame
        let isSelected = filePickerSelectedIndex == index
        row.backgroundColor = isSelected ? resolvedCGColor(.selectedContentBackgroundColor) : nil
        if row.sublayers?.count != 2 {
            row.sublayers?.forEach { $0.removeFromSuperlayer() }
            row.addSublayer(SymbolImageLayer(symbolName: "doc", accessibilityTitle: "File"))
            row.addSublayer(makeTextLayer(size: 12, weight: .regular, color: .labelColor))
        }
        if let icon = row.sublayers?[0] as? SymbolImageLayer {
            icon.symbolName = entry.isDirectory ? "folder" : "doc"
            icon.accessibilityTitle = entry.isDirectory ? "Folder" : "File"
            icon.tintColor = resolvedNSColor(isSelected ? .white : .secondaryLabelColor)
            icon.symbolPointSize = 15
            icon.maxSymbolSize = CGSize(width: 16, height: 16)
            icon.frame = CGRect(x: 12, y: 6, width: 16, height: 16)
        }
        if let name = row.sublayers?[1] as? CATextLayer {
            name.string = entry.name
            name.foregroundColor = resolvedCGColor(isSelected ? .white : .labelColor)
            name.frame = CGRect(x: 38, y: 6, width: max(frame.width - 50, 1), height: 16)
        }
    }

    private func resetFilePickerRowLayers() {
        withoutImplicitAnimations {
            filePickerRowsContentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            filePickerVisibleRowLayers.removeAll()
            filePickerReusableRowLayers.removeAll()
            filePickerEntryFrames.removeAll()
            filePickerRowsContentLayer.frame = CGRect(origin: .zero,
                                                      size: CGSize(width: filePickerListLayer.bounds.width,
                                                                   height: 0))
        }
    }

    fileprivate func setFilePickerScroll(_ value: CGFloat) {
        let maxScroll = max(filePickerContentHeight - filePickerListFrame.height, 0)
        let clamped = min(max(value, 0), maxScroll)
        guard abs(clamped - filePickerScroll) > 0.001 else {
            updateFilePickerScrollbarLayout()
            return
        }
        filePickerScroll = clamped
        updateFilePickerVisibleRows(rebuild: false)
    }

    private func updateFilePickerVisibleRows(rebuild: Bool) {
        defer { notifyAccessibilityLayoutChanged() }
        guard let picker = pendingFilePicker else {
            resetFilePickerRowLayers()
            return
        }

        let entries = picker.isLoading || !picker.error.isEmpty ? [] : picker.entries
        let viewportHeight = max(filePickerListLayer.bounds.height, 0)
        let viewportWidth = max(filePickerListLayer.bounds.width, 1)
        filePickerContentHeight = CGFloat(entries.count) * filePickerRowHeight
        filePickerScroll = min(max(filePickerScroll, 0), max(filePickerContentHeight - viewportHeight, 0))

        withoutImplicitAnimations {
            filePickerEntryFrames.removeAll()
            let contentY = viewportHeight - filePickerContentHeight + filePickerScroll
            filePickerRowsContentLayer.frame = CGRect(x: 0,
                                                      y: contentY,
                                                      width: viewportWidth,
                                                      height: max(filePickerContentHeight, 0))
            guard !entries.isEmpty, viewportHeight > 0 else {
                resetFilePickerRowLayers()
                return
            }

            let visibleStart = max(Int(floor(filePickerScroll / filePickerRowHeight)), 0)
            let visibleEnd = min(entries.count, visibleStart + Int(ceil(viewportHeight / filePickerRowHeight)) + 2)
            let visibleRange = visibleStart..<visibleEnd

            for index in filePickerVisibleRowLayers.keys.filter({ !visibleRange.contains($0) }) {
                if let layer = filePickerVisibleRowLayers.removeValue(forKey: index) {
                    layer.removeFromSuperlayer()
                    filePickerReusableRowLayers.append(layer)
                }
            }

            for index in visibleRange {
                let row: CALayer
                if let existing = filePickerVisibleRowLayers[index] {
                    row = existing
                } else if let reusable = filePickerReusableRowLayers.popLast() {
                    row = reusable
                    filePickerRowsContentLayer.addSublayer(row)
                    filePickerVisibleRowLayers[index] = row
                } else {
                    row = makeFilePickerRowLayer()
                    filePickerRowsContentLayer.addSublayer(row)
                    filePickerVisibleRowLayers[index] = row
                }
                let rowFrame = CGRect(x: 0,
                                      y: filePickerContentHeight - CGFloat(index + 1) * filePickerRowHeight,
                                      width: viewportWidth,
                                      height: filePickerRowHeight)
                configureFilePickerRowLayer(row, entry: entries[index], index: index, frame: rowFrame)
                let visibleFrame = rowFrame.offsetBy(dx: filePickerRowsContentLayer.frame.minX,
                                                     dy: filePickerRowsContentLayer.frame.minY)
                filePickerEntryFrames.append((visibleFrame.offsetBy(dx: filePickerListFrame.minX,
                                                                    dy: filePickerListFrame.minY),
                                              entries[index],
                                              index))
            }
        }
        updateFilePickerScrollbarLayout()
        _ = rebuild
    }

    private func updateFilePickerScrollbarLayout() {
        filePickerScrollbarController?.updateLayout(metrics: ScrollbarController.Metrics(viewportSize: filePickerListLayer.bounds.size,
                                                                                         contentHeight: filePickerContentHeight,
                                                                                         scrollOffset: filePickerScroll))
    }

    private func updateFilePickerNameDisplay() {
        withoutImplicitAnimations {
            filePickerNameFieldLayer.borderColor = resolvedCGColor(filePickerNameInputController.isFocused ? .separatorColor : .separatorColor)
            filePickerNameFieldLayer.borderWidth = filePickerNameInputController.isFocused ? 1.5 : 1
            filePickerNameTextLayer.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            filePickerNameTextLayer.fontSize = 13
            filePickerNamePlaceholderLayer.font = NSFont.systemFont(ofSize: 13, weight: .regular)
            filePickerNamePlaceholderLayer.fontSize = 13
            filePickerNameTextLayer.foregroundColor = resolvedCGColor(.labelColor)
            filePickerNamePlaceholderLayer.foregroundColor = resolvedCGColor(.placeholderTextColor)
            filePickerNameFieldLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
            filePickerNameSelectionLayer.backgroundColor = resolvedCGColor(.selectedTextBackgroundColor)
            filePickerNameMarkedUnderlineLayer.backgroundColor = resolvedCGColor(.keyboardFocusIndicatorColor)
            filePickerNameCaretLayer.backgroundColor = resolvedCGColor(.textColor)

            let textFrame = filePickerNameTextFrame()
            filePickerNameTextLayer.frame = textFrame
            filePickerNamePlaceholderLayer.frame = textFrame
            filePickerNameTextLayer.string = filePickerNameInputController.text
            filePickerNamePlaceholderLayer.string = "Name"
            filePickerNamePlaceholderLayer.isHidden = !filePickerNameInputController.text.isEmpty

            if let range = filePickerNameInputController.selectionRange {
                let lower = filePickerNameTextX(for: range.lowerBound)
                let upper = filePickerNameTextX(for: range.upperBound)
                filePickerNameSelectionLayer.frame = CGRect(x: textFrame.minX + min(lower, upper),
                                                            y: textFrame.minY + 1,
                                                            width: max(abs(upper - lower), 1),
                                                            height: max(textFrame.height - 2, 1))
                filePickerNameSelectionLayer.isHidden = false
            } else {
                filePickerNameSelectionLayer.isHidden = true
            }

            if let range = filePickerNameInputController.markedRange {
                let lower = filePickerNameTextX(for: range.lowerBound)
                let upper = filePickerNameTextX(for: range.upperBound)
                filePickerNameMarkedUnderlineLayer.frame = CGRect(x: textFrame.minX + min(lower, upper),
                                                                  y: textFrame.minY + 1,
                                                                  width: max(abs(upper - lower), 1),
                                                                  height: 2)
                filePickerNameMarkedUnderlineLayer.isHidden = false
            } else {
                filePickerNameMarkedUnderlineLayer.isHidden = true
            }

            let caretX = filePickerNameTextX(for: filePickerNameInputController.cursorPosition)
            filePickerNameCaretLayer.frame = CGRect(x: textFrame.minX + caretX,
                                                    y: textFrame.minY + 1,
                                                    width: cursorWidth,
                                                    height: max(textFrame.height - 2, 1))
            filePickerNameCaretLayer.isHidden = !(pendingFilePicker != nil && filePickerNameInputController.isFocused && windowIsActive && viewIsFocused)
            if filePickerNameCaretLayer.isHidden {
                stopBlinkingCaret(filePickerNameCaretLayer)
            } else {
                startBlinkingCaret(filePickerNameCaretLayer)
            }
        }
    }

    private func filePickerNameTextFrame() -> CGRect {
        CGRect(x: 9, y: 7, width: max(filePickerNameFieldLayer.bounds.width - 18, 1), height: 16)
    }

    private func filePickerNameTextX(for characterIndex: Int) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let clamped = min(max(characterIndex, 0), filePickerNameInputController.text.count)
        let endIndex = filePickerNameInputController.text.index(filePickerNameInputController.text.startIndex, offsetBy: clamped)
        let prefix = String(filePickerNameInputController.text[..<endIndex]) as NSString
        return min(max(prefix.size(withAttributes: [.font: font]).width, 0), max(filePickerNameTextFrame().width - cursorWidth, 0))
    }

    private func filePickerNameCharacterIndex(atX x: CGFloat) -> Int {
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in 0...filePickerNameInputController.text.count {
            let distance = abs(filePickerNameTextX(for: index) - max(x, 0))
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func focusFilePickerNameField(atRootPoint rootPoint: CGPoint, clickCount: Int, modifySelection: Bool) {
        let localX = rootPoint.x - filePickerNameFieldFrame.minX - filePickerNameTextFrame().minX
        let position = filePickerNameCharacterIndex(atX: localX)
        filePickerNameInputController.focus(selectAll: false)
        if clickCount >= 2 {
            filePickerNameInputController.selectWord(at: position)
        } else {
            filePickerNameInputController.setCursorPosition(position, modifySelection: modifySelection)
        }
        updateCursor()
    }

    private func showHomePopover() {
        pickerMode = "recent"; showOpenFilePicker()
    }

    private func showOpenFilePicker() {
        endUndoGroup()
        cancelPathPrompt()
        pickerTarget = document?.draft.target ?? "host"
        let shouldAnimate = pendingFilePicker == nil || filePickerOverlayLayer.isHidden
        prepareFilePickerOverlayForPresentation(animated: shouldAnimate)
        let directory: String
        if filePath.isEmpty {
            directory = "~"
        } else {
            let parent = (filePath as NSString).deletingLastPathComponent
            directory = parent.isEmpty ? "~" : parent
        }
        pendingFilePicker = PendingFilePicker(directory: directory,
                                              entries: [],
                                              isLoading: true,
                                              error: "")
        let defaultName = filePath.isEmpty ? (pickerMode == "save" ? "Untitled.txt" : "") : (filePath as NSString).lastPathComponent + (pickerMode == "copy" ? ".copy" : "")
        filePickerNameInputController.setText(defaultName)
        filePickerScroll = 0
        filePickerSelectedIndex = nil
        findInputController.blur()
        if ["move", "save", "copy"].contains(pickerMode) { filePickerNameInputController.focus() } else { filePickerNameInputController.blur() }
        resetFilePickerTypeahead()
        renderFilePicker()
        updateCursor()
        fadeInFilePickerOverlayIfNeeded(shouldAnimate)
        if pickerMode != "recent" && pickerMode != "conflict" { fetchFilePickerDirectory(path: directory, clearName: false) }
    }

    private func fetchFilePickerDirectory(path: String, clearName: Bool = true) {
        guard let endpoint = environmentEndpoint, let session = urlSession else { return }
        let token = UUID(); pickerRequest = token
        pendingFilePicker?.directory = path; pendingFilePicker?.entries = []; pendingFilePicker?.isLoading = true; pendingFilePicker?.error = ""
        filePickerScroll = 0; filePickerSelectedIndex = nil
        if clearName && pickerMode == "open" { filePickerNameInputController.setText("") }
        resetFilePickerTypeahead(); renderFilePicker()
        let target = pickerTarget
        Task {
            do {
                var request = URLRequest(url: endpoint); request.httpMethod = "POST"
                request.setValue("1", forHTTPHeaderField: "X-Environment-Request")
                request.httpBody = try PlaintextEnvironment.encode(1, target: target, path: path)
                let (data, _) = try await session.data(for: request)
                let envelope = BinaryPayloadReader(data: data)
                if try envelope.uint32(at: 12) != 0 { throw PlaintextDocumentError.message(try envelope.stringRef(at: 32)) }
                let metadata = try envelope.child(at: 16), count = Int(try metadata.uint32(at: 20))
                guard count <= 100_000 else { throw PlaintextDocumentError.message("Directory is too large") }
                var entries: [FilePickerEntryRecord] = []
                let parent = try metadata.stringRef(at: 56)
                if !parent.isEmpty { entries.append(FilePickerEntryRecord(name: "..", path: parent, isDirectory: true, size: 0, modified: 0)) }
                for index in 0..<count {
                    let offset = 64 + index * 48
                    let entry = FilePickerEntryRecord(name: try metadata.stringRef(at: offset), path: try metadata.stringRef(at: offset + 8), isDirectory: try metadata.uint32(at: offset + 24) != 0, size: try metadata.uint64(at: offset + 32), modified: Double(try metadata.uint64(at: offset + 40)))
                    if ["open", "recent"].contains(pickerMode) || entry.isDirectory { entries.append(entry) }
                }
                guard pickerRequest == token, pendingFilePicker != nil else { return }
                pendingFilePicker?.directory = try metadata.stringRef(at: 48); pendingFilePicker?.entries = entries; pendingFilePicker?.isLoading = false
            } catch {
                guard pickerRequest == token, pendingFilePicker != nil else { return }
                pendingFilePicker?.isLoading = false; pendingFilePicker?.error = error.localizedDescription
            }
            renderFilePicker()
        }
    }

    private func dismissFilePicker() {
        pickerRequest = UUID(); pendingFilePicker = nil
        layout()
        filePickerScroll = 0
        filePickerSelectedIndex = nil
        filePickerNameInputController.blur()
        filePickerNameInputController.setText("")
        resetFilePickerTypeahead()
        updateCursor()
        fadeOutAndHideFilePickerOverlay()
    }

    private func activateFilePickerEntry(_ entry: FilePickerEntryRecord) {
        if entry.isDirectory {
            fetchFilePickerDirectory(path: entry.path, clearName: pickerMode == "open")
        } else {
            dismissFilePicker(); shouldPushHistory = true
            openDocument(path: entry.path, target: pickerTarget)
        }
    }

    private func activateSelectedFilePickerEntry() {
        guard let selectedIndex = filePickerSelectedIndex,
              let entries = pendingFilePicker?.entries,
              entries.indices.contains(selectedIndex) else {
            openFilePickerTypedPath()
            return
        }
        activateFilePickerEntry(entries[selectedIndex])
    }

    private func openFilePickerTypedPath() {
        guard let picker = pendingFilePicker, !picker.isLoading, picker.error.isEmpty else { return }
        let name = filePickerNameInputController.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            guard let selectedIndex = filePickerSelectedIndex,
                  let entries = pendingFilePicker?.entries,
                  entries.indices.contains(selectedIndex) else {
                NSSound.beep()
                return
            }
            activateFilePickerEntry(entries[selectedIndex])
            return
        }
        if let selectedIndex = filePickerSelectedIndex,
           picker.entries.indices.contains(selectedIndex),
           picker.entries[selectedIndex].name == name,
           picker.entries[selectedIndex].isDirectory {
            activateFilePickerEntry(picker.entries[selectedIndex])
            return
        }

        let path: String
        if name.hasPrefix("/") || name.hasPrefix("~") {
            path = name
        } else {
            path = (picker.directory as NSString).appendingPathComponent(name)
        }
        let mode = pickerMode
        if ["move", "save", "copy"].contains(mode) {
            guard !name.isEmpty, !name.contains("/"), name != ".", name != ".." else { return }
            dismissFilePicker()
            if mode == "move" { moveFile(to: path) }
            else if let document { let target = pickerTarget; Task { await document.saveTo(path: path, target: target, copy: mode == "copy") } }
        } else { dismissFilePicker(); shouldPushHistory = true; openDocument(path: path, target: pickerTarget) }
    }

    private func moveFilePickerSelection(delta: Int) {
        guard let entries = pendingFilePicker?.entries, !entries.isEmpty else { return }
        let nextIndex = min(max((filePickerSelectedIndex ?? (delta > 0 ? -1 : entries.count)) + delta, 0), entries.count - 1)
        selectFilePickerIndex(nextIndex)
    }

    private func selectFilePickerIndex(_ index: Int) {
        guard let entries = pendingFilePicker?.entries, entries.indices.contains(index) else { return }
        filePickerSelectedIndex = index
        if pickerMode == "open" { filePickerNameInputController.setText(entries[index].name) }
        ensureFilePickerSelectionVisible()
        updateFilePickerVisibleRows(rebuild: true)
    }

    private func ensureFilePickerSelectionVisible() {
        guard let selectedIndex = filePickerSelectedIndex else { return }
        let rowTop = CGFloat(selectedIndex) * filePickerRowHeight
        let viewportHeight = max(filePickerListFrame.height, 1)
        if rowTop < filePickerScroll {
            filePickerScroll = rowTop
        } else if rowTop + filePickerRowHeight > filePickerScroll + viewportHeight {
            filePickerScroll = rowTop + filePickerRowHeight - viewportHeight
        }
    }

    private func resetFilePickerTypeahead() {
        filePickerTypeaheadBuffer = ""
        filePickerTypeaheadDeadline = nil
    }

    private func handleFilePickerTypeahead(_ text: String) {
        let now = Date()
        if let deadline = filePickerTypeaheadDeadline, deadline < now {
            filePickerTypeaheadBuffer = ""
        }
        filePickerTypeaheadDeadline = now.addingTimeInterval(1.0)
        filePickerTypeaheadBuffer += text.lowercased()
        guard let entries = pendingFilePicker?.entries, !filePickerTypeaheadBuffer.isEmpty else { return }
        if let match = filePickerMatch(in: entries, prefix: filePickerTypeaheadBuffer, startingAfterSelection: false) {
            selectFilePickerIndex(match)
            return
        }
        filePickerTypeaheadBuffer = text.lowercased()
        if let match = filePickerMatch(in: entries, prefix: filePickerTypeaheadBuffer, startingAfterSelection: true) {
            selectFilePickerIndex(match)
        }
    }

    private func filePickerMatch(in entries: [FilePickerEntryRecord], prefix: String, startingAfterSelection: Bool) -> Int? {
        guard !prefix.isEmpty else { return nil }
        let start = startingAfterSelection ? (filePickerSelectedIndex ?? -1) + 1 : 0
        let split = min(max(start, 0), entries.count)
        let ordered = Array(entries.indices.dropFirst(split)) + Array(entries.indices.prefix(split))
        return ordered.first { entries[$0].name.lowercased().hasPrefix(prefix) }
    }

    private func handleFilePickerMouseDown(point: CGPoint, clickCount: Int) -> Bool {
        let rootPoint = rootLayer.convert(point, to: rootLayer)
        if pickerMode == "conflict", let action = conflictFrames.first(where: { $0.0.contains(rootPoint) })?.1 { resolveReview(action); return true }
        if ["recent", "open"].contains(pickerMode) {
            if recentTabFrame.contains(rootPoint) { pickerMode = "recent"; filePickerScroll = 0; renderFilePicker(); return true }
            if openTabFrame.contains(rootPoint) { pickerMode = "open"; fetchFilePickerDirectory(path: pendingFilePicker?.directory ?? "~"); return true }
            if newFileFrame.contains(rootPoint) { dismissFilePicker(); shouldPushHistory = true; openDocument(path: "", new: true, target: pickerTarget); return true }
        }
        if pickerMode == "recent" {
            for (frame, remove, recent) in recentFrames {
                if remove.contains(rootPoint) { preferences.recent.removeAll { $0.path == recent.path && $0.target == recent.target }; savePreferences(); renderFilePicker(); return true }
                if frame.contains(rootPoint) { dismissFilePicker(); shouldPushHistory = true; openDocument(path: recent.path, target: recent.target); return true }
            }
        }
        if targetControlFrame.contains(rootPoint), ["open", "save", "copy"].contains(pickerMode) { showTargetMenu(at: point); return true }
        if filePickerCancelFrame.contains(rootPoint) {
            dismissFilePicker()
            return true
        }
        if filePickerOpenFrame.contains(rootPoint) {
            openFilePickerTypedPath()
            return true
        }
        if filePickerNameFieldFrame.contains(rootPoint) {
            focusFilePickerNameField(atRootPoint: rootPoint, clickCount: clickCount, modifySelection: false)
            return true
        }
        if let path = FilePickerBreadcrumbBar.hitPath(at: rootPoint,
                                                      breadcrumbFrame: filePickerBreadcrumbFrame,
                                                      segmentFrames: filePickerBreadcrumbSegmentFrames) {
            fetchFilePickerDirectory(path: path, clearName: pickerMode == "open")
            return true
        }
        if filePickerListFrame.contains(rootPoint),
           filePickerScrollbarController?.handleMouseDown(at: filePickerListLayer.convert(rootPoint, from: rootLayer)) == true {
            return true
        }
        if filePickerListFrame.contains(rootPoint),
           let hit = filePickerEntryFrames.first(where: { $0.frame.contains(rootPoint) }) {
            filePickerSelectedIndex = hit.index
            if pickerMode == "open" { filePickerNameInputController.setText(hit.entry.name) }
            filePickerNameInputController.blur()
            resetFilePickerTypeahead()
            updateFilePickerVisibleRows(rebuild: true)
            if hit.entry.isDirectory || clickCount >= 2 {
                activateFilePickerEntry(hit.entry)
            }
            return true
        }
        if !filePickerPanelFrame.contains(rootPoint) { dismissFilePicker() }; return true
    }

    private func handleFilePickerKeyDown(characters: String,
                                         charactersIgnoringModifiers: String,
                                         modifierFlags: NSEvent.ModifierFlags) -> Bool {
        let normalized = (charactersIgnoringModifiers.isEmpty ? characters : charactersIgnoringModifiers).lowercased()
        if filePickerNameInputController.isFocused {
            switch normalized {
            case "\u{1b}":
                dismissFilePicker()
                return true
            case "\r", "\n":
                return true
            default:
                return true
            }
        }
        switch normalized {
        case "\u{1b}":
            dismissFilePicker()
            return true
        case "\r", "\n":
            return true
        default:
            break
        }
        if charactersIgnoringModifiers == "\u{F700}" {
            moveFilePickerSelection(delta: -1)
            return true
        }
        if charactersIgnoringModifiers == "\u{F701}" {
            moveFilePickerSelection(delta: 1)
            return true
        }
        let disallowed: NSEvent.ModifierFlags = [.command, .control, .option]
        if modifierFlags.intersection(disallowed).isEmpty,
           !characters.isEmpty,
           characters.rangeOfCharacter(from: .newlines) == nil {
            handleFilePickerTypeahead(characters)
            return true
        }
        return true
    }

    private func scheduleResizeLayoutUpdate() {
        guard !resizeLayoutUpdateScheduled else { return }
        resizeLayoutUpdateScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            resizeLayoutUpdateScheduled = false
            layout()
        }
    }

    private func renderHeader() {
        withoutImplicitAnimations {
            if let pathPromptMode {
                pathLayer.string = pathPromptText.isEmpty ? " " : pathPromptText
                statusLayer.string = pathPromptMode.label
            } else {
                let value = documentDisplayName()
                let styled = NSMutableAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: 15), .foregroundColor: resolvedNSColor(.secondaryLabelColor)])
                let filename = filePath.isEmpty ? "Untitled" : (filePath as NSString).lastPathComponent
                let range = (value as NSString).range(of: filename, options: .backwards)
                if range.location != NSNotFound { styled.addAttributes([.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: resolvedNSColor(.labelColor)], range: range) }
                pathLayer.string = styled
                statusLayer.string = statusText
            }
        }
        notifyAccessibilityLayoutChanged()
    }

    func textInputControllerDidChangeState() {
        defer { notifyAccessibilityLayoutChanged() }
        if filePickerNameInputController.isFocused || pendingFilePicker != nil {
            updateFilePickerNameDisplay()
            updateCursor()
            updateEditingCapabilities()
            return
        }
        recomputeFindMatches(selectNearestMatch: true)
        updateFindDisplay()
        updateCursor()
        updateEditingCapabilities()
    }

    private func updateFindDisplay() {
        withoutImplicitAnimations {
            findBarLayer.isHidden = !isFindVisible
            findFieldLayer.borderColor = resolvedCGColor(findInputController.isFocused ? .separatorColor : .separatorColor)
            findFieldLayer.borderWidth = findInputController.isFocused ? 1.5 : 1
            let buttonTint = resolvedNSColor(findInputController.text.isEmpty ? .tertiaryLabelColor : .secondaryLabelColor)
            findPreviousIconLayer.tintColor = buttonTint
            findNextIconLayer.tintColor = buttonTint
            findPreviousButtonLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
            findNextButtonLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
            findDoneButtonLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
            findPreviousButtonLayer.borderColor = resolvedCGColor(.separatorColor)
            findNextButtonLayer.borderColor = resolvedCGColor(.separatorColor)
            findDoneButtonLayer.borderColor = resolvedCGColor(.separatorColor)
            findDoneTextLayer.foregroundColor = resolvedCGColor(.labelColor)

            let font = NSFont.systemFont(ofSize: 13, weight: .regular)
            findTextLayer.font = font
            findTextLayer.fontSize = 13
            findPlaceholderLayer.font = font
            findPlaceholderLayer.fontSize = 13
            findStatusLayer.font = NSFont.systemFont(ofSize: 12, weight: .regular)
            findStatusLayer.fontSize = 12
            findDoneTextLayer.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
            findDoneTextLayer.fontSize = 12

            let textFrame = findTextFrame()
            findTextLayer.frame = textFrame
            findPlaceholderLayer.frame = textFrame
            findTextLayer.string = findInputController.text
            findPlaceholderLayer.string = "Find"
            findPlaceholderLayer.isHidden = !findInputController.text.isEmpty

            if let range = findInputController.selectionRange {
                let lower = findTextX(for: range.lowerBound, font: font, textFrame: textFrame)
                let upper = findTextX(for: range.upperBound, font: font, textFrame: textFrame)
                findSelectionLayer.frame = CGRect(x: textFrame.minX + min(lower, upper),
                                                  y: textFrame.minY + 1,
                                                  width: max(abs(upper - lower), 1),
                                                  height: max(textFrame.height - 2, 1))
                findSelectionLayer.isHidden = false
            } else {
                findSelectionLayer.isHidden = true
            }

            if let range = findInputController.markedRange {
                let lower = findTextX(for: range.lowerBound, font: font, textFrame: textFrame)
                let upper = findTextX(for: range.upperBound, font: font, textFrame: textFrame)
                findMarkedUnderlineLayer.frame = CGRect(x: textFrame.minX + min(lower, upper),
                                                        y: textFrame.minY + 1,
                                                        width: max(abs(upper - lower), 1),
                                                        height: 2)
                findMarkedUnderlineLayer.isHidden = false
            } else {
                findMarkedUnderlineLayer.isHidden = true
            }

            let caretX = findTextX(for: findInputController.cursorPosition, font: font, textFrame: textFrame)
            findCaretLayer.frame = CGRect(x: textFrame.minX + caretX,
                                          y: textFrame.minY + 1,
                                          width: cursorWidth,
                                          height: max(textFrame.height - 2, 1))
            findCaretLayer.isHidden = !(isFindVisible && findInputController.isFocused && windowIsActive && viewIsFocused)
            if findCaretLayer.isHidden {
                stopBlinkingCaret(findCaretLayer)
            } else {
                startBlinkingCaret(findCaretLayer)
            }

            if findInputController.text.isEmpty {
                findStatusLayer.string = ""
            } else if let activeFindMatchIndex {
                findStatusLayer.string = "\(activeFindMatchIndex + 1) / \(findMatches.count)"
            } else if !findMatches.isEmpty {
                findStatusLayer.string = "\(findMatches.count) results"
            } else {
                findStatusLayer.string = "No results"
            }
        }
    }

    private func findTextFrame() -> CGRect {
        CGRect(x: 9, y: 6, width: max(findFieldFrame.width - 18, 1), height: 16)
    }

    private func findTextX(for characterIndex: Int, font: NSFont, textFrame: CGRect) -> CGFloat {
        let clamped = min(max(characterIndex, 0), findInputController.text.count)
        let endIndex = findInputController.text.index(findInputController.text.startIndex, offsetBy: clamped)
        let prefix = String(findInputController.text[..<endIndex]) as NSString
        return min(max(prefix.size(withAttributes: [.font: font]).width, 0), max(textFrame.width - cursorWidth, 0))
    }

    private func showFind(selectCurrentSelection: Bool) {
        endUndoGroup()
        if selectCurrentSelection, let selected = selectedString(), !selected.isEmpty {
            findInputController.setText(selected)
        }
        isFindVisible = true
        findInputController.focus(selectAll: true)
        recomputeFindMatches(selectNearestMatch: true)
        layout()
        updateCursor()
    }

    private func hideFind() {
        guard isFindVisible else { return }
        findInputController.blur()
        isFindVisible = false
        layout()
        updateCursor()
    }

    private func useSelectionForFind() {
        if let selected = selectedString(), !selected.isEmpty {
            findInputController.setText(selected)
        }
        showFind(selectCurrentSelection: false)
    }

    private func recomputeFindMatches(selectNearestMatch: Bool) {
        findMatches.removeAll()
        activeFindMatchIndex = nil
        let query = findInputController.text
        guard !query.isEmpty else { return }

        let haystack = text as NSString
        let queryLength = (query as NSString).length
        guard queryLength > 0 else { return }

        var searchRange = NSRange(location: 0, length: haystack.length)
        while searchRange.length > 0 {
            let match = haystack.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], range: searchRange)
            if match.location == NSNotFound { break }
            findMatches.append(match)
            let nextLocation = match.location + max(match.length, 1)
            if nextLocation >= haystack.length { break }
            searchRange = NSRange(location: nextLocation, length: haystack.length - nextLocation)
        }

        if selectNearestMatch {
            activateFindMatch(nearestTo: cursorOffset, forward: true, allowBeep: false)
        }
    }

    private func activateFindMatch(nearestTo offset: Int, forward: Bool, allowBeep: Bool) {
        guard !findMatches.isEmpty else {
            if allowBeep { NSSound.beep() }
            return
        }
        let clamped = clampedOffset(offset)
        let index: Int
        if forward {
            index = findMatches.firstIndex { $0.location + max($0.length, 1) > clamped } ?? 0
        } else {
            index = findMatches.lastIndex { $0.location < clamped } ?? (findMatches.count - 1)
        }
        activateFindMatch(at: index)
    }

    private func activateFindMatch(at index: Int) {
        endUndoGroup()
        guard findMatches.indices.contains(index) else { return }
        let match = findMatches[index]
        activeFindMatchIndex = index
        selectionAnchor = match.location
        cursorOffset = match.location + match.length
        ensureCursorVisible()
        updateViewport()
        updateSelectionLayers(force: true)
        updateCursor()
        updateFindDisplay()
        updateEditingCapabilities()
    }

    private func currentFindMatchIndex() -> Int? {
        if let activeFindMatchIndex, findMatches.indices.contains(activeFindMatchIndex) {
            return activeFindMatchIndex
        }
        guard let selectionRange else { return nil }
        return findMatches.firstIndex {
            $0.location == selectionRange.location && $0.length == selectionRange.length
        }
    }

    private func findNext() {
        if !isFindVisible {
            showFind(selectCurrentSelection: false)
            return
        }
        recomputeFindMatches(selectNearestMatch: false)
        guard !findMatches.isEmpty else {
            updateFindDisplay()
            NSSound.beep()
            return
        }
        let nextIndex = currentFindMatchIndex().map { ($0 + 1) % findMatches.count }
            ?? (findMatches.firstIndex { $0.location >= cursorOffset } ?? 0)
        activateFindMatch(at: nextIndex)
    }

    private func findPrevious() {
        if !isFindVisible {
            showFind(selectCurrentSelection: false)
            return
        }
        recomputeFindMatches(selectNearestMatch: false)
        guard !findMatches.isEmpty else {
            updateFindDisplay()
            NSSound.beep()
            return
        }
        let previousIndex = currentFindMatchIndex().map { ($0 - 1 + findMatches.count) % findMatches.count }
            ?? (findMatches.lastIndex { $0.location < cursorOffset } ?? (findMatches.count - 1))
        activateFindMatch(at: previousIndex)
    }

    private func documentDisplayName() -> String {
        filePath.isEmpty ? "Untitled" : filePath
    }

    private func queryValue(_ name: String) -> String? {
        URLComponents(string: currentURLString)?.queryItems?.first(where: { $0.name == name })?.value
    }

    private func loadFile() {
        openDocument(path: filePath, draftID: queryValue("draft"), target: queryValue("target"))
    }

    private func flushDrafts() {
        let documents = Array(documents.values)
        Task { for document in documents { _ = await document.persist() } }
    }

    private func discoverTargets() {
        guard let session = urlSession, let endpoint = environmentEndpoint else { return }
        Task {
            do {
                var request = URLRequest(url: endpoint); request.httpMethod = "POST"; request.setValue("1", forHTTPHeaderField: "X-Environment-Request")
                request.httpBody = try PlaintextEnvironment.encode(7, target: "host", path: "")
                let (bytes, _) = try await session.data(for: request)
                let envelope = BinaryPayloadReader(data: bytes), metadata = try envelope.child(at: 16)
                let count = Int(try metadata.uint32(at: 16)); guard count < 10000 else { return }
                targets = try (0..<count).map { index in
                    let offset = 80 + index * 56
                    return (try metadata.stringRef(at: offset), try metadata.stringRef(at: offset + 24), try metadata.stringRef(at: offset + 32) == "running")
                }
                layout()
            } catch { statusText = error.localizedDescription; layout() }
        }
    }

    private func showTargetMenu(at point: CGPoint) {
        let id = UUID(); targetMenuIDs.insert(id)
        outerframeHost.showContextMenu(menuID: id, items: targets.map { OuterframeContextMenuItem(id: $0.id, title: $0.id == "host" ? "Host — " + $0.name : $0.name, isEnabled: $0.running) }, at: point)
    }

    private func startWatching() {
        guard let doc = document, let session = urlSession, let endpoint = environmentEndpoint else { return }
        let key = doc.draft.id + ":" + doc.draft.target + ":" + doc.draft.path
        guard key != watchedKey else { return }
        watchedKey = key; watchTask?.cancel(); watchTask = nil
        guard !doc.draft.path.isEmpty else { return }
        watchTask = Task { [weak self, weak doc] in
            var delay: UInt64 = 1
            while !Task.isCancelled {
                guard let doc else { return }
                do {
                    var request = URLRequest(url: endpoint.deletingLastPathComponent().appendingPathComponent("watch"))
                    request.httpMethod = "POST"; request.timeoutInterval = 3600
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    request.setValue("1", forHTTPHeaderField: "X-Environment-Request")
                    request.httpBody = try PlaintextEnvironment.encode(10, target: doc.draft.target, path: doc.draft.path)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PlaintextDocumentError.connection }
                    await doc.refresh()
                    for try await line in bytes.lines {
                        guard !Task.isCancelled, self?.document === doc else { return }
                        if line.contains("\"changed\":true") || line.contains("\"changed\": true") { await doc.refresh() }
                        delay = 1
                    }
                } catch {}
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000); delay = min(30, delay * 2)
            }
        }
    }

    private func makeDocument(_ record: PlaintextDraft, storage: PlaintextDraftStore? = nil) -> PlaintextDocument? {
        guard let store = storage ?? draftStore, let session = urlSession, let endpoint = environmentEndpoint else { return nil }
        let doc = PlaintextDocument(draft: record, store: store) { operation, target, path, revision, draftRevision, contents in
            try await PlaintextEnvironment.request(session: session, endpoint: endpoint, operation: operation,
                                                   target: target, path: path, destination: draftRevision, revision: revision, contents: contents)
        }
        doc.changed = { [weak self, weak doc] in
            guard let self, let doc, self.document === doc else { return }
            let pathChanged = self.filePath != doc.draft.path
            self.filePath = doc.draft.path
            if !self.showingServerVersion && self.text != doc.draft.contents {
                self.text = doc.draft.contents; self.cursorOffset = min(self.cursorOffset, self.text.utf16.count); self.selectionAnchor = nil
                self.updateTextContent(force: true)
            }
            if pathChanged { self.rememberRecent() }
            self.startWatching()
            self.isSaving = doc.isSaving
            self.statusText = self.showingServerVersion ? "Server version (read-only) · Use the file menu to return to your draft" : doc.status
            self.outerframeHost.setTitle((self.showingServerVersion ? "Server version · " : "") + (doc.draft.dirty ? "• " : "") + (doc.draft.path.isEmpty ? "Untitled" : (doc.draft.path as NSString).lastPathComponent))
            self.updateURLForCurrentFile()
            self.renderHeader(); self.updateColors()
            self.layout()
        }
        documents[record.id] = doc
        return doc
    }

    private func activate(_ doc: PlaintextDocument) {
        endUndoGroup()
        document = doc; reviewedDisk = nil; showingServerVersion = false
        filePath = doc.draft.path; text = doc.draft.contents
        cursorOffset = 0; selectionAnchor = nil; scrollOffset = 0; horizontalOffset = 0
        clearMarkedTextState()
        doc.changed?(); updateTextContent(force: true); layout()
        rememberRecent(); startWatching(); doc.resume()
        if showStartupPopover { showStartupPopover = false; showHomePopover() }
    }

    private func openDocument(path: String, draftID: String? = nil, new: Bool = false, target requestedTarget: String? = nil) {
        guard !isLoading, let store = draftStore, let session = urlSession, let endpoint = environmentEndpoint else { return }
        isLoading = true; statusText = "Opening…"; renderHeader()
        let target = requestedTarget ?? document?.draft.target ?? queryValue("target") ?? "host"
        Task {
            defer { isLoading = false; renderHeader(); updateColors() }
            if let document, !(await document.persist()) { statusText = document.status; return }
            do {
                let records: [PlaintextDraft]
                do { records = try await store.all() }
                catch {
                    if document != nil { throw error }
                    records = []
                }
                var record = (new || (path.isEmpty && draftID == nil)) ? nil : records.first { draftID != nil ? $0.id == draftID : $0.path == path && $0.target == target }
                if let record, let existing = documents[record.id] { activate(existing); return }
                if record == nil {
                    var fresh = PlaintextDraft(); fresh.target = target; fresh.path = path
                    if !path.isEmpty {
                        let result = try await PlaintextEnvironment.request(session: session, endpoint: endpoint, operation: 11, target: target, path: path)
                        fresh.path = result.path; fresh.contents = result.contents; fresh.revision = result.revision
                        fresh.dirty = result.dirty; fresh.conflict = result.conflict; fresh.draftRevision = result.draftRevision; fresh.remoteVersion = fresh.version
                    }
                    record = fresh
                }
                guard var selected = record else { return }
                var selectedStore = store
                do {
                    if !(try await store.claim(selected.id)) {
                        selected.id = UUID().uuidString; selected.pending = nil
                        guard try await store.claim(selected.id) else { throw PlaintextDocumentError.message("Cannot claim a new draft") }
                    }
                } catch {
                    if document != nil { throw error }
                    selected.id = UUID().uuidString
                    selectedStore = PlaintextDraftStore(directory: nil, unavailableReason: error.localizedDescription)
                }
                guard let doc = makeDocument(selected, storage: selectedStore) else { return }
                _ = await doc.persist(); activate(doc)
                if !didRestoreQueue {
                    didRestoreQueue = true
                    for record in records where record.pending != nil && !record.conflict && documents[record.id] == nil {
                        if try await store.claim(record.id), let queued = makeDocument(record) { queued.resume() }
                    }
                }
                await doc.refresh()
            } catch {
                if let document { filePath = document.draft.path }
                statusText = error.localizedDescription
            }
        }
    }

    private func scheduleSave() {
        guard !showingServerVersion else { return }
        document?.edit(text)
    }

    private func saveNow() {
        endUndoGroup()
        guard let document, !isLoading, !showingServerVersion else { return }
        if document.draft.conflict { reviewServerVersion(); return }
        if document.draft.path.isEmpty { pickerMode = "save"; showOpenFilePicker(); return }
        Task { await document.save() }
    }

    private func openPath(_ path: String) {
        let nextPath = normalizedPath(path, relativeTo: filePath)
        guard !nextPath.isEmpty else { return }
        openDocument(path: nextPath)
    }

    private func moveFile(to path: String) {
        let targetPath = normalizedPath(path, relativeTo: filePath)
        guard let document, !isLoading, !document.draft.dirty, document.draft.pending == nil,
              !targetPath.isEmpty, targetPath != filePath, let session = urlSession, let endpoint = environmentEndpoint else {
            statusText = "Save the file before moving it"; renderHeader(); return
        }
        isLoading = true; statusText = "Moving…"; renderHeader()
        Task {
            defer { isLoading = false; renderHeader() }
            guard await document.persist() else { return }
            do {
                let result = try await PlaintextEnvironment.request(session: session, endpoint: endpoint, operation: 4,
                                                                    target: document.draft.target, path: document.draft.path,
                                                                    destination: targetPath, revision: document.draft.revision)
                document.draft.path = result.path; document.draft.revision = result.revision
                _ = await document.persist(); document.changed?()
            } catch { statusText = error.localizedDescription }
        }
    }

    private func reviewServerVersion() {
        endUndoGroup()
        guard let doc = document else { return }
        Task {
            do {
                let shared = try await doc.sharedState()
                let disk = try await doc.disk()
                guard document === doc else { return }
                reviewedShared = shared
                reviewedDisk = disk; showingServerVersion = false
                pickerMode = "conflict"; showOpenFilePicker(); filePickerNameInputController.blur()
            } catch { statusText = error.localizedDescription; renderHeader() }
        }
    }

    private func resolveReview(_ action: String) {
        guard let doc = document, let disk = reviewedDisk else { return }
        let sharedRevision = reviewedShared?.draftRevision ?? "missing"
        dismissFilePicker()
        switch action {
        case "copy": pickerMode = "copy"; showOpenFilePicker()
        case "replace": Task { await doc.replaceReviewedFile(revision: disk.revision, draftRevision: sharedRevision) }
        case "discard": Task { do { try await doc.discardReviewedFile(disk, draftRevision: sharedRevision) } catch { statusText = error.localizedDescription; layout() } }
        default: break
        }
    }

    private func returnToDraft() {
        guard let document else { return }
        showingServerVersion = false; text = document.draft.contents; cursorOffset = 0; selectionAnchor = nil
        updateTextContent(force: true); document.changed?()
    }

    private func exportDraft() {
        guard let document, let directory = outerframeHost.stagedFileDirectoryURL else { return }
        let contents = document.draft.contents
        Task {
            do {
                let url = try await Task.detached {
                    let url = directory.appendingPathComponent("Plaintext-draft-" + UUID().uuidString + ".txt")
                    try Data(contents.utf8).write(to: url)
                    return url
                }.value
                outerframeHost.requestPasteboardWrite(items: [OuterframeContentPasteboardItem(representations: [
                    OuterframeContentPasteboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.fileURL.rawValue,
                                                              data: Data(url.absoluteString.utf8))
                ])])
                statusText = "Draft copied as a file · Paste into Finder to keep it"; renderHeader()
            } catch { statusText = "Export failed: " + error.localizedDescription; renderHeader() }
        }
    }

    private func normalizedPath(_ value: String, relativeTo basePath: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return trimmed
        }
        let directory = (basePath as NSString).deletingLastPathComponent
        guard !directory.isEmpty, directory != "." else { return trimmed }
        return (directory as NSString).appendingPathComponent(trimmed)
    }

    private func updateURLForCurrentFile() {
        guard !currentURLString.isEmpty,
              var components = URLComponents(string: currentURLString) else {
            return
        }
        var items = components.queryItems ?? []
        items.removeAll { ["file", "draft", "target"].contains($0.name) }
        if !filePath.isEmpty {
            items.append(URLQueryItem(name: "file", value: filePath))
        }
        if let document {
            items.append(URLQueryItem(name: "draft", value: document.draft.id))
            items.append(URLQueryItem(name: "target", value: document.draft.target))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return }
        guard currentURLString != url.absoluteString else { return }
        currentURLString = url.absoluteString
        if shouldPushHistory { shouldPushHistory = false; outerframeHost.pushHistoryEntry(url: url) }
        else { outerframeHost.replaceHistoryEntry(url: url) }
    }

    private func showContainerPicker() {
        pickerMode = filePath.isEmpty ? "save" : "open"; showOpenFilePicker()
    }

    private func showOpenPrompt() {
        pickerMode = "open"; showOpenFilePicker()
    }

    private func showMoveRenamePrompt() {
        guard !filePath.isEmpty else { pickerMode = "save"; showOpenFilePicker(); return }
        guard document?.draft.dirty == false, document?.draft.pending == nil else { statusText = "Save this file before moving it"; layout(); return }
        pickerMode = "move"; showOpenFilePicker()
    }

    private func beginPathPrompt(mode: PathPromptMode, defaultValue: String) {
        endUndoGroup()
        pathPromptMode = mode
        findInputController.blur()
        filePickerNameInputController.blur()
        pathPromptSelectionRange = nil
        pathPromptText = defaultValue
        pathPromptCursorOffset = (pathPromptText as NSString).length
        renderHeader()
        layout()
    }

    private func cancelPathPrompt() {
        pathPromptMode = nil
        pathPromptText = ""
        pathPromptSelectionRange = nil
        pathPromptCursorOffset = 0
        renderHeader()
        layout()
        updateColors()
    }

    private func confirmPathPrompt() {
        guard let mode = pathPromptMode else { return }
        let value = pathPromptText
        cancelPathPrompt()
        switch mode {
        case .open:
            openPath(value)
        case .moveRename:
            moveFile(to: value)
        case .saveAs:
            let path = normalizedPath(value, relativeTo: filePath)
            if !path.isEmpty, let document { Task { await document.save(path: path) } }
        case .saveCopy:
            let path = normalizedPath(value, relativeTo: filePath)
            if !path.isEmpty, let document {
                returnToDraft()
                Task { await document.saveCopy(path: path) }
            }
        }
    }

    private func pathPromptCursorX(font: NSFont, maxWidth: CGFloat) -> CGFloat {
        let nsString = pathPromptText as NSString
        let cursor = min(max(pathPromptCursorOffset, 0), nsString.length)
        let prefix = nsString.substring(to: cursor) as NSString
        let width = prefix.size(withAttributes: [.font: font]).width
        return min(max(width, 0), max(maxWidth - cursorWidth, 0))
    }

    private func setPathPromptCursor(atToolbarX toolbarX: CGFloat) {
        guard pathPromptMode != nil else { return }
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let relativeX = max(toolbarX - pathLayer.frame.minX, 0)
        let nsString = pathPromptText as NSString
        var bestOffset = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for offset in 0...nsString.length where OuterframeAccessibilityTextRange.isValid(NSRange(location: offset, length: 0), in: pathPromptText) {
            let prefix = nsString.substring(to: offset) as NSString
            let width = prefix.size(withAttributes: [.font: font]).width
            let distance = abs(width - relativeX)
            if distance < bestDistance {
                bestDistance = distance
                bestOffset = offset
            }
        }
        pathPromptSelectionRange = nil
        pathPromptCursorOffset = bestOffset
        layout()
    }

    private func insertPathPromptText(_ value: String) {
        replacePathPromptText(range: pathPromptSelectionRange ?? NSRange(location: pathPromptCursorOffset, length: 0), with: value)
    }

    private func replacePathPromptText(range: NSRange, with replacement: String) {
        let nsString = pathPromptText as NSString
        let safeLocation = min(max(range.location, 0), nsString.length)
        let safeLength = min(max(range.length, 0), nsString.length - safeLocation)
        pathPromptText = nsString.replacingCharacters(in: NSRange(location: safeLocation, length: safeLength),
                                                      with: replacement)
        pathPromptSelectionRange = nil
        pathPromptCursorOffset = safeLocation + (replacement as NSString).length
        renderHeader()
        layout()
    }

    private func deletePathPromptBackward() {
        if let selection = pathPromptSelectionRange { replacePathPromptText(range: selection, with: ""); return }
        let nsString = pathPromptText as NSString
        guard pathPromptCursorOffset > 0, nsString.length > 0 else { return }
        replacePathPromptText(range: nsString.rangeOfComposedCharacterSequence(at: pathPromptCursorOffset - 1), with: "")
    }

    private func deletePathPromptForward() {
        if let selection = pathPromptSelectionRange { replacePathPromptText(range: selection, with: ""); return }
        let nsString = pathPromptText as NSString
        guard pathPromptCursorOffset < nsString.length else { return }
        replacePathPromptText(range: nsString.rangeOfComposedCharacterSequence(at: pathPromptCursorOffset), with: "")
    }

    private func performPathPromptTextCommand(_ command: String) {
        let nsString = pathPromptText as NSString
        switch command {
        case "insertNewline", "insertNewlineIgnoringFieldEditor":
            confirmPathPrompt()
        case "cancelOperation":
            cancelPathPrompt()
        case "deleteBackward":
            deletePathPromptBackward()
        case "deleteForward", "deleteForwardByDecomposingPreviousCharacter":
            deletePathPromptForward()
        case "selectAll":
            pathPromptSelectionRange = nsString.length > 0 ? NSRange(location: 0, length: nsString.length) : nil
            pathPromptCursorOffset = nsString.length
            layout()
        case "moveLeft":
            pathPromptCursorOffset = pathPromptSelectionRange?.location ?? (pathPromptCursorOffset > 0 ? nsString.rangeOfComposedCharacterSequence(at: pathPromptCursorOffset - 1).location : 0)
            pathPromptSelectionRange = nil
            layout()
        case "moveRight":
            pathPromptCursorOffset = pathPromptSelectionRange.map(NSMaxRange) ?? (pathPromptCursorOffset < nsString.length ? NSMaxRange(nsString.rangeOfComposedCharacterSequence(at: pathPromptCursorOffset)) : nsString.length)
            pathPromptSelectionRange = nil
            layout()
        case "moveToBeginningOfLine", "moveToBeginningOfDocument", "moveToLeftEndOfLine":
            pathPromptSelectionRange = nil
            pathPromptCursorOffset = 0
            layout()
        case "moveToEndOfLine", "moveToEndOfDocument", "moveToRightEndOfLine":
            pathPromptSelectionRange = nil
            pathPromptCursorOffset = nsString.length
            layout()
        default:
            break
        }
    }

    private func pastePathPrompt(_ items: [OuterframeContentPasteboardItem]) {
        for item in items {
            if let representation = item.representations.first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue }),
               let string = String(data: representation.data, encoding: .utf8) {
                insertPathPromptText(string)
                return
            }
        }
    }

    private func showPathMenu(at point: CGPoint) {
        endUndoGroup()
        let menuID = UUID()
        pendingPathMenuIDs.insert(menuID)
        let doc = document
        Task {
            var recovery: [OuterframeContextMenuItem] = []
            do {
                if let draftStore {
                    recovery = try await draftStore.all().map {
                        OuterframeContextMenuItem(id: "recover:" + $0.id,
                                                  title: ($0.path.isEmpty ? "Untitled" : $0.path) + " · " + $0.target + " · " + $0.updated.formatted() + ($0.pending == nil ? "" : " · Save queued"))
                    }
                }
            } catch { statusText = error.localizedDescription; renderHeader() }
            var items = [
                OuterframeContextMenuItem(id: "text-smaller", title: "Smaller Text", isEnabled: preferences.textScale > 0.25),
                OuterframeContextMenuItem(id: "text-reset", title: "Text Size: \(Int(preferences.textScale * 100))% — Reset"),
                OuterframeContextMenuItem(id: "text-larger", title: "Larger Text", isEnabled: preferences.textScale < 3),
                OuterframeContextMenuItem(id: "text-wrap", title: (preferences.wrapLines ? "✓ " : "") + "Wrap lines"),
                OuterframeContextMenuItem(id: "path-recover", title: "Recover Draft", kind: .submenu, isEnabled: !recovery.isEmpty, children: recovery),
                OuterframeContextMenuItem(id: "path-export", title: "Copy Draft as File", isEnabled: doc != nil),
                OuterframeContextMenuItem(id: "path-copy-text", title: "Copy Draft Text", isEnabled: doc != nil),
                OuterframeContextMenuItem(id: "path-save-copy", title: "Save a Copy…", isEnabled: doc != nil && doc?.isSynchronizing == false),
                OuterframeContextMenuItem(id: "path-copy", title: "Copy Path", isEnabled: !filePath.isEmpty)
            ]
            if doc?.draft.conflict == true { items.append(OuterframeContextMenuItem(id: "path-review", title: "Review conflicting changes…")) }
            outerframeHost.showContextMenu(menuID: menuID, items: items, at: point)
        }
    }

    private func copyCurrentPath() {
        guard !filePath.isEmpty else { return }
        let item = OuterframeContentPasteboardItem(representations: [
            OuterframeContentPasteboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                                      data: Data(filePath.utf8))
        ])
        outerframeHost.requestPasteboardWrite(items: [item])
    }

    private func textFont() -> NSFont {
        NSFont.monospacedSystemFont(ofSize: 15 * preferences.textScale, weight: .regular)
    }

    private func updateTextContent(force: Bool = false, keepingCursorVisible: Bool = false) {
        let displayText = text.isEmpty ? " " : text
        let textChanged = displayText != attributedText.string
        guard force || textChanged else { return }

        withoutImplicitAnimations {
            generation += 1
            if !preferences.wrapLines {
                naturalTextWidth = text.components(separatedBy: .newlines).reduce(CGFloat(1)) { max($0, ($1 as NSString).size(withAttributes: [.font: textFont()]).width + 4) }
            }
            contentHeightCache = nil
            visualLineCache = nil
            fragmentCoverage = nil
            clearTextFragmentLayers()

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 2
            let updatedText = NSMutableAttributedString(string: displayText,
                                                        attributes: [
                                                            .font: textFont(),
                                                            .foregroundColor: resolvedNSColor(.labelColor),
                                                            .paragraphStyle: paragraph
                                                        ])
            if let markedRange = normalizedRange(markedTextRange),
               markedRange.location + markedRange.length <= updatedText.length {
                updatedText.addAttributes([
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                    .underlineColor: resolvedNSColor(.keyboardFocusIndicatorColor)
                ], range: markedRange)
            }
            attributedText = updatedText
            contentStorage.attributedString = attributedText
            cursorOffset = clampedOffset(cursorOffset)
            selectionAnchor = selectionAnchor.map(clampedOffset)
            if textChanged { recomputeFindMatches(selectNearestMatch: false) }
            layoutText(keepingCursorVisible: keepingCursorVisible)
            updateEditingCapabilities()
        }
        notifyAccessibilityLayoutChanged()
    }

    private func editorTextWidth() -> CGFloat {
        let viewport = max(editorClipLayer.bounds.width - textInsetX * 2, 1)
        return preferences.wrapLines ? viewport : max(viewport, naturalTextWidth)
    }

    private var pendingTextScale: CGFloat?
    private var textScaleUpdateScheduled = false
    private var textScaleSaveTask: Task<Void, Never>?

    private func scheduleTextMagnification(_ amount: CGFloat) {
        guard amount.isFinite else { return }
        let scale = pendingTextScale ?? preferences.textScale
        pendingTextScale = min(3, max(0.25, scale * (1 + amount)))
        guard !textScaleUpdateScheduled else { return }
        textScaleUpdateScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
            guard let self else { return }
            self.textScaleUpdateScheduled = false
            guard let scale = self.pendingTextScale else { return }
            self.pendingTextScale = nil
            guard self.pendingFilePicker == nil else { return }
            self.setTextScale(scale, deferSaving: true)
        }
    }

    private func setTextScale(_ value: CGFloat, deferSaving: Bool = false) {
        pendingTextScale = nil
        guard value.isFinite else { return }
        let scale = min(3, max(0.25, value))
        guard scale != preferences.textScale else { return }
        preferences.textScale = scale
        textScaleSaveTask?.cancel()
        textScaleSaveTask = nil
        if deferSaving {
            textScaleSaveTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { return }
                self?.savePreferences()
            }
        } else {
            savePreferences()
        }
        updateTextContent(force: true, keepingCursorVisible: true)
    }

    private func savePreferences() {
        guard let store = draftStore else { return }
        let value = preferences, previous = preferencesWriteTask
        preferencesWriteTask = Task {
            await previous?.value
            do {
                let encoder = PropertyListEncoder(); encoder.outputFormat = .binary
                try await store.putSetting("preferences", value: encoder.encode(value))
            } catch { statusText = "Could not save preferences: " + error.localizedDescription; renderHeader() }
        }
    }

    private func rememberRecent() {
        guard let doc = document, !doc.draft.path.isEmpty else { return }
        preferences.recent.removeAll { $0.path == doc.draft.path && $0.target == doc.draft.target }
        preferences.recent.insert(NativeRecentFile(path: doc.draft.path, target: doc.draft.target), at: 0)
        preferences.recent = Array(preferences.recent.prefix(30)); savePreferences()
    }

    private func layoutText(keepingCursorVisible: Bool = false) {
        guard editorClipLayer.bounds.width > 0, editorClipLayer.bounds.height > 0 else { return }
        let textWidth = editorTextWidth()
        if abs(textWidth - textLayoutWidth) > 0.5 {
            textLayoutWidth = textWidth
            clearTextFragmentLayers()
            contentHeightCache = nil
            visualLineCache = nil
        }
        textContainer.size = CGSize(width: textWidth,
                                    height: max(contentHeight() - textInsetY * 2, editorClipLayer.bounds.height))
        scrollOffset = clampedScrollOffset(scrollOffset)
        if keepingCursorVisible { ensureCursorVisible() }
        updateViewport()
        updateSelectionLayers()
        updateCursor()
    }

    private func updateViewport() {
        withoutImplicitAnimations {
            guard editorClipLayer.bounds.width > 0, editorClipLayer.bounds.height > 0 else {
                clearTextFragmentLayers()
                return
            }

            let textWidth = editorTextWidth()
            let contentHeight = max(self.contentHeight() - textInsetY * 2, editorClipLayer.bounds.height)
            textContentLayer.frame = CGRect(x: textInsetX - horizontalOffset,
                                            y: editorClipLayer.bounds.height - textInsetY - contentHeight + scrollOffset,
                                            width: textWidth,
                                            height: contentHeight)
            textSelectionLayer.frame = CGRect(x: 0, y: 0, width: textWidth, height: contentHeight)
            scrollbarController?.updateLayout(metrics: ScrollbarController.Metrics(viewportSize: editorClipLayer.bounds.size,
                                                                                    contentHeight: self.contentHeight(),
                                                                                    scrollOffset: scrollOffset))

            let visibleTextRect = visibleTextContentRect()
            if let coverage = fragmentCoverage,
               coverage.generation == generation,
               abs(coverage.textWidth - textWidth) <= 0.5,
               abs(coverage.contentHeight - contentHeight) <= 0.5,
               coverage.rect.contains(visibleTextRect) {
                return
            }

            let layoutRect = expandedTextContentRect(containing: visibleTextRect, contentHeight: contentHeight)
            textLayoutManager.ensureLayout(for: layoutRect)
            let startLocation = textLayoutManager.textLayoutFragment(for: CGPoint(x: 0, y: max(layoutRect.minY, 0)))?.rangeInElement.location
                ?? textLayoutManager.documentRange.location

            var visibleFragmentIDs = Set<ObjectIdentifier>()
            textLayoutManager.enumerateTextLayoutFragments(from: startLocation, options: [.ensuresLayout]) { fragment in
                let frame = fragment.layoutFragmentFrame
                if frame.minY > layoutRect.maxY {
                    return false
                }
                guard frame.maxY >= layoutRect.minY else {
                    return true
                }

                let id = ObjectIdentifier(fragment)
                visibleFragmentIDs.insert(id)
                let layer = self.textFragmentLayers[id] ?? {
                    let layer = TextFragmentLayer()
                    layer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
                    self.textContentLayer.addSublayer(layer)
                    self.textFragmentLayers[id] = layer
                    return layer
                }()
                layer.textLayoutFragment = fragment
                let surface = fragment.renderingSurfaceBounds
                let topDownFrame = CGRect(x: frame.minX + surface.minX,
                                          y: frame.minY + surface.minY,
                                          width: surface.width,
                                          height: surface.height)
                layer.renderingSurfaceOffset = surface.origin
                layer.frame = CGRect(x: topDownFrame.minX,
                                     y: contentHeight - topDownFrame.maxY,
                                     width: topDownFrame.width,
                                     height: topDownFrame.height)
                return true
            }

            fragmentCoverage = (generation: generation,
                                textWidth: textWidth,
                                contentHeight: contentHeight,
                                rect: layoutRect)
            let staleIDs = textFragmentLayers.keys.filter { !visibleFragmentIDs.contains($0) }
            for id in staleIDs {
                textFragmentLayers[id]?.removeFromSuperlayer()
                textFragmentLayers[id] = nil
            }
        }
        notifyAccessibilityLayoutChanged()
    }

    private func clearTextFragmentLayers() {
        for layer in textFragmentLayers.values {
            layer.removeFromSuperlayer()
        }
        textFragmentLayers = [:]
        fragmentCoverage = nil
    }

    private func contentHeight() -> CGFloat {
        guard editorClipLayer.bounds.width > 0, editorClipLayer.bounds.height > 0 else { return 0 }
        let textWidth = editorTextWidth()
        return contentHeight(textWidth: textWidth)
    }

    private func contentHeight(textWidth: CGFloat) -> CGFloat {
        if let cache = contentHeightCache,
           cache.generation == generation,
           abs(cache.textWidth - textWidth) <= 0.5 {
            return cache.height
        }

        textContainer.size = CGSize(width: textWidth,
                                    height: max(textMeasurementHeight, editorClipLayer.bounds.height))
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        let height = max(textLayoutManager.usageBoundsForTextContainer.maxY + textInsetY * 2,
                         editorClipLayer.bounds.height)
        contentHeightCache = (generation: generation, textWidth: textWidth, height: height)
        return height
    }

    private func visualLineMetrics(textWidth: CGFloat? = nil) -> EditorVisualLineMetrics {
        let resolvedTextWidth = max(textWidth ?? editorTextWidth(), 1)
        if let cache = visualLineCache,
           cache.generation == generation,
           abs(cache.textWidth - resolvedTextWidth) <= 0.5 {
            return cache.metrics
        }

        let font = textFont()
        let charWidth = max(("0" as NSString).size(withAttributes: [.font: font]).width, 1)
        let lineHeight = ceil(font.ascender - font.descender + font.leading + 2)
        let charactersPerLine = max(Int(floor(resolvedTextWidth / charWidth)), 1)
        let nsString = text as NSString
        let length = nsString.length
        var lines: [EditorVisualLine] = []
        var lineStart = 0

        while lineStart < length {
            let lineRange = nsString.lineRange(for: NSRange(location: lineStart, length: 0))
            var contentLength = lineRange.length
            while contentLength > 0 {
                let character = nsString.character(at: lineRange.location + contentLength - 1)
                if character == 10 || character == 13 {
                    contentLength -= 1
                } else {
                    break
                }
            }
            let visualLineCount = max(Int(ceil(Double(contentLength) / Double(charactersPerLine))), 1)
            for visualLineIndex in 0..<visualLineCount {
                let offset = visualLineIndex * charactersPerLine
                let location = min(lineRange.location + offset, length)
                let remaining = max(contentLength - offset, 0)
                let visualLength = min(remaining, charactersPerLine)
                lines.append(EditorVisualLine(range: NSRange(location: location, length: visualLength)))
            }

            let nextLineStart = NSMaxRange(lineRange)
            if nextLineStart <= lineStart { break }
            lineStart = nextLineStart
        }

        if length == 0 {
            lines.append(EditorVisualLine(range: NSRange(location: 0, length: 0)))
        } else {
            let lastCharacter = nsString.character(at: length - 1)
            if lastCharacter == 10 || lastCharacter == 13 {
                lines.append(EditorVisualLine(range: NSRange(location: length, length: 0)))
            }
        }

        let metrics = EditorVisualLineMetrics(textWidth: resolvedTextWidth,
                                              charWidth: charWidth,
                                              lineHeight: lineHeight,
                                              charactersPerLine: charactersPerLine,
                                              lines: lines)
        visualLineCache = (generation: generation, textWidth: resolvedTextWidth, metrics: metrics)
        return metrics
    }

    private func visibleTextContentRect() -> CGRect {
        CGRect(x: 0,
               y: max(scrollOffset - textInsetY, 0),
               width: editorTextWidth(),
               height: editorClipLayer.bounds.height)
    }

    private func expandedTextContentRect(containing rect: CGRect, contentHeight: CGFloat) -> CGRect {
        let overscan = max(editorClipLayer.bounds.height * 1.5, 600)
        let minY = max(rect.minY - overscan, 0)
        let maxY = min(max(rect.maxY + overscan, minY + rect.height), contentHeight)
        return CGRect(x: rect.minX, y: minY, width: rect.width, height: max(maxY - minY, rect.height))
    }

    private func clampedScrollOffset(_ proposed: CGFloat) -> CGFloat {
        min(max(proposed, 0), max(contentHeight() - editorClipLayer.bounds.height, 0))
    }

    private var selectionRange: NSRange? {
        guard let selectionAnchor, selectionAnchor != cursorOffset else { return nil }
        let location = min(selectionAnchor, cursorOffset)
        return NSRange(location: location, length: abs(selectionAnchor - cursorOffset))
    }

    private func normalizedRange(_ range: NSRange?) -> NSRange? {
        guard let range else { return nil }
        let length = (text as NSString).length
        let lower = max(min(range.location, length), 0)
        let upper = max(min(range.location + range.length, length), lower)
        guard upper > lower else { return nil }
        return NSRange(location: lower, length: upper - lower)
    }

    private func normalizedReplacementRange(_ range: NSRange) -> NSRange? {
        normalizedRange(range) ?? (range.length == 0 ? NSRange(location: clampedOffset(range.location), length: 0) : nil)
    }

    private func textLocation(forUTF16Offset offset: Int) -> (any NSTextLocation)? {
        textLayoutManager.location(textLayoutManager.documentRange.location,
                                   offsetBy: clampedOffset(offset))
    }

    private func utf16Offset(for location: any NSTextLocation) -> Int {
        clampedOffset(textLayoutManager.offset(from: textLayoutManager.documentRange.location, to: location))
    }

    private func textRange(for range: NSRange) -> NSTextRange? {
        let lower = clampedOffset(range.location)
        let upper = clampedOffset(range.location + range.length)
        guard let start = textLocation(forUTF16Offset: min(lower, upper)),
              let end = textLocation(forUTF16Offset: max(lower, upper)) else {
            return nil
        }
        return NSTextRange(location: start, end: end)
    }

    private func textSegmentRects(for range: NSRange, type: NSTextLayoutManager.SegmentType) -> [CGRect] {
        guard let textRange = textRange(for: range) else { return [] }
        textLayoutManager.ensureLayout(for: textRange)
        var rects: [CGRect] = []
        textLayoutManager.enumerateTextSegments(in: textRange, type: type, options: []) { _, rect, _, _ in
            rects.append(rect)
            return true
        }
        return rects
    }

    private func caretTopDownRect(for offset: Int) -> CGRect? {
        let insertionRange = NSRange(location: clampedOffset(offset), length: 0)
        return textSegmentRects(for: insertionRange, type: .standard).first
    }

    private func updateSelectionLayers(force: Bool = false) {
        _ = force
        withoutImplicitAnimations {
            for layer in selectionLayers {
                layer.removeFromSuperlayer()
            }
            selectionLayers = []
            guard let selectionRange, selectionRange.length > 0 else { return }

            let selectionColor = resolvedCGColor(windowIsActive
                                                 ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.78)
                                                 : NSColor.unemphasizedSelectedTextBackgroundColor.withAlphaComponent(0.78))
            let contentHeight = textSelectionLayer.bounds.height
            let visibleRect = expandedTextContentRect(containing: visibleTextContentRect(), contentHeight: contentHeight)

            for rect in textSegmentRects(for: selectionRange, type: .selection) {
                guard rect.intersects(visibleRect) else { continue }
                let normalizedRect = CGRect(x: rect.minX,
                                            y: rect.minY,
                                            width: max(rect.width, 1),
                                            height: max(rect.height, 1))

                let highlight = CALayer()
                highlight.frame = CGRect(x: normalizedRect.minX,
                                         y: contentHeight - normalizedRect.maxY,
                                         width: normalizedRect.width,
                                         height: normalizedRect.height)
                highlight.backgroundColor = selectionColor
                highlight.cornerRadius = 2
                textSelectionLayer.addSublayer(highlight)
                selectionLayers.append(highlight)
            }
        }
    }

    private func cursorRect(for offset: Int) -> CGRect {
        guard let topDownRect = caretTopDownRect(for: offset) else {
            let lineHeight = ceil(textFont().ascender - textFont().descender + textFont().leading + 2)
            return CGRect(x: 0,
                          y: textSelectionLayer.bounds.height - lineHeight,
                          width: cursorWidth,
                          height: lineHeight)
        }
        return CGRect(x: topDownRect.minX,
                      y: textSelectionLayer.bounds.height - topDownRect.maxY,
                      width: cursorWidth,
                      height: max(topDownRect.height, 1))
    }

    private func updateCursor() {
        withoutImplicitAnimations {
            if filePickerNameInputController.isFocused, pendingFilePicker != nil, viewIsFocused, windowIsActive {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                pathPromptCursorLayer.isHidden = true
                stopBlinkingCaret(pathPromptCursorLayer)
                updateFindDisplay()
                updateFilePickerNameDisplay()
                sendTextInputGeometryUpdate(rect: filePickerNameCaretLayer.bounds, in: filePickerNameCaretLayer, fieldID: filePickerNameInputID)
            } else if filePickerNameInputController.isFocused {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                pathPromptCursorLayer.isHidden = true
                stopBlinkingCaret(pathPromptCursorLayer)
                updateFilePickerNameDisplay()
                outerframeHost.sendTextInputGeometryUpdate(nil)
            } else if findInputController.isFocused, viewIsFocused, windowIsActive {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                pathPromptCursorLayer.isHidden = true
                stopBlinkingCaret(pathPromptCursorLayer)
                updateFindDisplay()
                sendTextInputGeometryUpdate(rect: findCaretLayer.bounds, in: findCaretLayer, fieldID: findInputID)
            } else if findInputController.isFocused {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                pathPromptCursorLayer.isHidden = true
                stopBlinkingCaret(pathPromptCursorLayer)
                updateFindDisplay()
                outerframeHost.sendTextInputGeometryUpdate(nil)
            } else if pathPromptMode != nil, viewIsFocused, windowIsActive {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                pathPromptCursorLayer.isHidden = pathPromptSelectionRange != nil
                startBlinkingCaret(pathPromptCursorLayer)
                sendTextInputGeometryUpdate(rect: pathPromptCursorLayer.bounds, in: pathPromptCursorLayer, fieldID: editorInputID)
            } else if pathPromptMode != nil {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                stopBlinkingCaret(pathPromptCursorLayer)
                outerframeHost.sendTextInputGeometryUpdate(nil)
            } else if pendingFilePicker != nil {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                outerframeHost.sendTextInputGeometryUpdate(nil)
            } else if viewIsFocused && windowIsActive && selectionRange == nil {
                let rect = cursorRect(for: cursorOffset)
                editorCaretLayer.frame = rect
                editorCaretLayer.isHidden = false
                startBlinkingCaret(editorCaretLayer)
                sendTextInputGeometryUpdate(rect: rect, in: textContentLayer, fieldID: editorInputID)
            } else {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                outerframeHost.sendTextInputGeometryUpdate(nil)
            }
        }
    }

    private func sendTextInputGeometryUpdate(rect: CGRect, in layer: CALayer, fieldID: UUID) {
        let rootRect = layer.convert(rect, to: rootLayer)
        let topLeftRect = CGRect(x: rootRect.minX,
                                 y: rootLayer.bounds.height - rootRect.maxY,
                                 width: rootRect.width,
                                 height: rootRect.height)
        outerframeHost.sendTextInputGeometryUpdate(OuterframeContentTextInputGeometry(fieldID: fieldID,
                                                                                     rect: topLeftRect))
    }

    private func startBlinkingCaret(_ layer: CALayer) {
        layer.opacity = 1
        if layer.animation(forKey: caretBlinkAnimationKey) != nil { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.55
        animation.beginTime = CACurrentMediaTime() + 0.55
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: caretBlinkAnimationKey)
    }

    private func stopBlinkingCaret(_ layer: CALayer) {
        layer.removeAnimation(forKey: caretBlinkAnimationKey)
        layer.opacity = 1
    }

    private func ensureCursorVisible() {
        guard let rect = caretTopDownRect(for: cursorOffset) else { return }
        if !preferences.wrapLines {
            let width = max(editorClipLayer.bounds.width - textInsetX * 2, 1)
            if rect.minX < horizontalOffset { horizontalOffset = max(0, rect.minX - 4) }
            if rect.maxX > horizontalOffset + width { horizontalOffset = max(0, rect.maxX - width + 4) }
        }
        let cursorTop = rect.minY + textInsetY
        let cursorBottom = rect.maxY + textInsetY
        if cursorTop < scrollOffset + 4 {
            scrollOffset = clampedScrollOffset(max(cursorTop - 4, 0))
        } else if cursorBottom > scrollOffset + editorClipLayer.bounds.height - 4 {
            scrollOffset = clampedScrollOffset(cursorBottom - editorClipLayer.bounds.height + 4)
        }
    }

    private func lineIndex(for offset: Int, metrics: EditorVisualLineMetrics) -> Int {
        metrics.lines.firstIndex { line in
            offset >= line.range.location && offset <= line.range.location + line.range.length
        } ?? max(metrics.lines.count - 1, 0)
    }

    private func clampedOffset(_ offset: Int) -> Int {
        min(max(offset, 0), (text as NSString).length)
    }

    private func setCursorOffset(_ offset: Int, modifySelection: Bool) {
        endUndoGroup()
        clearMarkedTextState()
        let clamped = clampedOffset(offset)
        if modifySelection {
            if selectionAnchor == nil {
                selectionAnchor = cursorOffset
            }
            cursorOffset = clamped
        } else {
            cursorOffset = clamped
            selectionAnchor = nil
        }
        ensureCursorVisible()
        updateViewport()
        updateSelectionLayers()
        updateCursor()
        updateEditingCapabilities()
    }

    private var editSelection: TextEditSelection {
        TextEditSelection(caret: cursorOffset, anchor: selectionAnchor)
    }

    private var canEditDocument: Bool {
        document != nil && !isLoading && !showingServerVersion && pendingFilePicker == nil &&
            pathPromptMode == nil && !findInputController.isFocused
    }

    private func endUndoGroup() {
        document?.undoHistory.finishComposition(text: text, selection: editSelection)
        document?.undoHistory.breakCoalescing()
        document?.composing = false
        markedTextRange = nil; pendingMarkedTextReplacementRange = nil
    }

    private func performUndo(redo: Bool = false) {
        guard canEditDocument, let document else { return }
        endUndoGroup()
        clearMarkedTextState()
        guard let result = redo ? document.undoHistory.redo(text: text) : document.undoHistory.undo(text: text) else { return }
        text = result.text; cursorOffset = result.selection.caret; selectionAnchor = result.selection.anchor
        updateTextContent(force: true)
        ensureCursorVisible(); updateViewport(); updateSelectionLayers(force: true); updateCursor()
        scheduleSave(); updateEditingCapabilities()
    }

    private func replace(range: NSRange, with replacement: String, kind: TextUndoHistory.Kind = .replacement, clearsMarkedText: Bool = true) {
        guard !isLoading, !showingServerVersion, let document,
              let normalized = normalizedReplacementRange(range),
              let swiftRange = Range(normalized, in: text) else { return }
        let before = editSelection
        let removed = String(text[swiftRange])
        let composing = document.undoHistory.isComposing
        withoutImplicitAnimations {
            if clearsMarkedText {
                markedTextRange = nil
                pendingMarkedTextReplacementRange = nil
            }
            text.replaceSubrange(swiftRange, with: replacement)
            cursorOffset = normalized.location + replacement.utf16.count
            selectionAnchor = nil
            if composing {
                if clearsMarkedText { document.undoHistory.finishComposition(text: text, selection: editSelection); document.composing = false }
            } else {
                document.undoHistory.record(range: normalized, removed: removed, inserted: replacement,
                                            before: before, after: editSelection, kind: kind)
            }
            updateTextContent(force: true)
            ensureCursorVisible()
            scheduleSave(); updateEditingCapabilities()
        }
    }

    private func insertText(_ value: String, kind: TextUndoHistory.Kind = .typing) {
        if let range = markedTextRange ?? pendingMarkedTextReplacementRange {
            replace(range: range, with: value, kind: kind)
            return
        }
        if let selectionRange {
            replace(range: selectionRange, with: value, kind: kind)
            return
        }
        replace(range: NSRange(location: cursorOffset, length: 0), with: value, kind: kind)
    }

    private func setMarkedText(_ value: String,
                               selectedLocation: Int,
                               selectedLength: Int,
                               hasReplacementRange: Bool,
                               replacementLocation: Int,
                               replacementLength: Int) {
        guard !isLoading, !showingServerVersion, document != nil else { return }
        let requestedRange = hasReplacementRange
            ? NSRange(location: replacementLocation, length: replacementLength)
            : (markedTextRange ?? selectionRange ?? NSRange(location: cursorOffset, length: 0))
        guard let replacementRange = normalizedReplacementRange(requestedRange) else { return }

        document?.composing = true
        document?.undoHistory.beginComposition(text: text, selection: editSelection)
        let markedLength = (value as NSString).length
        markedTextRange = markedLength > 0 ? NSRange(location: replacementRange.location, length: markedLength) : nil
        pendingMarkedTextReplacementRange = nil
        replace(range: replacementRange, with: value, clearsMarkedText: false)

        let selectedLower = min(max(selectedLocation, 0), markedLength)
        let selectedUpper = min(max(selectedLower + selectedLength, selectedLower), markedLength)
        if selectedUpper > selectedLower {
            selectionAnchor = replacementRange.location + selectedLower
            cursorOffset = replacementRange.location + selectedUpper
        } else {
            selectionAnchor = nil
            cursorOffset = replacementRange.location + selectedLower
        }
        ensureCursorVisible()
        updateViewport()
        updateSelectionLayers(force: true)
        updateCursor()
        updateEditingCapabilities()
    }

    private func unmarkText() {
        document?.composing = false
        pendingMarkedTextReplacementRange = markedTextRange
        markedTextRange = nil
        updateTextContent(force: true)
        updateSelectionLayers(force: true)
        updateCursor()
    }

    private func clearMarkedTextState() {
        endUndoGroup()
        markedTextRange = nil
        pendingMarkedTextReplacementRange = nil
    }

    private func deleteBackward() {
        if let selectionRange {
            replace(range: selectionRange, with: "")
            return
        }
        guard cursorOffset > 0 else { return }
        let range = (text as NSString).rangeOfComposedCharacterSequence(at: cursorOffset - 1)
        replace(range: range, with: "", kind: .backwardDelete)
    }

    private func deleteForward() {
        if let selectionRange {
            replace(range: selectionRange, with: "")
            return
        }
        guard cursorOffset < (text as NSString).length else { return }
        let range = (text as NSString).rangeOfComposedCharacterSequence(at: cursorOffset)
        replace(range: range, with: "", kind: .forwardDelete)
    }

    private func performTextCommand(_ command: String) {
        if command.hasPrefix("delete"), let selectionRange {
            replace(range: selectionRange, with: "", kind: .delete)
            return
        }
        if command.hasPrefix("move") || command.hasPrefix("select") { endUndoGroup() }
        switch command {
        case "undo": performUndo()
        case "redo": performUndo(redo: true)
        case "find":
            showFind(selectCurrentSelection: true)
        case "findNext":
            findNext()
        case "findPrevious":
            findPrevious()
        case "useSelectionForFind":
            useSelectionForFind()
        case "insertNewline":
            insertText("\n")
        case "insertTab":
            endUndoGroup(); insertText("\t"); endUndoGroup()
        case "deleteBackward":
            deleteBackward()
        case "deleteForward":
            deleteForward()
        case "deleteWordBackward":
            replace(range: NSRange(location: previousWordBoundary(from: cursorOffset), length: cursorOffset - previousWordBoundary(from: cursorOffset)), with: "", kind: .delete)
        case "deleteWordForward":
            let next = nextWordBoundary(from: cursorOffset)
            replace(range: NSRange(location: cursorOffset, length: next - cursorOffset), with: "", kind: .delete)
        case "deleteToBeginningOfLine", "deleteToBeginningOfParagraph":
            let start = lineStart(for: cursorOffset)
            replace(range: NSRange(location: start, length: cursorOffset - start), with: "", kind: .delete)
        case "deleteToEndOfLine", "deleteToEndOfParagraph":
            let end = lineEnd(for: cursorOffset)
            replace(range: NSRange(location: cursorOffset, length: end - cursorOffset), with: "", kind: .delete)
        case "moveLeft":
            move(to: previousCharacterOffset(), modifySelection: false)
        case "moveRight":
            move(to: nextCharacterOffset(), modifySelection: false)
        case "moveLeftAndModifySelection":
            move(to: previousCharacterOffset(), modifySelection: true)
        case "moveRightAndModifySelection":
            move(to: nextCharacterOffset(), modifySelection: true)
        case "moveWordLeft":
            move(to: previousWordBoundary(from: cursorOffset), modifySelection: false)
        case "moveWordRight":
            move(to: nextWordBoundary(from: cursorOffset), modifySelection: false)
        case "moveWordLeftAndModifySelection":
            move(to: previousWordBoundary(from: cursorOffset), modifySelection: true)
        case "moveWordRightAndModifySelection":
            move(to: nextWordBoundary(from: cursorOffset), modifySelection: true)
        case "moveUp":
            moveVertical(delta: -1, modifySelection: false)
        case "moveDown":
            moveVertical(delta: 1, modifySelection: false)
        case "moveUpAndModifySelection":
            moveVertical(delta: -1, modifySelection: true)
        case "moveDownAndModifySelection":
            moveVertical(delta: 1, modifySelection: true)
        case "moveToBeginningOfLine", "moveToLeftEndOfLine":
            move(to: visualLineStart(for: cursorOffset), modifySelection: false)
        case "moveToEndOfLine", "moveToRightEndOfLine":
            move(to: visualLineEnd(for: cursorOffset), modifySelection: false)
        case "moveToBeginningOfLineAndModifySelection", "moveToLeftEndOfLineAndModifySelection":
            move(to: visualLineStart(for: cursorOffset), modifySelection: true)
        case "moveToEndOfLineAndModifySelection", "moveToRightEndOfLineAndModifySelection":
            move(to: visualLineEnd(for: cursorOffset), modifySelection: true)
        case "moveToBeginningOfParagraph":
            move(to: lineStart(for: cursorOffset), modifySelection: false)
        case "moveToEndOfParagraph":
            move(to: lineEnd(for: cursorOffset), modifySelection: false)
        case "moveToBeginningOfParagraphAndModifySelection":
            move(to: lineStart(for: cursorOffset), modifySelection: true)
        case "moveToEndOfParagraphAndModifySelection":
            move(to: lineEnd(for: cursorOffset), modifySelection: true)
        case "moveToBeginningOfDocument":
            move(to: 0, modifySelection: false)
        case "moveToEndOfDocument":
            move(to: (text as NSString).length, modifySelection: false)
        case "moveToBeginningOfDocumentAndModifySelection":
            move(to: 0, modifySelection: true)
        case "moveToEndOfDocumentAndModifySelection":
            move(to: (text as NSString).length, modifySelection: true)
        case "pageUp":
            scrollOffset = clampedScrollOffset(scrollOffset - editorClipLayer.bounds.height)
            updateViewport()
        case "pageDown":
            scrollOffset = clampedScrollOffset(scrollOffset + editorClipLayer.bounds.height)
            updateViewport()
        case "selectAll":
            clearMarkedTextState()
            selectionAnchor = 0
            cursorOffset = (text as NSString).length
            updateSelectionLayers(force: true)
            updateCursor()
            updateEditingCapabilities()
        case "saveDocument", "insertNewlineIgnoringFieldEditor":
            saveNow()
        default:
            break
        }
    }

    private func performFindTextCommand(_ command: String) {
        switch command {
        case "find":
            showFind(selectCurrentSelection: false)
        case "findNext":
            findNext()
        case "findPrevious":
            findPrevious()
        case "useSelectionForFind":
            useSelectionForFind()
        case "cancelOperation":
            hideFind()
        default:
            findInputController.performCommand(command)
        }
    }

    private func performFilePickerTextCommand(_ command: String) {
        switch command {
        case "insertNewline", "insertNewlineIgnoringFieldEditor":
            if filePickerNameInputController.isFocused { openFilePickerTypedPath() }
            else { activateSelectedFilePickerEntry() }
        case "cancelOperation":
            dismissFilePicker()
        default:
            if filePickerNameInputController.isFocused { filePickerNameInputController.performCommand(command) }
        }
    }

    private func previousCharacterOffset() -> Int {
        guard cursorOffset > 0 else { return 0 }
        return (text as NSString).rangeOfComposedCharacterSequence(at: cursorOffset - 1).location
    }

    private func nextCharacterOffset() -> Int {
        guard cursorOffset < text.utf16.count else { return text.utf16.count }
        return NSMaxRange((text as NSString).rangeOfComposedCharacterSequence(at: cursorOffset))
    }

    private func move(to offset: Int, modifySelection: Bool) {
        if !modifySelection, let selectionRange {
            let target = offset < cursorOffset ? selectionRange.location : selectionRange.location + selectionRange.length
            setCursorOffset(target, modifySelection: false)
            return
        }
        setCursorOffset(offset, modifySelection: modifySelection)
    }

    private func moveVertical(delta: Int, modifySelection: Bool) {
        guard let rect = caretTopDownRect(for: cursorOffset) else { return }
        let target = textOffset(atTextPoint: CGPoint(x: rect.minX, y: rect.midY + CGFloat(delta) * max(rect.height, 1)))
        setCursorOffset(target, modifySelection: modifySelection)
    }

    private func previousWordBoundary(from offset: Int) -> Int {
        let string = text as NSString
        var index = clampedOffset(offset)
        while index > 0, isWhitespace(string.character(at: index - 1)) { index -= 1 }
        while index > 0, !isWhitespace(string.character(at: index - 1)) { index -= 1 }
        return index
    }

    private func nextWordBoundary(from offset: Int) -> Int {
        let string = text as NSString
        let length = string.length
        var index = clampedOffset(offset)
        while index < length, !isWhitespace(string.character(at: index)) { index += 1 }
        while index < length, isWhitespace(string.character(at: index)) { index += 1 }
        return index
    }

    private func isWhitespace(_ character: unichar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(UnicodeScalar(character) ?? " ")
    }

    private func lineStart(for offset: Int) -> Int {
        let string = text as NSString
        return string.lineRange(for: NSRange(location: clampedOffset(offset), length: 0)).location
    }

    private func lineEnd(for offset: Int) -> Int {
        let string = text as NSString
        let range = string.lineRange(for: NSRange(location: clampedOffset(offset), length: 0))
        var end = range.location + range.length
        while end > range.location {
            let character = string.character(at: end - 1)
            if character == 10 || character == 13 {
                end -= 1
            } else {
                break
            }
        }
        return end
    }

    private func visualLineRange(for offset: Int) -> NSRange {
        let clamped = clampedOffset(offset)
        guard let caretRect = caretTopDownRect(for: clamped) else {
            return NSRange(location: lineStart(for: clamped), length: lineEnd(for: clamped) - lineStart(for: clamped))
        }

        let point = CGPoint(x: max(caretRect.midX, 0), y: max(caretRect.midY, 0))
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        guard let fragment = textLayoutManager.textLayoutFragment(for: point) else {
            return NSRange(location: lineStart(for: clamped), length: lineEnd(for: clamped) - lineStart(for: clamped))
        }

        let localY = point.y - fragment.layoutFragmentFrame.minY
        guard let line = fragment.textLineFragment(forVerticalOffset: localY, requiresExactMatch: false) else {
            let fragmentStart = utf16Offset(for: fragment.rangeInElement.location)
            let fragmentEnd = fragmentStart + textLayoutManager.offset(from: fragment.rangeInElement.location,
                                                                        to: fragment.rangeInElement.endLocation)
            return NSRange(location: clampedOffset(fragmentStart),
                           length: max(clampedOffset(fragmentEnd) - clampedOffset(fragmentStart), 0))
        }

        let fragmentStart = utf16Offset(for: fragment.rangeInElement.location)
        let start = clampedOffset(fragmentStart + line.characterRange.location)
        let paragraphEnd = lineEnd(for: clamped)
        let end = min(clampedOffset(fragmentStart + line.characterRange.location + line.characterRange.length),
                      paragraphEnd)
        return NSRange(location: start, length: max(end - start, 0))
    }

    private func visualLineStart(for offset: Int) -> Int {
        visualLineRange(for: offset).location
    }

    private func visualLineEnd(for offset: Int) -> Int {
        let range = visualLineRange(for: offset)
        return range.location + range.length
    }

    private func handleMouseDown(point: CGPoint, modifierFlags: NSEvent.ModifierFlags, clickCount: Int) {
        let rootPoint = rootLayer.convert(point, to: rootLayer)
        let headerPoint = headerLayer.convert(rootPoint, from: rootLayer)
        if isFindVisible, findBarFrame.contains(headerPoint) {
            if handleFindBarButtonClick(atHeaderPoint: headerPoint) {
                return
            }
            if findFieldFrame.contains(findBarPoint(fromHeaderPoint: headerPoint)) {
                focusFindField(atHeaderPoint: headerPoint, clickCount: clickCount, modifySelection: modifierFlags.contains(.shift))
            }
            return
        }
        findInputController.blur()
        if openControlFrame.contains(headerPoint) { showHomePopover(); return }
        if containerControlFrame.contains(headerPoint), document?.draft.target != "host" { showContainerPicker(); return }
        if menuControlFrame.contains(headerPoint) { showPathMenu(at: point); return }
        if saveControlFrame.contains(headerPoint), document?.draft.dirty == true || document?.draft.pending != nil { saveNow(); return }
        if pathControlFrame.contains(headerPoint) {
            if pathPromptMode != nil {
                setPathPromptCursor(atToolbarX: headerPoint.x)
            } else {
                showMoveRenamePrompt()
            }
            return
        }
        if scrollbarController?.handleMouseDown(at: rootLayer.convert(point, to: editorClipLayer)) == true {
            return
        }
        guard isPointInEditor(point) else { return }
        let offset = textOffset(atRootPoint: point)
        dragAnchorOffset = offset
        if clickCount == 2 {
            clearMarkedTextState()
            selectWord(at: offset)
        } else if clickCount >= 3 {
            clearMarkedTextState()
            selectLine(at: offset)
        } else {
            setCursorOffset(offset, modifySelection: modifierFlags.contains(.shift))
        }
    }

    private func handleMouseDragged(point: CGPoint) {
        if scrollbarController?.handleMouseDragged(to: rootLayer.convert(point, to: editorClipLayer)) == true {
            return
        }
        guard let dragAnchorOffset else { return }
        let offset = textOffset(atRootPoint: point)
        clearMarkedTextState()
        selectionAnchor = dragAnchorOffset
        cursorOffset = clampedOffset(offset)
        ensureCursorVisible()
        updateViewport()
        updateSelectionLayers()
        updateCursor()
        updateEditingCapabilities()
    }

    private func handleRightMouseDown(point: CGPoint, clickCount: Int) {
        let rootPoint = rootLayer.convert(point, to: rootLayer)
        let headerPoint = headerLayer.convert(rootPoint, from: rootLayer)
        if isFindVisible, findBarFrame.contains(headerPoint) {
            if findFieldFrame.contains(findBarPoint(fromHeaderPoint: headerPoint)) {
                focusFindField(atHeaderPoint: headerPoint, clickCount: clickCount, modifySelection: false)
                showFindContextMenu(at: point)
            }
            return
        }
        if pathControlFrame.contains(headerPoint) {
            if pathPromptMode == nil {
                showPathMenu(at: point)
            }
            return
        }
        guard isPointInEditor(point) else { return }
        let offset = textOffset(atRootPoint: point)
        if let selectionRange,
           NSLocationInRange(offset, selectionRange) {
            showEditorContextMenu(at: point)
            return
        }
        if clickCount >= 2 {
            selectWord(at: offset)
        } else {
            setCursorOffset(offset, modifySelection: false)
        }
        showEditorContextMenu(at: point)
    }

    private func focusFindField(atHeaderPoint headerPoint: CGPoint, clickCount: Int, modifySelection: Bool) {
        let localX = headerPoint.x - findBarFrame.minX - findTextFrame().minX
        let position = findCharacterIndex(atX: localX)
        findInputController.focus(selectAll: false)
        if clickCount >= 2 {
            findInputController.selectWord(at: position)
        } else {
            findInputController.setCursorPosition(position, modifySelection: modifySelection)
        }
        updateCursor()
    }

    private func findBarPoint(fromHeaderPoint headerPoint: CGPoint) -> CGPoint {
        CGPoint(x: headerPoint.x - findBarFrame.minX,
                y: headerPoint.y - findBarFrame.minY)
    }

    private func handleFindBarButtonClick(atHeaderPoint headerPoint: CGPoint) -> Bool {
        let point = findBarPoint(fromHeaderPoint: headerPoint)
        if findPreviousButtonFrame.contains(point) {
            findPrevious()
            return true
        }
        if findNextButtonFrame.contains(point) {
            findNext()
            return true
        }
        if findDoneButtonFrame.contains(point) {
            hideFind()
            return true
        }
        return false
    }

    private func findCharacterIndex(atX x: CGFloat) -> Int {
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        var bestIndex = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for index in 0...findInputController.text.count {
            let distance = abs(findTextX(for: index, font: font, textFrame: findTextFrame()) - max(x, 0))
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
            }
        }
        return bestIndex
    }

    private func showEditorContextMenu(at point: CGPoint) {
        endUndoGroup()
        let hasSelection = selectionRange?.length ?? 0 > 0
        let selectedText = selectedString() ?? ""
        var items: [OuterframeContextMenuItem] = [
            OuterframeContextMenuItem(id: "undo", title: "Undo" + (document?.undoHistory.undoName.map { " " + $0 } ?? ""),
                                      isEnabled: canEditDocument && document?.undoHistory.canUndo == true),
            OuterframeContextMenuItem(id: "redo", title: "Redo" + (document?.undoHistory.redoName.map { " " + $0 } ?? ""),
                                      isEnabled: canEditDocument && document?.undoHistory.canRedo == true),
            OuterframeContextMenuItem(id: "history-separator", title: "", kind: .separator, isEnabled: false)
        ]
        if !selectedText.isEmpty {
            let displayText = selectedText.count > 80 ? String(selectedText.prefix(80)) + "..." : selectedText
            let lookupTitle = "Look Up \"\(displayText)\""
            items.append(OuterframeContextMenuItem(id: "lookup",
                                                   title: lookupTitle,
                                                   action: .standardLookUp))
            items.append(OuterframeContextMenuItem(id: "lookup-separator",
                                                   title: "",
                                                   kind: .separator,
                                                   isEnabled: false))
        }
        items.append(OuterframeContextMenuItem(id: "cut",
                                               title: "Cut",
                                               action: .standardCut,
                                               isEnabled: hasSelection))
        items.append(OuterframeContextMenuItem(id: "copy",
                                               title: "Copy",
                                               action: .standardCopy,
                                               isEnabled: hasSelection))
        items.append(OuterframeContextMenuItem(id: "paste",
                                               title: "Paste",
                                               action: .standardPaste))
        if !selectedText.isEmpty {
            items.append(OuterframeContextMenuItem(id: "services-separator",
                                                   title: "",
                                                   kind: .separator,
                                                   isEnabled: false))
            items.append(OuterframeContextMenuItem(id: "services",
                                                   title: "Services",
                                                   action: .standardServices))
        }
        outerframeHost.showContextMenu(menuID: UUID(),
                                       items: items,
                                       at: point,
                                       attributedText: attributedSelection())
    }

    private func showFindContextMenu(at point: CGPoint) {
        let menuID = UUID()
        pendingFindMenuIDs.insert(menuID)
        let hasSelection = findInputController.hasSelection
        let items = [
            OuterframeContextMenuItem(id: "find-cut",
                                      title: "Cut",
                                      action: .standardCut,
                                      isEnabled: hasSelection),
            OuterframeContextMenuItem(id: "find-copy",
                                      title: "Copy",
                                      action: .standardCopy,
                                      isEnabled: hasSelection),
            OuterframeContextMenuItem(id: "find-paste",
                                      title: "Paste",
                                      action: .standardPaste)
        ]
        outerframeHost.showContextMenu(menuID: menuID, items: items, at: point)
    }

    private func showFilePickerNameContextMenu(at point: CGPoint) {
        let menuID = UUID()
        pendingFilePickerNameMenuIDs.insert(menuID)
        let hasSelection = filePickerNameInputController.hasSelection
        let items = [
            OuterframeContextMenuItem(id: "file-picker-name-cut",
                                      title: "Cut",
                                      action: .standardCut,
                                      isEnabled: hasSelection),
            OuterframeContextMenuItem(id: "file-picker-name-copy",
                                      title: "Copy",
                                      action: .standardCopy,
                                      isEnabled: hasSelection),
            OuterframeContextMenuItem(id: "file-picker-name-paste",
                                      title: "Paste",
                                      action: .standardPaste)
        ]
        outerframeHost.showContextMenu(menuID: menuID, items: items, at: point)
    }

    private func selectWord(at offset: Int) {
        let start = previousWordBoundary(from: offset)
        var end = nextWordBoundary(from: offset)
        if start == end {
            end = min(start + 1, (text as NSString).length)
        }
        selectionAnchor = start
        cursorOffset = end
        updateSelectionLayers(force: true)
        updateCursor()
        updateEditingCapabilities()
    }

    private func selectLine(at offset: Int) {
        let string = text as NSString
        let range = string.lineRange(for: NSRange(location: clampedOffset(offset), length: 0))
        selectionAnchor = range.location
        cursorOffset = min(range.location + range.length, string.length)
        updateSelectionLayers(force: true)
        updateCursor()
        updateEditingCapabilities()
    }

    private func isPointInEditor(_ point: CGPoint) -> Bool {
        editorClipLayer.frame.contains(rootLayer.convert(point, to: rootLayer))
    }

    private func textOffset(atRootPoint point: CGPoint) -> Int {
        let local = editorClipLayer.convert(rootLayer.convert(point, to: rootLayer), from: rootLayer)
        let topDown = CGPoint(x: local.x - textInsetX,
                              y: editorClipLayer.bounds.height - local.y + scrollOffset - textInsetY)
        return textOffset(atTextPoint: topDown)
    }

    private func textOffset(atTextPoint textPoint: CGPoint) -> Int {
        let point = CGPoint(x: max(textPoint.x, 0), y: max(textPoint.y, 0))
        textLayoutManager.ensureLayout(for: textLayoutManager.documentRange)
        guard let fragment = textLayoutManager.textLayoutFragment(for: point) else {
            return point.y <= 0 ? 0 : (text as NSString).length
        }
        let fragmentFrame = fragment.layoutFragmentFrame
        let localY = point.y - fragmentFrame.minY
        guard let line = fragment.textLineFragment(forVerticalOffset: localY, requiresExactMatch: false) else {
            return utf16Offset(for: fragment.rangeInElement.location)
        }

        let fragmentStart = utf16Offset(for: fragment.rangeInElement.location)
        let linePoint = CGPoint(x: point.x - fragmentFrame.minX - line.typographicBounds.minX,
                                y: localY - line.typographicBounds.minY)
        let localIndex = line.characterIndex(for: linePoint)
        let lineLower = line.characterRange.location
        let lineUpper = line.characterRange.location + line.characterRange.length
        let clampedLocalIndex = min(max(localIndex, lineLower), lineUpper)
        return clampedOffset(fragmentStart + clampedLocalIndex)
    }

    private func updateCursorShape(at point: CGPoint) {
        if pendingFilePicker != nil {
            let rootPoint = rootLayer.convert(point, to: rootLayer)
            outerframeHost.setCursor(filePickerNameFieldFrame.contains(rootPoint) ? .iBeam : .arrow)
            return
        }
        let rootPoint = rootLayer.convert(point, to: rootLayer)
        let headerPoint = headerLayer.convert(rootPoint, from: rootLayer)
        if isFindVisible, findBarFrame.contains(headerPoint) {
            let findPoint = findBarPoint(fromHeaderPoint: headerPoint)
            outerframeHost.setCursor(findFieldFrame.contains(findPoint) ? .iBeam : .arrow)
        } else if pathControlFrame.contains(headerPoint) {
            outerframeHost.setCursor(pathPromptMode == nil ? .pointingHand : .iBeam)
        } else {
            outerframeHost.setCursor(isPointInEditor(point) ? .iBeam : .arrow)
        }
    }

    private func selectedString() -> String? {
        guard let selectionRange,
              let range = Range(selectionRange, in: text) else { return nil }
        return String(text[range])
    }

    private func attributedSelection() -> NSAttributedString? {
        guard let selectionRange,
              selectionRange.location + selectionRange.length <= attributedText.length else {
            return nil
        }
        return attributedText.attributedSubstring(from: selectionRange)
    }

    private func pasteboardItemsForCopy() -> [OuterframeContentPasteboardItem] {
        if pathPromptMode != nil {
            return pasteboardItems(for: pathPromptSelectionRange.map { (pathPromptText as NSString).substring(with: $0) })
        }
        if filePickerNameInputController.isFocused {
            return pasteboardItems(for: filePickerNameInputController.selectedTextContent())
        }
        if findInputController.isFocused {
            return pasteboardItems(for: findInputController.selectedTextContent())
        }
        guard let selected = selectedString(), !selected.isEmpty else { return [] }
        return pasteboardItems(for: selected)
    }

    private func pasteboardItems(for text: String?) -> [OuterframeContentPasteboardItem] {
        guard let text, !text.isEmpty else { return [] }
        return [OuterframeContentPasteboardItem(representations: [
            OuterframeContentPasteboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                                      data: Data(text.utf8))
        ])]
    }

    private func pasteboardItemsForCut() -> [OuterframeContentPasteboardItem] {
        if pathPromptMode != nil {
            let items = pasteboardItemsForCopy()
            if let selection = pathPromptSelectionRange { replacePathPromptText(range: selection, with: "") }
            return items
        }
        if filePickerNameInputController.isFocused {
            return pasteboardItems(for: filePickerNameInputController.cutSelectedTextContent())
        }
        if findInputController.isFocused {
            return pasteboardItems(for: findInputController.cutSelectedTextContent())
        }
        let items = pasteboardItemsForCopy()
        if selectionRange != nil {
            endUndoGroup(); insertText("", kind: .cut); endUndoGroup()
        }
        return items
    }

    private func paste(_ items: [OuterframeContentPasteboardItem]) {
        for item in items {
            if let representation = item.representations.first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue }),
               let string = String(data: representation.data, encoding: .utf8) {
                if filePickerNameInputController.isFocused {
                    filePickerNameInputController.pasteText(string)
                    return
                }
                if findInputController.isFocused {
                    findInputController.pasteText(string)
                    return
                }
                guard pendingFilePicker == nil else { return }
                endUndoGroup(); insertText(string, kind: .paste); endUndoGroup()
                return
            }
        }
    }

    private func updateEditingCapabilities() {
        notifyAccessibilityLayoutChanged()
    }

    private func enabledEditCommands(in requestedCommands: OuterframeEditCommandSet) -> OuterframeEditCommandSet {
        if pathPromptMode != nil {
            var commands: OuterframeEditCommandSet = [.paste]
            if !pathPromptText.isEmpty { commands.insert(.selectAll) }
            if pathPromptSelectionRange != nil { commands.formUnion([.copy, .cut]) }
            return commands.intersection(requestedCommands)
        }
        if filePickerNameInputController.isFocused {
            return filePickerNameInputController.enabledEditCommands(in: requestedCommands)
        }
        if findInputController.isFocused {
            var commands = findInputController.enabledEditCommands(in: requestedCommands)
            if requestedCommands.contains(.find) {
                commands.insert(.find)
            }
            if requestedCommands.contains(.findNext), !findInputController.text.isEmpty {
                commands.insert(.findNext)
            }
            if requestedCommands.contains(.findPrevious), !findInputController.text.isEmpty {
                commands.insert(.findPrevious)
            }
            return commands
        }

        var enabledCommands: OuterframeEditCommandSet = []
        let hasSelection = selectionRange?.length ?? 0 > 0
        if hasSelection {
            if requestedCommands.contains(.copy) {
                enabledCommands.insert(.copy)
            }
            if requestedCommands.contains(.cut) {
                enabledCommands.insert(.cut)
            }
        }
        if requestedCommands.contains(.paste) {
            enabledCommands.insert(.paste)
        }
        if requestedCommands.contains(.selectAll), !text.isEmpty {
            enabledCommands.insert(.selectAll)
        }
        if requestedCommands.contains(.find) {
            enabledCommands.insert(.find)
        }
        if requestedCommands.contains(.findNext), !findInputController.text.isEmpty {
            enabledCommands.insert(.findNext)
        }
        if requestedCommands.contains(.findPrevious), !findInputController.text.isEmpty {
            enabledCommands.insert(.findPrevious)
        }
        if canEditDocument {
            if document?.undoHistory.canUndo == true || document?.undoHistory.isComposing == true { enabledCommands.insert(.undo) }
            if document?.undoHistory.canRedo == true && document?.undoHistory.isComposing == false { enabledCommands.insert(.redo) }
        } else { enabledCommands.subtract([.cut, .paste]) }
        return enabledCommands.intersection(requestedCommands)
    }

    private func handleContextMenuItem(menuID: UUID, itemID: String) {
        if targetMenuIDs.remove(menuID) != nil {
            pickerTarget = itemID; fetchFilePickerDirectory(path: "~"); return
        }
        if pendingFilePickerNameMenuIDs.remove(menuID) != nil {
            return
        }
        if pendingFindMenuIDs.remove(menuID) != nil {
            return
        }
        if pendingPathMenuIDs.remove(menuID) != nil {
            if itemID.hasPrefix("recover:") { openDocument(path: "", draftID: String(itemID.dropFirst(8))); return }
            switch itemID {
            case "text-smaller": setTextScale(preferences.textScale - 0.1)
            case "text-larger": setTextScale(preferences.textScale + 0.1)
            case "text-reset": setTextScale(1)
            case "text-wrap": preferences.wrapLines.toggle(); horizontalOffset = 0; savePreferences(); updateTextContent(force: true); layout()
            case "path-new": openDocument(path: "", new: true)
            case "path-export": exportDraft()
            case "path-copy-text":
                if let document { outerframeHost.requestPasteboardWrite(items: pasteboardItems(for: document.draft.contents)) }
            case "path-save-copy": pickerMode = "copy"; showOpenFilePicker()
            case "path-review": reviewServerVersion()
            case "path-discard":
                if let document, let reviewedDisk { Task { do { try await document.discardReviewedFile(reviewedDisk, draftRevision: reviewedShared?.draftRevision ?? "missing"); returnToDraft() } catch { statusText = error.localizedDescription; layout() } } }
            case "path-return": returnToDraft()
            case "path-replace":
                let confirmation = UUID(); pendingPathMenuIDs.insert(confirmation)
                outerframeHost.showContextMenu(menuID: confirmation, items: [
                    OuterframeContextMenuItem(id: "path-confirm-replace", title: "Replace Server File with My Draft"),
                    OuterframeContextMenuItem(id: "path-cancel", title: "Cancel")
                ], at: CGPoint(x: pathLayer.frame.minX, y: pathLayer.frame.maxY))
            case "path-confirm-replace":
                if let document, let reviewedDisk {
                    returnToDraft()
                    Task { await document.replaceReviewedFile(revision: reviewedDisk.revision, draftRevision: reviewedShared?.draftRevision ?? "missing") }
                }
            case "path-save":
                saveNow()
            case "path-open":
                showOpenPrompt()
            case "path-move-rename":
                showMoveRenamePrompt()
            case "path-copy":
                copyCurrentPath()
            default:
                break
            }
            return
        }
        switch itemID {
        case "undo": performUndo()
        case "redo": performUndo(redo: true)
        case "save":
            saveNow()
        default:
            break
        }
    }

    private func handleKeyDown(characters: String, charactersIgnoringModifiers: String, modifierFlags: NSEvent.ModifierFlags) {
        let normalized = (charactersIgnoringModifiers.isEmpty ? characters : charactersIgnoringModifiers).lowercased()
        if modifierFlags.contains(.command), normalized == "o" {
            showOpenPrompt()
        } else if modifierFlags.contains(.command), normalized == "f" {
            showFind(selectCurrentSelection: true)
        } else if modifierFlags.contains(.command), normalized == "g" {
            if modifierFlags.contains(.shift) {
                findPrevious()
            } else {
                findNext()
            }
        } else if modifierFlags.contains(.command), normalized == "e" {
            useSelectionForFind()
        } else if modifierFlags.contains(.command), normalized == "s" {
            saveNow()
        } else if findInputController.isFocused, normalized == "\u{1b}" {
            hideFind()
        } else if pathPromptMode != nil, normalized == "\u{1b}" {
            cancelPathPrompt()

        }
    }

    private func pasteFilePickerName(_ items: [OuterframeContentPasteboardItem]) {
        guard filePickerNameInputController.isFocused else { return }
        for item in items {
            if let representation = item.representations.first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue }),
               let string = String(data: representation.data, encoding: .utf8) {
                filePickerNameInputController.pasteText(string)
                return
            }
        }
    }

    private lazy var accessibilityTextLayout = PlaintextAccessibilityTextLayout(layoutManager: textLayoutManager)

    private func accessibilityTextQuery(identifier: UInt32, query: OuterframeAccessibilityTextQuery, range: NSRange, point: CGPoint) -> OuterframeAccessibilityTextResult? {
        if let key = ["find", "filename", "path-prompt"].first(where: { accessibilityIDs[$0] == identifier }),
           let value = accessibilityNodes[identifier]?.value {
            let layer = key == "find" ? findTextLayer : key == "filename" ? filePickerNameTextLayer : pathLayer
            let font = NSFont.systemFont(ofSize: 13, weight: .regular)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: [.font: font]))
            return accessibilitySingleLineQuery(query, range: range, point: point, text: value, line: line,
                frame: rootLayer.convert(layer.bounds, from: layer))
        }
        guard identifier == accessibilityIDs["editor"], pendingFilePicker == nil, !isLoading else { return nil }
        return accessibilityTextLayout.query(query, range: range, point: point, text: text, generation: generation,
            viewport: editorClipLayer.frame, scrollOffset: scrollOffset, inset: CGSize(width: textInsetX, height: textInsetY))
    }

    private var accessibilityIDs: [String: UInt32] = [:]
    private var accessibilityNodes: [UInt32: OuterframeAccessibilityNode] = [:]
    private var accessibilityHandlers: [UInt32: (PlaintextHandler, OuterframeAccessibilityAction, String) -> Void] = [:]

    private func axNode(_ key: String, _ role: OuterframeAccessibilityRole, _ frame: CGRect, _ label: String,
                        value: String? = nil, children: [OuterframeAccessibilityNode] = [],
                        actions: OuterframeAccessibilityActions = [], enabled: Bool = true, focused: Bool = false,
                        selected: Bool = false, rowIndex: Int? = nil, rowCount: Int? = nil, selection: NSRange? = nil,
                        handler: ((PlaintextHandler, OuterframeAccessibilityAction, String) -> Void)? = nil) -> OuterframeAccessibilityNode {
        let id = accessibilityIDs[key] ?? UInt32(accessibilityIDs.count + 1)
        accessibilityIDs[key] = id
        var actions = actions
        var selection = selection
        let isField = ["find", "filename", "path-prompt"].contains(key)
        if isField {
            actions.insert(.setSelectedTextRange)
            if key == "path-prompt" { selection = pathPromptSelectionRange ?? NSRange(location: pathPromptCursorOffset, length: 0) }
            else {
                let controller = key == "find" ? findInputController : filePickerNameInputController
                let selected = controller.selectionRange ?? controller.cursorPosition..<controller.cursorPosition
                let lower = controller.text.index(controller.text.startIndex, offsetBy: selected.lowerBound)
                let upper = controller.text.index(controller.text.startIndex, offsetBy: selected.upperBound)
                selection = NSRange(lower..<upper, in: controller.text)
            }
        }
        let node = OuterframeAccessibilityNode(identifier: id, role: role, frame: frame, label: label, value: value,
            children: children, rowCount: rowCount, isEnabled: enabled, actions: actions, isFocused: focused,
            isSelected: selected, rowIndex: rowIndex, selectedTextRange: selection, supportsTextGeometry: key == "editor" || isField, supportsActionSnapshot: true)
        accessibilityNodes[id] = node
        accessibilityHandlers[id] = handler
        return node
    }

    private func performAccessibilityAction(_ id: UInt32, action: OuterframeAccessibilityAction, value: String) {
        _ = buildAccessibilitySnapshot()
        guard let node = accessibilityNodes[id], node.isEnabled, node.actions.supports(action) else { return }
        if action == .setSelectedTextRange, let key = ["find", "filename", "path-prompt"].first(where: { accessibilityIDs[$0] == id }), let text = node.value {
            let parts = value.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let location = Int(parts[0]), let length = Int(parts[1]),
                  OuterframeAccessibilityTextRange.isValid(NSRange(location: location, length: length), in: text),
                  let selected = Range(NSRange(location: location, length: length), in: text),
                  (text.indices.contains(selected.lowerBound) || selected.lowerBound == text.endIndex),
                  (text.indices.contains(selected.upperBound) || selected.upperBound == text.endIndex) else { return }
            if key == "path-prompt" {
                pathPromptSelectionRange = length > 0 ? NSRange(location: location, length: length) : nil
                pathPromptCursorOffset = location + length
                layout()
            } else {
                let controller = key == "find" ? findInputController : filePickerNameInputController
                controller.focus()
                controller.setCursorPosition(text.distance(from: text.startIndex, to: selected.lowerBound), modifySelection: false)
                controller.setCursorPosition(text.distance(from: text.startIndex, to: selected.upperBound), modifySelection: true)
            }
        } else { accessibilityHandlers[id]?(self, action, value) }
        notifyAccessibilityLayoutChanged()
    }

    private func focusAccessibleEditor() {
        findInputController.blur()
        filePickerNameInputController.blur()
        if pathPromptMode != nil { cancelPathPrompt() }
        updateCursor()
        updateEditingCapabilities()
    }

    private func buildAccessibilitySnapshot() -> OuterframeAccessibilitySnapshot {
        accessibilityNodes.removeAll(keepingCapacity: true)
        accessibilityHandlers.removeAll(keepingCapacity: true)
        var children: [OuterframeAccessibilityNode] = []
        if let picker = pendingFilePicker {
            if pickerMode == "conflict" {
                for (frame, action) in conflictFrames { children.append(axNode("conflict-" + action, .button, frame, action == "discard" ? "Discard drafts and use saved file" : action == "replace" ? "Replace server file with my draft" : action == "copy" ? "Save a copy" : "Keep my draft", actions: [.press]) { owner, _, _ in owner.resolveReview(action) }) }
                for (index, item) in [("Your draft", document?.draft.contents ?? ""), ("Saved file", reviewedDisk?.contents ?? ""), ("Shared draft", reviewedShared?.contents ?? "")].enumerated() { children.append(axNode("comparison-\(index)", .staticText, filePickerPanelFrame, item.0, value: item.1)) }
                return OuterframeAccessibilitySnapshot(rootNodes: [axNode("conflict", .dialog, filePickerPanelFrame, "Review changes", children: children)])
            }
            if ["recent", "open"].contains(pickerMode) {
                children.append(axNode("recent-tab", .button, recentTabFrame, "Recent", actions: [.press]) { owner, _, _ in owner.pickerMode = "recent"; owner.filePickerScroll = 0; owner.renderFilePicker() })
                children.append(axNode("open-tab", .button, openTabFrame, "Open", actions: [.press]) { owner, _, _ in owner.pickerMode = "open"; owner.fetchFilePickerDirectory(path: owner.pendingFilePicker?.directory ?? "~") })
                children.append(axNode("new-file", .button, newFileFrame, "New text file", actions: [.press]) { owner, _, _ in owner.dismissFilePicker(); owner.shouldPushHistory = true; owner.openDocument(path: "", new: true, target: owner.pickerTarget) })
            }
            if pickerMode == "recent" {
                for (frame, remove, recent) in recentFrames {
                    children.append(axNode("recent:" + recent.target + recent.path, .button, frame, (recent.path as NSString).lastPathComponent, value: recent.path, actions: [.press]) { owner, _, _ in owner.dismissFilePicker(); owner.shouldPushHistory = true; owner.openDocument(path: recent.path, target: recent.target) })
                    children.append(axNode("remove:" + recent.target + recent.path, .button, remove, "Remove " + (recent.path as NSString).lastPathComponent + " from recents", actions: [.press]) { owner, _, _ in owner.preferences.recent.removeAll { $0.path == recent.path && $0.target == recent.target }; owner.savePreferences(); owner.renderFilePicker() })
                }
                return OuterframeAccessibilitySnapshot(rootNodes: [axNode("recents", .dialog, filePickerPanelFrame, "Open files", children: children)])
            }
            if ["open", "save", "copy"].contains(pickerMode) { children.append(axNode("target", .button, targetControlFrame, "Host or container", value: pickerTarget, actions: [.press]) { owner, _, _ in owner.showTargetMenu(at: owner.targetControlFrame.origin) }) }
            for segment in filePickerBreadcrumbSegmentFrames {
                let frame = filePickerBreadcrumbLayer.convert(segment.frame, to: rootLayer)
                children.append(axNode("directory:\(segment.path)", .button, frame, segment.path, actions: [.press]) { owner, _, _ in
                    owner.fetchFilePickerDirectory(path: segment.path)
                })
            }
            let rows = filePickerEntryFrames.filter { $0.frame.intersects(filePickerListFrame) }.map { item in
                axNode("file:\(picker.directory)/\(item.entry.name)", .row, item.frame.intersection(filePickerListFrame), item.entry.name,
                       value: item.entry.isDirectory ? "Folder" : "File", actions: [.press, .focus],
                       selected: filePickerSelectedIndex == item.index, rowIndex: item.index) { owner, action, _ in
                    if action == .press { owner.activateFilePickerEntry(item.entry) }
                    else { owner.selectFilePickerIndex(item.index) }
                }
            }
            children.append(axNode("file-list", .table, filePickerListFrame, "Files", children: rows,
                                   actions: [.scrollUp, .scrollDown], rowCount: picker.entries.count) { owner, action, _ in
                owner.setFilePickerScroll(owner.filePickerScroll + (action == .scrollUp ? -1 : 1) * owner.filePickerListFrame.height * 0.8)
            })
            if picker.isLoading || !picker.error.isEmpty {
                children.append(axNode("picker-status", .staticText, filePickerListFrame, picker.isLoading ? "Loading files" : picker.error))
            }
            if pickerMode != "open" { children.append(axNode("filename", .textField, filePickerNameFieldFrame, "File name", value: filePickerNameInputController.text,
                                   actions: [.focus, .setValue], focused: filePickerNameInputController.isFocused) { owner, action, value in
                owner.filePickerNameInputController.focus()
                if action == .setValue { owner.filePickerNameInputController.setText(value) }
            })
            }
            children.append(axNode("open", .button, filePickerOpenFrame, pickerMode == "move" ? "Move" : pickerMode == "open" ? "Open file" : "Save", actions: [.press], enabled: !picker.isLoading && picker.error.isEmpty) { owner, _, _ in owner.openFilePickerTypedPath() })
            return OuterframeAccessibilitySnapshot(rootNodes: [axNode("picker", .dialog, filePickerPanelFrame, pickerMode == "move" ? "Move or rename file" : pickerMode == "save" ? "Save text file" : pickerMode == "copy" ? "Save a copy" : "Open files", children: children)])
        }
        if let mode = pathPromptMode {
            children.append(axNode("path-prompt", .textField, headerLayer.convert(pathControlFrame, to: rootLayer), "\(mode.label) path",
                                   value: pathPromptText, actions: [.focus, .setValue], focused: true) { owner, action, value in
                if action == .setValue {
                    owner.pathPromptText = value
                    owner.pathPromptSelectionRange = nil
                    owner.pathPromptCursorOffset = value.utf16.count
                    owner.renderHeader()
                    owner.updateCursor()
                }
            })
        } else {
            children.append(axNode("file-actions", .button, headerLayer.convert(pathControlFrame, to: rootLayer), "Move or rename file",
                                   value: documentDisplayName(), actions: [.press, .showMenu]) { owner, _, _ in
                let frame = owner.headerLayer.convert(owner.pathControlFrame, to: owner.rootLayer)
                _ = frame; owner.showMoveRenamePrompt()
            })
        }
        if document?.draft.target != "host", containerControlFrame.width > 0 {
            children.append(axNode("container", .button, headerLayer.convert(containerControlFrame, to: rootLayer), "Choose host or container", value: targets.first { $0.id == document?.draft.target }?.name, actions: [.press]) { owner, _, _ in owner.showContainerPicker() })
        }
        children.append(axNode("open-files", .button, headerLayer.convert(openControlFrame, to: rootLayer), "Open files", actions: [.press]) { owner, _, _ in owner.showHomePopover() })
        children.append(axNode("document-actions", .button, headerLayer.convert(menuControlFrame, to: rootLayer), "Document actions", actions: [.press, .showMenu]) { owner, _, _ in owner.showPathMenu(at: owner.headerLayer.convert(owner.menuControlFrame.origin, to: owner.rootLayer)) })
        if document?.draft.dirty == true || document?.draft.pending != nil { children.append(axNode("save-file", .button, headerLayer.convert(saveControlFrame, to: rootLayer), isSaving ? "Saving" : "Save", actions: [.press]) { owner, _, _ in owner.saveNow() }) }
        if let status = statusLayer.string as? String, !status.isEmpty {
            children.append(axNode("status", .staticText, headerLayer.convert(statusLayer.frame, to: rootLayer), "Status", value: status))
        }
        if isFindVisible {
            children.append(axNode("find", .textField, findFieldLayer.convert(findFieldLayer.bounds, to: rootLayer), "Find", value: findInputController.text,
                                   actions: [.focus, .setValue], focused: findInputController.isFocused) { owner, action, value in
                owner.findInputController.focus()
                if action == .setValue { owner.findInputController.setText(value) }
            })
            children.append(axNode("find-previous", .button, findPreviousButtonLayer.convert(findPreviousButtonLayer.bounds, to: rootLayer), "Previous match",
                                   actions: [.press], enabled: !findMatches.isEmpty) { owner, _, _ in owner.findPrevious() })
            children.append(axNode("find-next", .button, findNextButtonLayer.convert(findNextButtonLayer.bounds, to: rootLayer), "Next match",
                                   actions: [.press], enabled: !findMatches.isEmpty) { owner, _, _ in owner.findNext() })
            children.append(axNode("find-count", .staticText, findStatusLayer.convert(findStatusLayer.bounds, to: rootLayer), "Matches", value: findStatusLayer.string as? String))
            children.append(axNode("find-done", .button, findDoneButtonLayer.convert(findDoneButtonLayer.bounds, to: rootLayer), "Done", actions: [.press]) { owner, _, _ in owner.hideFind() })
        }
        var editorActions: OuterframeAccessibilityActions = [.focus, .setSelectedTextRange, .showMenu, .scrollUp, .scrollDown]
        if !showingServerVersion { editorActions.insert(.setValue) }
        children.append(axNode("editor", .textArea, editorClipLayer.frame, filePath.isEmpty ? "Text editor" : "Text editor, \(filePath)", value: text,
                               actions: editorActions, enabled: !isLoading,
                               focused: viewIsFocused && !findInputController.isFocused && pathPromptMode == nil,
                               selection: selectionRange ?? NSRange(location: cursorOffset, length: 0)) { owner, action, value in
            switch action {
            case .focus: owner.focusAccessibleEditor()
            case .setValue:
                owner.focusAccessibleEditor()
                owner.replace(range: NSRange(location: 0, length: (owner.text as NSString).length), with: value)
            case .setSelectedTextRange:
                let parts = value.split(separator: ":", omittingEmptySubsequences: false)
                guard parts.count == 2, let location = Int(parts[0]), let length = Int(parts[1]), location >= 0, length >= 0,
                      location <= owner.text.utf16.count, length <= owner.text.utf16.count - location,
                      OuterframeAccessibilityTextRange.isValid(NSRange(location: location, length: length), in: owner.text) else { return }
                owner.focusAccessibleEditor()
                owner.setCursorOffset(location, modifySelection: false)
                owner.setCursorOffset(location + length, modifySelection: true)
            case .showMenu:
                owner.showEditorContextMenu(at: CGPoint(x: owner.editorClipLayer.frame.midX, y: owner.editorClipLayer.frame.midY))
            case .scrollUp, .scrollDown:
                owner.scrollbarDidChangeScrollOffset(owner.scrollOffset + (action == .scrollUp ? -1 : 1) * owner.editorClipLayer.bounds.height * 0.8)
            default: break
            }
        })
        return OuterframeAccessibilitySnapshot(rootNodes: [axNode("root", .container, rootLayer.bounds, "Plaintext", children: children)])
    }

    private func notifyAccessibilityLayoutChanged() {
        guard didRegisterLayer, !accessibilityNotificationScheduled else { return }
        accessibilityNotificationScheduled = true
        Task { @MainActor in
            accessibilityNotificationScheduled = false
            outerframeHost.notifyAccessibilityTreeChanged(.layoutChanged)
        }
    }
}

@MainActor
private final class FilePickerScrollbarDelegate: ScrollbarControllerDelegate {
    private weak var owner: PlaintextHandler?

    init(owner: PlaintextHandler) {
        self.owner = owner
    }

    func scrollbarDidChangeScrollOffset(_ offset: CGFloat) {
        owner?.setFilePickerScroll(offset)
    }
}

private func withoutImplicitAnimations(_ updates: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updates()
    CATransaction.commit()
}

private func accessibilitySingleLineQuery(_ query: OuterframeAccessibilityTextQuery, range: NSRange,
                                           point: CGPoint, text: String, line: CTLine,
                                           frame: CGRect) -> OuterframeAccessibilityTextResult? {
    let count = text.utf16.count
    switch query {
    case .lineForIndex:
        guard OuterframeAccessibilityTextRange.isValid(NSRange(location: range.location, length: 0), in: text) else { return nil }
        return OuterframeAccessibilityTextResult(index: 0)
    case .rangeForLine:
        guard range.location == 0 else { return nil }
        return OuterframeAccessibilityTextResult(range: NSRange(location: 0, length: count))
    case .visibleRange:
        let hit = CTLineGetStringIndexForPosition(line, CGPoint(x: frame.width, y: 0))
        let end = hit == kCFNotFound ? count : min(max(hit, 0), count)
        let boundary = end < count ? (text as NSString).rangeOfComposedCharacterSequence(at: end).location : count
        return OuterframeAccessibilityTextResult(range: NSRange(location: 0, length: boundary))
    case .frameForRange:
        guard OuterframeAccessibilityTextRange.isValid(range, in: text) else { return nil }
        let a = CTLineGetOffsetForStringIndex(line, range.location, nil)
        let b = CTLineGetOffsetForStringIndex(line, NSMaxRange(range), nil)
        return OuterframeAccessibilityTextResult(range: range,
            frame: CGRect(x: frame.minX + min(a, b), y: frame.minY, width: max(abs(b - a), 1), height: frame.height))
    case .rangeForPosition:
        guard frame.contains(point) else { return nil }
        let x = point.x - frame.minX
        let string = text as NSString
        var offset = 0
        while offset < count {
            let cluster = string.rangeOfComposedCharacterSequence(at: offset)
            let a = CTLineGetOffsetForStringIndex(line, cluster.location, nil)
            let b = CTLineGetOffsetForStringIndex(line, NSMaxRange(cluster), nil)
            if x >= min(a, b), x < max(a, b) { return OuterframeAccessibilityTextResult(range: cluster) }
            offset = NSMaxRange(cluster)
        }
        return OuterframeAccessibilityTextResult(range: NSRange(location: x <= 0 ? 0 : count, length: 0))
    }
}
