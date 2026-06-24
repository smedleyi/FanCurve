// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FanCurve",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "FanCurve",
            path: "Sources/FanCurve"
        )
    ]
)
