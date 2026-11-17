import AppKit
import SwiftUI

/// Fetches and remembers one icon per site.
@MainActor
final class FaviconStore: ObservableObject {
    @Published private(set) var icons: [String: NSImage] = [:]
    private var requested: Set<String> = []

    func icon(for url: URL?) -> NSImage? {
        guard let url, let host = url.host, !host.isEmpty else { return nil }
        if let icon = icons[host] { return icon }
        if !requested.contains(host) {
            requested.insert(host)
            fetch(host: host, scheme: url.scheme ?? "https")
        }
        return nil
    }

    private func fetch(host: String, scheme: String) {
        guard scheme == "http" || scheme == "https",
              let iconURL = URL(string: "\(scheme)://\(host)/favicon.ico")
        else { return }
        Task { @MainActor [weak self] in
            var request = URLRequest(url: iconURL)
            request.timeoutInterval = 10
            guard let (data, _) = try? await URLSession.shared.data(for: request),
                  let image = NSImage(data: data),
                  image.size.width > 0
            else { return }
            self?.icons[host] = image
        }
    }
}

struct FaviconView: View {
    @EnvironmentObject private var favicons: FaviconStore
    let url: URL?
    var size: CGFloat = 14

    var body: some View {
        Group {
            if let icon = favicons.icon(for: url) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
            } else {
                // Monogram until (or instead of) a real icon.
                ZStack {
                    RoundedRectangle(cornerRadius: size * 0.25)
                        .fill(Color.secondary.opacity(0.25))
                    Text(monogram)
                        .font(.system(size: size * 0.65, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(width: size, height: size)
    }

    private var monogram: String {
        guard var host = url?.host else { return "•" }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host.first.map { String($0).uppercased() } ?? "•"
    }
}
