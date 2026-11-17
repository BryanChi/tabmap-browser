# Built-in ad and tracker blocking

On by default (Settings > "Block ads and trackers", UserDefaults `contentBlockingEnabled`).

**Lists:** EasyList (ads) and EasyPrivacy (trackers), downloaded from easylist.to on first launch and
refreshed weekly (checked every 6 hours). Converted on this Mac by `FilterListConverter` (TabMapCore,
unit tested) into WebKit content rules and compiled by `WKContentRuleListStore`, which persists them,
so later launches just look them up. WebKit does the blocking and hiding inside the page process.
Until the first download finishes, a built-in list of ~40 common ad and tracking hosts is used.

**Conversion:** network filters with `||`, `|`, `*`, `^`, `@@` exceptions, third-party / first-party,
resource types and `~types`, domain=, match-case, popup; `@@||site^$document` page exceptions;
element hiding `##` (generic selectors batched 400 per rule) with `#@#` exceptions.
Skipped: regex filters, scriptlets / extended CSS, redirect, csp, removeparam and similar.
Request rules and hiding rules compile as separate lists (≤60,000 rules each); every request list
carries all exceptions, since WebKit only applies an exception within its own list. If WebKit
rejects a list, it is halved and retried, so one bad rule only loses a small slice.

**Per site:** a shield in the address island (between reload and the address field). Filled = blocking
on; click to allow ads on that site (shield with a slash) and the page reloads. Also in View menu:
"Allow / Block Ads and Trackers on This Site". Allowed sites (with subdomains, "www." ignored) are in
UserDefaults `contentBlockingAllowedSites` and listed in Settings with a remove button.
Mechanism: before each main-frame load `ContentBlocker.prepare` adds or removes the rule lists on
that tab's WKUserContentController.

**Blocked page:** opening an address that is itself on a list shows a short page saying so (WebKit
error 104), pointing at the shield.

## Applying
`python3 apply.py ~/Developer/Tabmap [--dry-run]` copies FilterListConverter.swift (core),
FilterListConverterTests.swift, ContentBlocker.swift (app) and makes anchored edits to WebTab
(install, prepare, error 104), IslandView (shield), SettingsView (section), TabmapApp (menu item).
Dry run clean against GitHub main (55b4ac9) on 2026-11-17.

## Check by hand
A news site with ads (e.g. a big newspaper) before/after; the shield toggle reloads and ads return;
Settings shows the rule count after the download; a second launch shows the full count immediately.
Known limits: no blocked-request count (WebKit has no public callback for it); a popup shares its
opener's content controller, so a per-site setting can briefly follow it to the other tab.
