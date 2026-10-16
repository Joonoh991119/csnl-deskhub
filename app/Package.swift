// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DeskHub",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DeskHub",
            path: "Sources/DeskHub"
        )
    ]
)
