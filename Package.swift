// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Hako",
    platforms: [
        .macOS("14.4") // NSMenuItem.subtitle を使うため
    ],
    targets: [
        .executableTarget(
            name: "Hako",
            path: "Sources/Hako"
        )
    ]
)
