import SwiftUI
import TabMapCore

// A link that opens a new tab (target=_blank, window.open, ⇧⌘-click) hops through the map:
// the page shrinks onto its card in the overview, the new tab's card pops into its row beside it,
// then the view zooms into the new page. The timing lives in GestureNavigator (hopToNewTab).

/// The tab whose card is popping into the map right now.
@MainActor
final class NewTabArrival: ObservableObject {
    static let shared = NewTabArrival()
    @Published var arriving: TabID?
    private init() {}
}

/// On a map card: when it is the tab just opened, it grows in from its left edge with a little bounce.
/// Only a render effect, so the card's reported frame (what the zoom lands on) stays put.
struct NewTabPop: ViewModifier {
    let tabID: TabID
    @ObservedObject private var arrival = NewTabArrival.shared
    @State private var landed = true

    func body(content: Content) -> some View {
        content
            .scaleEffect(landed ? 1 : 0.5, anchor: .leading)
            .opacity(landed ? 1 : 0)
            .onAppear { if arrival.arriving == tabID { pop() } }
            .onChange(of: arrival.arriving) { id in if id == tabID { pop() } }
    }

    private func pop() {
        var hidden = Transaction()
        hidden.disablesAnimations = true
        withTransaction(hidden) { landed = false }
        // Starts while the page is still shrinking, so it is landing as the map comes up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.66)) { landed = true }
        }
    }
}
