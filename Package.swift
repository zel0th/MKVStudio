// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "MKVStudio",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MKVStudio", targets: ["MKVStudio"])],
    targets: [
        .executableTarget(name: "MKVStudio", path: "MKVStudio", exclude: ["Assets.xcassets", "Preview Content", "Resources", "MKVStudio.entitlements"]),
        .testTarget(name: "MKVStudioTests", dependencies: ["MKVStudio"], path: "Tests")
    ],
    swiftLanguageModes: [.v6]
)
