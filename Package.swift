// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Ryokuon",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Ryokuon",
            path: "Sources/Ryokuon",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist",
                ])
            ]
        ),
        .testTarget(
            name: "RyokuonTests",
            dependencies: ["Ryokuon"],
            path: "Tests/RyokuonTests"
        ),
    ]
)
