// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SopranoGit",
    platforms: [.macOS(.v14)],
    targets: [
        // Git engine: runs the git CLI and parses its output. Foundation only, no AppKit.
        .target(
            name: "SopranoGitCore",
            path: "Sources/SopranoGitCore"
        ),
        .executableTarget(
            name: "SopranoGit",
            dependencies: ["SopranoGitCore"],
            path: "Sources/SopranoGit",
            exclude: ["Vendored/SOPRANO_COMMIT"],
            resources: [
                .copy("Resources/DepartureMono-Regular.woff2"),
                .copy("Resources/AppIcon.icns"),
            ],
            linkerSettings: [
                .linkedFramework("CoreText"),
                .linkedFramework("CoreServices"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(
            name: "SopranoGitTests",
            dependencies: ["SopranoGit", "SopranoGitCore"],
            path: "Tests/SopranoGitTests",
            swiftSettings: [
                .unsafeFlags(["-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks"]),
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                ]),
                .linkedFramework("Testing"),
            ]
        ),
    ]
)
