// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v15), .iOS(.v17)],
    products: [
        .library(name: "SSHTransport",         targets: ["SSHTransport"]),
        .library(name: "SSHTransportMac",      targets: ["SSHTransportMac"]),
        .library(name: "SSHTransportCitadel",  targets: ["SSHTransportCitadel"]),
        .library(name: "KnownHosts",           targets: ["KnownHosts"]),
    ],
    dependencies: [
        // libssh2 (macOS backend) — 벤더링된 Shout의 소켓 의존
        .package(url: "https://github.com/IBM-Swift/BlueSocket", from: "1.0.200"),
        // Citadel (pure-Swift backend) — CitadelSession의 C1 호스트키 캡처 패치가
        // NIOCore/NIOSSH/Crypto를 직접 import 하므로 명시적 직접 의존으로 선언.
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.9.2"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.81.0"),
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.12.3"),
    ],
    targets: [
        .target(name: "SSHTransport"),
        .systemLibrary(name: "CSSH", pkgConfig: "libssh2", providers: [.brew(["libssh2", "openssl"])]),
        .target(
            name: "Shout",
            dependencies: [
                "CSSH",
                .product(name: "Socket", package: "BlueSocket"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v5) ]
        ),
        .target(
            name: "SSHTransportMac",
            dependencies: [
                "SSHTransport",
                "Shout",
            ],
            swiftSettings: [ .swiftLanguageMode(.v5) ]
        ),
        .target(
            name: "SSHTransportCitadel",
            dependencies: [
                "SSHTransport",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSH", package: "swift-nio-ssh"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            swiftSettings: [ .swiftLanguageMode(.v5) ]
        ),
        .target(name: "KnownHosts"),
    ]
)
