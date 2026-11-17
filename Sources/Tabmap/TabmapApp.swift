import AppKit
import SwiftUI
import TabMapCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Needed when launched with `swift run`, where there is no app bundle to say this is a regular app.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationWillTerminate(_ notification: Notification) {
        BrowserStore.shared.persistEverything()
        DownloadStore.shared.saveNow()
    }

    /// A file dropped on the Dock icon: go to the page it was downloaded from.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.isFileURL { DownloadStore.shared.goToSource(ofFile: url) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

@main
@MainActor
struct TabmapApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = BrowserStore.shared
    @ObservedObject private var dock = AppDock.shared
    @ObservedObject private var reader = ReaderController.shared

    var body: some Scene {
        Window("Tabmap", id: "main") {
            ContentView()
                .environmentObject(store)
                .environmentObject(store.favicons)
                .frame(minWidth: 760, minHeight: 480)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Trail") { store.newTrail() }
                    .keyboardShortcut("t", modifiers: [.command])
                Button("New Tab in This Trail") { store.newTabInTrail() }
                    .keyboardShortcut("t", modifiers: [.command, .option])
                Button("Duplicate Tab") { store.duplicateActiveTab() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Open Location") { store.focusAddress() }
                    .keyboardShortcut("l", modifiers: [.command])
                Divider()
                Button("Close Tab") { store.closeActiveTab() }
                    .keyboardShortcut("w", modifiers: [.command])
                Button("Reopen Closed Tab") { store.reopenLastClosed() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
            }
            CommandGroup(after: .sidebar) {
                Button("Show Tab Map") { store.toggleOverview() }
                    .keyboardShortcut("e", modifiers: [.command])
                Button("Downloads") { DownloadStore.shared.togglePanel() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                Button(store.sidebarShown ? "Unpin Map Sidebar" : "Pin Map Sidebar Open") {
                    store.sidebarShown.toggle()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("Reload Page") { store.reload() }
                    .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button(reader.isShown ? "Hide Reader" : "Show Reader") { reader.toggle() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Picture in Picture") { PictureInPicture.shared.toggleFront() }
                    .keyboardShortcut("p", modifiers: [.command, .option])
                Divider()
            }
            CommandMenu("Go") {
                Button("Back") { store.goBack() }
                    .keyboardShortcut("[", modifiers: [.command])
                Button("Forward") { store.goForward() }
                    .keyboardShortcut("]", modifiers: [.command])
                Divider()
                Button("Tab to the Left") { store.move(.left) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Tab to the Right") { store.move(.right) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Trail Above") { store.move(.up) }
                    .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                Button("Trail Below") { store.move(.down) }
                    .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                Divider()
                Button(dock.isFront ? "Move App Back to the Map" : "Keep Tab in Dock") {
                    dock.toggleDockForFront()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button(store.activeSplit != nil ? "Separate Side-by-Side Tabs" : "View Side by Side with Next Tab") {
                    store.toggleSplit()
                }
                .keyboardShortcut("\\", modifiers: [.command])
                Divider()
                Button(store.map.activeTab?.pinned == true ? "Unpin Tab" : "Pin Tab (Never Auto-Close)") {
                    if let id = store.map.activeTabID { store.togglePin(id) }
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}
