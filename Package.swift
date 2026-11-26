// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "MRIViewer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MRIViewer", targets: ["MRIViewer"]),
        .executable(name: "mritool", targets: ["mritool"]),
        .library(name: "MRICore", targets: ["MRICore"]),
    ],
    targets: [
        // OpenJPEG 2.5.3 (BSD-2-Clause), vendored: Apple's ImageIO decodes 12/16-bit
        // JPEG 2000 at 8 bits, which silently destroys medical image precision.
        .target(
            name: "COpenJPEG",
            exclude: ["LICENSE", "VENDORED.md"],
            cSettings: [
                .unsafeFlags(["-w"]), // third-party code; keep build output clean
            ]
        ),
        .target(name: "MRICore", dependencies: ["COpenJPEG"]),
        .executableTarget(name: "mritool", dependencies: ["MRICore"]),
        .executableTarget(name: "MRIViewer", dependencies: ["MRICore"]),
        .testTarget(name: "MRICoreTests", dependencies: ["MRICore"]),
    ],
    swiftLanguageVersions: [.v5]
)
