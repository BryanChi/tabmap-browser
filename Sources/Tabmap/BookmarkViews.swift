import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit
import TabMapCore

// What bookmarks put on screen: the board over the whole window (⌘B or the hot corner)
// and the small note in the top right corner after saving.

/// Goes last in ContentView's outer ZStack, so it sits over everything else.
struct BookmarksLayer: View {
    @ObservedObject private var bookmarks = BookmarkStore.shared

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if bookmarks.boardShown {
                BookmarkBoard()
                    .transition(.opacity.combined(with: .scale(scale: 0.985)))
            }
            if let toast = bookmarks.toast, !bookmarks.boardShown {
                BookmarkToastView(toast: toast)
                    .padding(.top, 12)
                    .padding(.trailing, 14)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: 0.16), value: bookmarks.boardShown)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: bookmarks.toast)
    }
}

// MARK: The note after saving

struct BookmarkToastView: View {
    @ObservedObject private var bookmarks = BookmarkStore.shared
    let toast: BookmarkStore.Toast

    var body: some View {
        let bookmark = bookmarks.library.bookmark(toast.bookmarkID)
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 12, weight: .semibold))
                if let detail = detail(bookmark) {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            if bookmark != nil {
                Button("Edit") { bookmarks.editFromToast() }
                if toast.kind == .saved || toast.kind == .rowSaved {
                    Button("Undo") { bookmarks.undoToast() }
                }
            }
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: 380, alignment: .leading)
        .background(Capsule().fill(Color.black))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        .foregroundColor(.white)
        .environment(\.colorScheme, .dark)
        .onTapGesture { bookmarks.dismissToast() }
    }

    private var icon: String {
        switch toast.kind {
        case .saved, .rowSaved, .alreadySaved: return "bookmark.fill"
        case .highlightAdded: return "highlighter"
        case .nothingToSave: return "bookmark.slash"
        }
    }

    private var title: String {
        switch toast.kind {
        case .saved: return "Bookmarked"
        case .rowSaved: return "Row bookmarked"
        case .highlightAdded: return "Highlight saved"
        case .alreadySaved: return "Already bookmarked"
        case .nothingToSave: return "Nothing to bookmark here"
        }
    }

    private func detail(_ b: Bookmark?) -> String? {
        guard let b else { return toast.kind == .nothingToSave ? "Open a web page first" : nil }
        if toast.kind == .highlightAdded, let last = b.highlights.last { return "“\(last.text)”" }
        if bookmarks.filing.contains(b.id) { return "Filing…" }
        var parts: [String] = []
        if b.isRow { parts.append("\(b.pages.count) pages") }
        if !b.collection.isEmpty { parts.append("In \(b.collection)") }
        if !b.tags.isEmpty { parts.append(b.tags.prefix(3).joined(separator: ", ")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: The board

struct BookmarkBoard: View {
    @ObservedObject private var bookmarks = BookmarkStore.shared

    var body: some View {
        HStack(spacing: 0) {
            BoardSidebar()
                .frame(width: 214)
            Divider()
            VStack(spacing: 0) {
                header
                Divider()
                ScrollView(.vertical) {
                    cards
                        .padding(22)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if let id = bookmarks.editing, let b = bookmarks.library.bookmark(id) {
                ZStack {
                    Color.black.opacity(0.25)
                        .onTapGesture { bookmarks.editing = nil }
                    BookmarkEditor(bookmark: b)
                        .id(id)
                }
            }
        }
        .overlay {
            if let id = bookmarks.viewingCopy, let b = bookmarks.library.bookmark(id), let data = bookmarks.savedCopy(id) {
                ZStack {
                    Color.black.opacity(0.3)
                        .onTapGesture { bookmarks.viewingCopy = nil }
                    SavedCopyView(bookmark: b, data: data)
                        .id(id)
                        .padding(28)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            NativeTextField(text: $bookmarks.query,
                            placeholder: "Search titles, tags, notes, highlights, page text, colours",
                            fontSize: 16,
                            focusOnAppear: true)
                .frame(height: 22)
            Text("⌘B or esc to close")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private var cards: some View {
        let items = bookmarks.visibleBookmarks()
        let searching = !bookmarks.query.trimmingCharacters(in: .whitespaces).isEmpty
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(searching ? "Search results" : bookmarks.scope.title)
                    .font(.system(size: 20, weight: .semibold))
                Text("\(items.count)")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
            if items.isEmpty {
                Text(emptyText(searching: searching))
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .padding(.top, 30)
                    .frame(maxWidth: .infinity)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 20) {
                    ForEach(items) { b in
                        BookmarkCard(bookmark: b)
                    }
                }
            }
        }
    }

    private func emptyText(searching: Bool) -> String {
        if searching { return "No bookmarks match “\(bookmarks.query)”." }
        if bookmarks.library.bookmarks.isEmpty {
            return "Nothing saved yet. Press ⌘D on a page to bookmark it, or ⇧⌘B to save its whole row."
        }
        return "Nothing in \(bookmarks.scope.title) right now."
    }
}

// MARK: Sidebar

struct BoardSidebar: View {
    @ObservedObject private var bookmarks = BookmarkStore.shared
    @State private var renaming: String?
    @State private var newName = ""
    @State private var dropTarget: String?

    var body: some View {
        let now = Date()
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Bookmarks")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.leading, 8)
                    .padding(.bottom, 8)
                ForEach(BoardScope.smart, id: \.self) { scope in
                    let count = bookmarks.library.count(in: scope, now: now)
                    if count > 0 || scope == .all || scope == .readLater || scope == .thisWeek {
                        row(scope, count: count)
                    }
                }
                let collections = bookmarks.library.collections()
                if !collections.isEmpty {
                    Text("COLLECTIONS")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.secondary)
                        .padding(.leading, 8)
                        .padding(.top, 16)
                        .padding(.bottom, 4)
                    ForEach(collections) { item in
                        row(.collection(item.name), count: item.count)
                            .background(RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(Color.accentColor, lineWidth: dropTarget == item.name ? 2 : 0))
                            .onDrop(of: [UTType.text], isTargeted: Binding(
                                get: { dropTarget == item.name },
                                set: { dropTarget = $0 ? item.name : (dropTarget == item.name ? nil : dropTarget) })
                            ) { providers in
                                bookmarks.receiveDrop(providers, into: item.name)
                            }
                            .contextMenu {
                                Button("Rename…") {
                                    newName = item.name
                                    renaming = item.name
                                }
                            }
                            .popover(isPresented: Binding(get: { renaming == item.name },
                                                          set: { if !$0 { renaming = nil } })) {
                                renameField(item.name)
                            }
                    }
                }
                Text("Drag a card onto a collection to move it.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .padding(.leading, 8)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 10)
            .padding(.top, 38) // clear of the window buttons
            .padding(.bottom, 12)
        }
        .background(Color.primary.opacity(0.03))
    }

    private func row(_ scope: BoardScope, count: Int) -> some View {
        let selected = bookmarks.scope == scope && bookmarks.query.isEmpty
        return Button {
            bookmarks.scope = scope
            bookmarks.query = ""
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon(scope))
                    .frame(width: 16)
                    .foregroundColor(selected ? .white : .accentColor)
                Text(scope.title)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.system(size: 11))
                    .foregroundColor(selected ? .white.opacity(0.8) : .secondary)
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .foregroundColor(selected ? .white : .primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func renameField(_ old: String) -> some View {
        HStack {
            TextField("Collection name", text: $newName)
                .onSubmit {
                    bookmarks.renameCollection(old, to: newName)
                    renaming = nil
                }
                .frame(width: 180)
            Button("Rename") {
                bookmarks.renameCollection(old, to: newName)
                renaming = nil
            }
        }
        .padding(12)
    }

    private func icon(_ scope: BoardScope) -> String {
        switch scope {
        case .all: return "square.grid.2x2"
        case .thisWeek: return "calendar"
        case .readLater: return "eyeglasses"
        case .highlights: return "highlighter"
        case .rows: return "rectangle.split.3x1"
        case .changed: return "arrow.triangle.2.circlepath"
        case .offline: return "icloud.slash"
        case .collection: return "folder"
        }
    }
}

// MARK: A card

struct BookmarkCard: View {
    @ObservedObject private var bookmarks = BookmarkStore.shared
    let bookmark: Bookmark
    @State private var hovering = false

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            thumbnail
                .frame(height: 150)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .overlay(alignment: .topLeading) { badges.padding(6) }

            HStack(spacing: 6) {
                FaviconView(url: bookmark.url, size: 14)
                Text(bookmark.displayTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }

            if !bookmark.summary.isEmpty {
                Text(bookmark.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let highlight = bookmark.highlights.last {
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(Color.yellow.opacity(0.8)).frame(width: 3)
                    Text("“\(highlight.text)”")
                        .font(.system(size: 11).italic())
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .contentShape(Rectangle())
                .onTapGesture { bookmarks.openHighlight(highlight, of: bookmark) }
                .help(bookmark.highlights.count > 1
                      ? "\(bookmark.highlights.count) highlights. Click to open the page at this one."
                      : "Click to open the page at this passage.")
            }

            if !bookmark.note.isEmpty {
                Label(bookmark.note, systemImage: "note.text")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            tagLine

            Text(meta)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(hovering ? 0.07 : 0.03)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { bookmarks.activate(bookmark) }
        .contextMenu { menu }
        .onDrag { NSItemProvider(object: bookmark.id.uuidString as NSString) }
        .help(bookmark.isRow ? bookmark.pages.map(\.title).joined(separator: "\n") : bookmark.url.absoluteString)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let _ = bookmarks.snapshotVersions[bookmark.id]
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image = bookmarks.image(for: bookmark.id) {
                Color.clear.overlay(alignment: .top) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                }
                .clipped()
                .saturation(bookmark.isGone ? 0.2 : 1)
            } else {
                FaviconView(url: bookmark.url, size: 36)
            }
            if bookmark.isRow {
                VStack {
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(Array(bookmark.pages.prefix(7).enumerated()), id: \.offset) { _, page in
                            FaviconView(url: page.url, size: 14)
                        }
                        Spacer(minLength: 4)
                        Text("\(bookmark.pages.count) pages")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(.regularMaterial)
                }
            }
        }
    }

    @ViewBuilder
    private var badges: some View {
        HStack(spacing: 4) {
            if bookmarks.filing.contains(bookmark.id) { badge("Filing…", .gray) }
            if bookmark.isGone {
                badge(bookmark.hasCopy ? "Gone · saved copy" : "Gone from the web", .red)
            } else if bookmark.hasChanged {
                badge("Changed", .orange)
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.9)))
    }

    @ViewBuilder
    private var tagLine: some View {
        if !bookmark.collection.isEmpty || !bookmark.tags.isEmpty {
            HStack(spacing: 4) {
                if !bookmark.collection.isEmpty {
                    chip(bookmark.collection, systemImage: "folder", strong: true)
                }
                ForEach(bookmark.tags.prefix(3), id: \.self) { tag in
                    chip(tag, systemImage: nil, strong: false)
                }
            }
            .lineLimit(1)
        }
    }

    private func chip(_ text: String, systemImage: String?, strong: Bool) -> some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8)) }
            Text(text).font(.system(size: 10))
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(strong ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.07)))
        .onTapGesture {
            if strong { bookmarks.scope = .collection(text); bookmarks.query = "" } else { bookmarks.query = text }
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let host = BookmarkKey.displayHost(bookmark.url) { parts.append(host) }
        parts.append("saved " + Self.relative.localizedString(for: bookmark.createdAt, relativeTo: Date()))
        if bookmark.lastOpenedAt == nil && !bookmark.isRow { parts.append("unread") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var menu: some View {
        Button(bookmark.isRow ? "Open Row" : "Open") { bookmarks.open(bookmark) }
        if bookmark.hasCopy {
            Button("View Saved Copy") { bookmarks.viewingCopy = bookmark.id }
        }
        Divider()
        Button("Edit…") { bookmarks.editing = bookmark.id }
        Menu("Move to") {
            ForEach(bookmarks.collectionChoices(), id: \.self) { name in
                Button(name) { bookmarks.setCollection(name, for: bookmark.id) }
            }
        }
        Button("File Again Automatically") { bookmarks.refile(bookmark.id) }
        Button("Copy Address") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(bookmark.url.absoluteString, forType: .string)
        }
        Divider()
        Button("Delete Bookmark") { bookmarks.remove(bookmark.id) }
    }
}

// MARK: Editing

struct BookmarkEditor: View {
    @ObservedObject private var bookmarks = BookmarkStore.shared
    let bookmark: Bookmark
    @State private var title: String
    @State private var collection: String
    @State private var tags: String
    @State private var note: String

    init(bookmark: Bookmark) {
        self.bookmark = bookmark
        _title = State(initialValue: bookmark.title)
        _collection = State(initialValue: bookmark.collection)
        _tags = State(initialValue: bookmark.tags.joined(separator: ", "))
        _note = State(initialValue: bookmark.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(bookmark.isRow ? "Edit Saved Row" : "Edit Bookmark")
                .font(.system(size: 15, weight: .semibold))
            field("Title") { TextField("Title", text: $title) }
            field("Collection") {
                HStack(spacing: 6) {
                    TextField("Collection", text: $collection)
                    Menu("Choose") {
                        ForEach(bookmarks.collectionChoices(), id: \.self) { name in
                            Button(name) { collection = name }
                        }
                    }
                    .fixedSize()
                }
            }
            field("Tags") { TextField("Separated by commas", text: $tags) }
            field("Note") {
                TextEditor(text: $note)
                    .font(.system(size: 12))
                    .frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(0.15)))
            }
            if !bookmark.summary.isEmpty {
                Text(bookmark.summary)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !bookmark.highlights.isEmpty {
                Text("Highlights").font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(bookmark.highlights) { h in
                            HStack(alignment: .top, spacing: 6) {
                                Rectangle().fill(Color.yellow.opacity(0.8)).frame(width: 3)
                                Text(h.text).font(.system(size: 11)).lineLimit(4)
                                Spacer(minLength: 4)
                                Button { bookmarks.removeHighlight(h.id, from: bookmark.id) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                                }
                                .buttonStyle(.borderless)
                                .help("Remove this highlight")
                            }
                        }
                    }
                }
                .frame(maxHeight: 120)
            }
            HStack {
                Button("File Automatically") {
                    bookmarks.refile(bookmark.id)
                    bookmarks.editing = nil
                }
                .help(bookmarks.filer.modelAvailable
                      ? "Let Apple Intelligence on this Mac choose the collection, tags and description again."
                      : "Choose the collection, tags and description again from the page's site and words.")
                Spacer()
                Button("Cancel") { bookmarks.editing = nil }
                Button("Save") {
                    bookmarks.applyEdit(bookmark.id, title: title, collection: collection, tags: tags, note: note)
                    bookmarks.editing = nil
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
        .textFieldStyle(.roundedBorder)
        .padding(20)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(nsColor: .windowBackgroundColor)))
        .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
    }

    private func field<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundColor(.secondary)
            content()
        }
    }
}

// MARK: Saved copy

struct SavedCopyView: View {
    @ObservedObject private var bookmarks = BookmarkStore.shared
    let bookmark: Bookmark
    let data: Data

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox").foregroundColor(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(bookmark.displayTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text("Copy kept on this Mac on \(bookmark.createdAt.formatted(date: .abbreviated, time: .shortened))"
                         + (bookmark.isGone ? ". The live page is gone." : bookmark.hasChanged ? ". The live page has changed since." : "."))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Open Live Page") { bookmarks.open(bookmark) }
                Button("Close") { bookmarks.viewingCopy = nil }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            ArchiveWebView(data: data, baseURL: bookmark.url)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
    }
}

/// Shows a web archive as it was saved. Scripts are off, so the copy stays as it was.
struct ArchiveWebView: NSViewRepresentable {
    let data: Data
    let baseURL: URL

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.load(data, mimeType: "application/x-webarchive", characterEncodingName: "utf-8", baseURL: baseURL)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {}
}
