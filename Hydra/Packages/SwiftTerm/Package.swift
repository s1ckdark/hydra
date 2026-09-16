// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SwiftTerm",
    platforms: [.iOS(.v17), .macOS("15.0")],
    products: [.library(name: "SwiftTerm", targets: ["SwiftTerm"])],
    targets: [
        .target(name: "SwiftTerm", exclude: ["Mac/README.md"],
                resources: [.process("Apple/Metal/Shaders.metal")]),
        .testTarget(name: "SwiftTermInputTests", dependencies: ["SwiftTerm"])
    ],
    swiftLanguageVersions: [.v5]
)
