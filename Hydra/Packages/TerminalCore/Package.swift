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
        // Explicit direct deps for CitadelSession's host-key-capture patch (C1), which
        // imports NIOCore/NIOSSH/Crypto directly rather than relying on them transitively
        // through the Citadel product.
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "SSHTransport"),
        .target(
            name: "SSHTransportCitadel",
            dependencies: [
                "SSHTransport",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v5) ]   // Citadel API는 non-Sendable — 원본과 동일 posture
        ),
        .target(name: "KnownHosts"),
    ]
)
