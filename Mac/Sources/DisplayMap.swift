import CoreGraphics

/// A snapshot of the display layout. A value type, so the input queue and the
/// main thread never share mutable geometry.
struct DisplayMap: Sendable, Equatable {
    var rects: [CGRect]

    static func current() -> DisplayMap {
        var count: UInt32 = 0
        var rects: [CGRect] = []
        if CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 {
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            if CGGetActiveDisplayList(count, &ids, &count) == .success {
                rects = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
            }
        }
        return DisplayMap(rects: rects.isEmpty ? [CGDisplayBounds(CGMainDisplayID())] : rects)
    }

    /// The nearest point that is actually on a display.
    func clamp(_ p: CGPoint) -> CGPoint {
        if rects.contains(where: { $0.contains(p) }) { return p }
        var best = p
        var bestDist = CGFloat.greatestFiniteMagnitude
        for r in rects {
            let q = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let dist = hypot(q.x - p.x, q.y - p.y)
            if dist < bestDist { bestDist = dist; best = q }
        }
        return best
    }
}
