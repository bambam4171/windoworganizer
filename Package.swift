// swift-tools-version:6.0
import PackageDescription

// No Xcode on the build Mac: XCTest and Swift Testing are unavailable with the Command Line Tools
// alone, so the tests are a plain executable (WOChecks) that the gate runs.
let package = Package(
    name: "WindowOrganizer",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "WindowOrganizerCore"),
        .executableTarget(name: "WindowOrganizer", dependencies: ["WindowOrganizerCore"]),
        .executableTarget(name: "WOChecks", dependencies: ["WindowOrganizerCore"]),
    ]
)
