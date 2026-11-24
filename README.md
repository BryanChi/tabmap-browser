# Tabmap

A macOS browser where you never close a tab. Tabs live on a two-dimensional map instead of a strip:

- **Across (X) is context.** A link you open from a page (Cmd-click, or a link that opens a new tab) lands immediately to the right of that page, in the same row. A row is a *trail*: one train of thought.
- **Down (Y) is time.** The row you used most recently is on top. Rows you stop using sink. Tabs left alone long enough close on their own and drop below the horizon line, where they stay restorable.

## Build and run

Requires macOS 13 or later and Xcode 15 or later (or the matching Swift toolchain).

```sh
swift run Tabmap            # quick run from the terminal
scripts/make-app.sh         # builds build/Tabmap.app, then: open build/Tabmap.app
swift test                  # unit tests for the tab map rules
```

You can also open `Package.swift` in Xcode and press Run.

## How the map behaves

| Rule | Detail |
| --- | --- |
| New trail | `⌘T` starts a blank tab in a new row at the top. |
| Open to the right | Cmd-click opens the link to the right of the current tab, in the background. Add Shift to switch to it. Links that ask for a new tab or window open to the right and come to the front. Several links opened from the same page line up in the order you opened them. |
| What counts as use | A tab counts as used once you stay on it for 1.5 seconds, pick it from the map, or navigate in it. Stepping past a tab with the keyboard does not reshuffle the map. |
| Row order | Rows are ordered by the most recent use of any open tab in the row, under time labels (Last hour, Earlier today, Yesterday, This week, Older). |
| Sleep | After 30 minutes unused, a tab's page is unloaded to free memory. It keeps its place and thumbnail and reloads, with its history and scroll position, when you return. At most 12 pages stay in memory. A page playing audio or video is left awake. |
| Auto-close | After 1 day unused, a tab closes. In a row that is still in use it moves to the right end of the row, after a small gap, as a faded tab (the most recently closed nearest the open tabs). The 8 most recent closed tabs are shown; the rest are behind a **+N** button at the end of the row. A reopened tab goes back to its original place in the row. When every tab in a row has closed, the row sinks below the **Closed** horizon. |
| Re-home a tab | Drag a tab onto the left or right edge of another tab to put it beside that tab, onto empty space in a row to add it to the end of that row, or onto the **New row** strip to give it a row of its own. Right-click a tab for **Move to New Row**. |
| Restore | Click any closed tab, or press `⇧⌘T` for the most recent one. It reopens with its history and its row rises to the top. |
| Forget | Closed tabs are deleted for good after 30 days. |
| Pin | `⇧⌘P` pins a tab so it is never closed automatically. |

The front tab is never put to sleep or closed. All the time limits, the page limit and the search engine are in Settings (`⌘,`).

## Group names

Once a trail holds two or more pages, it gets a short name (2 to 4 words) and a one-sentence description, shown just above the row. In the sidebar only the name shows; hover it for the description. The name is made again a few seconds after the row's pages change (a page added, removed, or navigated), and dropped when the row falls back to one page.

