import Foundation

/// Places islands into a bar: left from the left margin, right from the right margin (its last
/// island outermost), center in the middle. The right zone wins space first (clock, status), then
/// left, then center. An island that would run into the notch or the other zone is hidden along
/// with the ones after it, so the order never shuffles. Empty islands (width 0) take no gap.
public enum LayoutSolver {
    public struct Input: Equatable, Sendable {
        public var width: Double
        public var marginLeft: Double
        public var marginRight: Double
        public var gap: Double
        /// The x range (bar coordinates) the notch covers, if the display has one.
        public var notch: ClosedRange<Double>?
        /// false: the center zone hides (narrow display, notch).
        public var centerAllowed: Bool
        public var left: [Double]
        public var center: [Double]
        public var right: [Double]

        public init(width: Double, marginLeft: Double, marginRight: Double, gap: Double, notch: ClosedRange<Double>? = nil,
                    centerAllowed: Bool = true, left: [Double], center: [Double], right: [Double]) {
            self.width = width
            self.marginLeft = marginLeft
            self.marginRight = marginRight
            self.gap = gap
            self.notch = notch
            self.centerAllowed = centerAllowed
            self.left = left
            self.center = center
            self.right = right
        }
    }

    public struct Output: Equatable, Sendable {
        /// x of each island's left edge; nil when hidden.
        public var left: [Double?]
        public var center: [Double?]
        public var right: [Double?]
    }

    public static func solve(_ i: Input) -> Output {
        // Right: from the right margin leftwards, last island outermost.
        var right = [Double?](repeating: nil, count: i.right.count)
        var edge = i.width - i.marginRight
        let rightLimit = i.notch.map { $0.upperBound + i.gap } ?? i.marginLeft
        var full = false
        for idx in i.right.indices.reversed() {
            let w = i.right[idx]
            guard w > 0, !full else { continue }
            let x = edge - w
            if x < rightLimit { full = true; continue }
            right[idx] = x
            edge = x - i.gap
        }
        let rightMin = right.compactMap { $0 }.min() ?? i.width - i.marginRight

        // Left: from the left margin, up to the notch and the right zone.
        var left = [Double?](repeating: nil, count: i.left.count)
        var x = i.marginLeft
        let leftLimit = min(i.notch.map { $0.lowerBound - i.gap } ?? .infinity, rightMin - i.gap)
        full = false
        for idx in i.left.indices {
            let w = i.left[idx]
            guard w > 0, !full else { continue }
            if x + w > leftLimit { full = true; continue }
            left[idx] = x
            x += w + i.gap
        }
        let leftMax = left.indices.compactMap { k in left[k].map { $0 + i.left[k] } }.max() ?? i.marginLeft

        // Center: all or nothing, centred on the display.
        var center = [Double?](repeating: nil, count: i.center.count)
        let widths = i.center.filter { $0 > 0 }
        if i.centerAllowed, i.notch == nil, !widths.isEmpty {
            let total = widths.reduce(0, +) + Double(widths.count - 1) * i.gap
            var cx = (i.width - total) / 2
            if cx >= leftMax + i.gap, cx + total <= rightMin - i.gap {
                for idx in i.center.indices where i.center[idx] > 0 {
                    center[idx] = cx
                    cx += i.center[idx] + i.gap
                }
            }
        }
        return Output(left: left, center: center, right: right)
    }
}
