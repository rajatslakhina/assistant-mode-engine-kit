// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AssistantModes",
    // Only the platforms CI actually builds: macOS (swift build + swift test) and iOS (xcodebuild, Simulator SDK).
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "AssistantModes", targets: ["AssistantModes"]),
        .library(name: "AssistantModesUI", targets: ["AssistantModesUI"]),
    ],
    targets: [
        .target(name: "AssistantModes"),
        .target(name: "AssistantModesUI", dependencies: ["AssistantModes"]),
        .testTarget(name: "AssistantModesTests", dependencies: ["AssistantModes", "AssistantModesUI"]),
    ]
)
