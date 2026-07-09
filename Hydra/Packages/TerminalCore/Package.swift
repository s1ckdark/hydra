// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "TerminalCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SSHTransport",        targets: ["SSHTransport"]),
        .library(name: "SSHTransportMac",     targets: ["SSHTransportMac"]),
        .library(name: "KnownHosts",           targets: ["KnownHosts"]),
    ],
    dependencies: [
        // Shout itself is vendored below (Sources/Shout + Sources/CSSH) rather than
        // taken as a remote dependency: iWorks/terminal's working LibSSH2Session relies
        // on a Shout patch (shell/PTY Channel API + this repo's host-key accessor) that
        // upstream jakeheis/Shout 0.5.7 doesn't have, and terminal's copy of that patch
        // only exists as an uncommitted edit inside its local SPM checkout
        // (.build/checkouts/Shout) — not reproducible from a clean `swift build`.
        // BlueSocket is Shout's own (unpatched) socket dependency.
        .package(url: "https://github.com/IBM-Swift/BlueSocket", from: "1.0.200"),
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
            // Shout's API takes non-Sendable closures/types (SSH, Channel aren't
            // marked Sendable). Compile in Swift 5 mode so the strict-concurrency
            // checker doesn't reject the bridging code.
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
        .target(name: "KnownHosts"),
    ]
)
