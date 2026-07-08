// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SSHTransport",        targets: ["SSHTransport"]),
        .library(name: "SSHTransportCitadel",  targets: ["SSHTransportCitadel"]),
        .library(name: "KnownHosts",           targets: ["KnownHosts"]),
    ],
    dependencies: [
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.9.2"),
    ],
    targets: [
        .target(name: "SSHTransport"),
        .target(
            name: "SSHTransportCitadel",
            dependencies: ["SSHTransport", .product(name: "Citadel", package: "Citadel")],
            swiftSettings: [ .swiftLanguageMode(.v5) ]   // Citadel API는 non-Sendable — 원본과 동일 posture
        ),
        .target(name: "KnownHosts"),
    ]
)
