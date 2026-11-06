// swift-tools-version: 5.9
import PackageDescription

// Pure Swift, no Apple-only frameworks: builds and tests on Windows (see CLAUDE.md).
let package = Package(
    name: "NullViewCore",
    products: [.library(name: "NullViewCore", targets: ["NullViewCore"])],
    targets: [
        .target(name: "NullViewCore"),
        .testTarget(name: "NullViewCoreTests", dependencies: ["NullViewCore"]),
    ]
)
