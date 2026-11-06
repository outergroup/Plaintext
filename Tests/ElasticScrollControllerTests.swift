import AppKit
import QuartzCore

@MainActor
final class OuterframeHost {
    var callbacks: [UUID: (Double) -> Void] = [:]
    func registerDisplayLinkCallback(_ callback: @escaping (Double) -> Void) -> UUID {
        let id = UUID()
        callbacks[id] = callback
        return id
    }
    func stopDisplayLinkCallback(_ id: UUID) { callbacks[id] = nil }
}

@main
struct ElasticControllerTests {
    @MainActor static func main() {
        let host = OuterframeHost()
        let controller = ElasticScrollController(host: host)
        let root = CALayer()
        root.frame = CGRect(x: 0, y: 0, width: 600, height: 600)
        let clip = CALayer()
        clip.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
        clip.masksToBounds = true
        root.addSublayer(clip)
        let first = CALayer()
        first.frame = clip.bounds
        clip.addSublayer(first)
        let second = CALayer()
        let offset = controller.scroll("first", by: -100, offset: 0, maximum: 1000, viewport: 600,
            phase: .began, momentumPhase: [], precise: true) { [first] }
        precondition(offset == 0)
        precondition(first.sublayerTransform.m42 < 0)
        precondition(host.callbacks.count == 1)
        _ = controller.scroll("second", by: 100, offset: 1000, maximum: 1000, viewport: 600,
            phase: .began, momentumPhase: [], precise: true, direction: -1) { [second] }
        precondition(CATransform3DIsIdentity(first.sublayerTransform))
        precondition(second.sublayerTransform.m42 < 0)
        precondition(host.callbacks.count == 1)
        controller.reset()
        precondition(CATransform3DIsIdentity(second.sublayerTransform))
        precondition(host.callbacks.isEmpty)
        _ = controller.scroll("first", by: -100, offset: 0, maximum: 1000, viewport: 500,
            phase: .began, momentumPhase: [], precise: true) { [first] }
        let stretch = first.sublayerTransform.m42
        let click = controller.finish(at: CGPoint(x: 100, y: 100), in: root)
        precondition(abs(click.y - (100 - stretch)) < 0.001)
        precondition(CATransform3DIsIdentity(first.sublayerTransform))
        precondition(host.callbacks.isEmpty)
        _ = controller.scroll("first", by: -100, offset: 0, maximum: 1000, viewport: 500,
            phase: .began, momentumPhase: [], precise: true) { [first] }
        let toolbarClick = CGPoint(x: 100, y: 550)
        precondition(controller.finish(at: toolbarClick, in: root) == toolbarClick)
        print("PASS elastic presentation: bounded offsets, flipped coordinates, surface switching, and callback cleanup")
    }
}
