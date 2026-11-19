// swift-tools-version: 5.9
import PackageDescription

// Everything the Mac app, the iOS app and the iOS extensions share: prompts and result models, the provider
// clients, settings, the translation cache, usage tracking and the vocabulary store. UI and anything that only
// one platform can do (reading selections, global hotkeys, screen capture, Sparkle) stay in the app targets.
let package = Package(
    name: "SwipeSayKit",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "SwipeSayKit", targets: ["SwipeSayKit"]),
    ],
    targets: [
        .target(name: "SwipeSayKit"),
        .testTarget(name: "SwipeSayKitTests", dependencies: ["SwipeSayKit"]),
    ]
)
