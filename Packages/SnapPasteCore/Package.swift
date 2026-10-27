// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SnapPasteCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SnapPasteCore", targets: ["SnapPasteCore"]),
    ],
    targets: [
        .target(name: "SnapPasteCore"),
        .testTarget(name: "SnapPasteCoreTests", dependencies: ["SnapPasteCore"]),
    ]
)