- **On-device model.** On macOS 26 with Apple Intelligence turned on, names come from Apple's on-device language model (the Foundation Models framework). Page titles and site names are the only input, and nothing leaves the Mac.
- **Fallback.** On older macOS, with Apple Intelligence off, or if the model refuses or fails, the name is built from the words the page titles share (or the main site's name), and the description counts the pages and sites, e.g. "5 pages across github.com, stackoverflow.com and 1 other site".
- **Search.** In the full map, a query that matches a row's name or description shows that whole row; otherwise only the matching tabs show. Every word you type has to match.

Settings says which of the two is in use. The model path is compiled only with a macOS 26 SDK (Xcode 26, or the Command Line Tools with Swift 6.2); built with an older SDK, Tabmap always uses the fallback.

## Joining rows

When two rows are about the same thing, Tabmap offers to join them.

- **How rows are compared.** Rows with open tabs are compared by the words in their page titles, the searches they hold, and the sites (and corners of a site, such as one GitHub repository) they share. Search engines and filler words don't count, and one shared word is never enough.
- **On-device model.** Where Apple Intelligence is available, the likeliest pairs go to the on-device model, which says yes or no and words the reason ("Both about planning a trip to Kyoto"). Without it, only strong matches are offered.
- **The offer.** A banner at the top of the sidebar and of the full map names the two rows, with **Join** and **Not now**. The more recently used row keeps its place; the other row's tabs move to its right-hand end, keeping their pages and history. The joined row is then renamed by itself.
- **Undo.** For 10 seconds after a join the banner offers **Undo**, which splits the rows again (tabs opened from a moved tab since go back with it). Not now or Undo stops that pair being offered again.
- **Settings** has a switch to turn the offers off. Everything stays on the Mac, and nothing is joined until you press Join.

## The window

There is no title bar and no toolbar: the page fills the whole window.

- **The island.** Move the pointer to the top edge of the window (or press `⌘L`) and a black capsule drops down at the top centre with back, forward, reload, the address field, a button to pin the map sidebar and a button for the full map. It folds away when the pointer moves more than 80 points down from the top, unless you are typing in it. On a blank tab it stays open. While a page loads, the island shows as a small pill with the site and a progress ring; click it to edit the address.
- **The map sidebar.** Push the pointer against the left edge and the sidebar floats in over the page; it slides away once the pointer is more than 300 points from the edge. `⇧⌘S` (or the pin button in the sidebar or the island) pins it open beside the page.
- **The full map.** `⌘E`, or pinch your fingers together on a page that is not zoomed in: the page shrinks onto its own card in the map as your fingers close. Spread your fingers on the map and the selected tab grows back out to fill the window.
- The close, minimise and zoom buttons only show while the island, the pinned sidebar or the full map is showing.

## Gestures

| Gesture | Action |
| --- | --- |
| Two-finger swipe at the edge of a page | Moves through the map, with the pages following your fingers. Vertical: at the top of the page, swiping down shows the trail above; at the bottom, swiping up shows the trail below. Sideways: once the page has no back/forward history left in that direction, it slides to the neighbouring tab in the trail. Let go part-way and the page springs back |
| `⌥` + two-finger swipe | Always moves through the map, wherever the page is scrolled |
| Two-finger sideways swipe | Back and forward in the page while it has history in that direction |
| Pinch fingers together on a page | Zooms out onto the page's card in the full map |
| Spread fingers on the full map | Opens the selected tab, zooming in from its card |
| Pinch on a zoomed-in page | Zooms the page |
| `⌥` + mouse wheel | One step through the map per notch |
| Three-finger swipe | Slides to the neighbouring tab, if macOS sends it: set System Settings > Trackpad > More Gestures > Swipe between pages to include three fingers |

The edge behaviour can be turned off in Settings; `⌥` + swipe keeps working. `⌥⌘` + arrow keys slide between tabs the same way, and give a small nudge when there is no tab in that direction.

## Downloads

- **Badge on the tab.** Each download is tied to the tab it came from. That tab gets a small badge with the number of files, in the sidebar and in the full map. A link that opens an empty window just for the file puts the badge on the tab the link was on.
- **Search by file name.** In the map search (`⌘E`), typing part of a file's name finds the tab it was downloaded from.
- **List grouped by row.** `⌥⌘L` (or the pill at the top right) shows every download under the row its tab is in. Right-click a tab for the files from that tab only.
- **Back to the source tab.** From the list, jump to the tab a file came from (it reopens if it was closed) or show the file in Finder. Drop a downloaded file on Tabmap's Dock icon to go to the page it came from.
- Files are saved to `~/Downloads`, with the address and page recorded in Finder's "Where from".

## Bookmarks

- **One key to save.** `⌘D` saves the page in front with a picture of it. A note at the top right says Bookmarked, then which collection it was filed in and its tags.
- **Highlights.** Text selected on the page when you press `⌘D` is saved with the bookmark as a highlight; on a page already saved, `⌘D` with a selection adds another. Clicking a highlight on the board opens the page scrolled to that passage.
- **Saved rows.** `⇧⌘B` saves the whole row: its open pages in order, its name and description. Opening it brings it back as a new row.
- **The board.** `⌘B` (or Esc to close) shows every bookmark as a card, with smart views and your collections down the side. Drag a card onto a collection to file it there; Edit… changes its title, tags and collection, and File Automatically puts the automatic choice back.
- **Search by anything.** The board's search looks at titles, addresses, tags, notes, highlights, the text of the page itself and its main colours ("blue").
- **Filed for you.** New bookmarks are filed and tagged on this Mac by Apple Intelligence when it is available, otherwise from their site and words. Nothing leaves this Mac.
- **Hot corner.** In Settings, pick a corner of the window (bottom right works best): resting the pointer there opens the board, and again closes it.
- **Changes and dead links.** Once a day, saved pages are fetched (without your cookies) to see whether they changed or are gone. A page that is gone shows the copy saved when you bookmarked it.
- Everything stays in `~/Library/Application Support/Tabmap/bookmarks`.

## Links from other apps

Links opened in other apps (Claude, Slack, Mail) open in a new row at the top of the map, with that app's icon on the tab. Search the map for the app's name to find them, along with the tabs you opened from them. For this, make Tabmap the default browser: Settings (⌘,) → Make Default.

## Passwords and passkeys

- **Fill.** Click into a sign-in field and a pill under the island offers the logins saved for that site (subdomains count, so a login for `google.com` shows on `accounts.google.com`). Filling asks for Touch ID or your Mac password, then not again for five minutes. Each frame only ever gets logins for its own site, and only over https.
- **Save.** After you sign in or change a password, the pill offers Save, Update, Never for This Site or Not Now. Two-step sign-ins (account on one page, password on the next) are saved with the account from the first page.
- **Suggest.** In a new-password field the pill offers a strong password (`abcdEf-ghij2k-mnopqr` style). Using it saves it as soon as the form is sent.
- **Where they live.** Logins are internet passwords in your Mac's login keychain, so Keychain Access shows them and the importer can add logins exported from Chrome, Safari or the Passwords app. Settings > Saved Passwords lists, reveals, copies and deletes them.

What macOS does not allow a browser like this (as of macOS 26):

- **iCloud Keychain passwords** cannot be read directly. There is no public API for it. Apple's own bridge (the helper behind the iCloud Passwords extension for Chrome and Firefox) only answers browsers on Apple's allow-list in [`apple/password-manager-resources`](https://github.com/apple/password-manager-resources/blob/main/quirks/web-browser-extension-distribution-information.json), which checks the bundle ID and the Developer ID team. Getting there needs a paid Apple Developer account, Developer ID signing, and a pull request to that list. Until then, export from the Passwords app (File > Export All Passwords) and import the file.
- **Passkeys** in a WKWebView need Apple's `com.apple.developer.web-browser.public-key-credential` entitlement. The Account Holder of a paid Apple Developer account requests it on a dedicated form; Apple approves it by hand. Without it WebKit refuses every passkey request, so Tabmap tells sites there is no passkey support (most then show their password form) and, when a site asks for a passkey anyway, offers to finish that sign-in in Safari.
- Once the entitlement is granted, build with `TABMAP_SIGN_IDENTITY="Developer ID Application: …" TABMAP_TEAM_ID=XXXXXXXXXX TABMAP_PROVISIONING_PROFILE=path/to/profile.provisionprofile scripts/make-app.sh`. The app then detects the entitlement, drops the fallback, and WebKit handles passkeys from iCloud Keychain, security keys and phones itself. The bundle ID in `scripts/Info.plist` must match the App ID the entitlement was granted for.

## Letting Claude control Tabmap

Turn on **Settings > Let Claude control Tabmap**, then run the command shown there in Terminal to add Tabmap to Claude Code as an MCP server (`claude mcp add --transport http tabmap http://127.0.0.1:47823/mcp --header "Authorization: Bearer <key>"`).

- Claude gets tools to list and switch tabs, open pages, read a page (text plus numbered elements), take a screenshot, click, hover, type, press keys, scroll, pick from drop-downs and wait; to close and name tabs and rows of its own, show two of its tabs in split view, and list downloads.
- Clicks, typing and scrolling are real mouse, keyboard and wheel events sent to the page, in your normal signed-in session. Pages Claude opens go in its own row, marked with Claude's icon.
- Claude can work in background tabs, several at once, while you use Tabmap: each is held in an off-screen window that WebKit keeps running as if it were in front, and gets the same real input. Tabs on screen (the page in front, both halves of a split) share one queue; each background tab has its own. A link that opens a new tab from a background tab opens it in the background too.
- Every action waits for the page to load and settle (no requests finishing and no content changing for half a second) before it returns.
- Pages are read from the page's HTML, or, if you allow Tabmap under **Privacy & Security > Accessibility** (Settings has an **Allow…** button), from WebKit's accessibility tree, the way VoiceOver reads them, including frames from other sites.
- While Claude acts on a page you can see, the page glows, Claude's own pointer moves across it, and a pill at the bottom says what it is doing, with **Stop**. Clicking or typing in that page yourself also stops it. Work in background tabs shows as a count on the pill, and Stop stops every tab.
- Claude never reads or types passwords. When a site shows a human check (CAPTCHA, Cloudflare and the like), asks for a password, or puts up a dialog, Claude stops, you get a notification, and the pill shows **Done** for when you have dealt with it. Claude does not try to get past human checks.
- The server listens on 127.0.0.1 only, refuses requests from web pages, and needs the key from Settings (**New Key** replaces it).

## Keyboard

| Keys | Action |
| --- | --- |
| `⌘T` | New trail |
| `⌥⌘T` | New blank tab to the right, in this trail |
| `⌘L` | Show the island and focus the address field (Esc returns to the page) |
| `⌘E` | Open or close the full tab map |
| `⌥⌘←` `⌥⌘→` | Previous or next tab in this trail |
| `⌥⌘↑` `⌥⌘↓` | Trail above or below (lands on the tab you last used there) |
| `⌘W` | Close the tab now (it stays restorable) |
| `⇧⌘T` | Reopen the last closed tab |
| `⇧⌘P` | Pin or unpin the tab |
| `⇧⌘S` | Pin the map sidebar open, or unpin it |
| `⌥⌘L` | Show or hide the downloads list |
| `⌘D` | Bookmark the page (with the selected text as a highlight) |
| `⇧⌘B` | Bookmark the whole row |
| `⌘B` | Show or hide the bookmark board |
| `⌘[` `⌘]` `⌘R` | Back, forward, reload |

In the full map: type to search open and closed tabs and group names, arrows to move, Return to open, `⌘⌫` to close the selected tab, Esc to dismiss.

## Layout of the code

- `Sources/TabMapCore` holds every rule of the map as plain Swift with no UI: where a new tab goes, row ordering, sleep, auto-close, restore, keyboard movement, and address parsing. `Tests/TabMapCoreTests` covers it.
- `Sources/Tabmap` is the app: `BrowserStore` (state and actions), `WebTab` (one WKWebView per loaded tab), `MapViews` (sidebar and full map), `TrailNamer` (group names), `MergeAdvisor` (offers to join rows), `ContentView` (window layout), `PageStage` (the AppKit view that shows pages, two at once during a swipe), `GestureNavigator` (swipe, pinch and the map zoom), `GestureViews` (overview layer and the swipe dot map), `IslandView` (the floating chrome), `NativeTextField` (the borderless address and search field), `Persistence`, `SettingsView`.

State is saved to `~/Library/Application Support/Tabmap` (the map as `state.json`, plus thumbnails and per-tab session data), so the map survives quitting.

## Not built yet

Private windows, multiple windows, and extensions.
