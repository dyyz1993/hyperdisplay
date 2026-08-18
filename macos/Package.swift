// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "hyperdisplay-host",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "HyperdisplayObjC",
            path: "Sources/HyperdisplayObjC",
            publicHeadersPath: "include"
        ),
        .executableTarget(
            name: "HyperdisplayHost",
            dependencies: ["HyperdisplayObjC"]
        ),
    ]
)
