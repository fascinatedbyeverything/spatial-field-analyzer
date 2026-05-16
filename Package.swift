// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "spatial-field-analyzer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "analyze-bed", targets: ["analyze-bed"]),
    ],
    targets: [
        .executableTarget(name: "analyze-bed", path: "Sources/analyze-bed"),
    ]
)
