import AppKit
import SwiftUI
import TabMapCore

// Goes in Sources/Tabmap.

// MARK: The badge on a tab

/// Sits on a tab in the map and says how many files were downloaded from it.
/// Draws nothing for a tab with no downloads. Click it to list that tab's files.
struct DownloadBadge: View {
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var store = BrowserStore.shared
    let tabID: TabID
    let style: MapStyle

    var body: some View {
        let count = downloads.count(forTab: tabID)
        if count > 0 {
            let busy = downloads.ledger.isDownloading(tab: tabID)
            let match = matchedFile
            HStack(spacing: style == .cards ? 3 : 1) {
                Image(systemName: "arrow.down")
                    .font(.system(size: style == .cards ? 9 : 7, weight: .bold))
                Text(match ?? "\(count)")
                    .font(.system(size: style == .cards ? 10 : 8, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundColor(.white)
            .padding(.horizontal, style == .cards ? 6 : 3)
            .padding(.vertical, style == .cards ? 3 : 1)
            .frame(maxWidth: style == .cards ? 180 : nil)
            .fixedSize(horizontal: match == nil, vertical: true)
            .background(Capsule().fill(busy ? Color.orange : Color.black.opacity(0.78)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 0.5))
            .padding(style == .cards ? 6 : 0)
            .offset(x: style == .cards ? 0 : 3, y: style == .cards ? 0 : -3)
            .contentShape(Rectangle())
            .onTapGesture { downloads.showPanel(forTab: tabID) }
            .help(tooltip(count: count, busy: busy))
        }
    }

    /// While the map is being searched, a tab found by a file name shows that name.
    private var matchedFile: String? {
        guard style == .cards, store.overviewShown else { return nil }
        return downloads.ledger.firstMatch(forTab: tabID, query: store.overviewQuery)?.filename
    }

    private func tooltip(count: Int, busy: Bool) -> String {
        let names = downloads.ledger.records(forTab: tabID).filter(\.countsTowardTab).map(\.filename)
        var lines = [count == 1 ? "1 file downloaded from this tab" : "\(count) files downloaded from this tab"]
        if busy { lines[0] += " (still downloading)" }
        lines.append(contentsOf: names.prefix(8))
        if names.count > 8 { lines.append("and \(names.count - 8) more") }
        return lines.joined(separator: "\n")
    }
}

/// Extra entries for a tab's right-click menu in the map.
struct DownloadMenuItems: View {
    @ObservedObject private var downloads = DownloadStore.shared
    let tabID: TabID

    var body: some View {
        let count = downloads.count(forTab: tabID)
        if count > 0 {
            Divider()
            Button(count == 1 ? "Show the File Downloaded Here" : "Show the \(count) Files Downloaded Here") {
                downloads.showPanel(forTab: tabID)
            }
        }
    }
}

// MARK: The layer over the window

/// Everything downloads put on screen: a small pill at the top right while something is downloading
/// (and for a moment after it finishes), and the downloads list sliding in from the right.
struct DownloadsLayer: View {
    @ObservedObject private var downloads = DownloadStore.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if downloads.panelShown {
                // Click anywhere else to dismiss.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { downloads.panelShown = false }
                DownloadsPanel()
                    .frame(width: 380)
                    .padding(10)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else if downloads.pillVisible {
                DownloadPill()
                    .padding(.top, 9)
                    .padding(.trailing, 12)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: 0.18), value: downloads.panelShown)
        .animation(.easeOut(duration: 0.18), value: downloads.pillVisible)
    }
}

struct DownloadPill: View {
    @ObservedObject private var downloads = DownloadStore.shared

    var body: some View {
        let active = downloads.ledger.activeCount
        HStack(spacing: 7) {
            if active > 0 {
                DownloadProgressRing(fraction: downloads.overallProgress)
                    .frame(width: 12, height: 12)
                Text(active == 1 ? runningName : "\(active) downloads")
            } else {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text(finishedName)
            }
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundColor(.white)
        .lineLimit(1)
        .truncationMode(.middle)
        .padding(.horizontal, 11)
        .frame(height: 28)
        .frame(maxWidth: 240)
        .fixedSize()
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .contentShape(Capsule())
        .onTapGesture { downloads.showPanel() }
        .help("Show downloads (⌥⌘L)")
    }

    private var runningName: String {
        downloads.ledger.records.last { $0.state == .inProgress }?.filename ?? "Downloading"
    }

    private var finishedName: String {
        downloads.justFinished.flatMap { downloads.ledger.record($0) }?.filename ?? "Downloaded"
    }
}

/// A ring that fills with progress, or spins slowly when the size is not known.
struct DownloadProgressRing: View {
    let fraction: Double?

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 2)
            if let fraction {
                Circle()
                    .trim(from: 0, to: CGFloat(max(0.04, fraction)))
                    .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.25), value: fraction)
            } else {
                TimelineView(.animation) { context in
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(context.date.timeIntervalSinceReferenceDate * 240))
                }
            }
        }
    }
}

// MARK: The list

struct DownloadsPanel: View {
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var store = BrowserStore.shared

