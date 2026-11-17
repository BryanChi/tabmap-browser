import AppKit
import SwiftUI
import TabMapCore

// Goes in Sources/Tabmap.

/// The menu items for switching profiles: used by the island badge, the Profiles menu and the Dock menu.
struct ProfileMenuItems: View {
    @ObservedObject private var profiles = ProfileSwitcher.shared
    /// Menu-bar copies get ⌃⌘1…9; the island's copy doesn't need them twice.
    var withShortcuts = false

    var body: some View {
        ForEach(Array(profiles.book.profiles.enumerated()), id: \.element.id) { index, profile in
            let button = Button {
                profiles.open(profile)
            } label: {
                if profiles.isCurrent(profile) {
                    Label(profile.name, systemImage: "checkmark")
                } else {
                    Text(profile.name)
                }
            }
            if withShortcuts && index < 9 {
                button.keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.control, .command])
            } else {
                button
            }
        }
        Divider()
        Button("New Profile") { profiles.newProfile() }
        Button("Edit Profiles…") { ProfileSwitcher.openSettings() }
    }
}

extension ProfileSwitcher {
    static func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        if #available(macOS 14.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
    }

    /// The menu under the Dock icon (right-click): every profile, so you can jump straight to one.
    func dockMenu() -> NSMenu {
        let menu = NSMenu()
        for profile in book.profiles {
            let item = NSMenuItem(title: profile.name, action: #selector(DockMenuTarget.pick(_:)), keyEquivalent: "")
            item.target = DockMenuTarget.shared
            item.representedObject = profile.id
            item.state = isCurrent(profile) ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let add = NSMenuItem(title: "New Profile", action: #selector(DockMenuTarget.add(_:)), keyEquivalent: "")
        add.target = DockMenuTarget.shared
        menu.addItem(add)
        return menu
    }
}

@MainActor
final class DockMenuTarget: NSObject {
    static let shared = DockMenuTarget()

    @objc func pick(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let profile = ProfileSwitcher.shared.book.profile(id) else { return }
        ProfileSwitcher.shared.open(profile)
    }

    @objc func add(_ sender: NSMenuItem) { ProfileSwitcher.shared.newProfile() }
}

/// A small coloured circle with the profile's initials, at the right end of the island.
/// Click it to switch profiles.
struct ProfileBadge: View {
    @ObservedObject private var profiles = ProfileSwitcher.shared

    var body: some View {
        let profile = profiles.currentProfile
        Menu {
            ProfileMenuItems()
        } label: {
            ProfileDot(profile: profile, size: 20)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profile: \(profile.name). Click to switch (⌃⌘1…9).")
    }
}

struct ProfileDot: View {
    let profile: Profile
    var size: CGFloat = 20

    var body: some View {
        Text(profile.initials)
            .font(.system(size: size * (profile.initials.count > 1 ? 0.4 : 0.5), weight: .bold, design: .rounded))
            .foregroundColor(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(profile.swatch))
    }
}

/// The Profiles part of Settings: rename, recolour, reorder, open and delete profiles.
struct ProfilesSettingsSection: View {
    @ObservedObject private var profiles = ProfileSwitcher.shared

    var body: some View {
        Section {
            ForEach(profiles.book.profiles) { profile in
                ProfileRow(profile: profile)
            }
            HStack {
                Button("New Profile") { profiles.newProfile() }
                Spacer()
            }
            Text(ProfileSwitcher.keepsSignInsSeparately
                 ? "Each profile has its own window, tab map, app dock, bookmarks, history and website sign-ins. Switch with the badge in the address bar or ⌃⌘1…9; both can stay open side by side."
                 : "Each profile has its own window, tab map, app dock, bookmarks and history. On macOS 13, sign-ins in profiles other than the first are forgotten when Tabmap quits; macOS 14 keeps them.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Profiles")
        }
    }
}

private struct ProfileRow: View {
    @ObservedObject private var profiles = ProfileSwitcher.shared
    let profile: Profile
    @State private var draft = ""
    @FocusState private var editing: Bool

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(Profile.colorNames.indices, id: \.self) { index in
                    Button(Profile.colorNames[index].capitalized) { profiles.setColor(profile, to: index) }
                }
            } label: {
                ProfileDot(profile: profile, size: 18)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Colour")

            TextField("Name", text: $draft)
                .textFieldStyle(.plain)
                .focused($editing)
                .onSubmit { profiles.rename(profile, to: draft) }
                .onChange(of: editing) { focused in
                    if !focused { profiles.rename(profile, to: draft) }
                }

            if profiles.isCurrent(profile) {
                Text("This window").font(.system(size: 11)).foregroundColor(.secondary)
            } else {
                Button("Open") { profiles.open(profile) }
            }
            Button { profiles.move(profile, by: -1) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.borderless)
                .disabled(profiles.book.profiles.first?.id == profile.id)
                .help("Move up (sets its ⌃⌘ number)")
            Button { profiles.delete(profile) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .disabled(profiles.deleteBlocker(profile) != nil)
                .help(profiles.deleteBlocker(profile) ?? "Delete this profile and its data")
        }
        .onAppear { draft = profile.name }
        .onChange(of: profile.name) { name in if !editing { draft = name } }
    }
}
