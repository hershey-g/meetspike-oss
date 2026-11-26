// swift-tools-version: 5.9
import PackageDescription

#if os(Linux)
let sqlite: Target = .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])])
#else
let sqlite: Target = .systemLibrary(name: "CSQLite")
#endif

let package = Package(
    name: "MeetspikeHRCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "MeetspikeHRCore", targets: ["MeetspikeHRCore"])],
    targets: [
        sqlite,
        .target(name: "MeetspikeHRCore", dependencies: ["CSQLite"], exclude: ["API/CONTRACT.md"]),
        .testTarget(
            name: "MeetspikeHRCoreTests",
            dependencies: ["MeetspikeHRCore", "CSQLite"],
            resources: [.copy("Fixtures")]
        )
    ]
)
