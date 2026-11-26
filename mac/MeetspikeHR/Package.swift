// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MeetspikeHR",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "MeetspikeHR", targets: ["MeetspikeHR"])],
    dependencies: [.package(path: "../../shared/MeetspikeHRCore")],
    targets: [
        .executableTarget(name: "MeetspikeHR", dependencies: [
            .product(name: "MeetspikeHRCore", package: "MeetspikeHRCore")
        ])
    ]
)
