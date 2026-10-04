// swift-tools-version:6.0
// steamac-vm: AppKit/Metal launcher for libkrun v1.19.6 (C API).
// libkrun headers/dylib location is supplied by build.sh (-Xcc -I / -Xlinker -L / rpath).
import PackageDescription

let package = Package(
    name: "steamac-vm",
    platforms: [.macOS(.v15)],
    targets: [
        .systemLibrary(name: "CKrun", path: "Sources/CKrun"),
        // zstd decoder (sources fetched by fetch-zstd.sh into Sources/CZstd/zstd, included by czstd.c).
        .target(name: "CZstd", path: "Sources/CZstd", exclude: ["zstd"]),
        .executableTarget(
            name: "steamac-vm",
            dependencies: ["CKrun", "CZstd"],
            path: "Sources/steamac-vm",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("GameController"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Carbon"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("Security"),
            ]
        ),
    ],
    swiftLanguageModes: [.v5]
)
