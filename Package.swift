// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Tabmap",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Tabmap", targets: ["Tabmap"]),
        .library(name: "TabMapCore", targets: ["TabMapCore"]),
    ],
    targets: [
        // Pure Foundation model of the tab map: no AppKit, fully unit tested.
        .target(name: "TabMapCore"),
        // The macOS app: SwiftUI shell around WKWebView.
        .executableTarget(name: "Tabmap", dependencies: ["TabMapCore"]),
        .testTarget(name: "TabMapCoreTests", dependencies: ["TabMapCore"]),
    ]
)
