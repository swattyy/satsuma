import Foundation
import SatsumaCore

/// Hover springs: the new segment lights up quickly and the old one fades out more slowly, both without
/// bounce, so the highlight never dips while moving from one segment to the next (Windows 1.0.2 timing).
enum HoverTiming {
    static let inResponse = 0.1
    static let outResponse = 0.35
}

final class SegmentState {
    let item: WheelItem
    let appear = Spring(0, response: 0.44, damping: 0.76)
    let hover = Spring(0, response: HoverTiming.inResponse, damping: 1)
    let press = Spring(0, response: 0.16, damping: 0.55)
    init(item: WheelItem) { self.item = item }
    var springs: [Spring] { [appear, hover, press] }
}

final class WheelState {
    var layout = WheelLayout(scale: 1, showHints: true)
    var dark = false
    let open = Spring(0, response: 0.36, damping: 0.72)
    let fade = Spring(0, response: 0.14, damping: 1)
    let hubPop = Spring(0, response: 0.34, damping: 0.6)
    let spin = Spring(0, response: 0.55, damping: 0.82)
    var segments: [SegmentState] = []
    var leaving: [SegmentState] = []
    var hover = -1
    var kind: WheelKind = .convert
    var content: WheelContent?
    var loading = true

    var hubFrom = HubText(), hubTo = HubText()
    let hubFade = Spring(1, response: 0.2, damping: 1)
    let chipX = Spring(0, response: 0.32, damping: 0.78)
    /// 1 while the drag has left the wheel.
    let dim = Spring(0, response: 0.2, damping: 1)

    var allSprings: [Spring] {
        [open, fade, hubPop, spin, hubFade, chipX, dim] + segments.flatMap(\.springs) + leaving.flatMap(\.springs)
    }

    static func applyHover(_ st: WheelState, from: Int, to: Int) {
        if from >= 0 && from < st.segments.count { st.segments[from].hover.configure(response: HoverTiming.outResponse, damping: 1).to(0) }
        if to >= 0 && to < st.segments.count { st.segments[to].hover.configure(response: HoverTiming.inResponse, damping: 1).to(1) }
        st.hover = to
    }
}

struct HubText: Equatable {
    var caption = ""
    var title = ""
    var accent = false
}
