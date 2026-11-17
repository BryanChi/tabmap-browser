import Foundation

/// How wide each tab in the tab bar is, Safari style.
///
/// - Few tabs share the whole bar equally, so one tab fills it and two take half each.
/// - Once equal shares get narrower than `activeMinimum`, the current tab keeps that width
///   (so its title stays readable) and the others share what is left.
/// - Those others shrink down to `inactiveMinimum` (about a favicon). Past that the bar scrolls.
public struct TabBarLayout: Equatable {
    public struct Metrics: Equatable {
        /// Width the current tab keeps once tabs get crowded.
        public var activeMinimum: Double
        /// Narrowest any other tab gets before the bar starts to scroll.
        public var inactiveMinimum: Double
        /// Below this an inactive tab shows only its icon.
        public var titleMinimum: Double

        public init(activeMinimum: Double = 200, inactiveMinimum: Double = 36, titleMinimum: Double = 76) {
            self.activeMinimum = activeMinimum
            self.inactiveMinimum = inactiveMinimum
            self.titleMinimum = titleMinimum
        }
    }

    /// One width per tab, in order.
    public var widths: [Double]
    /// Sum of the widths. More than the space available when the bar has to scroll.
    public var totalWidth: Double { widths.reduce(0, +) }
    public var scrolls: Bool

    public init(widths: [Double], scrolls: Bool) {
        self.widths = widths
        self.scrolls = scrolls
    }

    /// - Parameters:
    ///   - count: number of tabs.
    ///   - active: index of the current tab, or nil when none of them is current.
    ///   - available: width of the space for tabs.
    public static func make(count: Int, active: Int?, available: Double, metrics: Metrics = Metrics()) -> TabBarLayout {
        guard count > 0 else { return TabBarLayout(widths: [], scrolls: false) }
        let space = max(0, available)
        let equal = space / Double(count)
        let crowdedAt = active == nil ? metrics.inactiveMinimum : metrics.activeMinimum
        if equal >= crowdedAt || count == 1 {
            return TabBarLayout(widths: Array(repeating: max(equal, metrics.inactiveMinimum), count: count),
                                scrolls: equal < metrics.inactiveMinimum)
        }
        guard let active, active >= 0, active < count else {
            // No current tab: everyone shrinks evenly to the minimum, then the bar scrolls.
            return TabBarLayout(widths: Array(repeating: metrics.inactiveMinimum, count: count), scrolls: true)
        }
        let activeWidth = min(metrics.activeMinimum, space)
        let share = (space - activeWidth) / Double(count - 1)
        let other = max(share, metrics.inactiveMinimum)
        var widths = Array(repeating: other, count: count)
        widths[active] = activeWidth
        return TabBarLayout(widths: widths, scrolls: share < metrics.inactiveMinimum)
    }
}
