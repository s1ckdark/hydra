// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hydra",
    platforms: [
        .macOS(.v15),
        .iOS(.v17)
    ],
    products: [
        .executable(name: "Hydra", targets: ["Hydra"]),
    ],
    dependencies: [
        .package(url: "https://github.com/s1ckdark/SwiftTerm", revision: "54b436a6231976fa64d7c3859d0b197a6ccfcb91"),
        .package(path: "Packages/TerminalCore"),
    ],
    targets: [
        .executableTarget(
            name: "Hydra",
            dependencies: [
                // 터미널 기능은 macOS 전용 — iOS 빌드에는 링크하지 않음
                .product(name: "SwiftTerm", package: "SwiftTerm", condition: .when(platforms: [.macOS])),
                .product(name: "SSHTransport", package: "TerminalCore", condition: .when(platforms: [.macOS])),
                .product(name: "SSHTransportMac", package: "TerminalCore", condition: .when(platforms: [.macOS])),
                .product(name: "KnownHosts", package: "TerminalCore", condition: .when(platforms: [.macOS])),
            ],
            path: "Hydra",
            resources: [
                .process("Assets.xcassets")
            ],
            // tools-version 6.0 defaults to the Swift 6 language mode; the existing
            // app sources were written for Swift 5. Keep them in Swift 5 mode so the
            // platform bump (macOS 15, required by libssh2/SSHTransportMac) is the only change.
            swiftSettings: [ .swiftLanguageMode(.v5) ]
        ),
        .testTarget(
            name: "HydraTests",
            dependencies: ["Hydra"],
            path: "Tests/HydraTests",
            swiftSettings: [ .swiftLanguageMode(.v5) ]
        ),
    ]
)
