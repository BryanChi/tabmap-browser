import SwiftUI
import TabMapCore

// The SwiftUI pieces that go with gesture navigation.

/// Where each card's thumbnail sits in the overview, so a page can shrink onto its own card.
struct CardFramesKey: PreferenceKey {
    static var defaultValue: [TabID: CGRect] = [:]

    static func reduce(value: inout [TabID: CGRect], nextValue: () -> [TabID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Reports this view's frame as the card thumbnail of `id`.
    func reportsCardFrame(for id: TabID) -> some View {
        background(GeometryReader { geometry in
            Color.clear.preference(key: CardFramesKey.self, value: [id: geometry.frame(in: .global)])
        })
    }
}

/// The map overview, sitting underneath the page. It fades in as the page zooms out onto its card.
struct OverviewLayer: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var zoom = GestureNavigator.shared.zoom

    var body: some View {
        ZStack {
            if store.overviewShown || zoom.interactive {
                MapOverview()
                    .opacity(zoom.interactive ? min(1, Double(zoom.progress) * 2.4) : 1)
                    .allowsHitTesting(store.overviewShown && !zoom.interactive)
                    .onPreferenceChange(CardFramesKey.self) { frames in
                        Task { @MainActor in GestureNavigator.shared.cardFrames = frames }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Fully shown, the overview is on top and takes the clicks. During a zoom it is underneath,
        // so the shrinking page is seen in front of it.
        .zIndex(store.overviewShown && !zoom.interactive ? 2 : 0)
    }
}

/// Fades the pinned sidebar out as the map overview takes over the window.
struct FadesIntoOverview: ViewModifier {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject private var zoom = GestureNavigator.shared.zoom

    func body(content: Content) -> some View {
        let hidden = store.overviewShown && !zoom.interactive
        content
            .opacity(hidden ? 0 : (zoom.interactive ? max(0, 1 - Double(zoom.progress) * 2.4) : 1))
            .allowsHitTesting(!hidden && !zoom.interactive)
    }
}

/// A small map of dots, shown while swiping: one dot per open tab, rows as in the tab map.
struct MapHUD: View {
    @ObservedObject private var hud = GestureNavigator.shared.hud

    private let maxRows = 7
    private let maxColumns = 13

    var body: some View {
        let rows = window(hud.rows)
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(row, id: \.self) { id in
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(color(for: id))
                            .frame(width: id == hud.current || id == hud.target ? 14 : 9, height: 9)
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.black.opacity(0.78)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 10, y: 3)
        .opacity(hud.visible && !rows.isEmpty ? 1 : 0)
        .scaleEffect(hud.visible ? 1 : 0.9)
        .animation(.easeOut(duration: 0.18), value: hud.visible)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hud.current)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hud.target)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 26)
        .allowsHitTesting(false)
    }

    private func color(for id: TabID) -> Color {
        if id == hud.current { return .white }
        if id == hud.target { return .accentColor }
        return Color.white.opacity(0.28)
    }

    /// Keeps the dot map small: only the rows and columns around where you are.
    private func window(_ rows: [[TabID]]) -> [[TabID]] {
        guard let current = hud.current,
              let r = rows.firstIndex(where: { $0.contains(current) }),
              let c = rows[r].firstIndex(of: current) else {
            return Array(rows.prefix(maxRows)).map { Array($0.prefix(maxColumns)) }
        }
        let firstRow = max(0, min(r - maxRows / 2, rows.count - maxRows))
        let lastRow = min(rows.count, firstRow + maxRows)
        return rows[firstRow..<lastRow].map { row in
            guard row.count > maxColumns else { return row }
            let firstColumn = max(0, min(c - maxColumns / 2, row.count - maxColumns))
            return Array(row[firstColumn..<firstColumn + maxColumns])
        }
    }
}
