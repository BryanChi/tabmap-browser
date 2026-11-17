import Foundation

// Goes in Sources/TabMapCore.
//
// Profiles keep work and personal browsing apart. Each profile is its own Tabmap window running as its
// own process, with its own tab map, app dock, bookmarks, history, downloads list and website data
// (cookies, sign-ins, local storage). This file holds the pure rules: the list of profiles, how a
// process finds out which profile it is, and where each profile keeps its files.

public struct Profile: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Index into `Profile.colorNames`; the app turns it into a real colour.
    public var color: Int
    /// The first profile. It keeps the files Tabmap had before profiles existed, and the shared WebKit
    /// website data, so nobody is signed out by the upgrade.
    public var isDefault: Bool

    public init(id: UUID = UUID(), name: String, color: Int, isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.color = color
        self.isDefault = isDefault
    }

    public static let colorNames = ["blue", "orange", "green", "purple", "pink", "teal", "yellow", "gray"]

    /// One or two letters for the badge: "Work" → "W", "Side Project" → "SP".
    public var initials: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
        let letters = words.prefix(2).compactMap { $0.first.map { String($0).uppercased() } }
        return letters.isEmpty ? "?" : letters.joined()
    }

    /// Where this profile's files live, relative to Tabmap's Application Support folder.
    /// Empty for the default profile, which keeps the original location.
    public var relativeDataPath: String {
        isDefault ? "" : "Profiles/\(id.uuidString)"
    }
}

/// The list of profiles, saved as profiles.json and shared by every running profile.
public struct ProfileBook: Codable, Equatable, Sendable {
    public private(set) var profiles: [Profile]

    /// What a fresh install, or an install from before profiles, starts with.
    public init() {
        profiles = [
            Profile(name: "Personal", color: 0, isDefault: true),
            Profile(name: "Work", color: 1),
        ]
    }

    public init(profiles: [Profile]) {
        self.profiles = profiles
        repair()
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = try container.decode([Profile].self, forKey: .profiles)
        repair()
    }

    public var defaultProfile: Profile { profiles.first(where: \.isDefault) ?? profiles[0] }

    public func profile(_ id: UUID) -> Profile? { profiles.first { $0.id == id } }

    /// The profile for ⌃⌘1…9, in list order.
    public func profile(atShortcut number: Int) -> Profile? {
        guard number >= 1, number <= min(9, profiles.count) else { return nil }
        return profiles[number - 1]
    }

    /// Adds a profile with a unique name ("Profile", "Profile 2"…) and the least used colour.
    @discardableResult
    public mutating func add(named requested: String = "") -> Profile {
        let base = Self.clean(requested).isEmpty ? "Profile" : Self.clean(requested)
        let profile = Profile(name: uniqueName(base), color: leastUsedColor())
        profiles.append(profile)
        return profile
    }

    /// Renames a profile. Blank names are ignored; a name another profile has gets a number.
    public mutating func rename(_ id: UUID, to requested: String) {
        let name = Self.clean(requested)
        guard !name.isEmpty, let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        guard profiles[index].name != name else { return }
        profiles[index].name = uniqueName(name, ignoring: id)
    }

    public mutating func setColor(_ id: UUID, to color: Int) {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[index].color = Self.wrap(color)
    }

    /// Moves a profile up or down the list (which sets its ⌃⌘ number).
    public mutating func move(_ id: UUID, by offset: Int) {
        guard let from = profiles.firstIndex(where: { $0.id == id }) else { return }
        let to = max(0, min(profiles.count - 1, from + offset))
        guard to != from else { return }
        profiles.insert(profiles.remove(at: from), at: to)
    }

    /// Whether a profile may be deleted at all. The default one may not, nor the last one.
    public func canRemove(_ id: UUID) -> Bool {
        guard let profile = profile(id) else { return false }
        return !profile.isDefault && profiles.count > 1
    }

    /// Removes a profile from the list. Deleting its files and website data is the app's job.
    @discardableResult
    public mutating func remove(_ id: UUID) -> Profile? {
        guard canRemove(id), let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        return profiles.remove(at: index)
    }

    // MARK: Rules

    private func uniqueName(_ base: String, ignoring id: UUID? = nil) -> String {
        let taken = Set(profiles.filter { $0.id != id }.map { $0.name.lowercased() })
        if !taken.contains(base.lowercased()) { return base }
        var n = 2
        while taken.contains("\(base) \(n)".lowercased()) { n += 1 }
        return "\(base) \(n)"
    }

    private func leastUsedColor() -> Int {
        var counts = Array(repeating: 0, count: Profile.colorNames.count)
        for profile in profiles { counts[Self.wrap(profile.color)] += 1 }
        let least = counts.min() ?? 0
        return counts.firstIndex(of: least) ?? 0
    }

    private static func wrap(_ color: Int) -> Int {
        let n = Profile.colorNames.count
        return ((color % n) + n) % n
    }

    private static func clean(_ name: String) -> String {
        String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
    }

    /// Makes a list read from disk usable: never empty, exactly one default, unique ids, sane colours.
    private mutating func repair() {
        var seen = Set<UUID>()
        profiles = profiles.filter { seen.insert($0.id).inserted }
        if profiles.isEmpty { self = ProfileBook(); return }
        let firstDefault = profiles.firstIndex(where: \.isDefault) ?? 0
        for i in profiles.indices {
            profiles[i].isDefault = i == firstDefault
            profiles[i].color = Self.wrap(profiles[i].color)
            if Self.clean(profiles[i].name).isEmpty { profiles[i].name = profiles[i].isDefault ? "Personal" : "Profile" }
        }
    }
}

/// How a Tabmap process learns which profile it is: `--profile <uuid>` on its command line.
/// No argument, or an id that is no longer in the list, means the default profile.
public enum ProfileLaunch {
    public static let flag = "--profile"

    public static func requestedID(in arguments: [String]) -> UUID? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
        return UUID(uuidString: arguments[index + 1])
    }

    public static func resolve(arguments: [String], in book: ProfileBook) -> Profile {
        if let id = requestedID(in: arguments), let profile = book.profile(id) { return profile }
        return book.defaultProfile
    }

    public static func arguments(for profile: Profile) -> [String] {
        profile.isDefault ? [] : [flag, profile.id.uuidString]
    }
}
