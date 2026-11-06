import AppKit

@main
struct ElasticScrollTests {
    static func main() {
        var state = ElasticScrollState()
        func scroll(_ delta: CGFloat, offset: CGFloat = 0, phase: NSEvent.Phase = .changed,
                    momentum: NSEvent.Phase = [], precise: Bool = true, time: TimeInterval = 0,
                    maximum: CGFloat = 1000) -> CGFloat {
            state.scroll(by: delta, offset: offset, maximum: maximum, viewport: 600,
                         phase: phase, momentumPhase: momentum, precise: precise, time: time)
        }
        precondition(scroll(50, offset: 300, phase: .began) == 350)
        precondition(state.displacement == 0)
        precondition(scroll(-100, phase: .began) == 0)
        let first = state.displacement
        precondition(first < 0 && abs(first) < 100)
        _ = scroll(-100)
        precondition(state.displacement < first && abs(state.displacement - first) < abs(first))
        state.advance(to: 5)
        precondition(state.displacement < first, "A held gesture must stay stretched")
        _ = scroll(0, phase: .ended, time: 5)
        let released = state.displacement
        state.advance(to: 5.05)
        precondition(state.displacement > released && state.displacement < 0)
        let returning = state.displacement
        precondition(scroll(-500, phase: [], momentum: .began, time: 5.06) == 0)
        precondition(state.displacement == returning, "Momentum must not push a returning view back out")
        state.advance(to: 6)
        precondition(state.displacement == 0)
        precondition(scroll(40, phase: .began, time: 7) == 40)
        state.reset()
        _ = scroll(80, offset: 1000, phase: .began)
        precondition(state.displacement > 0 && state.displacement < 80)
        let reversed = scroll(-100, offset: 1000)
        precondition(abs(reversed - 980) < 0.001 && state.displacement == 0)
        state.reset()
        _ = scroll(40, offset: 990, phase: [], momentum: .changed)
        precondition(state.displacement > 0)
        state.advance(to: 1)
        precondition(state.displacement == 0)
        precondition(scroll(100, offset: 1000, phase: [], momentum: .changed, time: 1) == 1000)
        precondition(state.displacement == 0, "The remaining momentum tail must not create repeated bounces")
        state.reset()
        _ = scroll(-90, phase: [], time: 0)
        let unphased = state.displacement
        state.advance(to: 0.05)
        precondition(state.displacement == unphased)
        state.advance(to: 1)
        precondition(state.displacement == 0, "Precise devices without gesture phases must also settle")
        _ = scroll(-90, phase: .began, maximum: 0)
        precondition(state.displacement < 0)
        _ = scroll(0, phase: .cancelled, time: 1, maximum: 0)
        state.advance(to: 2)
        precondition(state.displacement == 0)
        _ = scroll(90, phase: .began, maximum: 0)
        precondition(state.displacement > 0)
        _ = scroll(-500, precise: false)
        precondition(state.displacement == 0 && !state.isTracking)
        print("PASS elastic scrolling: resistance, reversal, both edges, short documents, release/cancel, momentum, and phase-less devices")
    }
}
