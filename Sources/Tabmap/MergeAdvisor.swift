import SwiftUI
import TabMapCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// Notices when two rows of the map are about the same thing and offers to join them.
//
// Two steps. TabMapCore compares rows by the words in their page titles and searches and by the
// sites they share (cheap, runs on every pause). Where the Mac has Apple's on-device model, the
// likeliest pairs are then put to it for a yes or no and a few words on what they have in common.
// Without the model only strong matches are offered. Nothing leaves the Mac, and rows are never
// joined without the person pressing Join.

@MainActor
final class MergeAdvisor: ObservableObject {
    struct Suggestion: Equatable, Identifiable {
        let candidate: MergeCandidate
        /// A few words on what the rows share, shown under the offer.
        let reason: String
        let usedModel: Bool
        var id: String { candidate.pairKey }
    }

    /// UserDefaults key for the Settings switch. Missing means on.
    static let enabledKey = "mergeSuggestions"
    private static let dismissedKey = "mergeDismissedPairs"

    /// Score a pair needs before it is put to the model.
    private static let askModelAbove = 0.22
    /// Score a pair needs to be offered on word and site overlap alone.
    private static let offerAloneAbove = 0.42

    @Published private(set) var suggestion: Suggestion?
    /// Set for a few seconds after a join, so it can be taken back.
    @Published private(set) var lastJoin: MergeRecord?

    weak var store: BrowserStore?

    private var pending: Task<Void, Never>?
    private var evaluating = false
    private var evaluateAgain = false
    private var undoExpiry: Task<Void, Never>?
    /// The model's answers this session, keyed by the pair and what the rows held when it was asked.
    private var verdicts: [String: Verdict] = [:]
    private var dismissed: Set<String>

    private struct Verdict {
        let same: Bool
        let common: String
    }

    init() {
        dismissed = Set(UserDefaults.standard.stringArray(forKey: Self.dismissedKey) ?? [])
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// Whether the on-device model is there to give a second opinion.
    static var modelAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    // MARK: Hooks

    /// Call whenever the map changes. Cheap: the real work waits for a pause.
    func mapChanged() {
        dropStaleState()
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.evaluate()
        }
    }

    /// Call when the Settings switch is flipped.
    func settingChanged() {
        if !enabled { suggestion = nil }
        mapChanged()
    }

    // MARK: Actions

