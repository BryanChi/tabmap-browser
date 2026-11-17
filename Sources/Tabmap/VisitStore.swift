import Foundation
import TabMapCore

/// Keeps the addresses you go to (and imported history) on disk, and finishes what you type in the address bar.
/// Saved in ~/Library/Application Support/Tabmap/visits.json. Nothing leaves the Mac.
@MainActor
final class VisitStore: ObservableObject {
    static let shared = VisitStore()

    @Published private(set) var index = VisitIndex()
    private let fileURL: URL
    private var saveTask: Task<Void, Never>?

    private init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let root = base.appendingPathComponent("Tabmap", isDirectory: true)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("visits.json")
        if let data = try? Data(contentsOf: fileURL), let saved = try? JSONDecoder().decode(VisitIndex.self, from: data) {
            index = saved
        }
    }

    /// A page finished loading in a tab.
    func record(_ url: URL?, title: String?) {
        guard let url else { return }
        index.record(url, title: title ?? "", now: Date())
        scheduleSave()
    }

    /// An address typed and opened from the address bar.
    func markTyped(_ url: URL) {
        index.markTyped(url, now: Date())
        scheduleSave()
    }

    /// Returns how many addresses were new.
    func merge(_ visits: [ImportedVisit]) -> Int {
        let added = index.merge(visits, now: Date())
        scheduleSave()
        return added
    }

    func completion(for typed: String) -> String? {
        index.completion(for: typed, now: Date())
    }

    func forgetAll() {
        index.removeAll()
        saveNow()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        guard let data = try? JSONEncoder().encode(index) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
