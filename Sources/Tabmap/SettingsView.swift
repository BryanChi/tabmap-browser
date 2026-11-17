import SwiftUI
import TabMapCore

private struct Choice<Value: Hashable>: Identifiable {
    let label: String
    let value: Value
    var id: Value { value }
    init(_ label: String, _ value: Value) {
        self.label = label
        self.value = value
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: BrowserStore
    @AppStorage(GestureNavigator.edgeSwipeKey) private var edgeSwipe = true
    @AppStorage(MergeAdvisor.enabledKey) private var mergeSuggestions = true
    @AppStorage(BrowserStore.jumpToDuplicatesKey) private var jumpToDuplicates = true
    @AppStorage(BookmarkStore.hotCornerKey) private var bookmarkCorner = BookmarkStore.HotCorner.off.rawValue
    @AppStorage(BookmarkStore.watchKey) private var watchBookmarks = true

    private static let sleepChoices: [Choice<TimeInterval>] = [
        Choice("5 minutes", 5 * 60), Choice("15 minutes", 15 * 60), Choice("30 minutes", 30 * 60),
        Choice("1 hour", 3600), Choice("4 hours", 4 * 3600),
    ]
    private static let closeChoices: [Choice<TimeInterval>] = [
        Choice("1 hour", 3600), Choice("4 hours", 4 * 3600), Choice("12 hours", 12 * 3600), Choice("1 day", 86400),
        Choice("3 days", 3 * 86400), Choice("1 week", 7 * 86400),
    ]
    private static let purgeChoices: [Choice<TimeInterval>] = [
        Choice("1 week", 7 * 86400), Choice("1 month", 30 * 86400), Choice("3 months", 90 * 86400), Choice("1 year", 365 * 86400),
    ]
    private static let searchChoices: [Choice<String>] = [
        Choice("Google", "https://www.google.com/search?q=%s"),
        Choice("DuckDuckGo", "https://duckduckgo.com/?q=%s"),
        Choice("Bing", "https://www.bing.com/search?q=%s"),
        Choice("Kagi", "https://kagi.com/search?q=%s"),
    ]

    var body: some View {
        Form {
            Section {
                Picker("Unload a tab's page after", selection: binding(\.sleepAfter)) {
                    ForEach(Self.sleepChoices) { Text($0.label).tag($0.value) }
                }
                Picker("Close a tab after", selection: binding(\.closeAfter)) {
                    ForEach(Self.closeChoices) { Text($0.label).tag($0.value) }
                }
                Picker("Forget a closed tab after", selection: binding(\.purgeAfter)) {
                    ForEach(Self.purgeChoices) { Text($0.label).tag($0.value) }
                }
                Text("Times count from when you last used the tab. Pinned tabs and the tab in front are never closed. Closed tabs stay in the map below the horizon until they are forgotten.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Stepper("Keep at most \(store.map.settings.maxLoadedTabs) pages in memory",
                        value: binding(\.maxLoadedTabs), in: 2...60)
                Picker("Search with", selection: binding(\.searchTemplate)) {
                    ForEach(Self.searchChoices) { Text($0.label).tag($0.value) }
                }
                Text(store.trailNamer.modelAvailable
                     ? "Trail names and descriptions come from the on-device Apple Intelligence model. Nothing leaves this Mac."
                     : "Trail names come from page titles on this Mac (the Apple Intelligence model needs macOS 26 with Apple Intelligence turned on).")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Swipe past the edge of a page to move through the map", isOn: $edgeSwipe)
                Text("With this off, hold ⌥ while swiping with two fingers to move between tabs.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Section {
                Toggle("Go to the existing tab instead of opening a page twice", isOn: $jumpToDuplicates)
                Text("Hold ⌥ when pressing Return in the address bar, or use Duplicate Tab (⇧⌘D), to get a copy anyway.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Toggle("Suggest joining rows that are about the same thing", isOn: $mergeSuggestions)
                    .onChange(of: mergeSuggestions) { _ in store.mergeAdvisor.settingChanged() }
                Text(MergeAdvisor.modelAvailable
                     ? "Rows are compared on this Mac by Apple Intelligence. Nothing is joined until you press Join."
                     : "Rows are compared on this Mac by their page titles and sites. Nothing is joined until you press Join.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Picker("Show bookmarks when the pointer rests in a corner", selection: $bookmarkCorner) {
                    ForEach(BookmarkStore.HotCorner.allCases) { Text($0.label).tag($0.rawValue) }
                }
                Toggle("Check saved pages for changes once a day", isOn: $watchBookmarks)
                Text(BookmarkStore.shared.filer.modelAvailable
                     ? "Bookmarks are filed and tagged on this Mac by Apple Intelligence. Checking for changes fetches each saved page without your cookies."
                     : "Bookmarks are filed and tagged on this Mac from their site and words. Checking for changes fetches each saved page without your cookies.")
                    .font(.system(size: 11)).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<MapSettings, Value>) -> Binding<Value> {
        Binding(
            get: { store.map.settings[keyPath: keyPath] },
            set: { newValue in store.updateSettings { $0[keyPath: keyPath] = newValue } }
        )
    }
}