    var body: some View {
        let groups = downloads.ledger.groups(in: store.map, onlyTab: downloads.panelTab)
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if groups.isEmpty {
                Text(downloads.panelTab == nil
                     ? "Nothing downloaded yet.\nFiles you download are listed here under the row of the map they came from."
                     : "Nothing has been downloaded from this tab.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.title.uppercased())
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.bottom, 2)
                                ForEach(group.records) { record in
                                    DownloadRow(record: record)
                                }
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxHeight: groups.isEmpty ? nil : 440, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 18, y: 6)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Downloads")
                .font(.system(size: 13, weight: .semibold))
            if let tab = downloads.panelTab {
                Button { downloads.panelTab = nil } label: {
                    HStack(spacing: 4) {
                        Text(store.map.tab(tab)?.displayTitle ?? "One tab")
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .frame(maxWidth: 150)
                    .fixedSize()
                    .background(Capsule().fill(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .help("Showing files from one tab. Click to show all downloads.")
            }
            Spacer(minLength: 0)
            Button("Clear") { downloads.clearInactive() }
                .buttonStyle(.borderless)
                .font(.system(size: 11))
                .disabled(downloads.ledger.records.allSatisfy { $0.state == .inProgress })
                .help("Empty this list. The files stay in your Downloads folder.")
            Button { downloads.panelShown = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
                .help("Close (esc)")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct DownloadRow: View {
    @ObservedObject private var downloads = DownloadStore.shared
    @ObservedObject private var store = BrowserStore.shared
    let record: DownloadRecord
    @State private var hovering = false

    var body: some View {
        let exists = downloads.fileExists(record)
        let usable = record.state == .finished && exists
        HStack(spacing: 9) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 28, height: 28)
                .opacity(usable ? 1 : 0.45)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.filename)
                    .font(.system(size: 12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(record.state == .finished && !exists)
                detail(exists: exists)
            }
            Spacer(minLength: 4)
            if hovering { buttons(usable: usable) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { downloads.open(record) }
        .onDrag {
            if usable, let path = record.filePath,
               let provider = NSItemProvider(contentsOf: URL(fileURLWithPath: path)) {
                return provider
            }
            return NSItemProvider()
        }
        .contextMenu { menu(usable: usable) }
        .help(usable ? "Double-click to open. Drag it out to use the file elsewhere." : "")
    }

    private var icon: NSImage {
        if let path = record.filePath, FileManager.default.fileExists(atPath: path) {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSWorkspace.shared.icon(forFile: "/nonexistent/" + record.filename)
    }

    @ViewBuilder
    private func detail(exists: Bool) -> some View {
        switch record.state {
        case .inProgress:
            let fraction = downloads.progress[record.id] ?? -1
            if fraction >= 0 {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .controlSize(.small)
            }
        case .finished:
            Text(caption(exists ? nil : "Moved or deleted"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        case .failed:
            Text(caption("Failed"))
                .font(.system(size: 10))
                .foregroundColor(.red)
                .lineLimit(1)
        case .cancelled:
            Text(caption("Cancelled"))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
    }

    /// "Failed · 2.1 MB · example.com · 5 min. ago", leaving out whatever is unknown.
    private func caption(_ status: String?) -> String {
        var parts: [String] = []
        if let status { parts.append(status) }
        if let bytes = record.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
        }
        if let host = record.pageURL?.host ?? record.sourceURL?.host { parts.append(host) }
        parts.append(Self.relative.localizedString(for: record.startedAt, relativeTo: Date()))
        return parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private var sourceIsInMap: Bool {
        guard let tab = record.tabID else { return false }
        return store.map.tab(tab) != nil
    }

    private var canGoToSource: Bool { sourceIsInMap || record.pageURL != nil }

    @ViewBuilder
    private func buttons(usable: Bool) -> some View {
        HStack(spacing: 8) {
            if record.state == .inProgress {
                Button { downloads.cancel(record) } label: { Image(systemName: "xmark.circle.fill") }
                    .help("Stop this download")
            } else if record.state != .finished {
                Button { downloads.retry(record) } label: { Image(systemName: "arrow.clockwise") }
                    .help("Download again")
            }
            if canGoToSource {
                Button { downloads.goToSource(record) } label: { Image(systemName: "arrow.uturn.backward.circle") }
                    .help(sourceIsInMap ? "Go to the tab this came from" : "Open the page this came from again")
            }
            if usable {
                Button { downloads.revealInFinder(record) } label: { Image(systemName: "magnifyingglass.circle") }
                    .help("Show in Finder")
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14))
    }

    @ViewBuilder
    private func menu(usable: Bool) -> some View {
        if usable {
            Button("Open") { downloads.open(record) }
            Button("Show in Finder") { downloads.revealInFinder(record) }
        }
        if canGoToSource {
            Button(sourceIsInMap ? "Go to the Tab This Came From" : "Open the Page This Came From") {
                downloads.goToSource(record)
            }
        }
        if let source = record.sourceURL {
            Button("Copy Download Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(source.absoluteString, forType: .string)
            }
        }
        Divider()
        if record.state == .inProgress {
            Button("Stop Download") { downloads.cancel(record) }
        } else {
            if record.state != .finished { Button("Download Again") { downloads.retry(record) } }
            Button("Remove from List") { downloads.remove(record) }
        }
    }
}
