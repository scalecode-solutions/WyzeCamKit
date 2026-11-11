// swift-tools-version: 6.2
import PackageDescription

// WyzeCamKit — the home-camera client as a self-contained SPM: Connect transport
// for the control plane, a WebRTC player for live view, and the UI. Talks to
// mvCamera. A host app (or WyzeCamLab) adds a thin wrapper that supplies
// identity + a token.
//
// Mirrors LushKit's and GarageKit's shape: the kit never owns login — the host
// injects a `tokenProvider`. Swift 6 strict concurrency from line one. WebRTC
// comes from smc_webRTC, a shared WebRTC binary a host may already link, so a
// host never carries two copies.
let package = Package(
    name: "WyzeCamKit",
    platforms: [.iOS(.v26)], // iOS-only
    products: [
        .library(name: "WyzeCamKit", targets: ["WyzeCamKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/connectrpc/connect-swift", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf", from: "1.27.0"),
        .package(url: "https://github.com/scalecode-solutions/smc_webRTC.git", from: "152.0.0"),
    ],
    targets: [
        .target(
            name: "WyzeCamKit",
            dependencies: [
                .product(name: "Connect", package: "connect-swift"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "WebRTC", package: "smc_webRTC"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "WyzeCamKitTests",
            dependencies: ["WyzeCamKit"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
