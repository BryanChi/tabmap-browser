#!/usr/bin/env python3
"""Fits built-in ad and tracker blocking into a Tabmap checkout.

    python3 apply.py ~/Developer/Tabmap            # apply
    python3 apply.py ~/Developer/Tabmap --dry-run  # only report

Copies the new files, then makes small anchored edits. Idempotent: an edit whose marker is
already present is skipped. Any anchor it cannot find is reported and nothing in that file changes.
"""
import pathlib, shutil, sys

here = pathlib.Path(__file__).resolve().parent
root = pathlib.Path(sys.argv[1]).expanduser()
dry = "--dry-run" in sys.argv
problems = []

copies = {
    "FilterListConverter.swift": "Sources/TabMapCore/FilterListConverter.swift",
    "FilterListConverterTests.swift": "Tests/TabMapCoreTests/FilterListConverterTests.swift",
    "ContentBlocker.swift": "Sources/Tabmap/ContentBlocker.swift",
}

# (file, marker that shows the edit is done, anchor, replacement)
edits = [
    ("Sources/Tabmap/WebTab.swift", "ContentBlocker.shared.install",
     "        EdgeProbe.shared.install(in: config)\n",
     "        EdgeProbe.shared.install(in: config)\n"
     "        ContentBlocker.shared.install(in: config)\n"),
    ("Sources/Tabmap/WebTab.swift", "ContentBlocker.shared.prepare",
     "        if navigationAction.shouldPerformDownload { return .download }\n",
     "        // Ad and tracker blocking on or off for the site this tab is about to show.\n"
     "        if navigationAction.targetFrame?.isMainFrame == true { ContentBlocker.shared.prepare(webView, for: url) }\n"
     "        if navigationAction.shouldPerformDownload { return .download }\n"),
    ("Sources/Tabmap/WebTab.swift", "showBlockedByContentBlocker",
     "        if ns.domain == \"WebKitErrorDomain\", ns.code == 102 { return }\n",
     "        if ns.domain == \"WebKitErrorDomain\", ns.code == 102 { return }\n"
     "        if ns.domain == \"WebKitErrorDomain\", ns.code == 104 { showBlockedByContentBlocker(ns); return }\n"),

    ("Sources/Tabmap/IslandView.swift", "BlockingShield",
     "\n            NativeTextField(\n",
     "\n            BlockingShield(url: store.frontURL)\n\n            NativeTextField(\n"),

    ("Sources/Tabmap/SettingsView.swift", "ContentBlockingSettings()",
     "            Section {\n                Toggle(\"Go to the existing tab",
     "            ContentBlockingSettings()\n"
     "            Section {\n                Toggle(\"Go to the existing tab"),

    ("Sources/Tabmap/TabmapApp.swift", "private var blocker = ContentBlocker.shared",
     "    @ObservedObject private var dock = AppDock.shared\n",
     "    @ObservedObject private var dock = AppDock.shared\n"
     "    @ObservedObject private var blocker = ContentBlocker.shared\n"),
    ("Sources/Tabmap/TabmapApp.swift", "Ads and Trackers on This Site",
     "                Button(\"Reload Page\") { store.reload() }\n"
     "                    .keyboardShortcut(\"r\", modifiers: [.command])\n",
     "                Button(\"Reload Page\") { store.reload() }\n"
     "                    .keyboardShortcut(\"r\", modifiers: [.command])\n"
     "                Button(blocker.isBlocking(on: store.frontURL) || !blocker.enabled\n"
     "                       ? \"Allow Ads and Trackers on This Site\" : \"Block Ads and Trackers on This Site\") {\n"
     "                    blocker.toggleSite(of: store.frontURL)\n"
     "                }\n"
     "                .disabled(!blocker.enabled || store.frontURL?.host == nil)\n"),
]

for src, dst in copies.items():
    target = root / dst
    print(("would copy " if dry else "copy ") + f"{src} -> {dst}")
    if not dry:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(here / src, target)

by_file = {}
for e in edits:
    by_file.setdefault(e[0], []).append(e)

for rel, file_edits in by_file.items():
    path = root / rel
    text = path.read_text()
    ok = True
    for _, marker, anchor, replacement in file_edits:
        if marker in text:
            print(f"skip (done)  {rel}: {marker!r}")
            continue
        n = text.count(anchor)
        if n != 1:
            problems.append(f"{rel}: anchor found {n} times: {anchor[:70]!r}")
            ok = False
            continue
        text = text.replace(anchor, replacement)
        print(f"edit         {rel}: {marker!r}")
    if ok and not dry:
        path.write_text(text)

if problems:
    print("\nPROBLEMS (those files were left unchanged):")
    for p in problems:
        print("  " + p)
    sys.exit(1)
print("\nall edits applied" if not dry else "\ndry run clean")
