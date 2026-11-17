import SwiftUI
import TabMapCore

/// The import card, shown over the page on first launch and from File > Import Browsing Data or Settings.
struct ImportLayer: View {
    @ObservedObject private var importer = BrowserImporter.shared

    var body: some View {
        ZStack {
            if importer.shown {
                Color.black.opacity(0.25)
                    .contentShape(Rectangle())
                    .onTapGesture { importer.hide() }
                ImportCard()
                    .frame(width: 440)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: importer.shown)
    }
}

private struct ImportCard: View {
    @ObservedObject private var importer = BrowserImporter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch importer.phase {
            case .choosing: ChooseView()
            case .importing: ImportingView()
            case .done: DoneView()
            }
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.25), radius: 30, y: 10)
        .onExitCommand { importer.hide() }
    }
}

private struct ChooseView: View {
    @ObservedObject private var importer = BrowserImporter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Bring in your browsing").font(.system(size: 17, weight: .semibold))
            Text("Bookmarks go to your bookmark board, in collections named after their folders. History finishes addresses as you type them. Everything stays on this Mac.")
                .font(.system(size: 12)).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if importer.sources.isEmpty {
            Text("No other browsers were found on this Mac. You can still import files exported from one.")
                .font(.system(size: 12)).foregroundColor(.secondary)
        } else {
            VStack(spacing: 2) {
                ForEach(importer.sources) { SourceRow(source: $0) }
            }
            HStack(spacing: 16) {
                Toggle("Bookmarks", isOn: $importer.takeBookmarks)
                Toggle("History", isOn: $importer.takeHistory)
            }
            .toggleStyle(.checkbox)
            .font(.system(size: 12))
        }

        PasswordsNote()

        HStack {
            Button("Import Exported Files…") { importer.chooseFiles() }
            Spacer()
            Button("Not Now") { importer.hide() }
                .keyboardShortcut(.cancelAction)
            Button("Import") { importer.importSelected() }
                .keyboardShortcut(.defaultAction)
                .disabled(!importer.canImport)
        }
        .controlSize(.regular)
    }
}

private struct SourceRow: View {
    let source: ImportSource
    @ObservedObject private var importer = BrowserImporter.shared

    var body: some View {
        let on = importer.selected.contains(source.id)
        HStack(spacing: 10) {
            if let icon = source.browser.icon {
                Image(nsImage: icon).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "globe").frame(width: 22, height: 22)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(source.title).font(.system(size: 13))
                if !source.readable {
                    Text("Needs Full Disk Access, or import Safari's exported file")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                }
            }
            Spacer()
            if source.readable {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(on ? .accentColor : .secondary)
                    .font(.system(size: 16))
            } else {
                Button("Allow…") { importer.openFullDiskAccessSettings() }
                    .controlSize(.small)
                    .help("Opens Privacy & Security. Turn on Tabmap under Full Disk Access, then come back here.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
        .contentShape(Rectangle())
        .onTapGesture { importer.toggle(source) }
    }
}

private struct PasswordsNote: View {
    @ObservedObject private var importer = BrowserImporter.shared
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "key.fill").font(.system(size: 10))
                    Text("Passwords come from an exported file")
                    Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9))
                }
                .font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Browsers keep passwords locked to themselves, so export them first, then choose the file with Import Exported Files. They are saved to your login keychain, where Tabmap fills them in.")
                    ForEach(browsersForHelp, id: \.self) { browser in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text("•")
                            Text(browser.passwordExportHelp)
                            Spacer(minLength: 4)
                            Button("Open") { importer.openBrowser(browser) }
                                .controlSize(.mini)
                        }
                    }
                    Text("The file holds every password in plain text. Tabmap offers to move it to the Trash once it is read.")
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var browsersForHelp: [ImportSource.Browser] {
        var seen = Set<ImportSource.Browser>()
        let found = importer.sources.map(\.browser).filter { seen.insert($0).inserted }
        return found.isEmpty ? [.chrome, .safari] : found
    }
}

private struct ImportingView: View {
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Importing…").font(.system(size: 13))
        }
        .frame(maxWidth: .infinity, minHeight: 80)
    }
}

private struct DoneView: View {
    @ObservedObject private var importer = BrowserImporter.shared

    var body: some View {
        let s = importer.summary
        Text(lines(s).isEmpty ? "Nothing new to import" : "Imported").font(.system(size: 17, weight: .semibold))
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines(s), id: \.self) { line in
                Label(line, systemImage: "checkmark").font(.system(size: 12))
            }
            ForEach(s.problems, id: \.self) { problem in
                Label("Could not read \(problem)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundColor(.secondary)
            }
        }
        if !s.passwordFiles.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: s.trashed ? "trash" : "exclamationmark.lock").foregroundColor(.orange)
                VStack(alignment: .leading, spacing: 6) {
                    Text(s.trashed
                         ? "The password file is in the Trash. Empty the Trash to remove it for good."
                         : "\(fileNames(s.passwordFiles)) still holds your passwords in plain text.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                    if !s.trashed {
                        Button("Move to Trash") { importer.trashPasswordFiles() }.controlSize(.small)
                    }
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.1)))
        }
        HStack {
            Button("Import More…") { importer.show() }
            Spacer()
            Button("Done") { importer.hide() }.keyboardShortcut(.defaultAction)
        }
    }

    private func lines(_ s: BrowserImporter.Summary) -> [String] {
        var out: [String] = []
        if s.bookmarksAdded > 0 || s.bookmarksSkipped > 0 {
            var line = count(s.bookmarksAdded, "bookmark")
            if s.bookmarksSkipped > 0 { line += " (\(s.bookmarksSkipped) already saved)" }
            out.append(line)
        }
        if s.historyRead > 0 {
            out.append("\(count(s.historyRead, "address")) from history, \(s.historyAdded) new")
        }
        let p = s.passwords
        if p.added + p.updated + p.unchanged + p.failed > 0 {
            var line = count(p.added, "password")
            if p.updated > 0 { line += ", \(p.updated) updated" }
            if p.unchanged > 0 { line += ", \(p.unchanged) already there" }
            if p.failed > 0 { line += ", \(p.failed) could not be saved" }
            out.append(line)
        }
        if s.passwordsSkipped > 0 {
            out.append("\(count(s.passwordsSkipped, "entry")) without a web address left out (Wi-Fi, apps)")
        }
        return out
    }

    private func count(_ n: Int, _ noun: String) -> String {
        let plural = noun.hasSuffix("ss") ? noun + "es" : noun == "entry" ? "entries" : noun + "s"
        return "\(n.formatted()) \(n == 1 ? noun : plural)"
    }

    private func fileNames(_ urls: [URL]) -> String {
        urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) files"
    }
}
