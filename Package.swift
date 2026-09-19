// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Blip",
    platforms: [.macOS("15.2")],
    targets: [
        // Pure logic. No system frameworks, no permissions, no screen required.
        // Everything bug-dense (coordinates, numbering, matching, merging) lives here
        // so it can be unit tested headlessly.
        .target(
            name: "BlipCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // System integration: Accessibility, ScreenCaptureKit, Vision, CGEventTap.
        // Swift 5 language mode: CGEventTap needs bare C function pointers that cannot
        // capture context, which strict concurrency checking cannot express.
        .target(
            name: "BlipKit",
            dependencies: ["BlipCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .executableTarget(
            name: "Blip",
            dependencies: ["BlipKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        // Headless debug CLI: runs the real scan pipeline and dumps JSON + timings.
        .executableTarget(
            name: "blip-probe",
            dependencies: ["BlipKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "BlipCoreTests",
            dependencies: ["BlipCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
