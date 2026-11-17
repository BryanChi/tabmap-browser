import AppKit
import TabMapCore

/// Everything Tabmap keeps on disk lives in ~/Library/Application Support/Tabmap.
///   state.json     the tab map itself
///   snapshots/     one JPEG thumbnail per tab
///   sessions/      one WebKit session blob per tab (back/forward history, scroll position, form state)
final class Persistence {
    let root: URL
    private let stateURL: URL
    private let snapshotsDir: URL
    private let sessionsDir: URL
    private let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 150
        return cache
    }()

    init() {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        root = base.appendingPathComponent("Tabmap", isDirectory: true)
        stateURL = root.appendingPathComponent("state.json")
        snapshotsDir = root.appendingPathComponent("snapshots", isDirectory: true)
        sessionsDir = root.appendingPathComponent("sessions", isDirectory: true)
        for dir in [root, snapshotsDir, sessionsDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    // MARK: Map

    func loadMap() -> TabMap {
        guard let data = try? Data(contentsOf: stateURL) else { return TabMap() }
        do {
            return try JSONDecoder().decode(TabMap.self, from: data)
        } catch {
            // Keep the unreadable file around instead of silently overwriting it.
            let backup = root.appendingPathComponent("state-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: stateURL, to: backup)
            return TabMap()
        }
    }

    func saveMap(_ map: TabMap) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(map) else { return }
        try? data.write(to: stateURL, options: .atomic)
    }

    // MARK: Snapshots

    private func snapshotURL(_ id: TabID) -> URL {
        snapshotsDir.appendingPathComponent(id.uuidString + ".jpg")
    }

    func snapshot(for id: TabID) -> NSImage? {
        let key = id.uuidString as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = NSImage(contentsOf: snapshotURL(id)) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }

    func saveSnapshot(_ image: NSImage, for id: TabID) {
        imageCache.setObject(image, forKey: id.uuidString as NSString)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
        else { return }
        try? jpeg.write(to: snapshotURL(id), options: .atomic)
    }

    // MARK: Sessions

    private func sessionURL(_ id: TabID) -> URL {
        sessionsDir.appendingPathComponent(id.uuidString + ".session")
    }

    func session(for id: TabID) -> Data? {
        try? Data(contentsOf: sessionURL(id))
    }

    func saveSession(_ data: Data, for id: TabID) {
        try? data.write(to: sessionURL(id), options: .atomic)
    }

    // MARK: Cleanup

    func forget(_ id: TabID) {
        imageCache.removeObject(forKey: id.uuidString as NSString)
        try? FileManager.default.removeItem(at: snapshotURL(id))
        try? FileManager.default.removeItem(at: sessionURL(id))
    }
}
