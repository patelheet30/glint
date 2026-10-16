// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Glint",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "Glint", path: "Sources/Glint")
    ],
    swiftLanguageModes: [.v5]
)
