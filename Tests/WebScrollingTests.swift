import SwiftUI
import WebKit

@MainActor final class State: ObservableObject {
    let webView = WKWebView()
    var started = false
    var keyboardShown = false
    init() {
        NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keyboardShown = true }
        }
        guard let url = Bundle.main.url(forResource: "fixture", withExtension: "html") else {
            fatalError("Missing scrolling fixture")
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    func checkLayout(_ label: String) async throws {
        let result = try await webView.evaluateJavaScript("""
        (() => {
            const editor = document.querySelector('#editor');
            return {top:document.querySelector('header').getBoundingClientRect().top,
                    innerOverflow:editor.scrollHeight-editor.clientHeight,
                    viewport:visualViewport.height, width:document.documentElement.clientWidth,
                    pageWidth:document.documentElement.scrollWidth};
        })()
        """) as? [String: NSNumber]
        let insets = webView.scrollView.adjustedContentInset
        let bottomInset = max(insets.bottom, webView.window?.safeAreaInsets.bottom ?? 0)
        let minimumHeight = Double(webView.bounds.height - insets.top - bottomInset)
        guard let result, let top=result["top"], let overflow=result["innerOverflow"],
              let viewport=result["viewport"], let width=result["width"], let pageWidth=result["pageWidth"],
              abs(top.doubleValue)<1, overflow.doubleValue<=1, viewport.doubleValue>100,
              viewport.doubleValue >= minimumHeight-2, viewport.doubleValue <= Double(webView.bounds.height)+2,
              pageWidth.doubleValue<=width.doubleValue+1 else {
            print("FAIL \(label): \(String(describing:result)), native height \(webView.bounds.height)")
            exit(1)
        }
        print("PASS \(label): toolbar visible, one vertical scrollbar, keyboard not counted twice")
    }
    func checkAnimation() async throws {
        let frames = try await webView.evaluateJavaScript("toolbarFrames") as? [Double] ?? []
        print("ANIMATION toolbar range \(frames.min() ?? 0)...\(frames.max() ?? 0), \(frames.count) frames")
        guard !frames.isEmpty, frames.allSatisfy({ abs($0) < 1 }) else {
            print("FAIL toolbar moved during keyboard animation")
            exit(1)
        }
    }
    func run() async {
        do {
            for _ in 0..<100 {
                if (try? await webView.evaluateJavaScript("document.querySelector('#editor') !== null")) as? Bool == true { break }
                try await Task.sleep(for:.milliseconds(200))
            }
            try await Task.sleep(for:.milliseconds(500))
            try await checkLayout("initial document")
            _ = try await webView.evaluateJavaScript("""
            window.toolbarFrames = [];
            function sampleToolbar() {
                const top = document.querySelector('header').getBoundingClientRect().top - visualViewport.offsetTop;
                toolbarFrames.push(top);
                requestAnimationFrame(sampleToolbar);
            }
            requestAnimationFrame(sampleToolbar);
            """)
            for position in [4200, 700, 3000] {
                keyboardShown = false
                _ = try await webView.evaluateJavaScript("toolbarFrames=[];var e=document.querySelector('#editor');window.scrollTo(0,Math.max(0,\(position)/e.value.length*e.scrollHeight-450));e.setSelectionRange(\(position),\(position))")
                try await Task.sleep(for: .milliseconds(250))
                _ = try await webView.evaluateJavaScript("toolbarFrames=[];document.querySelector('#editor').dispatchEvent(new PointerEvent('pointerup',{pointerType:'touch'}))")
                for _ in 0..<60 {
                    try await Task.sleep(for: .milliseconds(16))
                    let scrollView = webView.scrollView
                    if scrollView.layer.animation(forKey: "bounds.origin") != nil,
                       let presentation = scrollView.layer.presentation() {
                        guard abs(presentation.bounds.minY - scrollView.bounds.minY) < 1 else {
                            print("FAIL native scroll animation diverged from the rendered viewport")
                            exit(1)
                        }
                    }
                }
                try await checkAnimation()
                guard keyboardShown else { print("FAIL software keyboard did not open"); exit(1) }
                try await checkLayout("focus after scrolling at \(position)")
                _ = try await webView.evaluateJavaScript("toolbarFrames=[];document.querySelector('#editor').blur()")
                for _ in 0..<60 {
                    try await Task.sleep(for: .milliseconds(16))
                    let scrollView = webView.scrollView
                    if scrollView.layer.animation(forKey: "bounds.origin") != nil,
                       let presentation = scrollView.layer.presentation() {
                        guard abs(presentation.bounds.minY - scrollView.bounds.minY) < 1 else {
                            print("FAIL native scroll animation diverged from the rendered viewport")
                            exit(1)
                        }
                    }
                }
                try await checkAnimation()
                try await checkLayout("keyboard dismissed")
            }
            _ = try await webView.evaluateJavaScript("document.querySelector('#editor').setAttribute('wrap','off')")
            try await Task.sleep(for:.milliseconds(300))
            try await checkLayout("wrapping disabled")
            _ = try await webView.evaluateJavaScript("document.querySelector('#editor').value='Short document';window.scrollTo(0,0)")
            try await Task.sleep(for:.milliseconds(300))
            try await checkLayout("document shrinks")
            print("PASS all web document scrolling checks")
            exit(0)
        } catch { print("FAIL \(error)"); exit(1) }
    }
}

struct Root: View {
    @StateObject var state = State()
    @StateObject var motion = MobilePortraitChromeMotion()
    @State var expansion: CGFloat = 1
    @State var initial: CGFloat?
    func drag(_ value: MobilePageDragValue) {
        switch value.phase {
        case .began:
            let current=motion.presentationExpansion ?? expansion
            if current>0 { initial=current }
            fallthrough
        case .changed:
            guard let initial else { return }
            let next=min(initial,max(0,initial+value.translation.y / max(1,motion.collapseDistance ?? 80)))
            let native=motion.scrub(to:next)
            if !native || next==0 { expansion=next }
        case .ended,.cancelled:
            guard initial != nil else { return }
            initial=nil
            withAnimation(.snappy(duration:0.3)) { expansion=(motion.presentationExpansion ?? expansion)>=0.5 ? 1:0 }
        }
    }
    var body: some View {
        GeometryReader { geometry in
            MobilePortraitChromeSurface(
                layout:.init(size:geometry.size,firstLeading:0,firstTrailing:0,windowLeading:0,windowTrailing:0,
                             topClearance:0,collapsedClearance:0,historyWidth:44,homeProgress:1,addressProgress:1,
                             keepsExpanded:false,tabHeight:0,compactLift:0),
                expansion:expansion,isDragging:false,motion:motion,
                top:AnyView(Text("Browser")),history:AnyView(EmptyView()),expandedAddress:AnyView(Text("Address")),
                compactAddress:AnyView(Text("Address")),tabs:AnyView(EmptyView()),
                browser:AnyView(MobileWebView(webView:state.webView,allowsReturnToServerSelection:false,
                    onServerBackSwipe:{_,_ in},onPageTap:{withAnimation(.snappy(duration:0.3)){expansion=0}},
                    onPageDrag:drag,portraitMotion:motion)))
        }
        .ignoresSafeArea(.container,edges:.bottom)
        .onAppear { if !state.started { state.started=true; Task { await state.run() } } }
    }
}
@main struct Test: App { var body: some Scene { WindowGroup { MobileBrowserKeyboardHost(shortcuts: [], content: AnyView(Root())).ignoresSafeArea(.container) } } }
