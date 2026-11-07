// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AirDial",
    platforms: [.macOS(.v12)],
    targets: [
        // Pure gesture logic (no camera, no AppKit) so it can be unit-tested.
        .target(name: "AirDialCore"),
        // The macOS app: camera + Apple Vision hand pose + media control + preview window.
        .executableTarget(
            name: "AirDial",
            dependencies: ["AirDialCore"],
            linkerSettings: [
                // Embed Info.plist (camera usage description) into the binary.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Support/Info.plist",
                ]),
            ]
        ),
        .testTarget(name: "AirDialCoreTests", dependencies: ["AirDialCore"]),
    ]
)
