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
        tintColor.set()
        configuredImage.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
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
    private let headerHeight: CGFloat = 42
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
            updateTextContent(force: true)
        case .windowActiveUpdate(let isActive):
            windowIsActive = isActive
            updateSelectionLayers(force: true)
            updateCursor()
        case .viewFocusChanged(let isFocused):
            viewIsFocused = isFocused
            updateCursor()
        case .mouseDown(let point, let modifierFlags, let clickCount):
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
        case .scrollWheelEvent(let point, let delta, _, _, _, let precise):
            let rootPoint = rootLayer.convert(point, to: rootLayer)
            if pendingFilePicker != nil, filePickerListFrame.contains(rootPoint) {
                setFilePickerScroll(filePickerScroll - delta.y * (precise ? 1 : filePickerRowHeight))
            } else if editorClipLayer.frame.contains(rootPoint) {
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
            openDocument(path: filePath(from: url) ?? "", draftID: queryValue("draft"), target: queryValue("target"))
        case .shutdown:
            flushDrafts()
            retainedSelf = nil
        default:
            break
        }
    }

    func outerframeHostDidDisconnect(_ host: OuterframeHost) {
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
        loadFile()
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
        headerLayer.backgroundColor = resolvedCGColor(.windowBackgroundColor)
        toolbarDividerLayer.backgroundColor = resolvedCGColor(.separatorColor)
        editorClipLayer.backgroundColor = resolvedCGColor(.textBackgroundColor)
        pathLayer.foregroundColor = resolvedCGColor(.labelColor)
        statusLayer.foregroundColor = resolvedCGColor(isSaving || isLoading ? .secondaryLabelColor : statusColor())
        pathChevronLayer.tintColor = resolvedNSColor(.secondaryLabelColor)
        pathPromptCursorLayer.backgroundColor = resolvedCGColor(.keyboardFocusIndicatorColor)
        editorCaretLayer.backgroundColor = resolvedCGColor(.textColor)
        findBarLayer.backgroundColor = resolvedCGColor(.windowBackgroundColor)
        findFieldLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
        findFieldLayer.borderColor = resolvedCGColor(findInputController.isFocused ? .keyboardFocusIndicatorColor : .separatorColor)
        findTextLayer.foregroundColor = resolvedCGColor(.labelColor)
        findPlaceholderLayer.foregroundColor = resolvedCGColor(.placeholderTextColor)
        findStatusLayer.foregroundColor = resolvedCGColor(.secondaryLabelColor)
        findDoneTextLayer.foregroundColor = resolvedCGColor(.labelColor)
        findSelectionLayer.backgroundColor = resolvedCGColor(.selectedTextBackgroundColor)
        findMarkedUnderlineLayer.backgroundColor = resolvedCGColor(.keyboardFocusIndicatorColor)
        findCaretLayer.backgroundColor = resolvedCGColor(.textColor)
        filePickerNameFieldLayer.backgroundColor = resolvedCGColor(.controlBackgroundColor)
        filePickerNameFieldLayer.borderColor = resolvedCGColor(filePickerNameInputController.isFocused ? .keyboardFocusIndicatorColor : .separatorColor)
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
            let pathX: CGFloat = 14
            let renderedStatus = (statusLayer.string as? String) ?? ""
            let statusWidth = renderedStatus.isEmpty ? CGFloat(0) : min(max(statusLayer.preferredFrameSize().width + 2, 58), currentSize.width * 0.65)
            let availablePathWidth = max(currentSize.width - pathX - statusWidth - 48, 42)
            let pathWidth = min(max(pathLayer.preferredFrameSize().width + 2, 42), availablePathWidth)
            let textY = floor((headerHeight - 18) / 2) + 1
            pathLayer.frame = CGRect(x: pathX, y: textY, width: pathWidth, height: 18)
            pathChevronLayer.frame = CGRect(x: pathLayer.frame.maxX + 2, y: textY, width: 12, height: 18)
            pathControlFrame = pathLayer.frame.union(pathChevronLayer.frame).insetBy(dx: -6, dy: -6)
            pathChevronLayer.isHidden = isPrompting
            statusLayer.frame = CGRect(x: pathChevronLayer.frame.maxX + 8,
                                       y: textY + 1,
                                       width: max(currentSize.width - pathChevronLayer.frame.maxX - 18, 1),
                                       height: 17)
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
        text.frame = CGRect(x: 6, y: 7, width: 58, height: 16)
        layer.addSublayer(text)
        return layer
    }

    private func renderFilePicker() {
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

    private func renderFilePickerContents(_ picker: PendingFilePicker) {
        filePickerOverlayLayer.isHidden = false
        filePickerOverlayLayer.frame = rootLayer.bounds
        filePickerOverlayLayer.backgroundColor = resolvedCGColor(NSColor.black.withAlphaComponent(0.18))
        filePickerOverlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }

        let width = rootLayer.bounds.width
        let height = rootLayer.bounds.height
        let panelWidth = min(max(width - 48, 460), 760)
        let panelHeight = min(max(height - 48, 340), 540)
        let panelFrame = CGRect(x: floor((width - panelWidth) / 2),
                                y: floor((height - panelHeight) / 2),
                                width: panelWidth,
                                height: panelHeight)
        filePickerPanelFrame = panelFrame

        let panel = CALayer()
        panel.frame = panelFrame
        panel.cornerRadius = 8
        panel.borderWidth = 1
        panel.borderColor = resolvedCGColor(.separatorColor)
        panel.backgroundColor = resolvedCGColor(.windowBackgroundColor)
        filePickerOverlayLayer.addSublayer(panel)

        let title = makeTextLayer(size: 15, weight: .semibold, color: .labelColor)
        title.string = "Open File"
        title.frame = CGRect(x: 18, y: panelHeight - 38, width: panelWidth - 36, height: 20)
        panel.addSublayer(title)

        let breadcrumbFrame = CGRect(x: 18,
                                     y: panelHeight - 78,
                                     width: panelWidth - 36,
                                     height: FilePickerBreadcrumbBar.height)
        filePickerBreadcrumbFrame = breadcrumbFrame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        filePickerBreadcrumbLayer.frame = breadcrumbFrame
        FilePickerBreadcrumbBar.render(path: picker.directory,
                                       in: filePickerBreadcrumbLayer,
                                       segmentFrames: &filePickerBreadcrumbSegmentFrames,
                                       appearance: appearance)
        panel.addSublayer(filePickerBreadcrumbLayer)

        let bottomControlsHeight: CGFloat = 108
        let listFrame = CGRect(x: 18,
                               y: bottomControlsHeight,
                               width: panelWidth - 36,
                               height: max(breadcrumbFrame.minY - bottomControlsHeight - 12, 80))
        filePickerListFrame = listFrame.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        filePickerListLayer.frame = listFrame
        filePickerListLayer.cornerRadius = 6
        filePickerListLayer.borderWidth = 1
        filePickerListLayer.borderColor = resolvedCGColor(.separatorColor)
        filePickerListLayer.backgroundColor = resolvedCGColor(NSColor.controlBackgroundColor.withAlphaComponent(0.35))
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
        panel.addSublayer(nameLabel)

        let nameFieldLocal = CGRect(x: 96, y: 64, width: max(panelWidth - 114, 80), height: 30)
        filePickerNameFieldFrame = nameFieldLocal.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        filePickerNameFieldLayer.frame = nameFieldLocal
        filePickerNameFieldLayer.borderWidth = filePickerNameInputController.isFocused ? 1.5 : 1
        panel.addSublayer(filePickerNameFieldLayer)
        updateFilePickerNameDisplay()

        let openLocal = CGRect(x: panelWidth - 84, y: 28, width: 66, height: 30)
        let cancelLocal = CGRect(x: openLocal.minX - 78, y: 28, width: 70, height: 30)
        filePickerOpenFrame = openLocal.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        filePickerCancelFrame = cancelLocal.offsetBy(dx: panelFrame.minX, dy: panelFrame.minY)
        let cancel = makeButtonLayer(title: "Cancel", emphasized: false)
        cancel.frame = cancelLocal
        panel.addSublayer(cancel)
        let open = makeButtonLayer(title: "Open", emphasized: true)
        open.frame = openLocal
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
            icon.tintColor = isSelected ? .white : .secondaryLabelColor
            icon.frame = CGRect(x: 22, y: 6, width: 16, height: 16)
        }
        if let name = row.sublayers?[1] as? CATextLayer {
            name.string = entry.name
            name.foregroundColor = resolvedCGColor(isSelected ? .white : .labelColor)
            name.frame = CGRect(x: 58, y: 6, width: max(frame.width - 70, 1), height: 16)
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
            filePickerNameFieldLayer.borderColor = resolvedCGColor(filePickerNameInputController.isFocused ? .keyboardFocusIndicatorColor : .separatorColor)
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

    private func showOpenFilePicker() {
        cancelPathPrompt()
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
        let defaultName = filePath.isEmpty ? "" : (filePath as NSString).lastPathComponent
        filePickerNameInputController.setText(defaultName)
        filePickerScroll = 0
        filePickerSelectedIndex = nil
        findInputController.blur()
        filePickerNameInputController.focus()
        resetFilePickerTypeahead()
        renderFilePicker()
        fadeInFilePickerOverlayIfNeeded(shouldAnimate)
        fetchFilePickerDirectory(path: directory, clearName: false)
    }

    private func fetchFilePickerDirectory(path: String, clearName: Bool = true) {
        guard let filesEndpoint, let urlSession else { return }
        pendingFilePicker?.directory = path
        pendingFilePicker?.entries = []
        pendingFilePicker?.isLoading = true
        pendingFilePicker?.error = ""
        filePickerScroll = 0
        filePickerSelectedIndex = nil
        if clearName {
            filePickerNameInputController.setText("")
        }
        resetFilePickerTypeahead()
        renderFilePicker()

        var components = URLComponents(url: filesEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        guard let url = components?.url else {
            pendingFilePicker?.isLoading = false
            pendingFilePicker?.error = "Could not build file request."
            renderFilePicker()
            return
        }
        urlSession.dataTask(with: url) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self, self.pendingFilePicker != nil else { return }
                self.pendingFilePicker?.isLoading = false
                if let error {
                    self.pendingFilePicker?.error = error.localizedDescription
                    self.renderFilePicker()
                    return
                }
                guard let data else {
                    self.pendingFilePicker?.error = "No directory response."
                    self.renderFilePicker()
                    return
                }
                do {
                    let response = try FilePickerResponse.decodeBinary(data)
                    self.pendingFilePicker?.directory = response.path
                    self.pendingFilePicker?.entries = response.entries
                    self.filePickerSelectedIndex = nil
                    if clearName {
                        self.filePickerNameInputController.setText("")
                    }
                } catch {
                    self.pendingFilePicker?.error = "Could not decode directory."
                }
                self.renderFilePicker()
            }
        }.resume()
    }

    private func dismissFilePicker() {
        pendingFilePicker = nil
        filePickerScroll = 0
        filePickerSelectedIndex = nil
        filePickerNameInputController.blur()
        filePickerNameInputController.setText("")
        resetFilePickerTypeahead()
        fadeOutAndHideFilePickerOverlay()
    }

    private func activateFilePickerEntry(_ entry: FilePickerEntryRecord) {
        if entry.isDirectory {
            fetchFilePickerDirectory(path: entry.path)
        } else {
            dismissFilePicker()
            openPath(entry.path)
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
        guard let picker = pendingFilePicker else { return }
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
        dismissFilePicker()
        openPath(path)
    }

    private func moveFilePickerSelection(delta: Int) {
        guard let entries = pendingFilePicker?.entries, !entries.isEmpty else { return }
        let nextIndex = min(max((filePickerSelectedIndex ?? (delta > 0 ? -1 : entries.count)) + delta, 0), entries.count - 1)
        selectFilePickerIndex(nextIndex)
    }

    private func selectFilePickerIndex(_ index: Int) {
        guard let entries = pendingFilePicker?.entries, entries.indices.contains(index) else { return }
        filePickerSelectedIndex = index
        filePickerNameInputController.setText(entries[index].name)
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
            fetchFilePickerDirectory(path: path)
            return true
        }
        if filePickerListFrame.contains(rootPoint),
           filePickerScrollbarController?.handleMouseDown(at: filePickerListLayer.convert(rootPoint, from: rootLayer)) == true {
            return true
        }
        if filePickerListFrame.contains(rootPoint),
           let hit = filePickerEntryFrames.first(where: { $0.frame.contains(rootPoint) }) {
            filePickerSelectedIndex = hit.index
            filePickerNameInputController.setText(hit.entry.name)
            filePickerNameInputController.blur()
            resetFilePickerTypeahead()
            updateFilePickerVisibleRows(rebuild: true)
            if clickCount >= 2 {
                activateFilePickerEntry(hit.entry)
            }
            return true
        }
        return filePickerPanelFrame.contains(rootPoint)
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
                pathLayer.string = documentDisplayName()
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
            findFieldLayer.borderColor = resolvedCGColor(findInputController.isFocused ? .keyboardFocusIndicatorColor : .separatorColor)
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

    private func makeDocument(_ record: PlaintextDraft, storage: PlaintextDraftStore? = nil) -> PlaintextDocument? {
        guard let store = storage ?? draftStore, let session = urlSession, let endpoint = environmentEndpoint else { return nil }
        let doc = PlaintextDocument(draft: record, store: store) { operation, target, path, revision, contents in
            try await PlaintextEnvironment.request(session: session, endpoint: endpoint, operation: operation,
                                                   target: target, path: path, revision: revision, contents: contents)
        }
        doc.changed = { [weak self, weak doc] in
            guard let self, let doc, self.document === doc else { return }
            self.filePath = doc.draft.path
            self.isSaving = doc.isSaving
            let previousStatus = self.statusText
            self.statusText = self.showingServerVersion ? "Server version (read-only) · Use the file menu to return to your draft" : doc.status
            self.outerframeHost.setTitle((self.showingServerVersion ? "Server version · " : "") + (doc.draft.dirty ? "• " : "") + (doc.draft.path.isEmpty ? "Untitled" : (doc.draft.path as NSString).lastPathComponent))
            self.updateURLForCurrentFile()
            self.renderHeader(); self.updateColors()
            if previousStatus != self.statusText { self.layout() }
        }
        documents[record.id] = doc
        return doc
    }

    private func activate(_ doc: PlaintextDocument) {
        document = doc; reviewedDisk = nil; showingServerVersion = false
        filePath = doc.draft.path; text = doc.draft.contents
        cursorOffset = 0; selectionAnchor = nil; scrollOffset = 0
        clearMarkedTextState()
        doc.changed?(); updateTextContent(force: true); layout()
        doc.resume()
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
                var record = new ? nil : records.first { draftID != nil ? $0.id == draftID : $0.path == path && $0.target == target }
                if let record, let existing = documents[record.id] { activate(existing); return }
                if record == nil {
                    var fresh = PlaintextDraft(); fresh.target = target; fresh.path = path
                    if !path.isEmpty {
                        let result = try await PlaintextEnvironment.request(session: session, endpoint: endpoint, operation: 2, target: target, path: path)
                        fresh.path = result.path; fresh.contents = result.contents; fresh.revision = result.revision
                        fresh.dirty = result.dirty; fresh.conflict = result.conflict
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
                if !doc.draft.dirty && doc.draft.pending == nil && !doc.draft.path.isEmpty {
                    let version = doc.draft.version
                    Task {
                        do {
                            let result = try await doc.disk()
                            guard document === doc, doc.draft.version == version, !doc.draft.dirty, doc.draft.pending == nil else { return }
                            doc.draft.contents = result.contents; doc.draft.revision = result.revision
                            _ = await doc.persist()
                            if document === doc && doc.draft.version == version { text = doc.draft.contents; updateTextContent(force: true) }
                        } catch {
                            if document === doc && !doc.draft.dirty { statusText = "Local copy · " + error.localizedDescription; renderHeader() }
                        }
                    }
                }
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
        guard let document, !isLoading, !showingServerVersion else { return }
        if document.draft.conflict { reviewServerVersion(); return }
        if document.draft.path.isEmpty { beginPathPrompt(mode: .saveAs, defaultValue: ""); return }
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
        guard let doc = document else { return }
        Task {
            do {
                let disk = try await doc.disk()
                guard document === doc else { return }
                reviewedDisk = disk; showingServerVersion = true; text = disk.contents
                cursorOffset = 0; selectionAnchor = nil
                updateTextContent(force: true); doc.changed?()
            } catch { statusText = error.localizedDescription; renderHeader() }
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
        outerframeHost.replaceHistoryEntry(url: url)
    }

    private func showOpenPrompt() {
        if document?.draft.target != "host" { beginPathPrompt(mode: .open, defaultValue: filePath); return }
        showOpenFilePicker()
    }

    private func showMoveRenamePrompt() {
        guard !filePath.isEmpty else { return }
        beginPathPrompt(mode: .moveRename, defaultValue: filePath)
    }

    private func beginPathPrompt(mode: PathPromptMode, defaultValue: String) {
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
            let items = [
                OuterframeContextMenuItem(id: "path-save", title: "Save", isEnabled: doc != nil && !isLoading && !showingServerVersion),
                OuterframeContextMenuItem(id: "path-new", title: "New"),
                OuterframeContextMenuItem(id: "path-open", title: "Open…"),
                OuterframeContextMenuItem(id: "path-recover", title: "Recover Draft", kind: .submenu, isEnabled: !recovery.isEmpty, children: recovery),
                OuterframeContextMenuItem(id: "path-export", title: "Copy Draft as File", isEnabled: doc != nil),
                OuterframeContextMenuItem(id: "path-copy-text", title: "Copy Draft Text", isEnabled: doc != nil),
                OuterframeContextMenuItem(id: "path-save-copy", title: "Save a Copy…", isEnabled: doc != nil && doc?.isSynchronizing == false),
                OuterframeContextMenuItem(id: "path-review", title: "Review Server Version", isEnabled: doc?.draft.conflict == true),
                OuterframeContextMenuItem(id: "path-return", title: "Return to My Draft", isEnabled: showingServerVersion),
                OuterframeContextMenuItem(id: "path-replace", title: "Replace Reviewed Server Version with My Draft…", isEnabled: reviewedDisk != nil && doc?.draft.conflict == true),
                OuterframeContextMenuItem(id: "path-move-rename", title: "Move/Rename…", isEnabled: doc != nil && !filePath.isEmpty && doc?.draft.dirty == false && doc?.draft.pending == nil),
                OuterframeContextMenuItem(id: "path-copy", title: "Copy Path", isEnabled: !filePath.isEmpty)
            ]
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
        NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    private func updateTextContent(force: Bool = false) {
        let displayText = text.isEmpty ? " " : text
        guard force || displayText != attributedText.string else { return }

        withoutImplicitAnimations {
            generation += 1
            contentHeightCache = nil
            visualLineCache = nil
            fragmentCoverage = nil
            clearTextFragmentLayers()

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byCharWrapping
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
            textContainer.size = CGSize(width: max(textLayoutWidth, 1), height: max(contentHeight() - textInsetY * 2, editorClipLayer.bounds.height))
            cursorOffset = clampedOffset(cursorOffset)
            selectionAnchor = selectionAnchor.map(clampedOffset)
            recomputeFindMatches(selectNearestMatch: false)
            layoutText()
            updateEditingCapabilities()
        }
        notifyAccessibilityLayoutChanged()
    }

    private func layoutText() {
        guard editorClipLayer.bounds.width > 0, editorClipLayer.bounds.height > 0 else { return }
        let textWidth = max(editorClipLayer.bounds.width - textInsetX * 2, 1)
        if abs(textWidth - textLayoutWidth) > 0.5 {
            textLayoutWidth = textWidth
            clearTextFragmentLayers()
            contentHeightCache = nil
            visualLineCache = nil
        }
        textContainer.size = CGSize(width: textWidth,
                                    height: max(contentHeight() - textInsetY * 2, editorClipLayer.bounds.height))
        scrollOffset = clampedScrollOffset(scrollOffset)
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

            let textWidth = max(editorClipLayer.bounds.width - textInsetX * 2, 1)
            let contentHeight = max(self.contentHeight() - textInsetY * 2, editorClipLayer.bounds.height)
            textContentLayer.frame = CGRect(x: textInsetX,
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
        let textWidth = max(editorClipLayer.bounds.width - textInsetX * 2, 1)
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
        let resolvedTextWidth = max(textWidth ?? (editorClipLayer.bounds.width - textInsetX * 2), 1)
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
               width: max(editorClipLayer.bounds.width - textInsetX * 2, 1),
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

    private func replace(range: NSRange, with replacement: String, clearsMarkedText: Bool = true) {
        guard !isLoading, !showingServerVersion, document != nil,
              let normalized = normalizedReplacementRange(range),
              let swiftRange = Range(normalized, in: text) else {
            return
        }
        withoutImplicitAnimations {
            if clearsMarkedText {
                markedTextRange = nil
                pendingMarkedTextReplacementRange = nil
            }
            text.replaceSubrange(swiftRange, with: replacement)
            cursorOffset = normalized.location + (replacement as NSString).length
            selectionAnchor = nil
            updateTextContent(force: true)
            ensureCursorVisible()
            scheduleSave()
        }
    }

    private func insertText(_ value: String) {
        if let range = markedTextRange ?? pendingMarkedTextReplacementRange {
            replace(range: range, with: value)
            return
        }
        if let selectionRange {
            replace(range: selectionRange, with: value)
            return
        }
        replace(range: NSRange(location: cursorOffset, length: 0), with: value)
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
        pendingMarkedTextReplacementRange = markedTextRange
        markedTextRange = nil
        updateTextContent(force: true)
        updateSelectionLayers(force: true)
        updateCursor()
    }

    private func clearMarkedTextState() {
        markedTextRange = nil
        pendingMarkedTextReplacementRange = nil
    }

    private func deleteBackward() {
        if let selectionRange {
            replace(range: selectionRange, with: "")
            return
        }
        guard cursorOffset > 0 else { return }
        replace(range: NSRange(location: cursorOffset - 1, length: 1), with: "")
    }

    private func deleteForward() {
        if let selectionRange {
            replace(range: selectionRange, with: "")
            return
        }
        guard cursorOffset < (text as NSString).length else { return }
        replace(range: NSRange(location: cursorOffset, length: 1), with: "")
    }

    private func performTextCommand(_ command: String) {
        switch command {
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
            insertText("\t")
        case "deleteBackward":
            deleteBackward()
        case "deleteForward":
            deleteForward()
        case "deleteWordBackward":
            replace(range: NSRange(location: previousWordBoundary(from: cursorOffset), length: cursorOffset - previousWordBoundary(from: cursorOffset)), with: "")
        case "deleteWordForward":
            let next = nextWordBoundary(from: cursorOffset)
            replace(range: NSRange(location: cursorOffset, length: next - cursorOffset), with: "")
        case "deleteToBeginningOfLine", "deleteToBeginningOfParagraph":
            let start = lineStart(for: cursorOffset)
            replace(range: NSRange(location: start, length: cursorOffset - start), with: "")
        case "deleteToEndOfLine", "deleteToEndOfParagraph":
            let end = lineEnd(for: cursorOffset)
            replace(range: NSRange(location: cursorOffset, length: end - cursorOffset), with: "")
        case "moveLeft":
            move(to: cursorOffset - 1, modifySelection: false)
        case "moveRight":
            move(to: cursorOffset + 1, modifySelection: false)
        case "moveLeftAndModifySelection":
            move(to: cursorOffset - 1, modifySelection: true)
        case "moveRightAndModifySelection":
            move(to: cursorOffset + 1, modifySelection: true)
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
        if pathControlFrame.contains(headerPoint) {
            if pathPromptMode != nil {
                setPathPromptCursor(atToolbarX: headerPoint.x)
            } else {
                showPathMenu(at: point)
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
        let hasSelection = selectionRange?.length ?? 0 > 0
        let selectedText = selectedString() ?? ""
        var items: [OuterframeContextMenuItem] = []
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
            insertText("")
        }
        return items
    }

    private func paste(_ items: [OuterframeContentPasteboardItem]) {
        for item in items {
            if let representation = item.representations.first(where: { $0.typeIdentifier == NSPasteboard.PasteboardType.string.rawValue }),
               let string = String(data: representation.data, encoding: .utf8) {
                if filePickerNameInputController.isFocused {
                    filePickerNameInputController.insertText(string)
                    return
                }
                if findInputController.isFocused {
                    findInputController.insertText(string)
                    return
                }
                insertText(string)
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
        return enabledCommands
    }

    private func handleContextMenuItem(menuID: UUID, itemID: String) {
        if pendingFilePickerNameMenuIDs.remove(menuID) != nil {
            return
        }
        if pendingFindMenuIDs.remove(menuID) != nil {
            return
        }
        if pendingPathMenuIDs.remove(menuID) != nil {
            if itemID.hasPrefix("recover:") { openDocument(path: "", draftID: String(itemID.dropFirst(8))); return }
            switch itemID {
            case "path-new": openDocument(path: "", new: true)
            case "path-export": exportDraft()
            case "path-copy-text":
                if let document { outerframeHost.requestPasteboardWrite(items: pasteboardItems(for: document.draft.contents)) }
            case "path-save-copy": beginPathPrompt(mode: .saveCopy, defaultValue: filePath)
            case "path-review": reviewServerVersion()
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
                    Task { await document.replaceReviewedFile(revision: reviewedDisk.revision) }
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
        case "save":
            saveNow()
        default:
            break
        }
    }

    private func handleKeyDown(characters: String, charactersIgnoringModifiers: String, modifierFlags: NSEvent.ModifierFlags) {
        let normalized = (charactersIgnoringModifiers.isEmpty ? characters : charactersIgnoringModifiers).lowercased()
        if modifierFlags.contains(.command), normalized == "f" {
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
                filePickerNameInputController.insertText(string)
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
            children.append(axNode("filename", .textField, filePickerNameFieldFrame, "File name", value: filePickerNameInputController.text,
                                   actions: [.focus, .setValue], focused: filePickerNameInputController.isFocused) { owner, action, value in
                owner.filePickerNameInputController.focus()
                if action == .setValue { owner.filePickerNameInputController.setText(value) }
            })
            children.append(axNode("cancel-open", .button, filePickerCancelFrame, "Cancel", actions: [.press]) { owner, _, _ in owner.dismissFilePicker() })
            children.append(axNode("open", .button, filePickerOpenFrame, "Open", actions: [.press], enabled: !picker.isLoading) { owner, _, _ in owner.openFilePickerTypedPath() })
            return OuterframeAccessibilitySnapshot(rootNodes: [axNode("picker", .dialog, filePickerPanelFrame, "Open File", children: children)])
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
            children.append(axNode("file-actions", .button, headerLayer.convert(pathControlFrame, to: rootLayer), "File actions",
                                   value: documentDisplayName(), actions: [.press, .showMenu]) { owner, _, _ in
                let frame = owner.headerLayer.convert(owner.pathControlFrame, to: owner.rootLayer)
                owner.showPathMenu(at: CGPoint(x: frame.midX, y: frame.maxY))
            })
        }
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
