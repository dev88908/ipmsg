// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IPMsgMac",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "IPMsgMac", targets: ["IPMsgMac"]),
        .library(name: "IPMsgCore", targets: ["IPMsgCore"]),
    ],
    targets: [
        // Protocol + networking engine. No UI dependency, fully unit-testable.
        .target(
            name: "IPMsgCore"
        ),
        // SwiftUI front-end.
        .executableTarget(
            name: "IPMsgMac",
            dependencies: ["IPMsgCore"]
        ),
        .testTarget(
            name: "IPMsgCoreTests",
            dependencies: ["IPMsgCore"]
        ),
    ]
)
