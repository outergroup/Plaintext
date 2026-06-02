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

    init?(data: Data) {
        guard PlaintextBinary.version(in: data) == 1,
              let fileAPIPath = PlaintextBinary.stringRef64(in: data, at: 4) else {
            return nil
        }
        self.fileAPIPath = fileAPIPath
    }
}

private struct FileLoadResponse {
    let ok: Bool
    let path: String
    let contents: String
    let size: UInt64
    let modified: Double
    let error: String
    let dirty: Bool

    init?(data: Data) {
        guard PlaintextBinary.version(in: data) == 1,
              let flags = PlaintextBinary.uint8(in: data, at: 4),
              let size = PlaintextBinary.uint64(in: data, at: 8),
              let modified = PlaintextBinary.double(in: data, at: 16),
              let path = PlaintextBinary.stringRef64(in: data, at: 24),
              let contents = PlaintextBinary.stringRef64(in: data, at: 40),
              let error = PlaintextBinary.stringRef64(in: data, at: 56) else {
            return nil
        }
        self.ok = flags & 1 != 0
        self.dirty = flags & 2 != 0
        self.path = path
        self.contents = contents
        self.size = size
        self.modified = modified
        self.error = error
    }
}

private struct FileSaveResponse {
    let ok: Bool
    let path: String
    let size: UInt64
    let modified: Double
    let error: String
    let dirty: Bool

    init?(data: Data) {
        guard PlaintextBinary.version(in: data) == 1,
              let flags = PlaintextBinary.uint8(in: data, at: 4),
              let size = PlaintextBinary.uint64(in: data, at: 8),
              let modified = PlaintextBinary.double(in: data, at: 16),
              let path = PlaintextBinary.stringRef64(in: data, at: 24),
              let error = PlaintextBinary.stringRef64(in: data, at: 40) else {
            return nil
        }
        self.ok = flags & 1 != 0
        self.dirty = flags & 2 != 0
        self.path = path
        self.size = size
        self.modified = modified
        self.error = error
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
        let configuredImage = image.withSymbolConfiguration(.init(pointSize: 9, weight: .medium)) ?? image
        let imageSize = configuredImage.size
        let maxSize = CGSize(width: min(bounds.width, 10), height: min(bounds.height, 7))
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

    var label: String {
        switch self {
        case .open:
            return "Open"
        case .moveRename:
            return "Move/Rename"
        }
    }
}

@MainActor
private final class PlaintextHandler: NSObject, OuterframeHostDelegate, ScrollbarControllerDelegate {
    private let outerframeHost: OuterframeHost
    private let appConnection: OuterframeAppConnection
    private var retainedSelf: PlaintextHandler?

    private var appearance: NSAppearance = .currentDrawing()
    private var currentSize = CGSize(width: 900, height: 640)
    private var windowIsActive = true
    private var viewIsFocused = true
    private var didRegisterLayer = false
    private var currentURLString = ""

    private var urlSession: URLSession?
    private var fileEndpoint: URL?
    private var filePath = ""
    private var loadedModified: Double = 0
    private var loadedSize: UInt64 = 0
    private var statusText = "Loading..."
    private var isLoading = false
    private var isSaving = false
    private var saveTask: URLSessionDataTask?
    private var draftTask: URLSessionDataTask?

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

    private let contentStorage = NSTextContentStorage()
    private let textLayoutManager = NSTextLayoutManager()
    private let textContainer = NSTextContainer(size: CGSize(width: 320, height: 1_000_000))
    private var textFragmentLayers: [ObjectIdentifier: TextFragmentLayer] = [:]
    private var fragmentCoverage: (generation: Int, textWidth: CGFloat, contentHeight: CGFloat, rect: CGRect)?

    private var text = ""
    private var attributedText = NSAttributedString(string: "")
    private var generation = 0
    private var estimatedContentHeightCache: (generation: Int, textWidth: CGFloat, height: CGFloat)?
    private var visualLineCache: (generation: Int, textWidth: CGFloat, metrics: EditorVisualLineMetrics)?
    private var textLayoutWidth: CGFloat = 0

