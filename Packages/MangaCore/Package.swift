// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MangaCore",
    platforms: [.macOS("26.0"), .iOS("26.0"), .visionOS("26.0")],
    products: [.library(name: "MangaCore", targets: ["MangaCore"]),
               .executable(name: "manga-probe", targets: ["MangaProbe"])],
    dependencies: [.package(url: "https://github.com/groue/GRDB.swift.git", from: "7.11.1")],
    targets: [
        .target(name: "MangaCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")],
                resources: [.copy("Resources")]),
        .executableTarget(name: "MangaProbe", dependencies: ["MangaCore"]),
        .testTarget(name: "MangaCoreTests", dependencies: ["MangaCore"])
    ]
)