    func accept() {
        guard let current = suggestion, let store else { return }
        suggestion = nil
        guard let record = store.joinTrails(current.candidate.sourceID, into: current.candidate.targetID) else { return }
        lastJoin = record
        undoExpiry?.cancel()
        undoExpiry = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.lastJoin = nil
        }
    }

    func dismiss() {
        guard let current = suggestion else { return }
        remember(dismissed: current.candidate.pairKey)
        suggestion = nil
        mapChanged()
    }

    func undo() {
        guard let record = lastJoin, let store else { return }
        undoExpiry?.cancel()
        lastJoin = nil
        if store.undoJoin(record) {
            // They did not want these two together, so do not offer the pair again.
            remember(dismissed: MergeCandidate.pairKey(record.targetID, record.source.id))
        }
    }

    private func remember(dismissed key: String) {
        dismissed.insert(key)
        // Row ids are never reused, so old entries only cost space. Keep the list bounded.
        if dismissed.count > 400 { dismissed = Set(dismissed.shuffled().prefix(300)); dismissed.insert(key) }
        UserDefaults.standard.set(Array(dismissed), forKey: Self.dismissedKey)
    }

    // MARK: Deciding

    private func dropStaleState() {
        guard let map = store?.map else { return }
        if let current = suggestion {
            let alive = [current.candidate.targetID, current.candidate.sourceID].allSatisfy { id in
                map.trails.first { $0.id == id }?.hasOpenTabs == true
            }
            if !alive { suggestion = nil }
        }
        if let record = lastJoin, !map.trails.contains(where: { $0.id == record.targetID }) {
            lastJoin = nil
        }
    }

    private func evaluate() async {
        if evaluating { evaluateAgain = true; return }
        evaluating = true
        defer {
            evaluating = false
            if evaluateAgain { evaluateAgain = false; mapChanged() }
        }
        guard let store, enabled else { suggestion = nil; return }

        let modelReady = Self.modelAvailable
        let candidates = store.map.mergeCandidates(
            minimumScore: modelReady ? Self.askModelAbove : Self.offerAloneAbove,
            excluding: dismissed,
            limit: 4)

        // Leave an offer that still stands where it is, so it does not flicker or change under the pointer.
        if let current = suggestion, candidates.contains(where: { $0.pairKey == current.candidate.pairKey }) { return }

        for candidate in candidates {
            guard let a = store.map.trails.first(where: { $0.id == candidate.targetID }),
                  let b = store.map.trails.first(where: { $0.id == candidate.sourceID })
            else { continue }

            if modelReady {
                let key = candidate.pairKey + "|" + Self.signature(a) + "|" + Self.signature(b)
                var verdict = verdicts[key]
                if verdict == nil {
                    verdict = await Self.askModel(a, b)
                    if let verdict { verdicts[key] = verdict }
                    // The map may have moved on while the model was thinking.
                    let map = store.map
                    guard map.trails.first(where: { $0.id == a.id }) == a,
                          map.trails.first(where: { $0.id == b.id }) == b
                    else { evaluateAgain = true; return }
                }
                if let verdict {
                    if verdict.same {
                        let reason = verdict.common.isEmpty ? Self.plainReason(candidate) : verdict.common
                        suggestion = Suggestion(candidate: candidate, reason: reason, usedModel: true)
                        return
                    }
                    continue
                }
                // The model gave no answer: fall through and judge on overlap alone.
            }
            if candidate.score >= Self.offerAloneAbove {
                suggestion = Suggestion(candidate: candidate, reason: Self.plainReason(candidate), usedModel: false)
                return
            }
        }
        suggestion = nil
    }

    private static func signature(_ trail: Trail) -> String {
        trail.tabs.filter { !$0.isBlank }
            .map { ($0.url?.absoluteString ?? "") + "\u{1}" + $0.title }
            .joined(separator: "\u{2}")
    }

    static func plainReason(_ candidate: MergeCandidate) -> String {
        let words = Array(candidate.sharedWords.prefix(3))
        switch words.count {
        case 0: return "Both are on the same part of one site"
        case 1: return "Both mention \(words[0])"
        case 2: return "Both mention \(words[0]) and \(words[1])"
        default: return "Both mention \(words[0]), \(words[1]) and \(words[2])"
        }
    }

    /// A short name for a row, for the offer's text: its group name when it has one.
    static func rowName(_ trail: Trail) -> String {
        if let name = trail.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty { return name }
        let tabs = trail.openTabs.isEmpty ? trail.tabs : trail.openTabs
        guard let first = tabs.first else { return "Empty row" }
        var title = first.displayTitle
        if title.count > 34 { title = String(title.prefix(33)).trimmingCharacters(in: .whitespaces) + "…" }
        return tabs.count > 1 ? "\(title) +\(tabs.count - 1)" : title
    }

    // MARK: The model

    private static func describe(_ trail: Trail) -> String {
        trail.tabs.filter { !$0.isBlank }.prefix(8).map { tab in
            var title = tab.displayTitle
            if title.count > 80 { title = String(title.prefix(80)) }
            let host = tab.url?.host ?? ""
            return "- \(title) (\(host))"
        }.joined(separator: "\n")
    }

    /// Reads the model's two-line reply. Nil when there is no clear yes or no in it.
    private static func parseVerdict(_ reply: String) -> Verdict? {
        var same: Bool?
        var common = ""
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "*-")))
                .lowercased()
            let value = line[line.index(after: colon)...]
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”.*")))
            if key == "same" {
                let answer = value.lowercased()
                if answer.hasPrefix("yes") { same = true } else if answer.hasPrefix("no") { same = false }
            } else if key == "common" {
                common = value.count > 60 ? String(value.prefix(60)) : value
            }
        }
        guard let same else { return nil }
        return Verdict(same: same, common: same ? common : "")
    }

    private static func askModel(_ a: Trail, _ b: Trail) async -> Verdict? {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard SystemLanguageModel.default.availability == .available else { return nil }
            let instructions = """
            You compare two groups of web pages that one person has open. Decide whether both groups \
            belong to the same task or topic, so that keeping them as one group would make sense. \
            Sharing a website is not enough: two unrelated videos, or two unrelated repositories, are \
            different topics. If you are unsure, answer no. Reply with exactly two lines and nothing else:
            Same: yes or no
            Common: what the two groups have in common, as a phrase of at most 8 words starting with \
            "Both", for example "Both about planning a trip to Kyoto". Leave it empty if they differ.
            """
            let prompt = """
            Group A:
            \(describe(a))

            Group B:
            \(describe(b))
            """
            // One fresh session per pair, so earlier comparisons never colour this one.
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(temperature: 0.2, maximumResponseTokens: 60)
            do {
                let response = try await session.respond(to: prompt, options: options)
                return parseVerdict(response.content)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}

// MARK: The offer, as shown at the top of the map

struct MergeSuggestionBanner: View {
    @EnvironmentObject private var store: BrowserStore
    @ObservedObject var advisor: MergeAdvisor
    /// The narrow sidebar stacks the text and buttons; the overview lays them out in a line.
    let compact: Bool

    var body: some View {
        Group {
            if let suggestion = advisor.suggestion,
               let target = store.map.trails.first(where: { $0.id == suggestion.candidate.targetID }),
               let source = store.map.trails.first(where: { $0.id == suggestion.candidate.sourceID }) {
                offer(suggestion, target: target, source: source)
            } else if advisor.lastJoin != nil {
                joined
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: advisor.suggestion)
        .animation(.spring(response: 0.35, dampingFraction: 0.86), value: advisor.lastJoin)
    }

    @ViewBuilder
    private func offer(_ suggestion: MergeAdvisor.Suggestion, target: Trail, source: Trail) -> some View {
        let text = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "sparkles").font(.system(size: 10, weight: .semibold))
                Text("Join these rows?").font(.system(size: 12, weight: .semibold))
            }
            Text("“\(MergeAdvisor.rowName(source))” and “\(MergeAdvisor.rowName(target))”")
                .font(.system(size: 11))
                .lineLimit(compact ? 3 : 1)
            Text(suggestion.reason)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        let buttons = HStack(spacing: 8) {
            Button("Join") { advisor.accept() }
                .controlSize(.small)
            Button("Not now") { advisor.dismiss() }
                .controlSize(.small)
        }
        frame {
            if compact {
                VStack(alignment: .leading, spacing: 8) { text; buttons }
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                HStack(alignment: .center, spacing: 16) { text; Spacer(minLength: 0); buttons }
            }
        }
        .help("The second row's tabs move to the end of the first. You can undo it straight after.")
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private var joined: some View {
        frame {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.secondary)
                Text("Rows joined").font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
                Button("Undo") { advisor.undo() }.controlSize(.small)
            }
        }
        .transition(.opacity)
    }

    private func frame<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(compact ? 10 : 12)
            .background(
                RoundedRectangle(cornerRadius: compact ? 9 : 12)
                    .fill(Color.accentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: compact ? 9 : 12)
                    .strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 1)
            )
            // Spacing lives here, so the banner takes no room at all when there is nothing to show.
            .padding(.horizontal, compact ? 8 : 20)
            .padding(.top, compact ? 0 : 14)
            .padding(.bottom, compact ? 8 : 0)
    }
}