    private var cursorOffset = 0
    private var selectionAnchor: Int?
    private var dragAnchorOffset: Int?
    private var selectionLayers: [CALayer] = []
    private var scrollOffset: CGFloat = 0
    private var scrollbarController: ScrollbarController<PlaintextHandler>?
    private var pathControlFrame = CGRect.zero
    private var pendingPathMenuIDs: Set<UUID> = []
    private var pathPromptMode: PathPromptMode?
    private var pathPromptText = ""
    private var pathPromptCursorOffset = 0

    private let editorInputID = UUID()
    private let headerHeight: CGFloat = 42
    private let textInsetX: CGFloat = 14
    private let textInsetY: CGFloat = 12
    private let scrollLineHeight: CGFloat = 18
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
            layout()
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
            handleMouseDown(point: point, modifierFlags: modifierFlags, clickCount: clickCount)
        case .mouseDragged(let point, _):
            handleMouseDragged(point: point)
        case .mouseUp(let point, _):
            _ = scrollbarController?.handleMouseUp(at: rootLayer.convert(point, to: editorClipLayer))
            dragAnchorOffset = nil
        case .mouseMoved(let point, _):
            updateCursorShape(at: point)
        case .rightMouseDown(let point, _, let clickCount):
            handleRightMouseDown(point: point, clickCount: clickCount)
        case .keyDown(_, let characters, let charactersIgnoringModifiers, let modifierFlags, _):
            handleKeyDown(characters: characters,
                          charactersIgnoringModifiers: charactersIgnoringModifiers,
                          modifierFlags: modifierFlags)
        case .scrollWheelEvent(let point, let delta, _, _, _, let precise):
            if editorClipLayer.frame.contains(rootLayer.convert(point, to: rootLayer)) {
                scrollOffset = clampedScrollOffset(scrollOffset - delta.y * (precise ? 1 : scrollLineHeight))
                updateViewport()
                updateCursor()
            }
        case .textInput(let input, let hasReplacementRange, let replacementLocation, let replacementLength):
            if pathPromptMode != nil {
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
        case .textCommand(let command):
            if pathPromptMode != nil {
                performPathPromptTextCommand(command)
            } else {
                performTextCommand(command)
            }
        case .setCursorPosition(let fieldID, let position, let modifySelection):
            guard fieldID == editorInputID else { return }
            if pathPromptMode != nil {
                let textLength = (pathPromptText as NSString).length
                pathPromptCursorOffset = min(max(Int(position), 0), textLength)
                layout()
            } else {
                setCursorOffset(Int(position), modifySelection: modifySelection)
            }
        case .selectionToPasteboardCopyRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID, items: pasteboardItemsForCopy())
        case .selectionToPasteboardCutRequest(let requestID):
            outerframeHost.sendCopySelectedPasteboardResponse(requestID: requestID, items: pasteboardItemsForCut())
        case .pasteboardContentPasted(let items):
            if pathPromptMode != nil {
                pastePathPrompt(items)
            } else {
                paste(items)
            }
        case .pasteboardDropHitTestRequest(let requestID, let point, let pasteboardTypes, let operationMask, _):
            let accepts = isPointInEditor(point) && pasteboardTypes.contains(NSPasteboard.PasteboardType.string.rawValue)
            outerframeHost.sendPasteboardDropHitTestResponse(requestID: requestID,
                                                             operationMask: accepts ? NSDragOperation.copy : [])
            _ = operationMask
        case .pasteboardContentDropped(let point, let items):
            let offset = textOffset(atRootPoint: point)
            setCursorOffset(offset, modifySelection: false)
            paste(items)
        case .contextMenuItemSelected(let menuID, let itemID):
            handleContextMenuItem(menuID: menuID, itemID: itemID)
        case .accessibilitySnapshotRequest(let requestID):
            outerframeHost.sendAccessibilitySnapshotResponse(requestID: requestID,
                                                             snapshot: OuterframeAccessibilitySnapshot.notImplementedSnapshot())
        case .historyTraversal(_, let url):
            currentURLString = url
            if let nextPath = filePath(from: url), nextPath != filePath {
                filePath = nextPath
                loadFile()
            }
        case .shutdown:
            retainedSelf = nil
        default:
            break
        }
    }

    func outerframeHostDidDisconnect(_ host: OuterframeHost) {
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
        currentURLString = arguments.url ?? ""
        appearance = arguments.appearance ?? .currentDrawing()
        windowIsActive = arguments.windowIsActive ?? true
        currentSize = arguments.contentSize ?? currentSize

        if let data = arguments.data,
           let configuration = PlaintextConfiguration(data: data),
           let base = outerframeHost.pluginBaseURL() {
            fileEndpoint = URL(string: configuration.fileAPIPath, relativeTo: base)?.absoluteURL
        } else if let base = outerframeHost.pluginBaseURL() {
            fileEndpoint = URL(string: "/api/file", relativeTo: base)?.absoluteURL
        }
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
        headerLayer.addSublayer(toolbarDividerLayer)
        headerLayer.addSublayer(pathChevronLayer)
        headerLayer.addSublayer(pathPromptCursorLayer)
        pathPromptCursorLayer.zPosition = 10
        editorClipLayer.addSublayer(textContentLayer)
        textContentLayer.addSublayer(textSelectionLayer)
        textContentLayer.addSublayer(editorCaretLayer)
        editorCaretLayer.zPosition = 20
        editorCaretLayer.isHidden = true

        editorClipLayer.masksToBounds = true
        for textLayer in [pathLayer, statusLayer] {
            textLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
            textLayer.truncationMode = .middle
            textLayer.alignmentMode = .left
            headerLayer.addSublayer(textLayer)
        }

        scrollbarController = ScrollbarController(appConnection: outerframeHost,
                                                  viewportLayer: editorClipLayer,
                                                  appearance: appearance,
                                                  scrollOffsetOrigin: .bottom)
        scrollbarController?.delegate = self
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
        scrollbarController?.updateAppearance(appearance)
        updateSelectionLayers(force: true)
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
        statusText.lowercased().contains("error") || statusText.lowercased().contains("failed")
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
            let statusWidth = renderedStatus.isEmpty ? CGFloat(0) : min(max(statusLayer.preferredFrameSize().width + 2, 58), 120)
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
            if isPrompting {
                let cursorX = pathLayer.frame.minX + pathPromptCursorX(font: pathFont, maxWidth: pathLayer.frame.width)
                pathPromptCursorLayer.frame = CGRect(x: cursorX, y: textY, width: cursorWidth, height: 17)
                pathPromptCursorLayer.isHidden = false
                startBlinkingCaret(pathPromptCursorLayer)
            } else {
                pathPromptCursorLayer.isHidden = true
                stopBlinkingCaret(pathPromptCursorLayer)
            }
            layoutText()
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
    }

    private func documentDisplayName() -> String {
        filePath.isEmpty ? "No file" : filePath
    }

    private func loadFile() {
        guard !filePath.isEmpty else {
            statusText = "Open with ?file=/path/to/file.txt"
            text = ""
            cursorOffset = 0
            selectionAnchor = nil
            updateTextContent(force: true)
            renderHeader()
            return
        }
        guard let fileEndpoint, let urlSession else { return }
        isLoading = true
        statusText = "Loading..."
        renderHeader()

        var components = URLComponents(url: fileEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "file", value: filePath)]
        guard let url = components?.url else { return }
        urlSession.dataTask(with: url) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isLoading = false
                if let error {
                    self.statusText = "Load failed: \(error.localizedDescription)"
                } else if let data,
                          let response = FileLoadResponse(data: data) {
                    self.filePath = response.path
                    self.loadedSize = response.size
                    self.loadedModified = response.modified
                    if response.ok {
                        self.text = response.contents
                        self.cursorOffset = 0
                        self.selectionAnchor = nil
                        self.scrollOffset = 0
                        self.statusText = self.documentStatusText(dirty: response.dirty)
                    } else if response.error == "No such file or directory" {
                        self.text = ""
                        self.loadedSize = 0
                        self.loadedModified = 0
                        self.cursorOffset = 0
                        self.selectionAnchor = nil
                        self.scrollOffset = 0
                        self.statusText = "New file"
                    } else {
                        self.text = ""
                        self.cursorOffset = 0
                        self.selectionAnchor = nil
                        self.statusText = "Load failed: \(response.error)"
                    }
                    self.updateTextContent(force: true)
                } else {
                    self.statusText = "Load failed: invalid response"
                }
                self.renderHeader()
                self.updateColors()
            }
        }.resume()
    }

    private func scheduleSave() {
        guard !filePath.isEmpty else { return }
        statusText = documentStatusText(dirty: true)
        renderHeader()
        syncDraftNow()
    }

    private func syncDraftNow() {
        guard !filePath.isEmpty,
              let fileEndpoint,
              let urlSession else {
            return
        }
        draftTask?.cancel()

        var components = URLComponents(url: fileEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "file", value: filePath),
            URLQueryItem(name: "draft", value: "1")
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(text.utf8)

        draftTask = urlSession.dataTask(with: request)
        draftTask?.resume()
    }

    private func saveNow() {
        guard !filePath.isEmpty,
              let fileEndpoint,
              let urlSession else {
            return
        }
        saveTask?.cancel()
        draftTask?.cancel()
        isSaving = true
        statusText = "Saving..."
        renderHeader()

        var components = URLComponents(url: fileEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "file", value: filePath)]
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(text.utf8)

        saveTask = urlSession.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isSaving = false
                if let error {
                    self.statusText = "Save failed: \(error.localizedDescription)"
                } else if let data,
                          let response = FileSaveResponse(data: data) {
                    if response.ok {
                        self.loadedSize = response.size
                        self.loadedModified = response.modified
                        self.statusText = self.documentStatusText(dirty: false)
                    } else {
                        self.statusText = "Save failed: \(response.error)"
                    }
                } else {
                    self.statusText = "Save failed: invalid response"
                }
                self.renderHeader()
                self.updateColors()
            }
        }
        saveTask?.resume()
    }

    private func openPath(_ path: String) {
        let nextPath = normalizedPath(path, relativeTo: filePath)
        guard !nextPath.isEmpty else { return }
        filePath = nextPath
        updateURLForCurrentFile()
        loadFile()
    }

    private func moveFile(to path: String) {
        let targetPath = normalizedPath(path, relativeTo: filePath)
        guard !filePath.isEmpty, !targetPath.isEmpty, targetPath != filePath,
              let fileEndpoint,
              let urlSession else {
            return
        }

        isSaving = true
        statusText = "Moving..."
        renderHeader()
        updateColors()

        var components = URLComponents(url: fileEndpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "file", value: filePath),
            URLQueryItem(name: "moveTo", value: targetPath)
        ]
        guard let url = components?.url else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data()

        urlSession.dataTask(with: request) { [weak self] data, _, error in
            Task { @MainActor in
                guard let self else { return }
                self.isSaving = false
                if let error {
                    self.statusText = "Move failed: \(error.localizedDescription)"
                } else if let data,
                          let response = FileSaveResponse(data: data) {
                    if response.ok {
                        self.filePath = response.path
                        self.loadedSize = response.size
                        self.loadedModified = response.modified
                        self.statusText = self.documentStatusText(dirty: response.dirty)
                        self.updateURLForCurrentFile()
                    } else {
                        self.statusText = "Move failed: \(response.error)"
                    }
                } else {
                    self.statusText = "Move failed: invalid response"
                }
                self.renderHeader()
                self.layout()
                self.updateColors()
            }
        }.resume()
    }

    private func normalizedPath(_ value: String, relativeTo basePath: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("/") {
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
        items.removeAll { $0.name == "file" }
        if !filePath.isEmpty {
            items.append(URLQueryItem(name: "file", value: filePath))
        }
        components.queryItems = items.isEmpty ? nil : items
        guard let url = components.url else { return }
        currentURLString = url.absoluteString
        outerframeHost.replaceHistoryEntry(url: url)
    }

    private func showOpenPrompt() {
        beginPathPrompt(mode: .open, defaultValue: filePath)
    }

    private func showMoveRenamePrompt() {
        guard !filePath.isEmpty else { return }
        beginPathPrompt(mode: .moveRename, defaultValue: filePath)
    }

    private func beginPathPrompt(mode: PathPromptMode, defaultValue: String) {
        pathPromptMode = mode
        pathPromptText = defaultValue
        pathPromptCursorOffset = (pathPromptText as NSString).length
        renderHeader()
        layout()
    }

    private func cancelPathPrompt() {
        pathPromptMode = nil
        pathPromptText = ""
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
        for offset in 0...nsString.length {
            let prefix = nsString.substring(to: offset) as NSString
            let width = prefix.size(withAttributes: [.font: font]).width
            let distance = abs(width - relativeX)
            if distance < bestDistance {
                bestDistance = distance
                bestOffset = offset
            }
        }
        pathPromptCursorOffset = bestOffset
        layout()
    }

    private func insertPathPromptText(_ value: String) {
        replacePathPromptText(range: NSRange(location: pathPromptCursorOffset, length: 0), with: value)
    }

    private func replacePathPromptText(range: NSRange, with replacement: String) {
        let nsString = pathPromptText as NSString
        let safeLocation = min(max(range.location, 0), nsString.length)
        let safeLength = min(max(range.length, 0), nsString.length - safeLocation)
        pathPromptText = nsString.replacingCharacters(in: NSRange(location: safeLocation, length: safeLength),
                                                      with: replacement)
        pathPromptCursorOffset = safeLocation + (replacement as NSString).length
        renderHeader()
        layout()
    }

    private func deletePathPromptBackward() {
        let nsString = pathPromptText as NSString
        guard pathPromptCursorOffset > 0, nsString.length > 0 else { return }
        replacePathPromptText(range: NSRange(location: pathPromptCursorOffset - 1, length: 1), with: "")
    }

    private func deletePathPromptForward() {
        let nsString = pathPromptText as NSString
        guard pathPromptCursorOffset < nsString.length else { return }
        replacePathPromptText(range: NSRange(location: pathPromptCursorOffset, length: 1), with: "")
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
        case "moveLeft":
            pathPromptCursorOffset = max(pathPromptCursorOffset - 1, 0)
            layout()
        case "moveRight":
            pathPromptCursorOffset = min(pathPromptCursorOffset + 1, nsString.length)
            layout()
        case "moveToBeginningOfLine", "moveToBeginningOfDocument", "moveToLeftEndOfLine":
            pathPromptCursorOffset = 0
            layout()
        case "moveToEndOfLine", "moveToEndOfDocument", "moveToRightEndOfLine":
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
        let hasFile = !filePath.isEmpty
        let items = [
            OuterframeContextMenuItem(id: "path-title",
                                      title: hasFile ? filePath : "No file",
                                      isEnabled: false),
            OuterframeContextMenuItem(id: "path-separator-1",
                                      title: "",
                                      isEnabled: false,
                                      isSeparator: true),
            OuterframeContextMenuItem(id: "path-save",
                                      title: "Save",
                                      isEnabled: hasFile),
            OuterframeContextMenuItem(id: "path-open",
                                      title: "Open..."),
            OuterframeContextMenuItem(id: "path-separator-2",
                                      title: "",
                                      isEnabled: false,
                                      isSeparator: true),
            OuterframeContextMenuItem(id: "path-move-rename",
                                      title: "Move/Rename...",
                                      isEnabled: hasFile),
            OuterframeContextMenuItem(id: "path-copy",
                                      title: "Copy Path",
                                      isEnabled: hasFile)
        ]
        outerframeHost.showContextMenu(menuID: menuID, items: items, at: point)
    }

    private func copyCurrentPath() {
        guard !filePath.isEmpty else { return }
        let item = OuterframeContentPasteboardItem(representations: [
            OuterframeContentPasteboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                                      data: Data(filePath.utf8))
        ])
        outerframeHost.requestPasteboardWrite(items: [item])
    }

    private func documentStatusText(dirty: Bool) -> String {
        dirty ? "Modified" : ""
    }

    private func textFont() -> NSFont {
        NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    }

    private func updateTextContent(force: Bool = false) {
        let displayText = text.isEmpty ? " " : text
        guard force || displayText != attributedText.string else { return }

        withoutImplicitAnimations {
            generation += 1
            estimatedContentHeightCache = nil
            visualLineCache = nil
            fragmentCoverage = nil
            clearTextFragmentLayers()

            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byCharWrapping
            paragraph.lineSpacing = 2
            attributedText = NSAttributedString(string: displayText,
                                                attributes: [
                                                    .font: textFont(),
                                                    .foregroundColor: resolvedNSColor(.labelColor),
                                                    .paragraphStyle: paragraph
                                                ])
            contentStorage.attributedString = attributedText
            textContainer.size = CGSize(width: max(textLayoutWidth, 1), height: max(contentHeight() - textInsetY * 2, editorClipLayer.bounds.height))
            cursorOffset = clampedOffset(cursorOffset)
            selectionAnchor = selectionAnchor.map(clampedOffset)
            layoutText()
            updateEditingCapabilities()
        }
    }

    private func layoutText() {
        guard editorClipLayer.bounds.width > 0, editorClipLayer.bounds.height > 0 else { return }
        let textWidth = max(editorClipLayer.bounds.width - textInsetX * 2, 1)
        if abs(textWidth - textLayoutWidth) > 0.5 {
            textLayoutWidth = textWidth
            clearTextFragmentLayers()
            estimatedContentHeightCache = nil
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
        return max(estimatedContentHeight(textWidth: textWidth), editorClipLayer.bounds.height)
    }

    private func estimatedContentHeight(textWidth: CGFloat) -> CGFloat {
        if let cache = estimatedContentHeightCache,
           cache.generation == generation,
           abs(cache.textWidth - textWidth) <= 0.5 {
            return cache.height
        }
        let metrics = visualLineMetrics(textWidth: textWidth)
        let height = CGFloat(max(metrics.lines.count, 1)) * metrics.lineHeight + textInsetY * 2
        estimatedContentHeightCache = (generation: generation, textWidth: textWidth, height: height)
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
            let textWidth = max(editorClipLayer.bounds.width - textInsetX * 2, 1)
            let contentHeight = max(self.contentHeight() - textInsetY * 2, editorClipLayer.bounds.height)
            let selectionRect = expandedTextContentRect(containing: visibleTextContentRect(), contentHeight: contentHeight)
            let metrics = visualLineMetrics(textWidth: textWidth)
            guard !metrics.lines.isEmpty else { return }

            let firstLine = max(Int(floor(max(selectionRect.minY, 0) / metrics.lineHeight)), 0)
            let lastLine = min(Int(floor(max(selectionRect.maxY - 0.001, 0) / metrics.lineHeight)), metrics.lines.count - 1)
            guard firstLine <= lastLine else { return }

            for lineIndex in firstLine...lastLine {
                let line = metrics.lines[lineIndex]
                let intersection = NSIntersectionRange(selectionRange, line.range)
                let selectsEmptyLine = line.range.length == 0 &&
                    selectionRange.location <= line.range.location &&
                    selectionRange.location + selectionRange.length > line.range.location
                guard intersection.length > 0 || selectsEmptyLine else { continue }

                let startColumn = selectsEmptyLine ? 0 : max(intersection.location - line.range.location, 0)
                let selectedColumnCount = selectsEmptyLine ? 1 : max(intersection.length, 1)
                let x = min(CGFloat(startColumn) * metrics.charWidth, textWidth)
                let width = max(min(CGFloat(selectedColumnCount) * metrics.charWidth, textWidth - x), 1)
                let topDownY = CGFloat(lineIndex) * metrics.lineHeight
                let rect = CGRect(x: x, y: topDownY, width: width, height: metrics.lineHeight)
                guard rect.intersects(selectionRect) else { continue }

                let highlight = CALayer()
                highlight.frame = CGRect(x: rect.minX,
                                         y: textSelectionLayer.bounds.height - rect.maxY,
                                         width: rect.width,
                                         height: rect.height)
                highlight.backgroundColor = selectionColor
                highlight.cornerRadius = 2
                textSelectionLayer.addSublayer(highlight)
                selectionLayers.append(highlight)
            }
        }
    }

    private func cursorRect(for offset: Int) -> CGRect {
        let metrics = visualLineMetrics()
        guard !metrics.lines.isEmpty else {
            return CGRect(x: 0, y: textSelectionLayer.bounds.height - metrics.lineHeight, width: cursorWidth, height: metrics.lineHeight)
        }
        var lineIndex = metrics.lines.firstIndex { line in
            offset >= line.range.location && offset <= line.range.location + line.range.length
        } ?? max(metrics.lines.count - 1, 0)
        if offset == (text as NSString).length,
           let lastIndex = metrics.lines.indices.last {
            lineIndex = lastIndex
        }
        let line = metrics.lines[lineIndex]
        let column = min(max(offset - line.range.location, 0), max(line.range.length, 0))
        let x = min(CGFloat(column) * metrics.charWidth, metrics.textWidth)
        let topDownY = CGFloat(lineIndex) * metrics.lineHeight
        return CGRect(x: x,
                      y: textSelectionLayer.bounds.height - topDownY - metrics.lineHeight,
                      width: cursorWidth,
                      height: metrics.lineHeight)
    }

    private func updateCursor() {
        withoutImplicitAnimations {
            if pathPromptMode != nil, viewIsFocused, windowIsActive {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                pathPromptCursorLayer.isHidden = false
                startBlinkingCaret(pathPromptCursorLayer)
                sendTextInputGeometryUpdate(rect: pathPromptCursorLayer.bounds, in: pathPromptCursorLayer)
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
                sendTextInputGeometryUpdate(rect: rect, in: textContentLayer)
            } else {
                editorCaretLayer.isHidden = true
                stopBlinkingCaret(editorCaretLayer)
                outerframeHost.sendTextInputGeometryUpdate(nil)
            }
        }
    }

    private func sendTextInputGeometryUpdate(rect: CGRect, in layer: CALayer) {
        let rootRect = layer.convert(rect, to: rootLayer)
        let topLeftRect = CGRect(x: rootRect.minX,
                                 y: rootLayer.bounds.height - rootRect.maxY,
                                 width: rootRect.width,
                                 height: rootRect.height)
        outerframeHost.sendTextInputGeometryUpdate(OuterframeContentTextInputGeometry(fieldID: editorInputID,
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
        let metrics = visualLineMetrics()
        let cursorTop = CGFloat(lineIndex(for: cursorOffset, metrics: metrics)) * metrics.lineHeight + textInsetY
        let cursorBottom = cursorTop + metrics.lineHeight
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

    private func replace(range: NSRange, with replacement: String) {
        guard let normalized = normalizedRange(range) ?? (range.length == 0 ? NSRange(location: clampedOffset(range.location), length: 0) : nil),
              let swiftRange = Range(normalized, in: text) else {
            return
        }
        withoutImplicitAnimations {
            text.replaceSubrange(swiftRange, with: replacement)
            cursorOffset = normalized.location + (replacement as NSString).length
            selectionAnchor = nil
            updateTextContent(force: true)
            ensureCursorVisible()
            scheduleSave()
        }
    }

    private func insertText(_ value: String) {
        if let selectionRange {
            replace(range: selectionRange, with: value)
            return
        }
        replace(range: NSRange(location: cursorOffset, length: 0), with: value)
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
            move(to: lineStart(for: cursorOffset), modifySelection: false)
        case "moveToEndOfLine", "moveToRightEndOfLine":
            move(to: lineEnd(for: cursorOffset), modifySelection: false)
        case "moveToBeginningOfLineAndModifySelection", "moveToLeftEndOfLineAndModifySelection":
            move(to: lineStart(for: cursorOffset), modifySelection: true)
        case "moveToEndOfLineAndModifySelection", "moveToRightEndOfLineAndModifySelection":
            move(to: lineEnd(for: cursorOffset), modifySelection: true)
        case "moveToBeginningOfDocument", "moveToBeginningOfParagraph":
            move(to: 0, modifySelection: false)
        case "moveToEndOfDocument", "moveToEndOfParagraph":
            move(to: (text as NSString).length, modifySelection: false)
        case "moveToBeginningOfDocumentAndModifySelection", "moveToBeginningOfParagraphAndModifySelection":
            move(to: 0, modifySelection: true)
        case "moveToEndOfDocumentAndModifySelection", "moveToEndOfParagraphAndModifySelection":
            move(to: (text as NSString).length, modifySelection: true)
        case "pageUp":
            scrollOffset = clampedScrollOffset(scrollOffset - editorClipLayer.bounds.height)
            updateViewport()
        case "pageDown":
            scrollOffset = clampedScrollOffset(scrollOffset + editorClipLayer.bounds.height)
            updateViewport()
        case "selectAll":
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

    private func move(to offset: Int, modifySelection: Bool) {
        if !modifySelection, let selectionRange {
            let target = offset < cursorOffset ? selectionRange.location : selectionRange.location + selectionRange.length
            setCursorOffset(target, modifySelection: false)
            return
        }
        setCursorOffset(offset, modifySelection: modifySelection)
    }

    private func moveVertical(delta: Int, modifySelection: Bool) {
        let metrics = visualLineMetrics()
        let currentLine = lineIndex(for: cursorOffset, metrics: metrics)
        let line = metrics.lines[currentLine]
        let column = cursorOffset - line.range.location
        let targetLine = min(max(currentLine + delta, 0), metrics.lines.count - 1)
        let target = metrics.lines[targetLine]
        setCursorOffset(target.range.location + min(max(column, 0), target.range.length), modifySelection: modifySelection)
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

    private func handleMouseDown(point: CGPoint, modifierFlags: NSEvent.ModifierFlags, clickCount: Int) {
        let rootPoint = rootLayer.convert(point, to: rootLayer)
        let headerPoint = headerLayer.convert(rootPoint, from: rootLayer)
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
            selectWord(at: offset)
        } else if clickCount >= 3 {
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
            outerframeHost.showContextMenu(for: attributedSelection() ?? NSAttributedString(string: ""), at: point)
            return
        }
        if clickCount >= 2 {
            selectWord(at: offset)
        } else {
            setCursorOffset(offset, modifySelection: false)
        }
        outerframeHost.showContextMenu(for: attributedSelection() ?? NSAttributedString(string: ""), at: point)
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
        let metrics = visualLineMetrics()
        guard !metrics.lines.isEmpty else { return 0 }
        let lineIndex = min(max(Int(floor(max(textPoint.y, 0) / metrics.lineHeight)), 0), metrics.lines.count - 1)
        let line = metrics.lines[lineIndex]
        let column = min(max(Int(floor(max(textPoint.x, 0) / metrics.charWidth)), 0), line.range.length)
        return clampedOffset(line.range.location + column)
    }

    private func updateCursorShape(at point: CGPoint) {
        let rootPoint = rootLayer.convert(point, to: rootLayer)
        let headerPoint = headerLayer.convert(rootPoint, from: rootLayer)
        if pathControlFrame.contains(headerPoint) {
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
        guard let selected = selectedString(), !selected.isEmpty else { return [] }
        return [OuterframeContentPasteboardItem(representations: [
            OuterframeContentPasteboardRepresentation(typeIdentifier: NSPasteboard.PasteboardType.string.rawValue,
                                                      data: Data(selected.utf8))
        ])]
    }

    private func pasteboardItemsForCut() -> [OuterframeContentPasteboardItem] {
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
                insertText(string)
                return
            }
        }
    }

    private func updateEditingCapabilities() {
        let hasSelection = selectionRange?.length ?? 0 > 0
        outerframeHost.setEditingCapabilities(canCopy: hasSelection, canCut: hasSelection)
    }

    private func handleContextMenuItem(menuID: UUID, itemID: String) {
        if pendingPathMenuIDs.remove(menuID) != nil {
            switch itemID {
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
        if modifierFlags.contains(.command), normalized == "s" {
            saveNow()
        } else if pathPromptMode != nil, normalized == "\u{1b}" {
            cancelPathPrompt()
        } else if pathPromptMode != nil, normalized == "\r" || normalized == "\n" {
            confirmPathPrompt()
        }
    }
}

private func withoutImplicitAnimations(_ updates: () -> Void) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    updates()
    CATransaction.commit()
}
