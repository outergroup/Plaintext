import SwiftUI
import WebKit

@MainActor final class State: ObservableObject {
    let webView = WKWebView()
    var started = false
    var keyboardShown = false
    init() {
        setbuf(stdout, nil)
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
    func checkLandscape() async throws {
        guard let scene = webView.window?.windowScene else { throw NSError(domain: "No scene", code: 1) }
        for orientation: UIInterfaceOrientationMask in [.landscapeLeft, .landscapeRight] {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation))
            try await Task.sleep(for: .seconds(1))
            guard let fixture=Bundle.main.url(forResource: "fixture", withExtension: "html") else { exit(1) }
            _ = try await webView.evaluateJavaScript("window.previousFixture=true")
            webView.loadFileURL(fixture, allowingReadAccessTo: fixture.deletingLastPathComponent())
            for _ in 0..<100 {
                if (try? await webView.evaluateJavaScript("!window.previousFixture && !!document.documentElement.dataset.rail && typeof state!=='undefined'")) as? Bool == true { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            _ = try await webView.evaluateJavaScript("state.active.dirty=true;renderDocument()")
            print("PASS arrival already in landscape without an orientation event")
            let cover = try await webView.evaluateJavaScript("""
            (() => { const toolbar=document.querySelector('header').getBoundingClientRect(), editor=document.querySelector('#editor').getBoundingClientRect();
            return {width:innerWidth, angle:screen.orientation.angle, side:document.documentElement.dataset.rail,
                    left:toolbar.left,right:toolbar.right,editorLeft:editor.left,editorRight:editor.right,
                    padding:parseFloat(getComputedStyle(document.querySelector('main')).paddingTop), info:getComputedStyle(document.querySelector('#document-info')).display}; })()
            """) as? [String: Any]
            print("LANDSCAPE \(scene.effectiveGeometry.interfaceOrientation.rawValue): \(String(describing: cover)), native \(webView.bounds), safe \(webView.safeAreaInsets), adjusted \(webView.scrollView.adjustedContentInset)")
            guard let cover, let width=cover["width"] as? Double, abs(width-webView.bounds.width)<2,
                  let side=cover["side"] as? String, !side.isEmpty,
                  let padding=cover["padding"] as? Double, padding==0,
                  let left=cover["left"] as? Double, let right=cover["right"] as? Double,
                  let editorLeft=cover["editorLeft"] as? Double, let editorRight=cover["editorRight"] as? Double,
                  (side=="left" ? right<=editorLeft+1 : left>=editorRight-1) else {
                print("FAIL edge-to-edge rail did not occupy only the empty margin");exit(1)
            }
            _ = try await webView.evaluateJavaScript("document.querySelector('#editor').dispatchEvent(new PointerEvent('pointerup',{pointerType:'touch'}))")
            try await Task.sleep(for: .seconds(1))
            let keyboard = try await webView.evaluateJavaScript("({height:visualViewport.height,toolbarTop:document.querySelector('header').getBoundingClientRect().top-visualViewport.offsetTop,editorTop:document.querySelector('#editor').getBoundingClientRect().top-scrollY,side:document.documentElement.dataset.rail})")
            print("LANDSCAPE KEYBOARD \(String(describing: keyboard))")
            guard let keyboard=keyboard as? [String: Any], let height=keyboard["height"] as? Double,
                  let toolbarTop=keyboard["toolbarTop"] as? Double, toolbarTop>=4 && toolbarTop<=16,
                  height>=toolbarTop+44, keyboard["side"] as? String==side else {
                print("FAIL landscape keyboard obscured or moved the margin controls");exit(1)
            }
            _ = try await webView.evaluateJavaScript("Object.defineProperty(visualViewport,'height',{configurable:true,value:94});visualViewport.dispatchEvent(new Event('resize'))")
            try await Task.sleep(for: .milliseconds(100))
            let overflow = try await webView.evaluateJavaScript("""
            (() => {document.querySelector('#document-menu').open=true;
                const r=document.querySelector('#document-menu>summary').getBoundingClientRect(),save=document.querySelector('#save'),editor=document.querySelector('#editor');
                document.querySelector('#document-menu').open=false;
                editor.focus({preventScroll:true});editor.setSelectionRange(12,17);
                const down=new PointerEvent('pointerdown',{bubbles:true,cancelable:true});
                const mouse=new MouseEvent('mousedown',{bubbles:true,cancelable:true});
                save.dispatchEvent(down);save.dispatchEvent(mouse);
                return document.documentElement.hasAttribute('data-rail-overflow') && getComputedStyle(save).display!=='none' && getComputedStyle(document.querySelector('#document-info')).display==='none' && r.height===44 && r.bottom<=94 && !save.hidden && save.getBoundingClientRect().bottom<=94 && !document.querySelector('#overflow-save') && down.defaultPrevented && mouse.defaultPrevented && document.activeElement===editor && editor.selectionStart===12 && editor.selectionEnd===17;})()
            """)
            guard overflow as? Bool == true else { print("FAIL compact landscape overflow: \(String(describing: overflow))");exit(1) }
            _ = try await webView.evaluateJavaScript("state.active.dirty=false;renderDocument()")
            let contextual = try await webView.evaluateJavaScript("document.querySelector('#save').hidden") as? Bool
            guard contextual==true else { print("FAIL clean landscape Save visibility");exit(1) }
            _ = try await webView.evaluateJavaScript("state.active.dirty=true;renderDocument();document.querySelector('#document-menu').open=false;delete visualViewport.height;visualViewport.dispatchEvent(new Event('resize'))")
            try await Task.sleep(for: .milliseconds(100))
            print("CAPTURE landscape-\(Int(cover["angle"] as? Double ?? 0))")
            try await Task.sleep(for: .seconds(3))
            _ = try await webView.evaluateJavaScript("document.querySelector('#editor').blur();document.querySelector('meta[name=viewport]').content='width=device-width,initial-scale=1'")
            try await Task.sleep(for: .seconds(1))
            let insetWidth = try await webView.evaluateJavaScript("innerWidth") as? Double ?? 0
            guard insetWidth < width-50 else { print("FAIL ordinary page was not inset: \(insetWidth) vs \(width)");exit(1) }
            _ = try await webView.evaluateJavaScript("document.querySelector('meta[name=viewport]').content='width=device-width,initial-scale=1,viewport-fit=cover'")
            try await Task.sleep(for: .milliseconds(300))
            print("PASS landscape cover and default viewport contract")
        }
        for mode in ["auto", "cover", "auto"] {
            webView.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1,viewport-fit=\(mode)'><title>\(mode)</title><p>Viewport navigation check</p>", baseURL: nil)
            for _ in 0..<100 {
                if (try? await webView.evaluateJavaScript("document.title")) as? String == mode { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            try await Task.sleep(for: .milliseconds(300))
            let width = try await webView.evaluateJavaScript("innerWidth") as? Double ?? 0
            let expected = mode == "cover" ? webView.bounds.width : webView.bounds.width-webView.safeAreaInsets.left-webView.safeAreaInsets.right
            guard abs(width-expected)<2 else { print("FAIL viewport navigation to \(mode): \(width), expected \(expected)");exit(1) }
        }
        print("PASS navigation between ordinary and edge-to-edge pages")
    }
    func run() async {
        do {
            for _ in 0..<100 {
                if (try? await webView.evaluateJavaScript("document.querySelector('#editor') !== null")) as? Bool == true { break }
                try await Task.sleep(for:.milliseconds(200))
            }
            try await Task.sleep(for:.milliseconds(500))
            try await checkLayout("initial document")
            let dismissal = try await webView.evaluateJavaScript("""
            (() => {
                const editor=document.querySelector('#editor'),menu=document.querySelector('#document-menu');
                editor.blur();editor.setSelectionRange(12,12);menu.open=true;
                const down=new PointerEvent('pointerdown',{bubbles:true,cancelable:true,pointerId:1});
                const up=new PointerEvent('pointerup',{bubbles:true,cancelable:true,pointerId:1});
                const click=new MouseEvent('click',{bubbles:true,cancelable:true,detail:1});
                editor.dispatchEvent(down);editor.dispatchEvent(up);editor.dispatchEvent(click);
                const dismissed=!menu.open && down.defaultPrevented && up.defaultPrevented && click.defaultPrevented && document.activeElement!==editor && editor.selectionStart===12;
                menu.open=true;
                const inside=new PointerEvent('pointerdown',{bubbles:true,cancelable:true,pointerId:2});
                document.querySelector('#download').dispatchEvent(inside);
                const insideWorks=menu.open && !inside.defaultPrevented;
                menu.open=false;
                const next=new PointerEvent('pointerdown',{bubbles:true,cancelable:true,pointerId:3});
                editor.dispatchEvent(next);
                return dismissed && insideWorks && !next.defaultPrevented;
            })()
            """) as? Bool
            guard dismissal==true else { print("FAIL outside tap changed focus or passed through the menu");exit(1) }
            print("PASS outside tap dismisses without editor focus or caret movement; menu actions and subsequent taps remain enabled")

            let clean = try await webView.evaluateJavaScript("document.querySelector('#save').hidden && getComputedStyle(document.querySelector('#document-info')).display==='none'") as? Bool
            guard clean==true else { print("FAIL clean portrait controls");exit(1) }
            _ = try await webView.evaluateJavaScript("state.active.dirty=true;renderDocument()")
            let edited = try await webView.evaluateJavaScript("!document.querySelector('#save').hidden && document.querySelector('#save').textContent==='Save' && document.querySelector('#save').getAttribute('aria-label')==='Save' && getComputedStyle(document.querySelector('#document-info')).display==='none'") as? Bool
            guard edited==true else { print("FAIL edited portrait Save button");exit(1) }

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
            try await checkLandscape()
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
            if geometry.size.width > 600 {
                VStack(spacing: 0) {
                    Text("Browser").frame(height: 32)
                    MobileWebView(webView:state.webView,allowsReturnToServerSelection:false,
                        onServerBackSwipe:{_,_ in},onPageTap:{},onPageDrag:{_ in})
                        .ignoresSafeArea(.container, edges: .horizontal)
                }
            } else {
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
        }
        .ignoresSafeArea(.container,edges:.bottom)
        .onAppear { if !state.started { state.started=true; Task { await state.run() } } }
    }
}
@main struct Test: App { var body: some Scene { WindowGroup { MobileBrowserKeyboardHost(shortcuts: [], content: AnyView(Root())).ignoresSafeArea(.container) } } }
