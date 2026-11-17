# Profiles: integration

Work and Personal (and any others) each get their own window, tab map, app dock, bookmarks, history,
downloads list and website sign-ins. Both can be open side by side.

## How it works
- Each profile is its own Tabmap process, started with `--profile <uuid>` (no argument = the first profile).
  All stores stay singletons and read their files from `ProfileContext.current.dataDirectory`.
- First profile ("Personal") keeps `~/Library/Application Support/Tabmap` and WebKit's shared website data,
  so nothing moves and nobody is signed out. Other profiles: `Tabmap/Profiles/<uuid>/` and
  `WKWebsiteDataStore(forIdentifier:)` (macOS 14+; macOS 13 falls back to a private store forgotten on quit).
- `Tabmap/profiles.json` holds the list (seeded Personal + Work). Any window can edit it; others reload on activate.
- `running.lock` in each profile folder (flock) keeps one process per profile. A second launch of the same
  profile activates the first and exits before touching any files.
- Switching: badge at the right of the island, Profiles menu (⌃⌘1…9), right-click Dock menu, Settings.
  Non-first profiles show their initials as a Dock badge and their name in the window title.
- Deleting a profile (Settings, only when its window is closed) removes its folder and website data.

## Apply
    python3 apply.py ~/Developer/Tabmap --dry-run
    python3 apply.py ~/Developer/Tabmap
Copies Profiles.swift (core), ProfilesTests.swift, ProfileManager.swift, ProfileViews.swift; edits
Persistence, TabmapApp, ContentView, IslandView, SettingsView; routes every store that uses the
`base = Application Support / root = base/Tabmap` idiom, and every `.default()` website data store, to
the profile. It stops and lists anything else that still names Application Support (e.g. stores added
by later features with a different idiom): route those to `ProfileContext.current.dataDirectory` by hand.

## Check by hand
1. Fresh launch opens Personal with existing tabs and sign-ins intact.
2. ⌃⌘2 opens a Work window: empty map, signed out everywhere, "W" badge on the Dock icon.
3. Sign in to a site in Work; Personal stays signed out of it (and vice versa).
4. ⌃⌘1 / ⌃⌘2 bring each window forward; launching Tabmap again doesn't make a second Personal.
5. Quit and relaunch both: each keeps its own map, dock apps, bookmarks.
6. Settings → Profiles: rename, recolour, reorder, new profile, delete a closed profile.
