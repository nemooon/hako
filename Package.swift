// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ColimaUI",
    platforms: [
        .macOS("14.4") // NSMenuItem.subtitle を使うため
    ],
    targets: [
        .executableTarget(
            name: "ColimaUI",
            path: "Sources/ColimaUI"
        )
    ]
)
