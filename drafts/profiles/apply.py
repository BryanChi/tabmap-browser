#!/usr/bin/env python3
"""Applies the profiles feature to a Tabmap working copy.

Usage: python3 apply.py /path/to/Tabmap [--dry-run]

Copies the new files in, then makes small anchored edits. Every edit is checked first; if an anchor is
missing (another feature changed that spot) the script says which one and changes nothing. It also lists
any remaining Application Support paths or default website data stores that need routing through the
profile by hand (features merged after this script was written may add some).
"""
import pathlib
import re
import shutil
import sys

HERE = pathlib.Path(__file__).resolve().parent
root = pathlib.Path(sys.argv[1]).resolve()
dry = "--dry-run" in sys.argv
app = root / "Sources/Tabmap"
core = root / "Sources/TabMapCore"
tests = root / "Tests/TabMapCoreTests"

COPIES = {
    HERE / "Profiles.swift": core / "Profiles.swift",
    HERE / "ProfilesTests.swift": tests / "ProfilesTests.swift",
    HERE / "ProfileManager.swift": app / "ProfileManager.swift",
    HERE / "ProfileViews.swift": app / "ProfileViews.swift",
}

# (file, old, new) exact edits; each old must occur exactly once.
EDITS = [
    ("Persistence.swift",
     """        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        root = base.appendingPathComponent("Tabmap", isDirectory: true)""",
     """        // This profile's folder (the original Tabmap folder for the first profile).
        root = ProfileContext.current.dataDirectory"""),
    ("Persistence.swift",
     "/// Everything Tabmap keeps on disk lives in ~/Library/Application Support/Tabmap.",
     "/// Everything Tabmap keeps on disk lives in the profile's folder, ~/Library/Application Support/Tabmap\n"
     "/// for the first profile and Tabmap/Profiles/<id> for the others."),
    ("TabmapApp.swift",
     """        NSApp.activate(ignoringOtherApps: true)
    }
""",
     """        NSApp.activate(ignoringOtherApps: true)
        ProfileSwitcher.shared.didLaunch()
    }

    /// Right-click on the Dock icon: jump to any profile.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        ProfileSwitcher.shared.dockMenu()
    }
"""),
    ("TabmapApp.swift",
     """        }

        Settings {""",
     """            CommandMenu("Profiles") {
                ProfileMenuItems(withShortcuts: true)
            }
        }

        Settings {"""),
    ("ContentView.swift",
     ".navigationTitle(store.windowTitle)",
     ".navigationTitle(ProfileContext.current.titled(store.windowTitle))"),
    ("IslandView.swift",
     """            Button { store.sidebarShown.toggle() } label: {""",
     """            ProfileBadge()
            Button { store.sidebarShown.toggle() } label: {"""),
    ("SettingsView.swift",
     """        Form {
""",
     """        Form {
            ProfilesSettingsSection()
"""),
]

# The usual store idiom: "base = Application Support" then "root = base/Tabmap". Routed to the profile folder.
STORE_IDIOM = re.compile(
    r'let base = fm\.urls\(for: \.applicationSupportDirectory, in: \.userDomainMask\)\.first \?\? fm\.temporaryDirectory\n'
    r'(\s*)let root = base\.appendingPathComponent\("Tabmap", isDirectory: true\)')
STORE_NEW = "let root = ProfileContext.current.dataDirectory  // the profile folder"
DATA_STORE = re.compile(r'websiteDataStore = \.default\(\)|WKWebsiteDataStore\.default\(\)')
OWN_FILES = {"ProfileManager.swift", "ProfileViews.swift"}

problems = []
texts = {}

def text(name):
    if name not in texts:
        path = app / name
        if not path.exists():
            problems.append(f"missing file {path}")
            texts[name] = None
        else:
            texts[name] = path.read_text()
    return texts[name]

for name, old, new in EDITS:
    t = text(name)
    if t is None:
        continue
    if new in t:
        print(f"already applied: {name}: {new.strip().splitlines()[0][:60]}")
        continue
    n = t.count(old)
    if n != 1:
        problems.append(f"{name}: anchor found {n} times: {old.strip().splitlines()[0][:70]}")
        continue
    texts[name] = t.replace(old, new)

for path in sorted(app.glob("*.swift")):
    if path.name in OWN_FILES:
        continue
    t = text(path.name)
    if t is None:
        continue
    t, n = STORE_IDIOM.subn(STORE_NEW, t)
    if n:
        print(f"routed {n} store folder(s) in {path.name}")
    t, m = DATA_STORE.subn(lambda mt: "websiteDataStore = ProfileSwitcher.shared.websiteDataStore"
                           if mt.group(0).startswith("websiteDataStore") else "ProfileSwitcher.shared.websiteDataStore", t)
    if m:
        print(f"routed {m} website data store(s) in {path.name}")
    texts[path.name] = t

# Anything still pointing at the shared folder or WebKit's shared store needs a look by hand.
for name, t in texts.items():
    if t is None or name in OWN_FILES:
        continue
    for i, line in enumerate(t.splitlines(), 1):
        if "applicationSupportDirectory" in line or "nonPersistent()" in line:
            problems.append(f"check by hand: {name}:{i}: {line.strip()}")

if problems:
    print("\nNOT APPLIED:")
    for p in problems:
        print("  " + p)
    sys.exit(1)

if dry:
    print("\ndry run clean")
    sys.exit(0)

for src, dst in COPIES.items():
    shutil.copyfile(src, dst)
    print(f"copied {dst.relative_to(root)}")
for name, t in texts.items():
    if t is not None and t != (app / name).read_text():
        (app / name).write_text(t)
        print(f"edited {name}")
print("done")
